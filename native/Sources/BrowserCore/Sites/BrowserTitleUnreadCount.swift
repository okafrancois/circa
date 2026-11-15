import Foundation

/// Reads an unread prefix from a live page title; stored or user-assigned titles are not a source.
public enum BrowserTitleUnreadCount {
    public static func parse(_ title: String?) -> Int? {
        guard let title else { return nil }
        // Directional marks may surround a prefix in otherwise right-to-left page titles.
        let padding = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "\u{061C}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
        let trimmed = title.trimmingCharacters(in: padding)
        guard let opening = trimmed.first, opening == "(" || opening == "[",
              let closing = trimmed.firstIndex(of: opening == "(" ? ")" : "]") else { return nil }
        var token = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            .trimmingCharacters(in: padding)
        if token.hasSuffix("+") { token.removeLast() }
        guard !token.isEmpty else { return nil }
        var count = 0
        for scalar in token.unicodeScalars {
            guard (48...57).contains(scalar.value) else { return nil }
            let digit = Int(scalar.value - 48)
            // A huge valid count still shows the existing positive-count indicator.
            if count > (Int.max - digit) / 10 { count = Int.max }
            else { count = count * 10 + digit }
        }
        return count > 0 ? count : nil
    }
}
