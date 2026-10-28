import Foundation

/// Functional URL templates for the default site catalog.
/// No icons, remote suggestions, profile discovery or custom-engine import are needed here.
struct BrowserPaletteSiteSearch: Equatable {
    let name: String
    let aliases: [String]
    let template: String

    static let sites: [Self] = [
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
        .init(name: "X", aliases: ["x", "x.com"], template: "https://x.com/search?q=%s"),
        .init(name: "Twitter", aliases: ["twitter", "twitter.com"], template: "https://twitter.com/search?q=%s"),
        .init(name: "YouTube", aliases: ["youtube", "youtube.com"], template: "https://www.youtube.com/results?search_query=%s"),
        .init(name: "Wikipedia", aliases: ["wikipedia", "wikipedia.org", "en.wikipedia.org"], template: "https://wikipedia.org/w/index.php?search=%s"),
        .init(name: "Reddit", aliases: ["reddit", "reddit.com"], template: "https://www.reddit.com/search/?q=%s"),
        .init(name: "SoundCloud", aliases: ["soundcloud", "soundcloud.com"], template: "https://soundcloud.com/search?q=%s"),
        .init(name: "Asana", aliases: ["asana", "asana.com", "app.asana.com"], template: "https://app.asana.com/0/search?q=%s"),
        .init(name: "LinkedIn", aliases: ["linkedin", "linkedin.com"], template: "https://linkedin.com/search/results/all/?keywords=%s"),
        .init(name: "Apple Music", aliases: ["apple music", "music.apple.com"], template: "https://music.apple.com/us/search?term=%s"),
        .init(name: "Spotify", aliases: ["spotify", "spotify.com", "open.spotify.com"], template: "https://open.spotify.com/search/%s")
    ]

    static func matching(_ input: String) -> Self? {
        var keyword = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "www."] where keyword.hasPrefix(prefix) {
            keyword.removeFirst(prefix.count)
        }
        if keyword.hasSuffix("/") { keyword.removeLast() }
        return sites.first { $0.aliases.contains(keyword) }
    }

    func url(for query: String) -> URL? {
        // One opaque component works for query, path and fragment templates. In particular,
        // '+', '&', '#', '/' and '%' can never change the destination or split parameters.
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    func results(query: String) -> [BrowserPaletteResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = url(for: text) else { return [] }
        return [.init(id: "site-search", title: text, detail: uiFormat("Search %@", uiText(name)),
                      section: .search, action: .navigate(url))]
    }
}
