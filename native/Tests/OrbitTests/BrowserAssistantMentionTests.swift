import Foundation
import Testing
import BrowserCore
@testable import Orbit

private actor SyntheticMentionProviderFixture: BrowserAIProviderClient {
    nonisolated let id: BrowserAIProviderID = .codex
    private(set) var starts = 0
    func status(refresh: Bool) async -> BrowserAIProviderStatus { .init(id: id, state: .signedOut) }
    func shutdown() async {}
    func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        starts += 1
        let events = AsyncStream<BrowserAITurnEvent> { $0.finish() }
        return .init(events: events, interrupt: {})
    }
}

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
        var liveMembers = [source("Snapshot A"), source("Snapshot B")]
        let snapshot = BrowserAssistantMentionOption(id: .folder(UUID()), kind: .folder, title: "Snapshot",
            path: "Space / Snapshot", detail: "Folder", members: liveMembers)
        liveMembers.append(source("Added later"))
        #expect(snapshot.members.count == 2)
    }

    @Test("Selecting a suggestion adds context without reading a page or starting a provider")
    @MainActor
    func suggestionSelectionDoesNotReadOrSend() async {
        let source = source("Overview", host: "fixture.test")
        var preferences = BrowserAIPreferences()
        preferences.isEnabled = true
        var pageReads = 0
        let provider = SyntheticMentionProviderFixture()
        let conversation = BrowserAIConversation(choice: .init(provider: .codex), clients: [provider],
            preferences: { preferences }, isPrivate: { false },
            currentSource: { $0 == source.id ? source : nil },
            reader: { _ in pageReads += 1; return "Synthetic page" })
        let option = BrowserAssistantMentionOption(id: .tab(source.id), kind: .tab, title: source.title,
            path: "Tabs", detail: source.url.host ?? "", members: [source])

        let additions = BrowserAssistantMentionOptions.additions(for: option.members, selected: conversation.selectedSources)!
        for item in additions { conversation.select(item) }

        #expect(conversation.selectedSources == [source])
        #expect(pageReads == 0)
        #expect(await provider.starts == 0)
    }

    private func source(_ title: String) -> BrowserAIContextSource {
        .init(id: UUID(), revision: 1, url: URL(string: "https://example.test/\(title.hashValue)")!, title: title)
    }

    private func source(_ title: String, host: String) -> BrowserAIContextSource {
        .init(id: UUID(), revision: 1, url: URL(string: "https://\(host)/\(title.hashValue)")!, title: title)
    }
}
