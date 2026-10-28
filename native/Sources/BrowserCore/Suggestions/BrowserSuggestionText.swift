import Foundation

/// Shared local matching policy. Display strings never become navigation authorities.
public enum BrowserSuggestionText {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    /// Display form of a URL: decoded, credential-free and with invisible controls escaped.
    public static func displayURL(_ url: URL) -> String {
        safeDisplay(readableURL(url))
    }

    /// Decoded, credential-free URL text without display escaping. Matching and persisted
    /// search columns use this form so that indexing never depends on display policy.
    static func readableURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.user = nil
        components.password = nil
        // Foundation's host accessor decodes IDNA; decoded text is for reading and matching, never navigation.
        let host = components.host ?? url.host ?? ""
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

    public static func searchableURL(_ url: URL) -> String {
        var text = readableURL(url)
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
