import Foundation
import BrowserCore

/// Stable identity for an eligible live source or a snapshot group. Display text is never identity.
enum BrowserAssistantMentionID: Hashable, Sendable {
    case tab(UUID)
    case folder(UUID)
    case space(UUID)
}

struct BrowserAssistantMentionOption: Identifiable, Equatable {
    enum Kind: Equatable { case tab, folder, space }
    let id: BrowserAssistantMentionID
    let kind: Kind
    let title: String
    let path: String
    let detail: String
    let members: [BrowserAIContextSource]
    var displayName: String { title }
}

/// The active `@query` range uses NSString offsets, matching AppKit's UTF-16 selection offsets.
struct BrowserAssistantMentionRange: Equatable {
    let range: NSRange
    let query: String

    static func atCaret(in text: String, utf16Offset: Int, selection: NSRange? = nil) -> Self? {
        if let selection, selection.length > 0 { return nil }
        let value = text as NSString
        let caret = min(max(0, utf16Offset), value.length)
        guard caret <= value.length else { return nil }
        let prefix = NSRange(location: 0, length: caret)
        let found = value.range(of: "@", options: .backwards, range: prefix)
        guard found.location != NSNotFound else { return nil }
        let start = found.location
        let before = start == 0 ? " " : value.substring(with: NSRange(location: start - 1, length: 1))
        // A mention starts at a token boundary. This excludes e-mail addresses and URL userinfo/paths.
        guard before.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        let queryRange = NSRange(location: start + 1, length: caret - start - 1)
        let query = value.substring(with: queryRange)
        guard !query.contains(where: { $0.isWhitespace || $0 == "@" }) else { return nil }
        return .init(range: NSRange(location: start, length: caret - start), query: query)
    }

    func replacing(in text: String, with displayName: String) -> (text: String, caretUTF16: Int) {
        let value = text as NSString
        let result = value.replacingCharacters(in: range, with: displayName)
        return (result, range.location + (displayName as NSString).length)
    }
}

enum BrowserAssistantMentionOptions {
    static func matching(_ query: String, options: [BrowserAssistantMentionOption]) -> [BrowserAssistantMentionOption] {
        let terms = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        return options.filter { option in
            let haystack = [option.title, option.path, option.detail].joined(separator: " ")
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return terms.allSatisfy(haystack.contains)
        }
    }

    static func additions(for members: [BrowserAIContextSource], selected: [BrowserAIContextSource], cap: Int = 8) -> [BrowserAIContextSource]? {
        var seen = Set(selected.map(\.id))
        let additions = members.filter { seen.insert($0.id).inserted }
        guard seen.count <= cap else { return nil }
        return additions
    }

    static func origin(_ url: URL) -> String {
        (url.host ?? "") + (url.path == "/" ? "" : url.path)
    }
}
