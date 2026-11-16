import AppKit
@testable import BrowserCore
import CoreVideo
import Darwin
import Foundation
import Testing
@testable import Orbit

/// Answers suggestion requests after a fixed network latency.
final class LatencySuggestionURLProtocol: SuggestionURLProtocol, @unchecked Sendable {
    private static let latencyState = State()
    override class var state: State { latencyState }
    nonisolated(unsafe) static var latency: TimeInterval = 0.08
    private var work: DispatchWorkItem?
    override func startLoading() {
        Self.state.lock.withLock { Self.state.requests.append(request) }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { ["q", "query"].contains($0.name) }!.value!
        let item = DispatchWorkItem { [self] in
            let data = try! JSONSerialization.data(withJSONObject: [query, [query + " guide", query + " news"]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        work = item
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.latency, execute: item)
    }
    override func stopLoading() { work?.cancel() }

    @MainActor static func service(cache: BrowserSearchSuggestionCache, debounce: Duration = .milliseconds(180)) -> BrowserSearchSuggestions {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [self]
        return BrowserSearchSuggestions(configuration: configuration, debounce: debounce, cache: cache,
                                        endpoint: { $0.suggestionURL(for: $1) })
    }
}

private func perfShellRoot() throws -> URL {
    let canonical = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(canonical) }
    let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        .appendingPathComponent("Orbit-PERF-SHELL-B-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func inode(_ file: URL) -> UInt64? {
    (try? FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)?.uint64Value
}

@Suite("Shell hardening B", .serialized)
@MainActor
struct PerfShellBTests {
    // MARK: Search suggestion cache

    @Test("The suggestion cache evicts the least recently used entry and expires after its lifetime")
    func suggestionCacheEvictionAndExpiry() {
        var now: TimeInterval = 100
        let cache = BrowserSearchSuggestionCache(capacity: 3, lifetime: 60, clock: { now })
        let profile = ProfileID()
        func key(_ query: String, _ engine: SearchEngine = .google, _ owner: ProfileID? = nil) -> BrowserSearchSuggestionCache.Key {
            .init(engine: engine, profileID: owner ?? profile, query: query)
        }
        cache.store(["a1"], for: key("a"))
        cache.store(["b1"], for: key("b"))
        cache.store(["c1"], for: key("c"))
        #expect(cache.values(for: key("a")) == ["a1"])     // a becomes the most recent
        cache.store(["d1"], for: key("d"))                  // evicts b
        #expect(cache.values(for: key("b")) == nil)
        #expect(cache.values(for: key("a")) == ["a1"] && cache.values(for: key("c")) == ["c1"])
        #expect(cache.count == 3)
        // Provider and profile are part of the key.
        #expect(cache.values(for: key("a", .bing)) == nil)
        #expect(cache.values(for: key("a", .google, ProfileID())) == nil)
        now += 59.9
        #expect(cache.values(for: key("d")) == ["d1"])
        now += 0.2
        #expect(cache.values(for: key("d")) == nil)
        #expect(cache.count == 2)
        let full = BrowserSearchSuggestionCache(clock: { now })
        for index in 0..<60 { full.store(["\(index)"], for: key("q\(index)")) }
        #expect(full.count == 50 && full.values(for: key("q9")) == nil && full.values(for: key("q10")) == ["10"])
    }

    @Test("Erasing and retyping a draft shows cached suggestions at once; private windows never fill the cache")
    func suggestionRetypeIsInstant() async throws {
        LatencySuggestionURLProtocol.state.reset()
        let cache = BrowserSearchSuggestionCache()
        let service = LatencySuggestionURLProtocol.service(cache: cache), profile = ProfileID()
        func update(_ text: String, isPrivate: Bool = false) {
            service.update(query: text, engine: .google, profileID: profile, enabled: true, isPrivate: isPrivate)
        }
        update("orbit"); await service.waitForResults()
        update("orbi"); await service.waitForResults()
        #expect(LatencySuggestionURLProtocol.state.captured.count == 2)
        var changes = 0
        service.onChange = { changes += 1 }
        update("orbit")
        #expect(service.values == ["orbit guide", "orbit news"])     // synchronously, no debounce
        #expect(changes == 1)
        await service.waitForResults()
        #expect(LatencySuggestionURLProtocol.state.captured.count == 2)
        service.hide("orbit news", engine: .google)
        update("orbi"); update("orbit")
        #expect(service.values == ["orbit guide"])                    // hidden text stays hidden on a hit
        service.cancel()
        let privateCache = BrowserSearchSuggestionCache()
        let privateService = LatencySuggestionURLProtocol.service(cache: privateCache)
        privateService.update(query: "private draft", engine: .google, profileID: profile, enabled: true, isPrivate: true)
        await privateService.waitForResults()
        #expect(privateCache.count == 0 && privateService.values.isEmpty)
    }

    @Test("Bench: suggestion latency on backspace and retype, without and with the cache")
    func suggestionRetypeBench() async throws {
        func retypeMilliseconds(capacity: Int) async throws -> [Double] {
            LatencySuggestionURLProtocol.state.reset()
            let service = LatencySuggestionURLProtocol.service(cache: BrowserSearchSuggestionCache(capacity: capacity))
            let profile = ProfileID()
            var samples: [Double] = []
            for word in ["orbit", "swift", "kayak"] {
                service.update(query: word, engine: .google, profileID: profile, enabled: true, isPrivate: false)
                await service.waitForResults()
                for _ in 0..<3 {
                    service.update(query: String(word.dropLast()), engine: .google, profileID: profile, enabled: true, isPrivate: false)
                    await service.waitForResults()
                    let start = ContinuousClock.now
                    service.update(query: word, engine: .google, profileID: profile, enabled: true, isPrivate: false)
                    while service.values != [word + " guide", word + " news"] { try await Task.sleep(for: .milliseconds(1)) }
                    let elapsed = ContinuousClock.now - start
                    samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
                }
            }
            return samples.sorted()
        }
        let before = try await retypeMilliseconds(capacity: 0)
        let after = try await retypeMilliseconds(capacity: 50)
        #expect(after[after.count / 2] < 5)
        #expect(before[before.count / 2] > 200)
        print(String(format: "PERF-SHELL-B suggestions retype median before=%.1fms after=%.3fms (debounce 180 ms, fake latency 80 ms, n=%d)",
                     before[before.count / 2], after[after.count / 2], after.count))
    }

    // MARK: Session save coalescing (real environment)

    @Test("Bench: session saves per second under a sustained burst of structural changes")
    func sessionSaveBurstBench() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try perfShellRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try await BrowserEnvironment.open(engine: PeekSyntheticEngine(), sessionFile: root.appendingPathComponent("session.json"))
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        try await Task.sleep(for: .milliseconds(400))
        var saves = 0
        environment.onPersistenceSuccess = { saves += 1 }
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(4) {
            environment.scheduleSave()
            try await Task.sleep(for: .milliseconds(16))
        }
        let duringBurst = saves
        try await Task.sleep(for: .milliseconds(1_200))
        #expect((duringBurst + 1)...(duringBurst + 2) ~= saves)       // the burst's tail is saved within 1 s
        #expect(Double(duringBurst) / 4 <= 1.3)
        print(String(format: "PERF-SHELL-B session saves during a 4 s burst (change every 16 ms): %d (%.2f/s), trailing save %d",
                     duringBurst, Double(duringBurst) / 4, saves - duringBurst))
        try await environment.finalize()
        window.retireForTermination()
    }

    // MARK: Settings writes on Space switches

    @Test("Ten Space switches write the remembered window once after they settle, and quitting flushes it")
    func spaceSwitchWritesCoalesce() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func run(delay: Duration, finalizeEarly: Bool) async throws -> (during: Int, total: Int, lastSpace: SpaceID?, expected: SpaceID) {
            let root = try perfShellRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let session = root.appendingPathComponent("session.json")
            let settings = session.appendingPathExtension("settings.json")
            let environment = try await BrowserEnvironment.open(engine: PeekSyntheticEngine(), sessionFile: session)
            environment.windowActivityDelay = delay
            let controller = try await environment.makeWindow()
            defer { controller.window?.close() }
            let profile = try #require(controller.session.activeProfileID)
            var spaces: [SpaceID] = [try #require(controller.session.snapshot?.activeSpaceID)]
            for index in 0..<2 { spaces.append(try await environment.store.createSpace(name: "Synthetic \(index)", profileID: profile)) }
            await environment.flushWindowActivity()
            try await Task.sleep(for: .milliseconds(100))
            var last = inode(settings)
            var during = 0
            for index in 1...10 {
                controller.session.activateSpace(spaces[index % spaces.count])
                await controller.session.waitForPendingCommands()
                environment.recordActiveWindow(controller)
                try await Task.sleep(for: .milliseconds(20))
                await environment.windowActivitySave?.value
                if inode(settings) != last { during += 1; last = inode(settings) }
            }
            var total = during
            if finalizeEarly { try await environment.finalize() } else { try await Task.sleep(for: delay + .milliseconds(400)); await environment.windowActivitySave?.value }
            if inode(settings) != last { total += 1 }
            let stored = try BrowserSettingsStore(destination: settings)
            let lastSpace = await stored.snapshot().lastActiveSpaceID
            if !finalizeEarly { try await environment.finalize() }
            controller.retireForTermination()
            return (during, total, lastSpace, spaces[10 % spaces.count])
        }
        let immediate = try await run(delay: .zero, finalizeEarly: false)        // previous behaviour: one write per switch
        let settled = try await run(delay: .milliseconds(300), finalizeEarly: false)
        let quit = try await run(delay: .seconds(2), finalizeEarly: true)
        #expect(immediate.during > settled.during) // the unthrottled baseline writes during switches; its exact count depends on load
        #expect(settled.during == 0 && settled.total == 1 && settled.lastSpace == settled.expected)
        #expect(quit.during == 0 && quit.total == 1 && quit.lastSpace == quit.expected)
        print("PERF-SHELL-B settings writes during 10 Space switches before=\(immediate.during) after=\(settled.during) (one write \(settled.total) after settling; quit flush writes \(quit.total))")
    }

    // MARK: Display link per display

    @Test("Core Video motion links follow the window's display and rebind when it changes screen")
    func displayLinkFollowsWindowScreen() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let screen = OrbitDisplayLinkScreen()
        final class Reported { var display: CGDirectDisplayID = 4_242 }
        let reported = Reported()
        var bound: [CGDirectDisplayID] = []
        screen.displayOfWindow = { _ in reported.display }
        screen.setDisplay = { _, display in bound.append(display); return true }
        let link = try #require(OrbitDisplayLinkScreen.makeLink())
        screen.bind(link, to: window)
        #expect(screen.display == 4_242 && bound == [4_242])
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        #expect(bound == [4_242])                                          // same display: no rebind
        reported.display = 5_151
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: other)
        #expect(bound == [4_242])                                          // another window's move is ignored
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        #expect(screen.display == 5_151 && bound == [4_242, 5_151] && screen.rebinds == 1)
        screen.unbind()
        reported.display = 6_000
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        #expect(bound == [4_242, 5_151])

        // Without a window the real link stays on the main display; the drivers bind through `start(window:)`.
        let real = OrbitDisplayLinkScreen()
        real.bind(link, to: nil)
        #expect(real.display == CGMainDisplayID())
        let driver = OrbitCoreVideoMotionDriver()
        driver.screen.displayOfWindow = { _ in CGMainDisplayID() }
        #expect(driver.start(window: window))
        #expect(driver.screen.display == CGMainDisplayID())
        driver.stop()
        #expect(driver.screen.display == nil)
        let library = LibraryMotionDriver()
        library.start(window: window)
        #expect(library.screen.display != nil)
        library.stop()
    }

    // MARK: Assistant transcript citation memo

    private func transcript(messages: Int) -> [BrowserAIMessage] {
        let passage = "Actors allow one task at a time."
        let source = BrowserAIContextSource(id: UUID(), revision: 1, url: URL(string: "https://example.com/guide")!, title: "Guide")
        let context = [BrowserAIContextSnapshot(source: source, text: "Intro. " + passage + " Outro.")]
        let answer = String(repeating: "Swift concurrency keeps **state** isolated and `async` code readable. ", count: 9)
            + "[1: \"\(passage)\"] and more.\n\n- one\n- two"
        return (0..<messages).map { index in
            index.isMultiple(of: 2)
                ? BrowserAIMessage(id: UUID(), role: .user, choice: .init(provider: .codex), text: "Question \(index)", state: .completed, context: [])
                : BrowserAIMessage(id: UUID(), role: .assistant, choice: .init(provider: .codex), text: answer, state: .completed, context: context)
        }
    }

    @Test("The citation memo returns what direct parsing returns and parses only messages that changed")
    func citationMemoMatchesDirectParsing() {
        var messages = transcript(messages: 30)
        messages[29].state = .streaming
        messages[29].text = "Partial [1: \"Actors allow"
        let memo = BrowserAssistantCitationMemo()
        func check(_ message: BrowserAIMessage) {
            let entry = memo.entry(message)
            var numbers: Set<Int> = []
            #expect(entry.hasText == !BrowserAICitation.segments(message).isEmpty)
            #expect(entry.citations == BrowserAICitation.parse(message).filter { numbers.insert($0.number).inserted })
            #expect(entry.displayText == BrowserAICitation.displayText(message))
        }
        messages.forEach(check)
        #expect(memo.parses == 30)
        for token in ["", " one task", " at a time.\"] done"] {
            messages[29].text += token
            messages.forEach(check)
        }
        #expect(memo.parses == 30 + 2)                                     // the empty token changed nothing
        messages[29].state = .completed
        check(messages[29])
        #expect(memo.parses == 33)
        #expect(memo.entry(messages[29]).citations.count == 1)
    }

    @Test("Bench: transcript citation work per streamed token, direct parsing versus the memo")
    func citationMemoBench() {
        var messages = transcript(messages: 30)
        messages[29].state = .streaming
        let tokens = 200
        let memo = BrowserAssistantCitationMemo()
        var sink = 0
        func direct(_ message: BrowserAIMessage) {
            var numbers: Set<Int> = []
            if !BrowserAICitation.segments(message).isEmpty { sink += 1 }
            sink += BrowserAICitation.parse(message).filter { numbers.insert($0.number).inserted }.count
            if message.state != .streaming { sink += BrowserAICitation.displayText(message).count }
        }
        func memoized(_ message: BrowserAIMessage) {
            let entry = memo.entry(message)
            if entry.hasText { sink += 1 }
            sink += entry.citations.count
            if message.state != .streaming { sink += entry.displayText.count }
        }
        func measure(_ body: (BrowserAIMessage) -> Void) -> Double {
            var copy = messages
            let start = ContinuousClock.now
            for index in 0..<tokens {
                copy[29].text += " token\(index)"
                copy.forEach(body)
            }
            let elapsed = ContinuousClock.now - start
            return (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15) / Double(tokens)
        }
        let before = measure(direct)
        let after = measure(memoized)
        #expect(after < before / 4)
        print(String(format: "PERF-SHELL-B transcript citation work per token (30 messages, %d chars) before=%.3fms after=%.3fms sink=%d",
                     messages.reduce(0) { $0 + $1.text.count }, before, after, sink))
    }
}
