import BrowserCore
import Foundation

struct BrowserLinkPreviewDocument: Equatable, Sendable {
    let title: String
    let description: String
    let text: String
    let url: URL?
    init(title: String, description: String, text: String, url: URL? = nil) {
        self.title = title; self.description = description; self.text = text; self.url = url
    }
}

/// Anonymous, bounded HTML only. Redirects are followed explicitly after policy revalidation.
@MainActor
final class BrowserLinkPreviewLoader {
    nonisolated static let maximumBytes = 262_144
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration, delegate: LinkPreviewTransport(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    nonisolated static func validURL(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
            && url.user == nil && url.password == nil && url.absoluteString.utf8.count <= 8192
    }

    func load(_ original: URL, allowed: @escaping @MainActor (URL) -> Bool) async throws -> BrowserLinkPreviewDocument {
        var next = original
        var visited: Set<URL> = []
        for _ in 0..<5 {
            try Task.checkCancellation()
            guard Self.validURL(next), allowed(next), visited.insert(next).inserted else { throw CancellationError() }
            var request = URLRequest(url: next, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            request.httpShouldHandleCookies = false
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard allowed(next), let response = response as? HTTPURLResponse else { throw CancellationError() }
            if [301, 302, 303, 307, 308].contains(response.statusCode),
               let location = response.value(forHTTPHeaderField: "Location"),
               let redirected = URL(string: location, relativeTo: next)?.absoluteURL {
                guard Self.validURL(redirected), allowed(redirected) else { throw CancellationError() }
                next = redirected
                continue
            }
            guard response.statusCode == 200, let mime = response.mimeType,
                  ["text/html", "application/xhtml+xml"].contains(mime),
                  response.expectedContentLength <= Self.maximumBytes else { throw BrowserAIError.failed }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumBytes else { throw BrowserAIError.failed }
                data.append(byte)
                if data.count % 1024 == 0 {
                    try Task.checkCancellation()
                    guard allowed(next) else { throw CancellationError() }
                }
            }
            try Task.checkCancellation()
            guard allowed(next) else { throw CancellationError() }
            let payload = data
            let document = await Task.detached(priority: .utility) { Self.parse(payload) }.value
            guard allowed(next), let document else { throw BrowserAIError.failed }
            return .init(title: document.title, description: document.description, text: document.text, url: next)
        }
        throw BrowserAIError.failed
    }

    nonisolated static func parse(_ data: Data) -> BrowserLinkPreviewDocument? {
        guard data.count <= maximumBytes, let html = String(data: data, encoding: .utf8) else { return nil }
        func capture(_ pattern: String, in value: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[range])
        }
        func replace(_ pattern: String, in value: String, with replacement: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
            return regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
        }
        func clean(_ value: String, limit: Int) -> String {
            var value = replace("(?s)<[^>]*>", in: value, with: " ")
            for (entity, text) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
                value = value.replacingOccurrences(of: entity, with: text)
            }
            value = replace("\\s+", in: value, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return String(value.prefix(limit))
        }
        let title = clean(capture("(?is)<title\\b[^>]*>(.*?)</title\\s*>", in: html) ?? "", limit: 240)
        let descriptionTag = capture("(?is)(<meta\\b(?=[^>]*(?:name|property)\\s*=\\s*[\"'](?:description|og:description)[\"'])[^>]*>)", in: html) ?? ""
        let description = clean(capture("(?is)content\\s*=\\s*\"([^\"]*)\"", in: descriptionTag)
            ?? capture("(?is)content\\s*=\\s*'([^']*)'", in: descriptionTag) ?? "", limit: 500)
        // Form contents, scripts, styles and non-rendered declarations are never model context.
        var body = capture("(?is)<body\\b[^>]*>(.*)</body\\s*>", in: html) ?? html
        body = replace("(?is)<!--(?:.*?-->|.*\\z)", in: body, with: " ")
        for tag in ["script", "style", "noscript", "template", "form", "textarea", "select", "head"] {
            body = replace("(?is)<\(tag)\\b[^>]*>(?:.*?</\(tag)\\s*>|.*\\z)", in: body, with: " ")
        }
        let text = clean(body, limit: 12_000)
        guard !text.isEmpty || !description.isEmpty else { return nil }
        return .init(title: title, description: description, text: text)
    }
}

private final class LinkPreviewTransport: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
