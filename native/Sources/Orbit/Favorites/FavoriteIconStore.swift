import Foundation
import BrowserCore
import BrowserEngine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Profile-local favicon pixels. Chromium's authenticated image wins; dormant favorites can
/// discover a public icon using an anonymous session with no shared cookies or credentials.
actor FavoriteIconStore {
    private let directory: URL?
    private let session: URLSession
    private var images = BrowserCostCache<String, BrowserFaviconImage>(budget: 4 * 1024 * 1024)
    private var pending: [String: Task<BrowserFaviconImage?, Never>] = [:]
    private var failures = BrowserCostCache<String, Date>(budget: 128 * 1024, countLimit: 512)
    private var removedProfiles = Set<ProfileID>()

    init(directory: URL? = nil) {
        self.directory = directory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    func image(profile: ProfileID, home: URL) async -> BrowserFaviconImage? {
        guard !removedProfiles.contains(profile), let origin = Self.origin(home) else { return nil }
        let key = profile.rawValue.uuidString + "/" + origin.absoluteString
        if let image = cachedImage(profile: profile, home: home) { return image }
        if let failure = failures.value(for: key), Date().timeIntervalSince(failure) < 600 { return nil }
        if let task = pending[key] { return await task.value }
        let session = session
        let task = Task { await Self.discover(home: origin, session: session) }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        guard !removedProfiles.contains(profile) else { return nil }
        // A Chromium image may have arrived while public discovery was in flight, then
        // left the memory budget. The persisted owned image still takes precedence.
        if let image = cachedImage(profile: profile, home: home) { return image }
        if let result { put(result, profile: profile, home: home) }
        else { failures.insert(Date(), for: key, cost: key.utf8.count + 64) }
        return result
    }

    func cachedImage(profile: ProfileID, home: URL) -> BrowserFaviconImage? {
        guard !removedProfiles.contains(profile), let origin = Self.origin(home) else { return nil }
        let key = profile.rawValue.uuidString + "/" + origin.absoluteString
        if let image = images.value(for: key) { return image }
        if let file = file(profile: profile, origin: origin),
           let data = try? Data(contentsOf: file),
           let image = BrowserFaviconImage(sourceURL: origin, png: data) {
            images.insert(image, for: key, cost: image.png.count + key.utf8.count + 256)
            return image
        }
        return nil
    }

    func put(_ image: BrowserFaviconImage, profile: ProfileID, home: URL) {
        guard !removedProfiles.contains(profile), let origin = Self.origin(home) else { return }
        let key = profile.rawValue.uuidString + "/" + origin.absoluteString
        images.insert(image, for: key, cost: image.png.count + key.utf8.count + 256)
        failures.remove(key)
        guard let file = file(profile: profile, origin: origin) else { return }
        // Compare the actual persisted bytes: failed writes remain retryable, and a reopened
        // cache also avoids replacing the inode for an identical engine notification.
        if (try? Data(contentsOf: file)) == image.png { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try image.png.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* A disposable cache must never interrupt navigation or session saving. */ }
    }

    func remove(profile: ProfileID) throws {
        removedProfiles.insert(profile)
        let prefix = profile.rawValue.uuidString + "/"
        for key in Array(pending.keys) where key.hasPrefix(prefix) { pending.removeValue(forKey: key)?.cancel() }
        for key in images.keys where key.hasPrefix(prefix) { images.remove(key) }
        for key in failures.keys where key.hasPrefix(prefix) { failures.remove(key) }
        if let folder = directory?.appendingPathComponent(profile.rawValue.uuidString),
           FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    func releaseMemory() {
        images.removeAll()
        failures.removeAll()
    }

    nonisolated func cachedFile(profile: ProfileID, home: URL) -> URL? {
        guard let origin = Self.origin(home) else { return nil }
        return file(profile: profile, origin: origin)
    }

    var cacheStatistics: [String: Int] {
        ["entries": images.count, "bytes": images.cost,
         "failures": failures.count, "pending": pending.count]
    }

    nonisolated private func file(profile: ProfileID, origin: URL) -> URL? {
        let name = SHA256.hash(data: Data(origin.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(profile.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent(name + ".png")
    }

    nonisolated static func origin(_ url: URL) -> URL? {
        guard ["https", "http"].contains(url.scheme?.lowercased()), url.host != nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.user = nil; parts.password = nil; parts.path = "/"; parts.query = nil; parts.fragment = nil
        return parts.url
    }

    private static func discover(home: URL, session: URLSession) async -> BrowserFaviconImage? {
        var candidates: [URL] = []
        if let (data, finalURL) = await bytes(home, session: session),
           let html = String(data: data, encoding: .utf8) {
            candidates = iconURLs(html: html, base: finalURL)
        }
        candidates.append(home.appendingPathComponent("favicon.ico"))
        var seen = Set<URL>()
        for url in candidates.prefix(12) where seen.insert(url).inserted {
            guard !Task.isCancelled else { return nil }
            if let (data, _) = await bytes(url, session: session), let image = decode(data, source: url) { return image }
        }
        return nil
    }

    /// HTML discovery keeps declared CDN icons and relative paths, ignoring non-web schemes.
    static func iconURLs(html: String, base: URL) -> [URL] {
        guard let tags = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive),
              let attributes = try? NSRegularExpression(pattern: #"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [] }
        let source = html as NSString
        return tags.matches(in: html, range: NSRange(location: 0, length: source.length)).compactMap { tag in
            let text = source.substring(with: tag.range) as NSString
            var values: [String: String] = [:]
            for attribute in attributes.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let value = (2...4).first { attribute.range(at: $0).location != NSNotFound }!
                values[text.substring(with: attribute.range(at: 1)).lowercased()] = text.substring(with: attribute.range(at: value))
            }
            guard let rel = values["rel"]?.lowercased().split(whereSeparator: \.isWhitespace),
                  rel.contains("icon") || rel.contains("apple-touch-icon"), let href = values["href"],
                  let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL,
                  origin(url) != nil, url.pathExtension.lowercased() != "svg" else { return nil }
            return url
        }
    }

    private static func bytes(_ url: URL, session: URLSession) async -> (Data, URL)? {
        guard origin(url) != nil, url.user == nil, url.password == nil else { return nil }
        do {
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  response.expectedContentLength <= 524_288, let final = response.url, origin(final) != nil else { return nil }
            var data = Data()
            for try await byte in stream {
                guard !Task.isCancelled, data.count < 524_288 else { return nil }
                data.append(byte)
            }
            return (data, final)
        } catch { return nil }
    }

    static func decode(_ data: Data, source url: URL) -> BrowserFaviconImage? {
        guard data.count <= 524_288,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: BrowserFaviconImage.maximumDimension,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return BrowserFaviconImage(sourceURL: url, png: png as Data)
    }
}
