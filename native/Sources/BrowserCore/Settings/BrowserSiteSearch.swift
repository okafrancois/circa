import Foundation

/// App-wide, device-local shortcuts. Built-in identity is independent of editable fields.
public struct BrowserSiteSearch: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var shortcut: String
    public var template: String
    public var isEnabled: Bool
    public var isBuiltIn: Bool { id.hasPrefix("builtin.") && Self.extraAliases[String(id.dropFirst("builtin.".count))] != nil }

    public init(id: String = UUID().uuidString, name: String, shortcut: String, template: String, isEnabled: Bool = true) {
        self.id = id; self.name = name; self.shortcut = shortcut; self.template = template; self.isEnabled = isEnabled
    }

    private struct BuiltIn {
        let name: String
        let aliases: [String]
        let template: String
    }

    private static let defaults: [BuiltIn] = [
        .init(name: "Google", aliases: ["google", "google.com"], template: "https://www.google.com/search?q=%s"),
        .init(name: "DuckDuckGo", aliases: ["duckduckgo", "duckduckgo.com"], template: "https://duckduckgo.com/?q=%s"),
        .init(name: "Bing", aliases: ["bing", "bing.com"], template: "https://www.bing.com/search?q=%s"),
        .init(name: "Yahoo", aliases: ["yahoo", "yahoo!", "yahoo.com", "search.yahoo.com"], template: "https://search.yahoo.com/search?p=%s"),
        .init(name: "Ecosia", aliases: ["ecosia", "ecosia.org"], template: "https://www.ecosia.org/search?q=%s"),
        .init(name: "Yandex", aliases: ["yandex", "yandex.com"], template: "https://yandex.com/search/?text=%s"),
        .init(name: "Google Drive", aliases: ["drive", "google drive", "drive.google.com"], template: "https://drive.google.com/drive/search?q=%s"),
        .init(name: "Gmail", aliases: ["gmail", "gmail.com", "mail.google.com"], template: "https://mail.google.com/mail/ca/u/0/#apps/%s"),
        .init(name: "Google Maps", aliases: ["maps", "google maps", "maps.google.com"], template: "https://www.google.com/maps/search/%s"),
        .init(name: "Google Calendar", aliases: ["calendar", "google calendar", "calendar.google.com"], template: "https://calendar.google.com/calendar/u/0/r/search?q=%s"),
        .init(name: "Google Docs", aliases: ["docs", "google docs", "docs.google.com"], template: "https://docs.google.com/document/u/0/?q=%s"),
        .init(name: "Dropbox", aliases: ["dropbox", "dropbox.com"], template: "https://www.dropbox.com/search/personal?&query=%s"),
        .init(name: "Amazon", aliases: ["amazon", "amazon.com"], template: "https://www.amazon.com/s?k=%s"),
        .init(name: "GitHub", aliases: ["github", "github.com"], template: "https://github.com/search?q=%s"),
        .init(name: "Figma", aliases: ["figma", "figma.com"], template: "https://www.figma.com/files/search?q=%s"),
        .init(name: "X", aliases: ["x", "x.com", "twitter", "twitter.com"], template: "https://x.com/search?q=%s"),
        .init(name: "YouTube", aliases: ["youtube", "youtube.com"], template: "https://www.youtube.com/results?search_query=%s"),
        .init(name: "Wikipedia", aliases: ["wikipedia", "wikipedia.org", "en.wikipedia.org"], template: "https://wikipedia.org/w/index.php?search=%s"),
        .init(name: "Reddit", aliases: ["reddit", "reddit.com"], template: "https://www.reddit.com/search/?q=%s"),
        .init(name: "SoundCloud", aliases: ["soundcloud", "soundcloud.com"], template: "https://soundcloud.com/search?q=%s"),
        .init(name: "Asana", aliases: ["asana", "asana.com", "app.asana.com"], template: "https://app.asana.com/0/search?q=%s"),
        .init(name: "LinkedIn", aliases: ["linkedin", "linkedin.com"], template: "https://linkedin.com/search/results/all/?keywords=%s"),
        .init(name: "Apple Music", aliases: ["apple music", "music.apple.com"], template: "https://music.apple.com/us/search?term=%s"),
        .init(name: "Spotify", aliases: ["spotify", "spotify.com", "open.spotify.com"], template: "https://open.spotify.com/search/%s")
    ]

    public static let builtIns: [Self] = defaults.map {
        .init(id: "builtin." + $0.aliases[0], name: $0.name, shortcut: $0.aliases[0], template: $0.template)
    }

    // Host/name aliases retain compatibility when a built-in shortcut is edited.
    private static let extraAliases = Dictionary(uniqueKeysWithValues: defaults.map {
        ($0.aliases[0], Array($0.aliases.dropFirst()))
    })
    public var aliases: [String] {
        let key = String(id.dropFirst("builtin.".count))
        return [Self.normalized(shortcut)] + (isBuiltIn ? Self.extraAliases[key] ?? [] : [])
    }

    public static func normalized(_ input: String) -> String {
        var keyword = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "www."] where keyword.hasPrefix(prefix) { keyword.removeFirst(prefix.count) }
        if keyword.hasSuffix("/") { keyword.removeLast() }
        return keyword
    }

    public static func matching(_ input: String, in entries: [Self] = builtIns) -> Self? {
        let keyword = normalized(input)
        return entries.first { $0.isEnabled && $0.aliases.contains(keyword) }
    }

    public func validate(in entries: [Self]) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BrowserSiteSearchError.emptyName }
        let key = Self.normalized(shortcut)
        guard !key.isEmpty, !shortcut.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }) else {
            throw BrowserSiteSearchError.emptyShortcut
        }
        guard !entries.contains(where: { $0.id != id && ($0.aliases.contains(key) || aliases.contains(Self.normalized($0.shortcut))) }) else {
            throw BrowserSiteSearchError.duplicateShortcut
        }
        // Keep the substitution out of the authority: a query cannot choose the host or scheme.
        guard template.contains("%s"), !template.contains(where: \.isWhitespace),
              let parts = URLComponents(string: template.replacingOccurrences(of: "%s", with: "orbitquerymarker")),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, !host.contains("orbitquerymarker"),
              parts.user == nil, parts.password == nil, parts.url != nil,
              parts.port == nil || (1...65535).contains(parts.port!) else { throw BrowserSiteSearchError.invalidTemplate }
    }

    public func url(for query: String) -> URL? {
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }
}

public enum BrowserSiteSearchError: Error, Equatable {
    case emptyName, emptyShortcut, duplicateShortcut, invalidTemplate, builtInRemoval, missingEntry
}
