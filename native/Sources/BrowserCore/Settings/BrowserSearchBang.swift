import Foundation

/// An inline site search, independent of the palette's explicit Tab scope.
public struct BrowserSearchBang: Equatable, Sendable {
    public let site: BrowserSiteSearch
    public let query: String
    public let url: URL

    /// Only edge tokens are commands. The leading token wins, including when unknown.
    public static func parse(_ input: String, entries: [BrowserSiteSearch] = BrowserSiteSearch.builtIns,
                             preferredLanguages: [String] = Locale.preferredLanguages) -> Self? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard let first = tokens.first, let last = tokens.last else { return nil }
        let leading = first.hasPrefix("!")
        let token = leading ? first : last
        guard token.hasPrefix("!"), token.count > 1 else { return nil }
        let keyword = String(token.dropFirst()).lowercased()
        let query = (leading ? String(text.dropFirst(token.count)) : String(text.dropLast(token.count)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // User shortcuts win over both editable defaults and the compact built-in vocabulary.
        let configured = entries.first { !$0.isBuiltIn && $0.aliases.contains(keyword) }
            ?? entries.first { $0.aliases.contains(keyword) }
        let builtIn = builtIns(preferredLanguages: preferredLanguages).first { $0.site.shortcut == keyword }
        let site: BrowserSiteSearch
        let home: URL?
        if let configured {
            guard configured.isEnabled else { return nil }
            site = configured
            home = configured.isBuiltIn && configured.template == builtIn?.site.template ? builtIn?.home : homeURL(for: configured)
        } else {
            guard let builtIn else { return nil }
            site = builtIn.site
            home = builtIn.home
        }
        guard let url = query.isEmpty ? home : site.url(for: query) else { return nil }
        return .init(site: site, query: query, url: url)
    }

    private static func homeURL(for site: BrowserSiteSearch) -> URL? {
        guard var parts = site.url(for: "").flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        parts.path = "/"; parts.query = nil; parts.fragment = nil
        return parts.url
    }

    private struct BuiltIn {
        let site: BrowserSiteSearch
        let home: URL?
        init(_ keyword: String, _ name: String, _ template: String, home: String? = nil) {
            site = .init(id: "bang." + keyword, name: name, shortcut: keyword, template: template)
            self.home = home.flatMap(URL.init(string:)) ?? BrowserSearchBang.homeURL(for: site)
        }
    }

    private static func builtIns(preferredLanguages: [String]) -> [BuiltIn] {
        let code = preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        let language = code.flatMap { Locale.LanguageCode.isoLanguageCodes.contains(Locale.LanguageCode($0)) ? $0 : nil } ?? "en"
        return [
            .init("g", "Google", "https://www.google.com/search?q=%s"),
            .init("ddg", "DuckDuckGo", "https://duckduckgo.com/?q=%s"),
            .init("b", "Bing", "https://www.bing.com/search?q=%s"),
            .init("gh", "GitHub", "https://github.com/search?q=%s"),
            .init("w", "Wikipedia", "https://\(language).wikipedia.org/w/index.php?search=%s"),
            .init("yt", "YouTube", "https://www.youtube.com/results?search_query=%s"),
            .init("maps", "Google Maps", "https://www.google.com/maps/search/%s", home: "https://www.google.com/maps"),
            .init("gi", "Google Images", "https://www.google.com/search?tbm=isch&q=%s", home: "https://images.google.com/"),
            .init("gn", "Google News", "https://news.google.com/search?q=%s"),
            .init("r", "Reddit", "https://www.reddit.com/search/?q=%s"),
            .init("so", "Stack Overflow", "https://stackoverflow.com/search?q=%s"),
            .init("mdn", "MDN", "https://developer.mozilla.org/search?q=%s"),
            .init("npm", "npm", "https://www.npmjs.com/search?q=%s"),
            .init("pypi", "PyPI", "https://pypi.org/search/?q=%s"),
            .init("hn", "Hacker News", "https://hn.algolia.com/?q=%s", home: "https://news.ycombinator.com/"),
            .init("imdb", "IMDb", "https://www.imdb.com/find/?q=%s"),
            .init("wa", "Wolfram Alpha", "https://www.wolframalpha.com/input?i=%s"),
            .init("tr", "Google Translate", "https://translate.google.com/?text=%s"),
            .init("a", "Amazon", "https://www.amazon.com/s?k=%s"),
            .init("x", "X", "https://x.com/search?q=%s")
        ]
    }
}
