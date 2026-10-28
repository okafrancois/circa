import Foundation

/// Byte-level history matching shared by the SQLite reader functions and the in-memory index,
/// so cached and complete results agree on membership, quality bonus and ordering.
/// Inputs are already folded (`BrowserSuggestionText.fold`), so comparisons are binary.
public enum BrowserHistoryMatching {
    /// Terms shorter than this use indexed prefix/word-start paths instead of substring search.
    public static let substringMinimumScalars = 3

    public struct Term: Sendable, Equatable {
        public let text: String
        public let bytes: [UInt8]
        public var isShort: Bool { text.unicodeScalars.count < BrowserHistoryMatching.substringMinimumScalars }
        /// A term led by punctuation already starts a token wherever it occurs.
        public var isSymbolLed: Bool { bytes.first.map(BrowserHistoryMatching.isSeparator) ?? false }
    }

    /// Short terms use prefix/word-start semantics only when they alone select candidates.
    /// Next to a long term (already selective) or when symbol-led, they stay literal substrings.
    public static func usesWordStart(_ term: Term, in terms: [Term]) -> Bool {
        term.isShort && !term.isSymbolLed && !terms.contains { !$0.isShort }
    }

    public static func terms(_ query: String) -> [Term] {
        BrowserSuggestionText.terms(query).map { raw in
            let text = raw.replacingOccurrences(of: "^https?://(www\\.)?|^www\\.", with: "", options: .regularExpression)
            return Term(text: text, bytes: Array(text.utf8))
        }
    }

    /// Frecency is unchanged from the original SQL ranking: visits plus typed weight, decayed weekly.
    public static func frecency(visits: Int, typed: Int, last: Double, now: Double) -> Double {
        (Double(visits) + Double(typed) * 4.0) / (1.0 + max(0, now - last) / 86400.0 / 7.0)
    }

    /// Host prefix or host word start (after `.`, `-` or another ASCII separator) earns 1000;
    /// a title word start earns 100. An occurrence elsewhere in the host earns nothing.
    public static func bonus(searchURL: UnsafeBufferPointer<UInt8>, searchTitle: UnsafeBufferPointer<UInt8>,
                             first: [UInt8]) -> Int {
        guard !first.isEmpty else { return 0 }
        let host = UnsafeBufferPointer(rebasing: searchURL[0..<hostEnd(searchURL)])
        return (hasWordStart(host, first) ? 1000 : 0) + (hasWordStart(searchTitle, first) ? 100 : 0)
    }

    /// Substring mode membership: terms match anywhere in the folded URL or title, except short
    /// word-start terms (see `usesWordStart`), which match a URL prefix or a title word start.
    /// Every term must match.
    public static func matches(searchURL: UnsafeBufferPointer<UInt8>, searchTitle: UnsafeBufferPointer<UInt8>,
                               terms: [Term]) -> Bool {
        for term in terms where !term.bytes.isEmpty {
            let matched = usesWordStart(term, in: terms)
                ? hasPrefix(searchURL, term.bytes) || hasWordStart(searchTitle, term.bytes)
                : contains(searchURL, term.bytes) || contains(searchTitle, term.bytes)
            if !matched { return false }
        }
        return true
    }

    public static func hostEnd(_ searchURL: UnsafeBufferPointer<UInt8>) -> Int {
        searchURL.firstIndex { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#") } ?? searchURL.count
    }

    public static func hasPrefix(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for index in needle.indices where haystack[index] != needle[index] { return false }
        return true
    }

    public static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        firstOccurrence(haystack, needle, from: 0) != nil
    }

    /// An occurrence at the start or after an ASCII non-alphanumeric byte. Non-ASCII bytes are
    /// treated as word characters, matching FTS5 unicode61 for letters outside ASCII.
    public static func hasWordStart(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        if let first = needle.first, isSeparator(first) { return contains(haystack, needle) }
        var start = 0
        while let position = firstOccurrence(haystack, needle, from: start) {
            if position == 0 || isSeparator(haystack[position - 1]) { return true }
            start = position + 1
        }
        return false
    }

    static func isSeparator(_ byte: UInt8) -> Bool {
        guard byte < 0x80 else { return false }
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"): return false
        default: return true
        }
    }

    private static func firstOccurrence(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, let base = haystack.baseAddress, start + needle.count <= haystack.count else { return nil }
        return needle.withUnsafeBufferPointer { pattern -> Int? in
            guard let found = memmem(base + start, haystack.count - start, pattern.baseAddress!, pattern.count) else { return nil }
            return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
        }
    }
}
