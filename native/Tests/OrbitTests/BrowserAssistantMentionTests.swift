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
        #expect(BrowserAssistantMentionRange.atCaret(in: "😀 @x", utf16Offset: 1) == nil)
    }

    @Test("E-mail, URL and selected ranges stay literal")
    func literalAtSigns() {
        for text in ["maya@example.test", "https://example.test/@notes", "https://maya@example.test"] {
            #expect(BrowserAssistantMentionRange.atCaret(in: text, utf16Offset: (text as NSString).length) == nil)
        }
        #expect(BrowserAssistantMentionRange.atCaret(in: "@notes", utf16Offset: 6,
            selection: NSRange(location: 0, length: 6)) == nil)
    }

    @Test("Parsed multiword path query selects the matching duplicate and replaces only its range")
    func parsedPathQueryReplacement() throws {
        let first = BrowserAssistantMentionOption(id: .folder(UUID()), kind: .folder, title: "Notes",
            path: "Work / Notes", detail: "Folder", members: [])
        let second = BrowserAssistantMentionOption(id: .folder(UUID()), kind: .folder, title: "Notes",
            path: "Personal / Notes", detail: "Folder", members: [])
        let draft = "😀 Compare\nOpen @Personal / Notes after this"
        let ns = draft as NSString
        let mention = ns.range(of: "@Personal / Notes")
        let caret = NSMaxRange(mention)
        let parsed = try #require(BrowserAssistantMentionRange.atCaret(in: draft, utf16Offset: caret))
        #expect(parsed.query == "Personal / Notes")
        let matches = BrowserAssistantMentionOptions.matching(parsed.query, options: [first, second])
        #expect(matches.map(\.id) == [second.id])
        let replacement = parsed.replacing(in: draft, with: matches[0].title)
        #expect(replacement.text == "😀 Compare\nOpen Notes after this")
        #expect((replacement.text as NSString).substring(from: replacement.caretUTF16) == " after this")
    }

    @Test("Duplicate folder and tab names retain distinct identity and path matches")
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

    @Test("Whole Space member filtering starts empty and resets when returning to all context")
    func memberFilterIsIndependentFromGroupQuery() {
        let overview = source("Overview", host: "work.test")
        let roadmap = source("Roadmap", host: "personal.test")
        let group = BrowserAssistantMentionOption(id: .space(UUID()), kind: .space, title: "Whole Space",
            path: "Research", detail: "Current window", members: [overview, roadmap])
        let options = [
            BrowserAssistantMentionOption(id: .tab(overview.id), kind: .tab, title: overview.title,
                path: "Research / Notes", detail: "work.test", members: [overview]),
            BrowserAssistantMentionOption(id: .tab(roadmap.id), kind: .tab, title: roadmap.title,
                path: "Research / Notes", detail: "personal.test", members: [roadmap]),
        ]
        var selection = BrowserAssistantMentionMemberSelection()
        selection.begin(group, originalQuery: "Whole Space")
        selection.updateQuery("Whole Space")
        #expect(selection.query.isEmpty)
        #expect(BrowserAssistantMentionOptions.matching(selection.query, options: options).count == 2)
        selection.updateQuery("Whole Space roadmap personal.test")
        #expect(selection.query == "roadmap personal.test")
        selection.updateQuery("whole space roadmap")
        #expect(selection.query == "roadmap")
        selection.updateQuery("Whole Space")
        #expect(selection.query.isEmpty)
        selection.back()
        #expect(selection.group == nil)
        #expect(selection.originalQuery.isEmpty && selection.query.isEmpty)
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
        #expect(BrowserAssistantMentionOptions.additions(for: [overlap, oneNew], selected: Array(repeating: overlap, count: 8), cap: 2)?.map(\.id) == [oneNew.id])
        var liveMembers = [source("Snapshot A"), source("Snapshot B")]
        let snapshot = BrowserAssistantMentionOption(id: .folder(UUID()), kind: .folder, title: "Snapshot",
            path: "Space / Snapshot", detail: "Folder", members: liveMembers)
        liveMembers.append(source("Added later"))
        #expect(snapshot.members.count == 2)
    }

    @Test("Overflow, member choices and cap feedback fit inside the context popover")
    func pickerStateLayoutReservesNoticeSpace() {
        let regular = BrowserAssistantMentionPickerLayout.contentHeight(rowCount: 1, isEmpty: false,
            choosingMembers: false, showingOverflow: false, showingNotice: false)
        let overflow = BrowserAssistantMentionPickerLayout.contentHeight(rowCount: 1, isEmpty: false,
            choosingMembers: false, showingOverflow: true, showingNotice: false)
        let memberEmpty = BrowserAssistantMentionPickerLayout.contentHeight(rowCount: 0, isEmpty: true,
            choosingMembers: true, showingOverflow: false, showingNotice: false)
        let capped = BrowserAssistantMentionPickerLayout.contentHeight(rowCount: 1, isEmpty: false,
            choosingMembers: true, showingOverflow: false, showingNotice: true)

        #expect(regular == 116)
        #expect(overflow >= regular + 72)
        #expect(memberEmpty > regular)
        #expect(capped >= regular + 100)
        #expect(BrowserAssistantMentionPickerLayout.contentHeight(rowCount: 12, isEmpty: false,
            choosingMembers: true, showingOverflow: false, showingNotice: false) == 336)
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

    @Test("Active mention and assistant drafts do not request remote search suggestions")
    @MainActor
    func mentionDraftDoesNotRequestSearchSuggestions() throws {
        var endpointCalls = 0
        let suggestions = BrowserSearchSuggestions(debounce: .milliseconds(1), endpoint: { _, _ in
            endpointCalls += 1
            return URL(string: "http://127.0.0.1:1/suggestions")
        })
        let mentionText = "Compare @Synthetic North Research"
        let mentionCaret = (mentionText as NSString).length
        let mention = try #require(BrowserAssistantMentionRange.atCaret(in: mentionText, utf16Offset: mentionCaret))

        suggestions.update(query: mentionText, engine: .google, profileID: ProfileID(), enabled: true,
                           isPrivate: false, activeMention: mention)
        #expect(endpointCalls == 0)

        suggestions.update(query: "A selected source prompt", engine: .google, profileID: ProfileID(), enabled: true,
                           isPrivate: false, assistantMode: true)
        #expect(endpointCalls == 0)

        suggestions.update(query: "ordinary search", engine: .google, profileID: ProfileID(), enabled: true,
                           isPrivate: false)
        #expect(endpointCalls == 1)
        suggestions.cancel()
    }

    private func source(_ title: String) -> BrowserAIContextSource {
        .init(id: UUID(), revision: 1, url: URL(string: "https://example.test/\(title.hashValue)")!, title: title)
    }

    private func source(_ title: String, host: String) -> BrowserAIContextSource {
        .init(id: UUID(), revision: 1, url: URL(string: "https://\(host)/\(title.hashValue)")!, title: title)
    }
}
