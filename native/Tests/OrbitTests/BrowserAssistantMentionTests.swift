import Foundation
import Testing
import BrowserCore
@testable import Orbit

@Suite("Assistant mentions")
struct BrowserAssistantMentionTests {
    @Test("Mention range uses UTF-16 offsets and preserves suffix")
    func unicodeCaretReplacement() throws {
        let draft = "😀 résumé @réf après"
        let ns = draft as NSString
        let caret = ns.range(of: "@réf").location + ("@réf" as NSString).length
        let found = try #require(BrowserAssistantMentionRange.atCaret(in: draft, utf16Offset: caret))
        #expect(found.query == "réf")
        let replacement = found.replacing(in: draft, with: "Références")
        #expect(replacement.text == "😀 résumé Références après")
        #expect((replacement.text as NSString).substring(from: replacement.caretUTF16) == " après")
    }

    @Test("E-mail, URL and selected ranges stay literal")
    func literalAtSigns() {
        for text in ["maya@example.test", "https://example.test/@notes", "https://maya@example.test"] {
            #expect(BrowserAssistantMentionRange.atCaret(in: text, utf16Offset: (text as NSString).length) == nil)
        }
        #expect(BrowserAssistantMentionRange.atCaret(in: "@notes", utf16Offset: 6,
            selection: NSRange(location: 0, length: 6)) == nil)
    }

    @Test("Duplicate names retain distinct identity and path matches")
    func duplicateOptionIdentity() {
        let first = BrowserAssistantMentionOption(id: .folder(UUID()), kind: .folder, title: "Notes",
            path: "Work / Notes", detail: "Folder", members: [])
        let second = BrowserAssistantMentionOption(id: .folder(UUID()), kind: .folder, title: "Notes",
            path: "Personal / Notes", detail: "Folder", members: [])
        let matches = BrowserAssistantMentionOptions.matching("personal notes", options: [first, second])
        #expect(matches.map(\.id) == [second.id])
        #expect(Set([first.id, second.id]).count == 2)
        let tabA = source("Overview", host: "work.test")
        let tabB = source("Overview", host: "personal.test")
        let tabs = [tabA, tabB].map {
            BrowserAssistantMentionOption(id: .tab($0.id), kind: .tab, title: $0.title,
                path: "Tabs", detail: $0.url.host ?? "", members: [$0])
        }
        #expect(BrowserAssistantMentionOptions.matching("overview personal.test", options: tabs).map(\.id) == [.tab(tabB.id)])
    }

    @Test("Group additions deduplicate overlaps and reject overflow atomically")
    func groupCapIsAtomic() {
        let selected = (0..<7).map { source("Selected \($0)") }
        let overlap = selected[0]
        let oneNew = source("One")
        #expect(BrowserAssistantMentionOptions.additions(for: [overlap, oneNew], selected: selected)?.map(\.id) == [oneNew.id])
        let tooMany = [source("A"), source("B")]
        #expect(BrowserAssistantMentionOptions.additions(for: tooMany, selected: selected) == nil)
        #expect(BrowserAssistantMentionOptions.additions(for: tooMany, selected: [])?.count == 2)
    }

    private func source(_ title: String) -> BrowserAIContextSource {
        .init(id: UUID(), revision: 1, url: URL(string: "https://example.test/\(title.hashValue)")!, title: title)
    }

    private func source(_ title: String, host: String) -> BrowserAIContextSource {
        .init(id: UUID(), revision: 1, url: URL(string: "https://\(host)/\(title.hashValue)")!, title: title)
    }
}
