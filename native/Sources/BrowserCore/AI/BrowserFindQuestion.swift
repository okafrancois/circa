import Foundation

public enum BrowserFindQuestion {
    public static func isQuestion(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (3...2_000).contains(text.count) && (text.hasSuffix("?") || text.hasSuffix("？"))
    }
}
