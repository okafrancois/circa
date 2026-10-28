import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class SpacesSwitcherWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isVisible: Bool { true }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SpacesSwitcherTests {
    private func event(_ phase: Int64, x: Int32 = 0, time: Double) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: 0, wheel2: x, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.timestamp = UInt64(time * 1_000_000_000)
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test("Space hover capsule contains only the Space name and effective shortcut")
    func capsuleContent() {
        let capsule = SidebarSpaceTooltip()
        let size = capsule.configure(name: "Research", shortcut: "⌃4")
        #expect(size.height == 28)
        #expect(SidebarSpaceTooltip.appearanceDelay == 0.45)
        #expect(capsule.name == "Research" && capsule.shortcut == "⌃4")
        #expect(capsule.subviews.compactMap { ($0 as? NSTextField)?.stringValue } == ["Research", "⌃", "4"])
        #expect(capsule.subviews.compactMap { $0 as? NSVisualEffectView }.count == 1)
        #expect(BrowserSpaceCommands.shortcutLabel(at: 0) == "⌃1")
        #expect(BrowserSpaceCommands.shortcutLabel(at: 8) == "⌃9")
        #expect(BrowserSpaceCommands.shortcutLabel(at: 9) == nil)
        _ = capsule.configure(name: "Research", shortcut: nil)
        #expect(capsule.subviews.compactMap { ($0 as? NSTextField)?.stringValue } == ["Research"])
    }

    @Test("All nine Space shortcuts dispatch through the production keyboard on AZERTY number keys")
    func numberedShortcutDispatch() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic shortcut profile")
        var spaces: [SpaceID] = []
        for index in 1...9 { spaces.append(try await store.createSpace(name: "Space \(index)", profileID: profile)) }
        let router = BrowserWindowRouter(create: { id in
            let owner = BrowserWindowController(id: id, store: store, spaceID: spaces[8], engine: SiteSyntheticEngine(),
                opensInitialTab: false, onClose: {}, onActivate: {})
            await owner.session.waitForPendingCommands()
            return owner
        }, present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
            deliver: { $0.performAcceptedCommand($1) })
        BrowserSpaceCommands.install(in: registry)
        router.newWindow()
        await router.waitForPendingCommands()
        let owner = try #require(router.selectedWindow)
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true }, firstResponder: { nil })
        let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let glyphs = Array("&é\"'(-è_ç")
        for index in 0..<9 {
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                timestamp: Double(index), windowNumber: 0, context: nil, characters: String(glyphs[index]),
                charactersIgnoringModifiers: String(glyphs[index]), isARepeat: false, keyCode: codes[index]))
            #expect(registry.resolve(key) == BrowserSpaceCommands.numbered[index])
            #expect(keyboard.handle(key))
            await owner.session.waitForPendingCommands()
            #expect(owner.session.snapshot?.activeSpaceID == spaces[index])
        }
    }

    @Test("Prepared and cold swipe titles include their emoji before the first presented frame")
    func firstFrameEmoji() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let first = try await store.createSpace(name: "First", profileID: profile)
        let second = try await store.createSpace(name: "Research", profileID: profile)
        let document = await store.sessionDocument()
        let target = try #require(document.spaces.first { $0.id == second })
        for prepared in [false, true] {
            let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 640))
            sidebar.resolveSpaceIcon = { $0 == second ? .grapheme("🧪") : .none }
            sidebar.render(catalog: await store.catalogSnapshot(), activeSpaceID: first, organization: nil)
            sidebar.layoutSubtreeIfNeeded()
            if prepared { sidebar.prepareSpaceSwipeNeighbors(document: document, active: first, resolveTheme: { _ in .default }) }
            sidebar.showSpaceSwipe(offset: -1, space: target, content: .empty)
            func pages(_ view: NSView) -> [SidebarSpacePageView] {
                (view as? SidebarSpacePageView).map { [$0] } ?? view.subviews.flatMap { pages($0) }
            }
            let preview = try #require(pages(sidebar).first { $0.spaceID == second })
            #expect(preview.iconSelection == .grapheme("🧪"))
            sidebar.adoptSpaceSwipeDestination(second)
            #expect(sidebar.page === preview && sidebar.page.iconSelection == .grapheme("🧪"))
            sidebar.finishSpaceSwipe(committed: nil)
        }
    }

    @Test("Fast release uses warm metadata without waiting for an actor read; trailing overscroll opens creation once")
    func warmReleaseAndCreation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let first = try await store.createSpace(name: "First", profileID: profile)
        let second = try await store.createSpace(name: "Second", profileID: profile)
        let catalog = await store.catalogSnapshot(), document = await store.sessionDocument()
        let window = SpacesSwitcherWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sidebar = BrowserSidebarView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(sidebar)
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let swipe = sidebar.spaceSwipe
        swipe.loadDocument = { document }
        swipe.automaticallyAdvances = false
        swipe.clock = { 10 }
        sidebar.render(catalog: catalog, activeSpaceID: first, organization: nil)
        sidebar.layoutSubtreeIfNeeded()
        for _ in 0..<30 { await Task.yield() }
        var committed: SpaceID?
        swipe.commit = { target, _, _, _, _ in committed = target }
        _ = swipe.handleScroll(try event(1, time: 1), inside: true)
        _ = swipe.handleScroll(try event(2, x: -20, time: 1.01), inside: true)
        _ = swipe.handleScroll(try event(4, time: 1.02), inside: true)
        #expect(committed == second)
        swipe.cancel()
        var creations = 0
        sidebar.onNewSpace = { creations += 1 }
        sidebar.render(catalog: catalog, activeSpaceID: second, organization: nil)
        sidebar.layoutSubtreeIfNeeded()
        _ = swipe.handleScroll(try event(1, time: 2), inside: true)
        _ = swipe.handleScroll(try event(2, x: -320, time: 2.04), inside: true)
        #expect(sidebar.newSpaceSwipePage != nil && creations == 0)
        _ = swipe.handleScroll(try event(4, time: 2.05), inside: true)
        _ = swipe.advance(to: 12)
        #expect(creations == 1 && sidebar.newSpaceSwipePage == nil)
        _ = swipe.advance(to: 13)
        #expect(creations == 1)
        _ = swipe.handleScroll(try event(1, time: 3), inside: true)
        _ = swipe.handleScroll(try event(2, x: -320, time: 3.04), inside: true)
        _ = swipe.handleScroll(try event(8, time: 3.05), inside: true)
        _ = swipe.advance(to: 14)
        #expect(creations == 1)
    }

    @Test("Cold Space contact can release before metadata loading without rejecting its valid destination")
    func coldReleaseBeforeMetadata() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic cold contact")
        let first = try await store.createSpace(name: "First", profileID: profile)
        let second = try await store.createSpace(name: "Second", profileID: profile)
        let window = SpacesSwitcherWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sidebar = BrowserSidebarView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(sidebar)
        defer { sidebar.spaceSwipe.detach(); window.close() }
        sidebar.render(catalog: await store.catalogSnapshot(), activeSpaceID: first, organization: nil)
        sidebar.layoutSubtreeIfNeeded()
        let swipe = sidebar.spaceSwipe
        swipe.automaticallyAdvances = false
        swipe.clock = { 10 }
        var target: SpaceID?
        swipe.commit = { destination, _, _, _, _ in target = destination }
        _ = swipe.handleScroll(try event(1, time: 1), inside: true)
        _ = swipe.handleScroll(try event(2, x: -20, time: 1.01), inside: true)
        _ = swipe.handleScroll(try event(4, time: 1.02), inside: true)
        #expect(target == second)
    }
}
}

@Test("Space pager releases fast and short contacts by direction and slow contacts by nearest page")
func spacePagerReleasePolicy() {
    for (distance, duration) in [(12.0, 0.02), (80, 0.08), (120, 0.8)] {
        var gesture = SpaceSwipeGesture()
        gesture.update(x: 0, y: 0, time: 1, translationScale: 0)
        let count = 10
        for i in 1...count { gesture.update(x: -distance / Double(count), y: 0, time: 1 + duration * Double(i) / Double(count)) }
        #expect(gesture.destination(width: 228, hasPrevious: true, hasNext: true, at: 1 + duration) == 1)
    }
    var held = SpaceSwipeGesture()
    held.update(x: -50, y: 0, time: 1)
    #expect(held.destination(width: 228, hasPrevious: true, hasNext: true, at: 2) == nil)
    held.update(x: -80, y: 0, time: 2)
    #expect(held.destination(width: 228, hasPrevious: true, hasNext: true, at: 3) == 1)
}
