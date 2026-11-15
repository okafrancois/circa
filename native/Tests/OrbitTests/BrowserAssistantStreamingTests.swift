import AppKit
import SwiftUI
import Testing
import BrowserCore
import BrowserShell
@testable import Orbit

private actor StreamingProvider: BrowserAIProviderClient {
    nonisolated let id: BrowserAIProviderID = .codex
    var requests: [BrowserAITurnRequest] = []
    var streams: [AsyncStream<BrowserAITurnEvent>.Continuation] = []
    func status(refresh: Bool) async -> BrowserAIProviderStatus { .init(id: id, state: .signedOut) }
    func shutdown() async {}
    func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        requests.append(request)
        let pair = AsyncStream<BrowserAITurnEvent>.makeStream()
        streams.append(pair.continuation)
        return BrowserAITurn(events: pair.stream, interrupt: {})
    }
    func emit(_ event: BrowserAITurnEvent) { streams.last?.yield(event) }
}

@MainActor @Suite("Assistant streaming text")
struct BrowserAssistantStreamingTests {
    static let answer = """
    Here is a **summary** of the page with `inline code` and a few details that wrap across several lines of the panel.

    - First point about *actors* and isolation in a longer bullet that wraps
    - Second point with **bold** text and `await`
    1. Ordered step one
    2. Ordered step two with more words to wrap the line

    ```
    let value = try await client.fetch()
    print(value)
    ```

    A closing paragraph that explains the result in plain words, long enough to span two or three lines of text.
    """

    private func until(_ predicate: () async -> Bool) async {
        for _ in 0..<100_000 { if await predicate() { return }; await Task.yield() }
        Issue.record("Async operation did not finish")
    }

    private func transcript(turns: Int, provider: StreamingProvider) async -> BrowserAIConversation {
        var preferences = BrowserAIPreferences()
        preferences.isEnabled = true
        let allowed = preferences
        let conversation = BrowserAIConversation(choice: .init(provider: .codex), clients: [provider], preferences: { allowed },
            isPrivate: { false }, currentSource: { _ in nil }, reader: { _ in "PAGE" })
        for turn in 0..<turns {
            conversation.send("Question \(turn)")
            await until { await provider.requests.count == turn + 1 }
            await provider.emit(.text(Self.answer + String(repeating: " More detail.", count: 60)))
            await provider.emit(.completed)
            await until { !conversation.isRunning }
        }
        return conversation
    }

    private func streamedSnapshots(_ deltas: [String], page: String) async -> [BrowserAIMessage] {
        let provider = StreamingProvider()
        let item = BrowserAIContextSource(id: UUID(), revision: 1, url: URL(string: "https://example.com/guide")!, title: "Guide")
        var preferences = BrowserAIPreferences()
        preferences.isEnabled = true
        let allowed = preferences
        let conversation = BrowserAIConversation(choice: .init(provider: .codex), clients: [provider], preferences: { allowed },
            isPrivate: { false }, currentSource: { $0 == item.id ? item : nil }, reader: { _ in page })
        conversation.select(item)
        conversation.send("Question")
        await until { await provider.requests.count == 1 }
        var snapshots: [BrowserAIMessage] = []
        var expected = ""
        for delta in deltas {
            expected += delta
            await provider.emit(.text(delta))
            await until { conversation.messages.last?.role == .assistant && conversation.messages.last?.text == expected }
            if let last = conversation.messages.last { snapshots.append(last) }
        }
        await provider.emit(.completed)
        await until { !conversation.isRunning }
        if let last = conversation.messages.last { snapshots.append(last) }
        return snapshots
    }

    @Test("Incremental streaming renders exactly what a full render shows, at every token")
    func incrementalMatchesFullRender() async throws {
        let passage = "Actors allow one task at a time."
        let text = "Intro with **bold** and `code` 🚀 [1: \"\(passage)\"] then more.\n\n- item *one*\n- item **two**\n\n```\nlet x = 1\n```\n\nTail **bo" + "ld** end."
        let deltas = Array(text).chunked(3)
        let snapshots = await streamedSnapshots(deltas, page: passage)
        let palette = BrowserAssistantPalette(theme: .default, appearance: NSAppearance(named: .aqua)!)
        let streaming = BrowserAssistantAnswerText.TextView.make()
        streaming.fadeTicker.isManual = true
        for message in snapshots {
            streaming.update(message: message, palette: palette, activeCitation: nil, reduced: false)
            let fresh = BrowserAssistantAnswerText.TextView.make()
            fresh.update(message: message, palette: palette, activeCitation: nil, reduced: false)
            let shown = try #require(streaming.textStorage), full = try #require(fresh.textStorage)
            #expect(shown.isEqual(to: full), "Diverged at \(message.text.count) characters")
            #expect(streaming.height(forWidth: 280) == fresh.height(forWidth: 280))
        }
        // A citation pill that changes highlight is replaced alone, and the result still matches.
        let final = try #require(snapshots.last)
        let id = try #require(BrowserAICitation.parse(final).first?.id)
        streaming.update(message: final, palette: palette, activeCitation: id, reduced: false)
        let fresh = BrowserAssistantAnswerText.TextView.make()
        fresh.update(message: final, palette: palette, activeCitation: id, reduced: false)
        #expect(streaming.textStorage?.isEqual(to: fresh.textStorage!) == true)
        #expect(streaming.textStorage?.string.contains("\u{FFFC}") == true)
    }

    @Test("Arriving text fades with temporary colours and never edits the storage")
    func fadeUsesTemporaryAttributes() async throws {
        let snapshots = await streamedSnapshots(["Hello", " world"], page: "PAGE")
        let palette = BrowserAssistantPalette(theme: .default, appearance: NSAppearance(named: .aqua)!)
        let view = BrowserAssistantAnswerText.TextView.make()
        var now: CFTimeInterval = 50
        view.fadeTicker.isManual = true
        view.fadeTicker.clock = { now }
        view.update(message: snapshots[0], palette: palette, activeCitation: nil, reduced: false)
        now += 0.2
        view.fadeTicker.tick()
        view.update(message: snapshots[1], palette: palette, activeCitation: nil, reduced: false)
        let manager = try #require(view.layoutManager), storage = try #require(view.textStorage)
        func alpha(at index: Int) -> CGFloat? {
            (manager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor)?.alphaComponent
        }
        #expect(alpha(at: 7).map { $0 < 0.01 } == true)
        #expect(alpha(at: 2) == nil)
        for time in [0.03, 0.06, 0.09] {
            now += 0.03
            view.fadeTicker.tick()
            #expect(abs((alpha(at: 7) ?? -1) - CGFloat(time / 0.12)) < 1e-6)
            #expect((storage.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor) == palette.ink)
        }
        now += 0.03
        view.fadeTicker.tick()
        #expect(alpha(at: 7) == nil && alpha(at: 2) == nil)
        #expect(!view.fadeTicker.isRunning)
    }

    @Test("Changed ranges keep the longest equal prefix and suffix")
    func changedRange() {
        func range(_ old: String, _ new: String) -> (old: NSRange, new: NSRange)? {
            BrowserAssistantRichText.changedRange(old: NSAttributedString(string: old), new: NSAttributedString(string: new))
        }
        #expect(range("Hello", "Hello") == nil)
        #expect(range("Hello", "Hello world").map { [$0.old, $0.new] } == [NSRange(location: 5, length: 0), NSRange(location: 5, length: 6)])
        #expect(range("**bo", "bold").map { [$0.old, $0.new] } == [NSRange(location: 0, length: 4), NSRange(location: 0, length: 4)])
        #expect(range("a1c", "a2c").map { [$0.old, $0.new] } == [NSRange(location: 1, length: 1), NSRange(location: 1, length: 1)])
        let plain = NSAttributedString(string: "abc")
        let bold = NSMutableAttributedString(string: "abc")
        bold.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 12), range: NSRange(location: 1, length: 1))
        let edit = BrowserAssistantRichText.changedRange(old: plain, new: bold)
        #expect(edit.map { [$0.old, $0.new] } == [NSRange(location: 1, length: 1), NSRange(location: 1, length: 1)])
    }

    @Test("Streaming into a long transcript: main-thread time per token",
          .enabled(if: ProcessInfo.processInfo.environment["ORBIT_ASSISTANT_BENCH"] != nil))
    func streamingCost() async throws {
        let provider = StreamingProvider()
        let conversation = await transcript(turns: 14, provider: provider)
        let palette = BrowserAssistantPalette(theme: .default, appearance: NSAppearance(named: .aqua)!)
        conversation.send("Final question")
        await until { await provider.requests.count == 15 }
        let tokens = Array(Self.answer + String(repeating: " More detail.", count: 60)).chunked(6)
        var views: [UUID: BrowserAssistantAnswerText.TextView] = [:]
        // Each token updates every answer of the transcript and measures it, as SwiftUI does.
        func pass() -> Double {
            let start = CACurrentMediaTime()
            for message in conversation.messages where message.role == .assistant && !message.text.isEmpty {
                let view = views[message.id] ?? BrowserAssistantAnswerText.TextView.make()
                view.fadeTicker.isManual = true
                views[message.id] = view
                view.update(message: message, palette: palette, activeCitation: nil, reduced: false)
                _ = view.height(forWidth: 340)
            }
            return CACurrentMediaTime() - start
        }
        _ = pass()
        var update: [Double] = [], frames: [Double] = []
        var expected = ""
        for token in tokens {
            expected += token
            await provider.emit(.text(token))
            await until { conversation.messages.last?.role == .assistant && conversation.messages.last?.text == expected }
            update.append(pass())
            // One fade frame followed by the layout the next display pass needs.
            if let streaming = conversation.messages.last.flatMap({ views[$0.id] }) {
                let frame = CACurrentMediaTime()
                streaming.applyFade(at: CACurrentMediaTime())
                _ = streaming.height(forWidth: 340)
                frames.append(CACurrentMediaTime() - frame)
            }
        }
        let total = conversation.messages.filter { $0.role == .assistant }.map(\.text.count).reduce(0, +)
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] * 1000 }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count) * 0.95)] * 1000 }
        print(String(format: "ASSISTANT-BENCH messages=%d chars=%d tokens=%d update median=%.3f ms p95=%.3f ms fade-frame median=%.3f ms p95=%.3f ms",
                     conversation.messages.count, total, update.count, median(update), p95(update), median(frames), p95(frames)))
        await provider.emit(.completed)
        await until { !conversation.isRunning }
    }
}

private extension Array where Element == Character {
    func chunked(_ size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map { String(self[$0..<Swift.min($0 + size, count)]) }
    }
}
