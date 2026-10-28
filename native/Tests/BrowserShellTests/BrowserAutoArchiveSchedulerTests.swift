import BrowserCore
import BrowserShell
import Foundation
import Testing

private final class SchedulerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Each sleep suspends until the test releases one tick; requested durations are recorded.
private actor SleepGate {
    private var waiting: [CheckedContinuation<Void, any Error>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private(set) var durations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        for arrival in arrivals { arrival.resume() }
        arrivals.removeAll()
        try await withCheckedThrowingContinuation { waiting.append($0) }
        try Task.checkCancellation()
    }

    /// Returns once the scheduler is asleep for the `count`-th time.
    func waitForSleep(count: Int) async {
        while durations.count < count { await withCheckedContinuation { arrivals.append($0) } }
    }

    func tick() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }

    func cancelAll() {
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
        waiting.removeAll()
    }
}

@Suite("Auto-archive scheduling")
@MainActor
struct BrowserAutoArchiveSchedulerTests {
    @Test("The scheduler sweeps at start and after each interval, honoring shell protection")
    func sweepsOnSchedule() async throws {
        let clock = SchedulerClock()
        let store = BrowserStore(clock: { clock.now })
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Home", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let old = try await store.openTab(url: URL(string: "https://scheduler.test/old")!,
                                          from: store.captureContext(in: window), activate: true)
        let media = try await store.openTab(url: URL(string: "https://scheduler.test/media")!,
                                            from: store.captureContext(in: window), activate: true)
        _ = try await store.openTab(url: URL(string: "https://scheduler.test/visible")!,
                                    from: store.captureContext(in: window), activate: true)
        let document = await store.sessionDocument()
        let oldID = try #require(document.tabs.first { $0.occurrenceID == old }?.id)
        let mediaID = try #require(document.tabs.first { $0.occurrenceID == media }?.id)

        let gate = SleepGate()
        var reported: [[TabID]] = []
        let scheduler = BrowserAutoArchiveScheduler(store: store, interval: .seconds(30),
                                                    protectedTabs: { [mediaID] },
                                                    sleep: { try await gate.sleep($0) })
        scheduler.onArchive = { reported.append($0.map(\.id)) }
        scheduler.start()
        #expect(scheduler.isRunning)
        await gate.waitForSleep(count: 1)
        #expect(reported.isEmpty)
        clock.advance(by: 12 * 3600)
        await gate.tick()
        await gate.waitForSleep(count: 2)
        #expect(reported == [[oldID]])
        #expect(await gate.durations == [.seconds(30), .seconds(30)])
        scheduler.stop()
        await gate.cancelAll()
        #expect(!scheduler.isRunning)
        clock.advance(by: 30 * 24 * 3600)
        #expect(await scheduler.sweep().isEmpty)
        let context = try await store.captureContext(in: window)
        #expect(try await store.organizationSnapshot(from: context).today.compactMap(\.node.tabID).contains(mediaID))
    }
}
