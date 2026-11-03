import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum BrowserGmailPreviewError: Error, Equatable, Sendable {
    case signedOut, invalidResponse, unavailable
}

/// An account selector belongs to one browser profile; it is never an authentication token.
public struct BrowserGmailAccount: Hashable, Sendable {
    public let selector: String

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              ["mail.google.com", "gmail.com", "www.gmail.com"].contains(host) else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let selectors = query.filter { $0.name == "authuser" }
        guard selectors.count <= 1 else { return nil }
        var candidate = "0"
        if host != "mail.google.com" {
            guard path.isEmpty else { return nil }
        } else if !path.isEmpty {
            guard path.first == "mail" else { return nil }
            if let index = path.firstIndex(of: "u") {
                guard (index == 1 || (index == 2 && path[1] == "ca")), path.indices.contains(index + 1) else { return nil }
                candidate = path[index + 1]
            } else if path != ["mail"] { return nil }
        }
        if let item = selectors.first {
            guard let querySelector = item.value else { return nil }
            candidate = querySelector
        }
        guard candidate.utf8.count <= 320,
              candidate.range(of: #"^(?:[0-9]{1,2}|[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+)$"#,
                              options: .regularExpression) != nil else { return nil }
        selector = Int(candidate).map(String.init) ?? candidate.lowercased()
    }

    public var inboxURL: URL {
        URL(string: "https://mail.google.com/mail/u/")!.appendingPathComponent(selector).appendingPathComponent("")
    }

    public var feedURL: URL { inboxURL.appendingPathComponent("feed").appendingPathComponent("atom") }

    public var composeURL: URL {
        var value = URLComponents(url: inboxURL, resolvingAgainstBaseURL: false)!
        value.fragment = "inbox?compose=new"
        return value.url!
    }

    public func messageURL(id: String) -> URL? {
        guard Self.validMessageID(id) else { return nil }
        var value = URLComponents(url: inboxURL, resolvingAgainstBaseURL: false)!
        value.fragment = "inbox/" + id
        return value.url
    }

    static func validMessageID(_ value: String) -> Bool {
        (1...32).contains(value.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}

public struct BrowserGmailMessage: Equatable, Sendable, Identifiable {
    public let id: String
    public let sender: String
    public let subject: String
    public let summary: String
    public let receivedAt: Date?

    public init(id: String, sender: String, subject: String, summary: String, receivedAt: Date?) {
        self.id = id; self.sender = sender; self.subject = subject; self.summary = summary; self.receivedAt = receivedAt
    }
}

/// Mail metadata is ephemeral: this model deliberately has no persistence conformance.
public struct BrowserGmailInbox: Equatable, Sendable {
    public let unreadCount: Int
    public let messages: [BrowserGmailMessage]

    public init(unreadCount: Int, messages: [BrowserGmailMessage]) {
        self.unreadCount = unreadCount; self.messages = messages
    }

    public static func decodeFeed(_ data: Data) throws -> Self {
        guard data.count <= 262_144, let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw BrowserGmailPreviewError.invalidResponse }
        let delegate = GmailFeedDecoder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.failed, delegate.rootSeen,
              let count = delegate.unreadCount, count >= delegate.entryCount,
              count == 0 || !delegate.messages.isEmpty else { throw BrowserGmailPreviewError.invalidResponse }
        return .init(unreadCount: count, messages: delegate.messages)
    }
}

private final class GmailFeedDecoder: NSObject, XMLParserDelegate {
    private(set) var rootSeen = false
    private(set) var failed = false
    private(set) var unreadCount: Int?
    private(set) var entryCount = 0
    private(set) var messages: [BrowserGmailMessage] = []
    private var path: [String] = []
    private var fields: [String: String] = [:]
    private var ids: Set<String> = []
    private var rootNamespace: String?
    private let acceptedFields: Set<String> = ["feed/fullcount", "feed/entry/id", "feed/entry/title",
        "feed/entry/summary", "feed/entry/issued", "feed/entry/modified", "feed/entry/author/name", "feed/entry/author/email"]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if path.isEmpty {
            guard !rootSeen, elementName == "feed",
                  ["http://purl.org/atom/ns#", "http://www.w3.org/2005/Atom"].contains(namespaceURI ?? "") else {
                reject(parser); return
            }
            rootSeen = true; rootNamespace = namespaceURI
        }
        path.append(elementName)
        guard path.count <= 12 else { reject(parser); return }
        if path == ["feed", "entry"] { fields = fields.filter { $0.key == "feed/fullcount" } }
        if acceptedFields.contains(path.joined(separator: "/")), namespaceURI != rootNamespace { reject(parser) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let key = path.joined(separator: "/")
        guard acceptedFields.contains(key) else { return }
        let value = (fields[key] ?? "") + string
        guard value.utf8.count <= 8_192 else { reject(parser); return }
        fields[key] = value
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { reject(parser); return }
        self.parser(parser, foundCharacters: text)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { if !path.isEmpty { path.removeLast() } }
        if path == ["feed", "fullcount"] {
            guard unreadCount == nil, let value = Int((fields["feed/fullcount"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
                  (0...1_000_000).contains(value) else { reject(parser); return }
            unreadCount = value
        }
        if path == ["feed", "entry"] {
            guard let raw = fields["feed/entry/id"], let suffix = raw.split(separator: ":").last else {
                reject(parser); return
            }
            let id = String(suffix).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard BrowserGmailAccount.validMessageID(id), ids.insert(id).inserted else { reject(parser); return }
            entryCount += 1
            if messages.count < 20 {
                let sender = clean(fields["feed/entry/author/name"] ?? fields["feed/entry/author/email"] ?? "", limit: 160)
                messages.append(.init(id: id, sender: sender,
                    subject: clean(fields["feed/entry/title"] ?? "", limit: 300),
                    summary: clean(fields["feed/entry/summary"] ?? "", limit: 400),
                    receivedAt: date(fields["feed/entry/issued"] ?? fields["feed/entry/modified"])))
            }
        }
    }

    private func clean(_ value: String, limit: Int) -> String {
        String(value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }

    private func date(_ value: String?) -> Date? {
        guard let raw = value else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private func reject(_ parser: XMLParser) { failed = true; parser.abortParsing() }
}
