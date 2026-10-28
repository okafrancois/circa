import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeSwitcherTests {
    @Test("MRU changes only on committed selection, cycles both ways and cancels without mutation")
    func history() {
        let model = BrowserTabSwitcherModel()
        let space = SpaceID(), a = TabOccurrenceID(), b = TabOccurrenceID(), c = TabOccurrenceID()
        model.reconcile(space: space, available: [a, b, c], selected: a)
        model.reconcile(space: space, available: [a, b, c], selected: b)
        model.reconcile(space: space, available: [a, b, c], selected: c)
        model.cycle()
        #expect(model.candidates == [c, b, a])
        #expect(model.highlightedID == b)
        model.cycle(backward: true)
        #expect(model.highlightedID == c)
        model.cancel()
        #expect(model.releaseControl() == nil)
        model.cycle()
        #expect(model.releaseControl() == b)
        #expect(!model.isActive)
    }

    @Test("Histories are Space-local and removed occurrences cannot be committed")
    func spacesAndRemoval() {
        let model = BrowserTabSwitcherModel()
        let one = SpaceID(), two = SpaceID(), a = TabOccurrenceID(), b = TabOccurrenceID(), c = TabOccurrenceID()
        model.reconcile(space: one, available: [a, b], selected: a)
        model.cycle()
        model.reconcile(space: two, available: [c], selected: c)
        #expect(!model.isActive)
        model.cycle()
        #expect(!model.isActive)
        model.reconcile(space: one, available: [a, b], selected: a)
        model.cycle()
        #expect(model.removeHighlighted() == b)
        #expect(model.releaseControl() == a)
    }

    @Test("External selection cancels an active gesture")
    func externalSelection() {
        let model = BrowserTabSwitcherModel()
        let space = SpaceID(), a = TabOccurrenceID(), b = TabOccurrenceID()
        model.reconcile(space: space, available: [a, b], selected: a)
        model.cycle()
        model.reconcile(space: space, available: [a, b], selected: b)
        #expect(!model.isActive)
    }

    @Test("Production registry scopes Control-W and release activates the highlighted occurrence in a hidden window")
    func commands() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic switcher")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let engine = SiteSyntheticEngine()
        let router = BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>(create: { id in
            let controller = BrowserWindowController(id: id, store: store, spaceID: space, engine: engine,
                onClose: {}, onActivate: {})
            await controller.session.waitForPendingCommands()
            return controller
        }, present: { _, _ in }, dispose: { $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        router.newWindow()
        await router.waitForPendingCommands()
        let owner = try #require(router.selectedWindow)
        owner.tabSwitcher.controlIsHeld = { true }
        owner.session.openTab(url: URL(string: "https://switcher.invalid/second")!)
        await owner.session.waitForPendingCommands()
        let initial = try #require(owner.session.snapshot?.selectedOccurrenceID)
        #expect(registry.dispatch(.tabSwitcherForward, origin: .keyboard))
        let previous = try #require(owner.tabSwitcher.model.highlightedID)
        #expect(previous != initial)
        #expect(registry.activeScope == .switcher)
        #expect(owner.session.snapshot?.selectedOccurrenceID == initial)
        #expect(owner.tabSwitcher.view.superview == nil, "a quick tap has no overlay")
        owner.tabSwitcher.modifiersChanged(controlHeld: true)
        #expect(owner.tabSwitcher.model.isActive)
        owner.tabSwitcher.modifiersChanged(controlHeld: false)
        for _ in 0..<20 { await Task.yield(); await owner.session.waitForPendingCommands() }
        #expect(owner.session.snapshot?.selectedOccurrenceID == previous)
        #expect(registry.activeScope == .browser)
        owner.session.openTab(url: URL(string: "https://switcher.invalid/close-race")!)
        await owner.session.waitForPendingCommands()
        registry.dispatch(.tabSwitcherForward, origin: .keyboard)
        let closedTarget = try #require(owner.tabSwitcher.model.highlightedID)
        #expect(registry.resolve(.init(key: "w", modifiers: .control)) == .closeSwitcherTab)
        #expect(registry.dispatch(.closeSwitcherTab, origin: .keyboard))
        let closeNeighbor = owner.tabSwitcher.model.highlightedID
        owner.tabSwitcher.modifiersChanged(controlHeld: false)
        for _ in 0..<20 { await Task.yield(); await owner.session.waitForPendingCommands() }
        #expect(owner.session.snapshot?.tabs.contains { $0.occurrenceID == closedTarget } == false)
        #expect(owner.session.snapshot?.selectedOccurrenceID == closeNeighbor)
        owner.tabSwitcher.cancel()
        owner.session.openTab(url: URL(string: "https://switcher.invalid/third")!)
        await owner.session.waitForPendingCommands()
        let beforeCancel = owner.session.snapshot?.selectedOccurrenceID
        registry.dispatch(.tabSwitcherForward, origin: .keyboard)
        let revealDeadline = ContinuousClock.now + .seconds(5)
        while owner.tabSwitcher.view.superview == nil, ContinuousClock.now < revealDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(owner.tabSwitcher.view.superview != nil, "a held gesture reveals the hidden overlay")
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: owner.window!.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(owner.tabSwitcher.handle(escape))
        #expect(owner.session.snapshot?.selectedOccurrenceID == beforeCancel)
        #expect(owner.tabSwitcher.view.superview == nil)
        #expect(!owner.tabSwitcher.model.isActive)
        registry.dispatch(.tabSwitcherForward, origin: .keyboard)
        let clickTarget = try #require(owner.tabSwitcher.model.highlightedID)
        owner.tabSwitcher.view.onHover?(try #require(beforeCancel))
        #expect(owner.tabSwitcher.model.highlightedID == beforeCancel)
        #expect(owner.session.snapshot?.selectedOccurrenceID == beforeCancel)
        owner.tabSwitcher.view.onChoose?(clickTarget)
        for _ in 0..<20 { await Task.yield(); await owner.session.waitForPendingCommands() }
        #expect(owner.session.snapshot?.selectedOccurrenceID == clickTarget)
        #expect(owner.window?.isVisible == false)
    }
    @Test("Snapshot cache rejects replaced documents and revoked same-generation completions")
    func snapshotInvalidation() async {
        let surface = SwitcherSnapshotSurface()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(surface.hostView)
        defer { window.close() }
        let cache = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>()
        defer { cache.shutdown() }
        cache.request(surface)
        for _ in 0..<20 { await Task.yield() }
        #expect(surface.requests.first?.documentGeneration == 1)
        surface.findDocumentGeneration = 2
        surface.complete(generation: 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(cache.image(for: surface) == nil)
        cache.request(surface)
        for _ in 0..<20 { await Task.yield() }
        cache.invalidate(surface)
        surface.complete(generation: 2)
        for _ in 0..<20 { await Task.yield() }
        #expect(cache.image(for: surface) == nil)
        cache.request(surface)
        for _ in 0..<20 { await Task.yield() }
        surface.complete(generation: 2)
        for _ in 0..<20 { await Task.yield() }
        #expect(cache.image(for: surface) != nil)
        let count = surface.requests.count
        cache.request(surface)
        #expect(surface.requests.count == count)
        surface.navigationState.isLoading = true
        #expect(cache.image(for: surface) == nil)
        cache.request(surface)
        surface.navigationState.isLoading = false
        #expect(cache.image(for: surface) == nil)
    }

    @Test("Cache retirement and disposal reject captures even without a generation change")
    func snapshotRetirement() async {
        let surface = SwitcherSnapshotSurface()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(surface.hostView)
        defer { window.close() }
        let cache = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>()
        cache.request(surface)
        for _ in 0..<20 { await Task.yield() }
        cache.retain([])
        surface.complete(generation: 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(cache.image(for: surface) == nil)
        cache.request(surface)
        for _ in 0..<20 { await Task.yield() }
        surface.dispose()
        surface.complete(generation: 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(cache.image(for: surface) == nil)
        cache.shutdown()
    }

}
}
