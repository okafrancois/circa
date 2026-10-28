import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

private final class ArchiveRuntimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    private var elapsed: TimeInterval = 0
    var wall: Date { lock.withLock { date } }
    var uptime: TimeInterval { lock.withLock { elapsed } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds; elapsed += seconds } }
    func jumpWall(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

@MainActor
private struct ArchiveRuntimeFixture {
    let clock: ArchiveRuntimeClock
    let store: BrowserStore
    let engine: SiteSyntheticEngine
    let controller: BrowserWindowController<SiteSyntheticEngine>
    let runtime: BrowserArchiveRuntime<SiteSyntheticSurface>
    let profile: ProfileID

    static func make(launchGrace: TimeInterval = 0, mediaGrace: TimeInterval = 5,
                     probeSleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                     readMedia: @escaping @MainActor (SiteSyntheticSurface) async -> BrowserMediaState = { await $0.requestMediaState() }) async throws -> Self {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let clock = ArchiveRuntimeClock()
        let store = BrowserStore(clock: { clock.wall })
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        try await store.setAutoArchiveThreshold(.after(10), forProfile: profile)
        let engine = SiteSyntheticEngine()
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: space, engine: engine,
            restoringWindowID: window, onClose: {}, onActivate: {})
        await controller.session.waitForPendingCommands()
        let runtime = BrowserArchiveRuntime<SiteSyntheticSurface>(store: store, launchGrace: launchGrace,
            mediaGrace: mediaGrace, probeTimeout: .milliseconds(5), probeSleep: probeSleep, uptime: { clock.uptime },
            wallClock: { clock.wall }, readMedia: readMedia)
        runtime.register(controller.session)
        controller.archive.collectProtection = { await runtime.protectedTabs(forClearToday: true) }
        return Self(clock: clock, store: store, engine: engine, controller: controller, runtime: runtime, profile: profile)
    }
    func open(_ name: String) async throws -> (TabID, SiteSyntheticSurface) {
        controller.session.openTab(url: URL(string: "https://archive-r2.test/\(name)")!)
        await controller.session.waitForPendingCommands()
        let surface = try #require(controller.session.selectedSurface)
        surface.media = .init(playback: .none, isAudible: false)
        return (try #require(controller.session.organization?.selectedTab?.id), surface)
    }
    func close() { runtime.scheduler.stop(); controller.session.close(); controller.window?.close() }
}

extension NativeWebKitTests {
@Suite("Archive round two safety", .serialized)
@MainActor
struct NativeArchiveR2Tests {
    @Test("Capture, suspended playback and unobservable Web Audio are protected")
    func mediaClassification() {
        let states: [BrowserMediaState] = [
            .init(playback: .suspended, isAudible: false),
            .init(playback: .none, camera: .active, isAudible: false),
            .init(playback: .none, microphone: .active, isAudible: false),
            .init(playback: .none, camera: .muted, isAudible: false),
            .init(playback: .paused), .init(playback: .none), .init()
        ]
        for state in states { #expect(BrowserArchiveRuntime<SiteSyntheticSurface>.protects(state)) }
        #expect(!BrowserArchiveRuntime<SiteSyntheticSurface>.protects(.init(playback: .paused, isAudible: false)))
        #expect(!BrowserArchiveRuntime<SiteSyntheticSurface>.protects(.init(playback: .paused, isAudioPlaying: false)))
        #expect(BrowserArchiveRuntime<SiteSyntheticSurface>.protects(.init(playback: .playing, isAudioMuted: true, isAudioPlaying: true)))
        #expect(BrowserArchiveRuntime<SiteSyntheticSurface>.protects(.init(playback: .none, isAudioPlaying: true)))
    }

    @Test("Media protection touches activity and a paused track receives grace plus a fresh threshold")
    func mediaTouchAndGrace() async throws {
        let fixture = try await ArchiveRuntimeFixture.make()
        defer { fixture.close() }
        let idle = try await fixture.open("idle")
        let playing = try await fixture.open("playing")
        let camera = try await fixture.open("camera")
        let microphone = try await fixture.open("microphone")
        let suspended = try await fixture.open("suspended")
        let visible = try await fixture.open("visible")
        playing.1.media = .init(playback: .playing, isAudible: true)
        camera.1.media = .init(camera: .active, isAudible: false)
        microphone.1.media = .init(microphone: .active, isAudible: false)
        suspended.1.media = .init(playback: .suspended, isAudible: false)
        fixture.clock.advance(10)
        #expect(await fixture.runtime.scheduler.sweep().map(\.id) == [idle.0])
        let document = await fixture.store.sessionDocument()
        #expect(document.organization.tabs.first { $0.id == playing.0 }?.lastActiveAt == fixture.clock.wall)
        playing.1.media = .init(playback: .paused, isAudible: false)
        fixture.clock.advance(1)
        #expect(await fixture.runtime.scheduler.sweep().isEmpty)
        fixture.clock.advance(4)
        #expect(await fixture.runtime.scheduler.sweep().isEmpty)
        fixture.clock.advance(6)
        #expect(await fixture.runtime.scheduler.sweep().map(\.id) == [playing.0])
        #expect(await fixture.store.sessionDocument().tabs.contains { $0.id == visible.0 })
    }

    @Test("Production Clear Today hook retains visible and playing or capturing tabs")
    func clearToday() async throws {
        let fixture = try await ArchiveRuntimeFixture.make()
        defer { fixture.close() }
        let idle = try await fixture.open("idle")
        let audio = try await fixture.open("audio")
        let capture = try await fixture.open("capture")
        let visible = try await fixture.open("visible")
        audio.1.media = .init(playback: .playing, isAudible: true)
        capture.1.media = .init(microphone: .active, isAudible: false)
        fixture.controller.clearTodayFromArchiveCommand()
        await fixture.controller.session.waitForPendingCommands()
        let remaining = Set(try #require(fixture.controller.session.snapshot).tabs.map(\.id))
        #expect(remaining == [audio.0, capture.0, visible.0])
        #expect(await fixture.controller.session.archivedTabs().value.map(\.id) == [idle.0])
        #expect(fixture.controller.window?.isVisible == false)
    }

    @Test("Launch grace delays old tabs without delaying explicit Clear")
    func launchGrace() async throws {
        let fixture = try await ArchiveRuntimeFixture.make(launchGrace: 300)
        defer { fixture.close() }
        let old = try await fixture.open("old")
        _ = try await fixture.open("visible")
        fixture.clock.advance(299)
        #expect(await fixture.runtime.scheduler.sweep().isEmpty)
        fixture.clock.advance(1)
        #expect(await fixture.runtime.scheduler.sweep().map(\.id) == [old.0])
    }

    @Test("A forward wall-clock jump touches Today instead of mass archiving")
    func forwardClockJump() async throws {
        let fixture = try await ArchiveRuntimeFixture.make(launchGrace: 300)
        defer { fixture.close() }
        _ = try await fixture.open("old")
        _ = try await fixture.open("visible")
        var signals: [BrowserArchiveRuntime<SiteSyntheticSurface>.Signal] = []
        fixture.runtime.onSignal = { signals.append($0) }
        fixture.clock.jumpWall(86400)
        #expect(await fixture.runtime.scheduler.sweep().isEmpty)
        #expect(signals == [.clockDiscontinuity])
        #expect(await fixture.store.sessionDocument().organization.tabs.allSatisfy { $0.lastActiveAt == fixture.clock.wall })
    }

    @Test("Reopen compares the most recent manual archive against the dismissed Peek")
    func reopenRecency() async throws {
        let fixture = try await ArchiveRuntimeFixture.make()
        defer { fixture.close() }
        let archived = try await fixture.open("archived")
        let source = try await fixture.open("source")
        fixture.controller.peek.clock = { fixture.clock.wall }
        _ = fixture.controller.openPeek(URL(string: "https://archive-r2.test/peek")!)
        fixture.controller.dismissPeek(animated: false)
        fixture.clock.advance(1)
        fixture.controller.session.archiveTabs([archived.0])
        await fixture.controller.session.waitForPendingCommands()
        let router = BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>(
            create: { _ in fixture.controller }, present: { _, _ in }, dispose: { _ in })
        _ = router.newWindow()
        await router.waitForPendingCommands()
        // The production composition (`OrbitApplication.makeCommandSystem`): window state, then Peek state.
        let registry = try BrowserCommandRegistry(router: router, state: { controller in
            var state = controller?.commandState ?? BrowserCommandState()
            controller?.applyPeekCommandState(to: &state)
            return state
        })
        BrowserWindowCommands.install(in: registry)
        BrowserPeekCommands.install(in: registry)
        #expect(registry.dispatch(.restoreLastClosedTab, origin: .keyboard))
        await fixture.controller.session.waitForPendingCommands()
        #expect(fixture.controller.session.organization?.selectedTab?.id == archived.0)
        #expect(!fixture.controller.peek.isPresented)
        fixture.controller.session.selectTab(source.0)
        fixture.controller.session.archiveTabs([archived.0])
        await fixture.controller.session.waitForPendingCommands()
        fixture.clock.advance(1)
        _ = fixture.controller.openPeek(URL(string: "https://archive-r2.test/newer-peek")!)
        fixture.controller.dismissPeek(animated: false)
        #expect(registry.dispatch(.restoreLastClosedTab, origin: .keyboard))
        await fixture.controller.session.waitForPendingCommands()
        #expect(fixture.controller.peek.isPresented)
        #expect(registry.activeScope == .peek)
        #expect(await fixture.controller.session.archivedTabs().value.map(\.id) == [archived.0])
        fixture.controller.dismissPeek(animated: false)
        router.shutdown()
    }

    @Test("Archive keyboard actions require unmodified keys and Library exposes Downloads")
    func keyboardAndCategories() async throws {
        let fixture = try await ArchiveRuntimeFixture.make()
        defer { fixture.close() }
        let view = fixture.controller.archive.view
        var deleted = 0
        view.table.onDelete = { deleted += 1 }
        func event(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 51))
        }
        view.table.keyDown(with: try event(.command))
        #expect(deleted == 0)
        view.table.keyDown(with: try event([]))
        #expect(deleted == 1)
        #expect(view.table.focusRingType == .exterior)
        fixture.controller.showArchive()
        await fixture.controller.session.waitForPendingCommands()
        await fixture.controller.archive.task?.value
        view.onDownloads?()
        await fixture.controller.session.waitForPendingCommands()
        #expect(!fixture.controller.archive.isPresented)
        #expect(fixture.controller.downloadsProfileID == fixture.profile)
        #expect(fixture.controller.window?.isVisible == false)
    }

    @Test("A stuck probe times out, protects its tab and cannot stop another candidate or spawn duplicate requests")
    func mediaTimeout() async throws {
        var continuation: CheckedContinuation<BrowserMediaState, Never>?
        var probeCalls = 0
        let fixture = try await ArchiveRuntimeFixture.make(readMedia: { surface in
            if surface.currentURL?.path == "/stuck" {
                probeCalls += 1
                return await withCheckedContinuation { continuation = $0 }
            }
            return await surface.requestMediaState()
        })
        defer { continuation?.resume(returning: .init(playback: .none, isAudible: false)); fixture.close() }
        let stuck = try await fixture.open("stuck")
        let idle = try await fixture.open("idle")
        _ = try await fixture.open("visible")
        var signals: [BrowserArchiveRuntime<SiteSyntheticSurface>.Signal] = []
        fixture.runtime.onSignal = { signals.append($0) }
        // Non-candidates never invoke the engine.
        #expect(await fixture.runtime.scheduler.sweep().isEmpty)
        #expect(probeCalls == 0)
        fixture.clock.advance(10)
        #expect(await fixture.runtime.scheduler.sweep().map(\.id) == [idle.0])
        #expect(signals == [.mediaStateTimedOut])
        fixture.clock.advance(1)
        #expect(await fixture.runtime.scheduler.sweep().isEmpty)
        #expect(probeCalls == 1)
        #expect(signals.last == .mediaStateStillPending)
        #expect(await fixture.store.sessionDocument().tabs.contains { $0.id == stuck.0 })
    }

    @Test("A cancelled timeout that resumes after the media result cannot publish a losing signal")
    func losingMediaTimeoutDoesNotSignal() async throws {
        var sleepingTimer: CheckedContinuation<Void, Never>?
        var timerReturned = false
        let fixture = try await ArchiveRuntimeFixture.make(probeSleep: { duration in
            #expect(duration == .milliseconds(5))
            // Model a sleep already completed when cancellation arrives: it returns normally.
            await withCheckedContinuation { sleepingTimer = $0 }
            #expect(Task.isCancelled)
            timerReturned = true
        })
        defer { sleepingTimer?.resume(); fixture.close() }
        let idle = try await fixture.open("idle")
        _ = try await fixture.open("visible")
        var signals: [BrowserArchiveRuntime<SiteSyntheticSurface>.Signal] = []
        fixture.runtime.onSignal = { signals.append($0) }
        fixture.clock.advance(10)
        #expect(await fixture.runtime.scheduler.sweep().map(\.id) == [idle.0])
        try await waitForNativeState("synthetic timeout sleeping") { sleepingTimer != nil }
        #expect(signals.isEmpty)
        let lateTimer = try #require(sleepingTimer)
        sleepingTimer = nil
        lateTimer.resume()
        try await waitForNativeState("cancelled timeout returned") { timerReturned }
        #expect(signals.isEmpty)
    }
}
}
