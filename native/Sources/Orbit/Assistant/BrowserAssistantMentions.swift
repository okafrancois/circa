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
        if let selection, selection.length != 0 || selection.location != utf16Offset { return nil }
        let value = text as NSString
        guard (0...value.length).contains(utf16Offset),
              Range(NSRange(location: utf16Offset, length: 0), in: text) != nil else { return nil }
        let caret = utf16Offset
        let prefix = NSRange(location: 0, length: caret)
        let lastNewline = value.rangeOfCharacter(from: .newlines, options: .backwards, range: prefix)
        let lineStart = lastNewline.location == NSNotFound ? 0 : NSMaxRange(lastNewline)
        let found = value.range(of: "@", options: .backwards,
                                range: NSRange(location: lineStart, length: caret - lineStart))
        guard found.location != NSNotFound else { return nil }
        let start = found.location
        let before: String
        if start == 0 {
            before = " "
        } else {
            before = value.substring(with: value.rangeOfComposedCharacterSequence(at: start - 1))
        }
        // A mention starts at a token boundary. This excludes e-mail addresses and URL userinfo/paths.
        let openingPunctuation = CharacterSet(charactersIn: "([{\"'«“‘")
        guard before.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) })
                || before.unicodeScalars.count == 1 && before.unicodeScalars.allSatisfy({ openingPunctuation.contains($0) }) else { return nil }
        let queryRange = NSRange(location: start + 1, length: caret - start - 1)
        let query = value.substring(with: queryRange)
        guard !query.contains("@"), !query.contains(where: { $0.isNewline }) else { return nil }
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

    static func newMembers(for members: [BrowserAIContextSource], selected: [BrowserAIContextSource]) -> [BrowserAIContextSource] {
        var seen = Set(selected.map(\.id))
        return members.filter { seen.insert($0.id).inserted }
    }

    static func additions(for members: [BrowserAIContextSource], selected: [BrowserAIContextSource], cap: Int = 8) -> [BrowserAIContextSource]? {
        let additions = newMembers(for: members, selected: selected)
        guard Set(selected.map(\.id)).count + additions.count <= cap else { return nil }
        return additions
    }

    static func memberFilter(from query: String, relativeTo originalQuery: String) -> String {
        if let prefix = query.range(of: originalQuery, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) {
            return String(query[prefix.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if originalQuery.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { return "" }
        return query
    }

    static func origin(_ url: URL) -> String {
        (url.host ?? "") + (url.path == "/" ? "" : url.path)
    }
}

enum BrowserAssistantMentionPickerLayout {
    static func contentHeight(rowCount: Int, isEmpty: Bool, choosingMembers: Bool,
                              showingOverflow: Bool, showingNotice: Bool) -> CGFloat {
        let rows = CGFloat(max(1, rowCount)) * 50
        let emptyState: CGFloat = isEmpty ? 38 : 0
        let memberControls: CGFloat = choosingMembers ? 42 : 0
        let overflowControls: CGFloat = showingOverflow ? 72 : 0
        let notice: CGFloat = showingNotice ? 58 : 0
        return min(336, rows + 66 + emptyState + memberControls + overflowControls + notice)
    }
}

/// Keeps the original group mention separate from the member list's temporary search text.
struct BrowserAssistantMentionMemberSelection: Equatable {
    private(set) var group: BrowserAssistantMentionOption?
    private(set) var originalQuery = ""
    private(set) var query = ""

    mutating func begin(_ group: BrowserAssistantMentionOption, originalQuery: String) {
        self.group = group
        self.originalQuery = originalQuery
        query = ""
    }

    mutating func updateQuery(_ query: String) {
        guard group != nil else { return }
        self.query = BrowserAssistantMentionOptions.memberFilter(from: query, relativeTo: originalQuery)
    }

    mutating func back() {
        group = nil
        originalQuery = ""
        query = ""
    }
}
