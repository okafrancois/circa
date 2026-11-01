import Foundation
import Testing
@testable import BrowserCore

private actor ConversationProvider: BrowserAIProviderClient {
    nonisolated let id: BrowserAIProviderID = .codex
    var requests: [BrowserAITurnRequest] = []
    var streams: [AsyncStream<BrowserAITurnEvent>.Continuation] = []
    var interruptions = 0
    var suspendsLaunch = false
    var launchPause: CheckedContinuation<Void, Never>?
    func suspendLaunch() { suspendsLaunch = true }
    func resumeLaunch() { launchPause?.resume(); launchPause = nil }
    func status(refresh: Bool) async -> BrowserAIProviderStatus { .init(id: id, state: .signedOut) }
    func shutdown() async {}
    func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        requests.append(request)
        if suspendsLaunch { await withCheckedContinuation { launchPause = $0 } }
        let pair = AsyncStream<BrowserAITurnEvent>.makeStream()
        streams.append(pair.continuation)
        return BrowserAITurn(events: pair.stream, interrupt: { await self.interrupted() })
    }
    func interrupted() { interruptions += 1 }
    func emit(_ event: BrowserAITurnEvent, at index: Int = 0) { streams[index].yield(event) }
    func end() { streams.last?.finish() }
}

@MainActor private final class ContextFixture {
    var preferences = BrowserAIPreferences()
    var privateWindow = false
    var source = BrowserAIContextSource(id: UUID(), revision: 1, url: URL(string: "https://example.com")!, title: "Example")
    var reads = 0
    var pause: CheckedContinuation<String, Never>?
    var suspend = false
    init() { preferences.isEnabled = true }
    func conversation(_ provider: ConversationProvider, budgets: BrowserAIConversationBudgets = .init()) -> BrowserAIConversation {
        BrowserAIConversation(choice: .init(provider: .codex), clients: [provider], budgets: budgets,
            preferences: { self.preferences }, isPrivate: { self.privateWindow },
            currentSource: { $0 == self.source.id ? self.source : nil }, reader: { _ in
                self.reads += 1
                if self.suspend { return await withCheckedContinuation { self.pause = $0 } }
                return "PAGE"
            })
    }
}

@Suite @MainActor struct BrowserAIConversationTests {
    private func until(_ predicate: () async -> Bool) async {
        for _ in 0..<10_000 { if await predicate() { return }; await Task.yield() }
        Issue.record("Async operation did not finish")
    }

    @Test func revocationDuringLaunchInterruptsBeforeAnyEvent() async {
        let provider = ConversationProvider(), fixture = ContextFixture()
        await provider.suspendLaunch()
        let conversation = fixture.conversation(provider)
        conversation.select(fixture.source)
        conversation.send("Question?")
        await until { await provider.launchPause != nil }
        fixture.preferences.isEnabled = false
        await provider.resumeLaunch()
        await until { !conversation.isRunning }
        #expect(await provider.interruptions == 1)
        #expect(conversation.messages.last?.state == .stopped)
        #expect(conversation.messages.last?.text.isEmpty == true)
    }

    @Test func requiredPageReadFailureNeverStartsProvider() async {
        let provider = ConversationProvider(), fixture = ContextFixture()
        let conversation = BrowserAIConversation(choice: .init(provider: .codex), clients: [provider],
            requiresContext: true, preferences: { fixture.preferences }, isPrivate: { false },
            currentSource: { _ in fixture.source }, reader: { _ in throw CancellationError() })
        conversation.select(fixture.source)
        conversation.send("Question?")
        await until { !conversation.isRunning }
        #expect(await provider.requests.isEmpty)
        #expect(conversation.messages.last?.state == .failed(.failed))
    }

    @Test func boundedHelperAnswerInterruptsOversizedStream() async {
        let provider = ConversationProvider(), fixture = ContextFixture()
        let conversation = fixture.conversation(provider, budgets: .init(history: 0, sources: 1, output: 8))
        conversation.select(fixture.source)
        conversation.send("Question?")
        await until { await provider.requests.count == 1 }
        await provider.emit(.text("123456789"))
        await until { !conversation.isRunning }
        #expect(conversation.messages.last?.text == "")
        #expect(conversation.messages.last?.state == .failed(.failed))
        #expect(await provider.interruptions == 1)
    }

    @Test func combiningChunksCannotExceedTheCumulativeByteBudget() async {
        let provider = ConversationProvider(), fixture = ContextFixture()
        let conversation = fixture.conversation(provider, budgets: .init(output: 2))
        conversation.send("Question?")
        await until { await provider.streams.count == 1 }
        for chunk in ["a"] + Array(repeating: "\u{0301}", count: 8) {
            await provider.emit(.text(chunk))
        }
        await provider.emit(.completed)
        await until { !conversation.isRunning }
        #expect((conversation.messages.last?.text.utf8.count ?? 0) <= 8)
        #expect(conversation.messages.last?.state == .failed(.failed))
        #expect(await provider.interruptions == 1)
    }

    @Test func lifecycleAndHistory() async {
        let provider = ConversationProvider(), fixture = ContextFixture()
        let conversation = fixture.conversation(provider, budgets: .init(prompt: 4, history: 6, pages: 3))
        let identity = conversation.id
        conversation.select(fixture.source)
        #expect(fixture.reads == 0)
        conversation.send("QUESTION")
        await until { await provider.requests.count == 1 }
        await provider.emit(.text("answer"))
        let usage = BrowserAIUsage(windows: [.init(span: .week, usedPercent: 20, resetsAt: nil)])
        await provider.emit(.usage(usage)); await provider.emit(.completed)
        await until { !conversation.isRunning }
        #expect(conversation.messages.last?.text == "answer")
        #expect(conversation.messages.last?.usage == usage)
        #expect(conversation.messages.last?.state == .completed)
        #expect(conversation.messages.last?.context.first?.text == "PAG")
        conversation.removeSource(fixture.source.id)
        conversation.send("next")
        await until { await provider.requests.count == 2 }
        let request = await provider.requests[1]
        let json = try! JSONSerialization.jsonObject(with: Data(request.prompt.utf8)) as! [String: Any]
        #expect((json["history"] as? [[String: String]])?.isEmpty == true)
        #expect((json["pages"] as? [Any])?.isEmpty == true)
        #expect(request.instructions.hasPrefix(BrowserAITurnRequest.defaultInstructions))
        #expect(conversation.id == identity)
        await provider.end()
        await until { !conversation.isRunning }
        #expect(conversation.messages.last?.state == .failed(.failed))
    }

    @Test func stopReplacementAndExplicitSwitch() async {
        let provider = ConversationProvider(), fixture = ContextFixture()
        let conversation = fixture.conversation(provider)
        conversation.send("one")
        await until { await provider.requests.count == 1 }
        await provider.emit(.text("partial"))
        await until { conversation.messages.last?.text == "partial" }
        conversation.stop()
        #expect(conversation.messages.last?.state == .stopped)
        conversation.send("two")
        await until { await provider.requests.count == 2 }
        await provider.emit(.text("stale")); await provider.emit(.completed)
        await provider.emit(.failed(.signedOut), at: 1)
        await until { !conversation.isRunning }
        #expect(conversation.messages[1].text == "partial")
        #expect(conversation.messages.last?.state == .failed(.signedOut))
        conversation.switchProvider(to: .init(provider: .onDevice))
        #expect(!conversation.send("no fallback"))
        #expect(await provider.requests.count == 2)
        conversation.close()
        #expect(!conversation.send("closed"))
        await until { await provider.interruptions == 1 }
    }

    @Test func policyBeforeExtraction() async {
        for gate in 0..<5 {
            let provider = ConversationProvider(), fixture = ContextFixture()
            let conversation = fixture.conversation(provider)
            conversation.select(fixture.source)
            switch gate {
            case 0: fixture.preferences.isEnabled = false
            case 1: fixture.privateWindow = true
            case 2: fixture.preferences.readsCurrentTabOnRequest = false
            case 3: fixture.preferences.disabledSites = ["example.com"]
            default: conversation.removeSource(fixture.source.id)
            }
            let sent = conversation.send("question")
            if sent { await until { await provider.requests.count == 1 } }
            #expect(fixture.reads == 0)
            conversation.close()
        }
    }

    @Test func unsafeSourcesAndCloseDuringCapture() async {
        let provider = ConversationProvider(), fixture = ContextFixture()
        fixture.source = .init(id: UUID(), revision: 1, url: URL(string: "file:///tmp/example")!, title: "Local")
        let conversation = fixture.conversation(provider)
        conversation.select(fixture.source); conversation.send("question")
        await until { await provider.requests.count == 1 }
        #expect(fixture.reads == 0)
        #expect(conversation.messages.last?.context.isEmpty == true)
        conversation.close()

        let otherProvider = ConversationProvider(), other = ContextFixture()
        other.suspend = true
        let pending = other.conversation(otherProvider)
        pending.select(other.source); pending.send("pending")
        await until { other.pause != nil }
        pending.close()
        other.pause?.resume(returning: "discard")
        for _ in 0..<20 { await Task.yield() }
        #expect(await otherProvider.requests.isEmpty)
        #expect(pending.messages.last?.state == .stopped)
    }

    @Test func revalidationAfterAwait() async {
        for gate in 0..<7 {
            let provider = ConversationProvider(), fixture = ContextFixture()
            fixture.suspend = true
            let conversation = fixture.conversation(provider)
            conversation.select(fixture.source); conversation.send("question")
            await until { fixture.pause != nil }
            switch gate {
            case 0: fixture.preferences.isEnabled = false
            case 1: fixture.privateWindow = true
            case 2: fixture.preferences.readsCurrentTabOnRequest = false
            case 3: fixture.preferences.disabledSites = ["example.com"]
            case 4: conversation.removeSource(fixture.source.id)
            case 5: fixture.source = .init(id: fixture.source.id, revision: 2, url: fixture.source.url, title: "New")
            default: conversation.reset()
            }
            fixture.pause?.resume(returning: "SECRET_PAGE")
            if gate < 2 || gate == 6 {
                await until { !conversation.isRunning }
                #expect(await provider.requests.isEmpty)
            } else {
                await until { await provider.requests.count == 1 }
                #expect(await !provider.requests[0].prompt.contains("SECRET_PAGE"))
                #expect(conversation.messages.last?.context.isEmpty == true)
            }
            conversation.close()
        }
    }
}

extension BrowserAIConversationTests {
    @Test func policyRevocationStopsStreamAndKeepsPartialText() async {
        let provider = ConversationProvider(), fixture = ContextFixture()
        let conversation = fixture.conversation(provider)
        conversation.select(fixture.source)
        conversation.send("Question")
        await until { await provider.requests.count == 1 }
        await provider.emit(.text("Partial"))
        await until { conversation.messages.last?.text == "Partial" }
        fixture.preferences.isEnabled = false
        await provider.emit(.text(" must not appear"))
        await until { !conversation.isRunning }
        #expect(conversation.messages.last?.text == "Partial")
        #expect(conversation.messages.last?.state == .stopped)
    }

    @Test func sourceNavigationStopsStreamBeforeNewText() async {
        let provider = ConversationProvider(), fixture = ContextFixture()
        let conversation = fixture.conversation(provider)
        conversation.select(fixture.source)
        conversation.send("Question")
        await until { await provider.requests.count == 1 }
        fixture.source = .init(id: fixture.source.id, revision: 2, url: fixture.source.url, title: fixture.source.title)
        await provider.emit(.text("Stale answer"))
        await until { !conversation.isRunning }
        #expect(conversation.messages.last?.text.isEmpty == true)
        #expect(conversation.messages.last?.state == .stopped)
    }
}

extension BrowserAIConversationTests {
    @Test func removedContextIsNotRedisclosedThroughHistory() async {
        let provider = ConversationProvider(), fixture = ContextFixture()
        let conversation = fixture.conversation(provider)
        conversation.select(fixture.source)
        conversation.send("Question")
        await until { await provider.requests.count == 1 }
        await provider.emit(.text("Sensitive passage from the page"))
        await provider.emit(.completed)
        await until { !conversation.isRunning }
        conversation.removeSource(fixture.source.id)
        conversation.send("Follow-up")
        await until { await provider.requests.count == 2 }
        let request = await provider.requests[1]
        #expect(!request.prompt.contains("Sensitive passage"))
        #expect(!request.prompt.contains("PAGE"))
        conversation.close()
    }
}

extension BrowserAIConversationTests {
    @Test func historyWithoutPageContextKeepsItsCharacterBudget() async throws {
        let provider = ConversationProvider(), fixture = ContextFixture()
        let conversation = fixture.conversation(provider, budgets: .init(history: 6))
        conversation.send("Earlier question")
        await until { await provider.requests.count == 1 }
        await provider.emit(.text("long-answer")); await provider.emit(.completed)
        await until { !conversation.isRunning }
        conversation.send("Next question")
        await until { await provider.requests.count == 2 }
        let request = await provider.requests[1]
        let json = try JSONSerialization.jsonObject(with: Data(request.prompt.utf8)) as? [String: Any]
        let history = json?["history"] as? [[String: String]]
        #expect(history?.count == 1)
        #expect(history?.first?["text"] == "answer")
        conversation.close()
    }
}


extension BrowserAIConversationTests {
    @Test(arguments: 0..<4)
    func historyIsRevalidatedAfterPendingExtraction(gate: Int) async throws {
        let provider = ConversationProvider(), fixture = ContextFixture()
        let conversation = fixture.conversation(provider)
        defer { conversation.close() }
        conversation.select(fixture.source)
        conversation.send("Initial question")
        await until { await provider.requests.count == 1 }
        await provider.emit(.text("HISTORICAL_PAGE_SECRET"))
        await provider.emit(.completed)
        await until { !conversation.isRunning }

        fixture.suspend = true
        conversation.send("Follow-up")
        await until { fixture.pause != nil }
        switch gate {
        case 0: conversation.removeSource(fixture.source.id)
        case 1: fixture.preferences.readsCurrentTabOnRequest = false
        case 2: fixture.preferences.disabledSites = ["example.com"]
        default:
            fixture.source = .init(id: fixture.source.id, revision: 2, url: fixture.source.url, title: fixture.source.title)
        }
        let paused = try #require(fixture.pause)
        fixture.pause = nil
        paused.resume(returning: "NEW_PAGE_SECRET")
        await until { await provider.requests.count == 2 }
        let payload = await provider.requests[1].prompt
        #expect(!payload.contains("HISTORICAL_PAGE_SECRET"))
        #expect(!payload.contains("NEW_PAGE_SECRET"))
        let envelope = try #require(try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        #expect((envelope["history"] as? [Any])?.isEmpty == true)
        #expect((envelope["pages"] as? [Any])?.isEmpty == true)
        #expect(envelope["prompt"] as? String == "Follow-up")
    }
}
