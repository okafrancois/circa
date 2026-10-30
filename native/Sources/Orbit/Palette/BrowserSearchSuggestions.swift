import BrowserCore
import Foundation

/// One palette's cancellable remote work. Local ranking never awaits this task.
@MainActor
final class BrowserSearchSuggestions {
    private let session: URLSession
    private let endpoint: (SearchEngine, String) -> URL?
    private let debounce: Duration
    private var task: Task<Void, Never>?
    private var revision = UUID()
    private var key: RequestKey?
    private var hidden: [SearchEngine: Set<String>] = [:]
    private(set) var values: [String] = []
    var onChange: (() -> Void)?

    init(configuration: URLSessionConfiguration = .ephemeral, debounce: Duration = .milliseconds(180),
         endpoint: @escaping (SearchEngine, String) -> URL? = { engine, query in
             // Unit-test palettes must opt into an injected, offline transport.
             guard !ProcessInfo.processInfo.arguments.contains(where: { $0.contains(".xctest") }) else { return nil }
             return engine.suggestionURL(for: query)
         }) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        session = URLSession(configuration: configuration, delegate: SuggestionSessionDelegate(), delegateQueue: nil)
        self.debounce = debounce
        self.endpoint = endpoint
    }

    deinit { task?.cancel(); session.invalidateAndCancel() }

    func update(query: String, engine: SearchEngine, profileID: ProfileID, enabled: Bool, isPrivate: Bool) {
        guard enabled, !isPrivate,
              case .search(_, let text) = try? AddressResolver(searchEngine: engine).resolve(query),
              case .search = try? AddressResolver(searchEngine: engine).resolve(text),
              let url = endpoint(engine, text) else { cancel(); return }
        let next = RequestKey(query: text, engine: engine, profileID: profileID)
        guard next != key else { return }
        cancel()
        key = next
        let token = revision
        let session = session, delay = debounce
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
                request.httpShouldHandleCookies = false
                request.setValue("application/x-suggestions+json, application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                guard !Task.isCancelled, let self, revision == token,
                      let response = response as? HTTPURLResponse, response.statusCode == 200 else { return }
                values = Self.parse(data, query: next.query).filter { !(hidden[engine]?.contains(Self.identity($0)) ?? false) }
                onChange?()
            } catch { /* Suggestions are optional; local results remain available. */ }
        }
    }

    func cancel() {
        revision = UUID()
        task?.cancel()
        task = nil
        key = nil
        let changed = !values.isEmpty
        values = []
        if changed { onChange?() }
    }

    func hide(_ value: String, engine: SearchEngine) {
        hidden[engine, default: []].insert(Self.identity(value))
        values.removeAll { Self.identity($0) == Self.identity(value) }
        onChange?()
    }

    func waitForResults() async { await task?.value }

    nonisolated static func identity(_ text: String) -> String {
        BrowserSuggestionText.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated static func parse(_ data: Data, query: String) -> [String] {
        guard data.count <= 65_536,
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any], array.count >= 2,
              let echoedQuery = array[0] as? String, identity(echoedQuery) == identity(query),
              let strings = array[1] as? [String] else { return [] }
        var seen: Set<String> = []
        return Array(strings.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 512, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seen.insert(identity(value)).inserted else { return nil }
            return value
        }.prefix(8))
    }

    private struct RequestKey: Equatable {
        let query: String
        let engine: SearchEngine
        let profileID: ProfileID
    }
}

private final class SuggestionSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    // Redirects must never forward the draft to another endpoint, or ask for credentials.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
