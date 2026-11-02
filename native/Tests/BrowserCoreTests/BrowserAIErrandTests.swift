import Foundation
import Testing
@testable import BrowserCore

private actor ErrandProvider: BrowserAIProviderClient {
    nonisolated let id: BrowserAIProviderID = .codex
    var prompts: [BrowserAITurnRequest] = []
    var replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    func status(refresh: Bool) async -> BrowserAIProviderStatus { .init(id: id, state: .signedOut) }
    func shutdown() async {}
    func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        prompts.append(request)
        let text = replies.isEmpty ? "{}" : replies.removeFirst()
        return BrowserAITurn(events: AsyncStream { continuation in
            continuation.yield(.text(text)); continuation.yield(.completed); continuation.finish()
        }, interrupt: {})
    }
}

@Suite @MainActor struct BrowserAIErrandTests {
    private func sample() -> BrowserAIErrandObservation {
        .init(pages: [.init(id: UUID(), snapshot: UUID(), revision: 4,
            url: URL(string: "https://example.test/flights")!, title: "Flights", text: "Find flights",
            targets: [.init(id: UUID(), kind: .button, label: "Pay"), .init(id: UUID(), kind: .text, label: "Destination")])])
    }
    private func response(_ action: String, _ observation: BrowserAIErrandObservation, value: String? = nil) -> String {
        let page = observation.pages[0], target = page.targets[action == "type" ? 1 : 0]
        var object: [String: String] = ["action": action, "tab": page.id.uuidString, "target": target.id.uuidString]
        if let value { object["value"] = value }
        return String(decoding: try! JSONEncoder().encode(object), as: UTF8.self)
    }
    private func wait(_ condition: @MainActor () -> Bool) async {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() && ContinuousClock.now < end { await Task.yield() }
        #expect(condition())
    }
    private var enabled: BrowserAIPreferences {
        var preferences = BrowserAIPreferences(); preferences.isEnabled = true; return preferences
    }

    @Test func noMutationBeforeSingleUseApprovalAndNextTurnHasReceipt() async {
        let observation = sample()
        let provider = ErrandProvider([response("click", observation), #"{"action":"finish","summary":"Done"}"#])
        var executions = 0
        let errand = BrowserAIErrand(goal: "Compare flights", choice: .init(provider: .codex), client: provider,
            preferences: { enabled }, ownerCurrent: { true }, observe: { observation }, isCurrent: { $0 == observation },
            execute: { action, snapshot in
                #expect(action == .click(tab: observation.pages[0].id, target: observation.pages[0].targets[0].id))
                #expect(snapshot == observation)
                executions += 1; await Task.yield(); return true
            })
        errand.start()
        await wait { errand.phase == .waiting }
        #expect(executions == 0)
        let approval = errand.approval!.id
        errand.allowOnce(UUID())
        #expect(executions == 0 && errand.phase == .waiting)
        errand.allowOnce(approval); errand.allowOnce(approval)
        await wait { errand.phase == .completed }
        #expect(executions == 1 && errand.completedActions == 1 && errand.summary == "Done")
        let prompts = await provider.prompts
        #expect(prompts.count == 2 && prompts[1].prompt.contains("targetLabel"))
        #expect(prompts.allSatisfy { $0.instructions.contains("You have no tools") })
    }

    @Test func navigationOrPolicyOrOwnerChangeRevokesPendingApproval() async {
        for change in 0..<3 {
            let observation = sample()
            // Use this observation's identities, never another task's target token.
            let matchingProvider = ErrandProvider([response("click", observation)])
            var preferences = enabled, current = true, owner = true, executions = 0
            let errand = BrowserAIErrand(goal: "Search", choice: .init(provider: .codex), client: matchingProvider,
                preferences: { preferences }, ownerCurrent: { owner }, observe: { observation }, isCurrent: { _ in current },
                execute: { _, _ in executions += 1; return true })
            errand.start(); await wait { errand.phase == .waiting }
            let id = errand.approval!.id
            if change == 0 { current = false }
            if change == 1 { preferences.readsCurrentTabOnRequest = false }
            if change == 2 { owner = false }
            errand.reconcile(); errand.allowOnce(id)
            #expect(errand.phase == .stopped && errand.approval == nil && executions == 0)
        }
    }

    @Test func revocationDuringExtractionNeverStartsProvider() async {
        let observation = sample(), provider = ErrandProvider([])
        var current = true
        let errand = BrowserAIErrand(goal: "Read", choice: .init(provider: .codex), client: provider,
            preferences: { enabled }, ownerCurrent: { current }, observe: { current = false; return observation },
            isCurrent: { _ in true }, execute: { _, _ in Issue.record("Executed revoked task"); return false })
        errand.start(); await wait { errand.phase == .stopped }
        #expect(await provider.prompts.isEmpty)
    }

    @Test func stopDuringActionDoesNotResumeOrStartAnotherRequest() async {
        let observation = sample()
        let matching = ErrandProvider([response("click", observation)])
        var task: BrowserAIErrand?
        let errand = BrowserAIErrand(goal: "Read", choice: .init(provider: .codex), client: matching,
            preferences: { enabled }, ownerCurrent: { true }, observe: { observation }, isCurrent: { _ in true },
            execute: { _, _ in task?.stop(); await Task.yield(); return true })
        task = errand; errand.start(); await wait { errand.phase == .waiting }
        errand.allowOnce(errand.approval!.id)
        await wait { errand.phase == .stopped }
        #expect(await matching.prompts.count == 1)
    }

    @Test func strictResponseCannotAddressOtherTaskOrExecuteScriptOrChangeActionShape() throws {
        let observation = sample()
        #expect(try BrowserAIErrandAction.parse(response("type", observation, value: "Lisbon"), observation: observation)
            == .type(tab: observation.pages[0].id, target: observation.pages[0].targets[1].id, value: "Lisbon"))
        let rejected = [
            response("click", sample()), response("type", observation),
            #"{"action":"open","url":"javascript:alert(1)"}"#,
            #"{"action":"open","url":"file:///tmp/private"}"#,
            #"{"action":"open","url":"https://user:password@example.test"}"#,
            #"{"action":"finish","summary":"Done","script":"alert(1)"}"#,
            #"{"action":"evaluate","script":"alert(1)"}"#,
            "```json\n{\"action\":\"finish\",\"summary\":\"Done\"}\n```"
        ]
        for text in rejected {
            #expect(throws: (any Error).self) { try BrowserAIErrandAction.parse(text, observation: observation) }
        }
    }

    @Test func emptyOrOversizedObservationsNeverReachProvider() async {
        let page = sample().pages[0]
        for observation in [BrowserAIErrandObservation(pages: []), .init(pages: [page, page]),
            .init(pages: [.init(id: page.id, snapshot: page.snapshot, revision: page.revision,
                url: page.url, title: page.title, text: String(repeating: "x", count: 24_001), targets: [])])] {
            let provider = ErrandProvider([])
            let errand = BrowserAIErrand(goal: "Read", choice: .init(provider: .codex), client: provider,
                preferences: { enabled }, ownerCurrent: { true }, observe: { observation }, isCurrent: { _ in true },
                execute: { _, _ in false })
            errand.start(); await wait { errand.phase == .stopped }
            #expect(await provider.prompts.isEmpty)
        }
    }

    @Test func stopDropsPageDataAndNeverRunsPendingAction() async {
        let observation = sample()
        let matching = ErrandProvider([response("click", observation)])
        let errand = BrowserAIErrand(goal: "Read", choice: .init(provider: .codex), client: matching,
            preferences: { enabled }, ownerCurrent: { true }, observe: { observation }, isCurrent: { _ in true },
            execute: { _, _ in Issue.record("Stopped action executed"); return false })
        errand.start(); await wait { errand.phase == .waiting }
        let id = errand.approval!.id; errand.stop(); errand.allowOnce(id)
        #expect(errand.phase == .stopped && errand.pages.isEmpty)
    }
}
