import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private func switcherController() async throws -> BrowserWindowController<SiteSyntheticEngine> {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic switcher R2")
    let space = try await store.createSpace(name: "Synthetic", profileID: profile)
    let controller = BrowserWindowController(id: UUID(), store: store, spaceID: space,
        engine: SiteSyntheticEngine(), onClose: {}, onActivate: {})
    await controller.session.waitForPendingCommands()
    controller.session.openTab(url: URL(string: "https://switcher.invalid/second")!)
    await controller.session.waitForPendingCommands()
    return controller
}

@MainActor
private func settleSwitcher(_ controller: BrowserWindowController<SiteSyntheticEngine>) async {
    for _ in 0..<30 { await Task.yield(); await controller.session.waitForPendingCommands() }
}

@MainActor
private func switcherEvent(_ controller: BrowserWindowController<SiteSyntheticEngine>,
    type: NSEvent.EventType = .keyDown, keyCode: UInt16 = 48, characters: String = "\t",
    modifiers: NSEvent.ModifierFlags = .control) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeSwitcherRevisionTests {
    @Test("A command delivered after Control is released commits once without opening a gesture")
    func releasedBeforeDelivery() async throws {
        let controller = try await switcherController()
        defer { controller.window?.close() }
        controller.tabSwitcher.controlIsHeld = { false }
        let original = controller.session.snapshot?.selectedOccurrenceID
        controller.tabSwitcher.cycle()
        #expect(!controller.tabSwitcher.model.isActive)
        #expect(controller.tabSwitcher.view.superview == nil)
        await settleSwitcher(controller)
        #expect(controller.session.snapshot?.selectedOccurrenceID != original)

        var publishedSelection: TabOccurrenceID?
        let router = BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>(create: { _ in
            try await Task.sleep(for: .milliseconds(20))
            let window = try await switcherController()
            window.tabSwitcher.controlIsHeld = { false }
            publishedSelection = window.session.snapshot?.selectedOccurrenceID
            return window
        }, present: { _, _ in }, dispose: { $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        router.newWindow()
        #expect(registry.dispatch(.tabSwitcherForward, origin: .keyboard), "accepted during publication")
        await router.waitForPendingCommands()
        let published = try #require(router.selectedWindow)
        await settleSwitcher(published)
        #expect(!published.tabSwitcher.model.isActive)
        #expect(published.tabSwitcher.view.superview == nil)
        #expect(published.session.snapshot?.selectedOccurrenceID != publishedSelection)
    }

    @Test("The CMD monitor handles real modifier events, blocks modal input and keeps two windows independent")
    func commandMonitor() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let router = BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>(create: { _ in
            try await switcherController()
        }, present: { _, _ in }, dispose: { $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true })
        router.newWindow()
        await router.waitForPendingCommands()
        let first = try #require(router.selectedWindow)
        first.tabSwitcher.controlIsHeld = { true }
        let original = first.session.snapshot?.selectedOccurrenceID
        #expect(keyboard.handle(try switcherEvent(first)))
        #expect(first.tabSwitcher.model.isActive)
        let previous = first.tabSwitcher.model.highlightedID
        #expect(keyboard.handle(try switcherEvent(first, modifiers: [.control, .shift])))
        #expect(first.tabSwitcher.model.highlightedID == original)
        #expect(keyboard.handle(try switcherEvent(first)))
        #expect(first.tabSwitcher.model.highlightedID == previous)
        #expect(keyboard.handle(try switcherEvent(first, keyCode: 40, characters: "k")))
        #expect(first.tabSwitcher.model.isActive)
        #expect(keyboard.handle(try switcherEvent(first, type: .flagsChanged, keyCode: 59, characters: "", modifiers: [])))
        await settleSwitcher(first)
        #expect(first.session.snapshot?.selectedOccurrenceID != original)
        #expect(!first.tabSwitcher.model.isActive)
        #expect(keyboard.handle(try switcherEvent(first)))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first.window)
        #expect(!first.tabSwitcher.model.isActive)
        let firstSelection = first.session.snapshot?.selectedOccurrenceID
        router.newWindow()
        await router.waitForPendingCommands()
        let second = try #require(router.selectedWindow)
        second.tabSwitcher.controlIsHeld = { true }
        #expect(keyboard.handle(try switcherEvent(second)))
        #expect(second.tabSwitcher.model.isActive)
        #expect(!first.tabSwitcher.model.isActive)
        let outside = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: -10, y: -10),
            modifierFlags: .control, timestamp: 0, windowNumber: second.window!.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(keyboard.handle(outside), "the cancelling click is consumed")
        #expect(!second.tabSwitcher.model.isActive)
        #expect(first.session.snapshot?.selectedOccurrenceID == firstSelection)
        #expect(first.window?.isVisible == false && second.window?.isVisible == false)
    }

    @Test("LRU keeps visible targets across more than twelve tabs, expires SPA pixels and rejects blank captures")
    func cachePolicy() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let surfaces = (0..<15).map { _ in SwitcherSnapshotSurface() }
        for surface in surfaces { window.contentView?.addSubview(surface.hostView) }
        let cache = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>()
        defer { cache.shutdown() }
        var time: TimeInterval = 0
        cache.now = { time }
        var pendingVisible: Task<Void, Never>?
        for (index, surface) in surfaces.prefix(12).enumerated() {
            let task = cache.request(surface)
            while surface.continuations.isEmpty { await Task.yield() }
            if index == 0 { pendingVisible = task }
            else { surface.complete(generation: 1); await task?.value }
        }
        cache.protect([surfaces[0]])
        for surface in surfaces.suffix(3) {
            let task = cache.request(surface)
            while surface.continuations.isEmpty { await Task.yield() }
            surface.complete(generation: 1)
            await task?.value
        }
        #expect(surfaces[0].continuations.count == 1, "the oldest visible capture remains pending")
        surfaces[0].complete(generation: 1)
        await pendingVisible?.value
        #expect(cache.image(for: surfaces[0]) != nil)
        #expect(cache.image(for: surfaces[1]) == nil)
        #expect(cache.image(for: surfaces[2]) == nil)
        #expect(cache.image(for: surfaces[3]) == nil)
        time = cache.maximumAge + 1
        #expect(cache.image(for: surfaces[0]) == nil)
        let refresh = cache.request(surfaces[0], force: true)
        while surfaces[0].continuations.isEmpty { await Task.yield() }
        surfaces[0].complete(generation: 1, blank: true)
        await refresh?.value
        #expect(cache.image(for: surfaces[0]) == nil)
        surfaces[0].hostView.removeFromSuperview()
        #expect(cache.request(surfaces[0], force: true) == nil, "never ask a detached browser to paint")
    }

    @Test("Outgoing content remains attached until capture completes and rapid return never detaches the selected view")
    func outgoingRetention() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let card = BrowserContentCardView()
        var retirements: [@MainActor () -> Void] = []
        card.scheduleCaptureRetirement = { retirements.append($0) }
        window.contentView = card
        let surface = SwitcherSnapshotSurface()
        let replacement = NSView()
        card.present(surface.hostView)
        let cache = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>()
        defer { cache.shutdown() }
        let capture = cache.request(surface, force: true)
        card.present(replacement, retainingPreviousUntil: capture)
        #expect(surface.hostView.window === window)
        while surface.continuations.isEmpty { await Task.yield() }
        #expect(surface.requests.count == 1)
        #expect(surface.requests[0].afterScreenUpdates)
        card.present(surface.hostView)
        surface.complete(generation: 1)
        await capture?.value
        for _ in 0..<20 { await Task.yield() }
        #expect(surface.hostView.window === window)
        #expect(cache.image(for: surface) != nil)
        let firstRace = cache.request(surface, force: true)
        card.present(replacement, retainingPreviousUntil: firstRace)
        while surface.continuations.isEmpty { await Task.yield() }
        card.present(surface.hostView)
        cache.cancelPendingCapture(for: surface)
        let secondRace = cache.request(surface, force: true)
        card.present(replacement, retainingPreviousUntil: secondRace)
        while surface.continuations.count < 2 { await Task.yield() }
        surface.complete(generation: 1)
        await firstRace?.value
        for _ in 0..<20 { await Task.yield() }
        retirements[0]()
        retirements[1]()
        #expect(surface.hostView.window === window, "an older retirement cannot interrupt a newer capture")
        surface.complete(generation: 1)
        await secondRace?.value
        for _ in 0..<20 { await Task.yield() }
        #expect(surface.hostView.window == nil)
        #expect(cache.image(for: surface) != nil, "detachment keeps the last attached paint")
        card.present(surface.hostView)
        let timed = cache.request(surface, force: true)
        card.present(replacement, retainingPreviousUntil: timed)
        while surface.continuations.isEmpty { await Task.yield() }
        retirements.last?()
        #expect(surface.hostView.window == nil, "timeout detaches an unresponsive outgoing capture")
        surface.complete(generation: 1)
        await timed?.value
    }

    @Test("One hundred tab cycles reuse fitting cards and publish accessibility selection changes")
    func hundredTabs() async throws {
        let controller = try await switcherController()
        defer { controller.window?.close() }
        controller.tabSwitcher.controlIsHeld = { true }
        for index in 2..<100 { controller.session.openTab(url: URL(string: "https://switcher.invalid/\(index)")!) }
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.tabs.count == 100)
        var announcements: [String] = []
        controller.tabSwitcher.view.postSelection = { _, text in announcements.append(text) }
        controller.tabSwitcher.cycle()
        let start = ContinuousClock.now
        controller.tabSwitcher.show()
        let open = start.duration(to: .now)
        #expect(controller.tabSwitcher.model.candidates == Array(controller.session.snapshot!.tabs.reversed().map(\.occurrenceID)),
            "each batched publication contributes its selection in order")
        let allocated = controller.tabSwitcher.view.allocatedCardCount
        let identities = controller.tabSwitcher.view.cardIdentities
        var durations: [Double] = []
        for _ in 0..<100 {
            let start = ContinuousClock.now
            controller.tabSwitcher.cycle()
            let elapsed = start.duration(to: .now).components
            durations.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        #expect(controller.tabSwitcher.view.allocatedCardCount == allocated)
        #expect(controller.tabSwitcher.view.cardIdentities == identities)
        #expect(allocated == BrowserSwitcherView.cardsThatFit(width: controller.window!.contentView!.bounds.width))
        #expect(CGFloat(allocated) * OrbitTokens.Switcher.cardWidth + CGFloat(allocated - 1) * OrbitTokens.Switcher.gap
            + OrbitTokens.Switcher.padding * 2 <= controller.tabSwitcher.view.bounds.width)
        #expect(announcements.count == 101)
        #expect(controller.tabSwitcher.model.candidates.count == 100, "batch publication must keep every MRU entry")
        durations.sort()
        let openParts = open.components
        let openMS = Double(openParts.seconds) * 1000 + Double(openParts.attoseconds) / 1e15
        print("SWITCHER-R2 100 tabs: open=\(openMS)ms, cycle p50=\(durations[50])ms p95=\(durations[95])ms max=\(durations.last!)ms; cards=\(allocated)")
        controller.tabSwitcher.cancel()
    }
}
}
