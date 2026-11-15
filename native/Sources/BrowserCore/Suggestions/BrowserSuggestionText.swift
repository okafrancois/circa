import Foundation

/// Shared local matching policy. Display strings never become navigation authorities.
public enum BrowserSuggestionText {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    /// Display form of a URL: decoded, credential-free and with invisible controls escaped.
    /// The host is Unicode only where `BrowserHostDisplay` deems it safe; otherwise ASCII.
    public static func displayURL(_ url: URL) -> String {
        safeDisplay(readableURL(url))
    }

    /// Decoded, credential-free URL text without display escaping, with the display host.
    static func readableURL(_ url: URL) -> String {
        urlText(url) { BrowserHostDisplay.displayHost($0) }
    }

    /// Path, query and fragment are percent-decoded; the host comes from `host`.
    private static func urlText(_ url: URL, host: (URLComponents) -> String?) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.user = nil
        components.password = nil
        let host = host(components) ?? url.host ?? ""
        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        let query = components.percentEncodedQuery.map { "?" + ($0.removingPercentEncoding ?? $0) } ?? ""
        let fragment = components.percentEncodedFragment.map { "#" + ($0.removingPercentEncoding ?? $0) } ?? ""
        return "\(components.scheme ?? "https")://\(host)\(port)\(path)\(query)\(fragment)"
    }

    /// Keep invisible controls visible. This is display-only: never navigate or index the escaped
    /// text. Only C0/C1 controls (Cc) and bidi controls (Bidi_Control: ALM, LRM/RLM, embeddings,
    /// overrides and isolates) are escaped. Other format characters such as ZWNJ, ZWJ and the soft
    /// hyphen are required by real scripts and stay as they are.
    public static func safeDisplay(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if scalar.properties.generalCategory == .control || scalar.properties.isBidiControl {
                return String(format: "\\u{%04X}", scalar.value)
            }
            return String(scalar)
        }.joined()
    }

    /// Matching and persisted search columns use the ASCII (IDNA) host, so an ASCII query never
    /// matches a diacritic or lookalike host as if it were the same site, and indexing never
    /// depends on display policy.
    public static func searchableURL(_ url: URL) -> String {
        var text = urlText(url) { BrowserHostDisplay.asciiHost($0) }
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if text.lowercased().hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return fold(text)
    }

    public static func terms(_ query: String) -> [String] {
        fold(query.removingPercentEncoding ?? query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func matches(_ query: String, title: String, url: URL? = nil) -> Bool {
        let text = fold(title) + " " + (url.map(searchableURL) ?? "")
        return terms(query).allSatisfy { text.contains($0) }
    }
}
