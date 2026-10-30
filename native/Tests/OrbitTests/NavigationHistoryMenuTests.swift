import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class HistoryServices: BrowserNativePageServices {
    var history: BrowserNavigationHistory
    var jumps: [Int] = []
    var acceptsJump = true
    init(_ history: BrowserNavigationHistory) { self.history = history }
    func navigationHistory() -> BrowserNavigationHistory? { history }
    func goToEntry(index: Int) -> Bool { jumps.append(index); return acceptsJump }
    func securityState() -> BrowserPageSecurityState? { nil }
    func securityChanges() -> AsyncStream<BrowserPageSecurityState> { AsyncStream { $0.finish() } }
    func fullscreenChanges() -> AsyncStream<BrowserPageFullscreenChange> { AsyncStream { $0.finish() } }
    func committedURL() -> URL? { nil }
    func securityDisplay(for url: URL, scheme: BrowserSecuritySchemeDisplay) -> String? { nil }
    func mediaState() -> BrowserMediaSessionState? { nil }
    func mediaChanges() -> AsyncStream<BrowserMediaSessionState> { AsyncStream { $0.finish() } }
    func mediaAction(_ action: BrowserMediaAction, seconds: Double) -> Bool { false }
}

@MainActor
private final class HistoryClickTarget: NSObject {
    var clicks = 0
    @objc func click(_ sender: Any?) { clicks += 1 }
}

private func historyFixture() throws -> BrowserNavigationHistory {
    try JSONDecoder().decode(BrowserNavigationHistory.self, from: Data(#"{"currentIndex":2,"entries":[{"index":4,"url":"https://four.invalid/","title":"Four"},{"index":1,"url":"https://one.invalid/","title":"One"},{"index":2,"url":"https://two.invalid/","title":"Current"},{"index":0,"url":"https://zero.invalid/","title":""},{"index":3,"url":"https://three.invalid/","title":"Three"}]}"#.utf8))
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NavigationHistoryMenuTests {
    @Test("Native menus sort each direction nearest first and exclude the current entry")
    func contentAndFavicons() throws {
        let history = try historyFixture()
        let cached = NSImage(size: NSSize(width: 32, height: 32))
        var lookups: [URL] = []
        let back = BrowserNavigationHistoryMenu(history: history, direction: .back, favicon: {
            lookups.append($0); return $0.host == "one.invalid" ? cached : nil
        }, select: { _, _ in })
        #expect(back.menu.items.map(\.title) == ["One", "https://zero.invalid/"])
        #expect(lookups.map(\.host) == ["one.invalid", "zero.invalid"])
        #expect(back.menu.items.allSatisfy { $0.view == nil && $0.image != nil })
        if #available(macOS 27.0, *) {
            #expect(back.menu.items.allSatisfy { $0.preferredImageVisibility == .visible })
        }
        #expect(back.menu.items[0].image?.size == NSSize(width: 16, height: 16))
        #expect(cached.size == NSSize(width: 32, height: 32))
        let forward = BrowserNavigationHistoryMenu(history: history, direction: .forward, favicon: { _ in nil }, select: { _, _ in })
        #expect(forward.menu.items.map(\.title) == ["Three", "Four"])
        #expect(!forward.menu.autoenablesItems)
    }

    @Test("Menu selection routes the indexed entry and Command selects a new tab")
    func menuModifiers() throws {
        var routed: [(Int, Bool)] = []
        let presentation = BrowserNavigationHistoryMenu(history: try historyFixture(), direction: .back,
            favicon: { _ in nil }, select: { routed.append(($0.index, $1)) })
        presentation.activate(presentation.menu.items[0], modifiers: [])
        presentation.activate(presentation.menu.items[1], modifiers: [.command])
        #expect(routed.map(\.0) == [1, 0])
        #expect(routed.map(\.1) == [false, true])
    }

    @Test("The hold clock uses AppKit's delay and cancels a press without opening early")
    func pressTiming() {
        var clock: TimeInterval = 10
        var hold = BrowserNavigationHold(now: { clock })
        #expect(hold.delay == NSPressGestureRecognizer().minimumPressDuration)
        #expect(hold.remaining == nil)
        hold.begin()
        clock += hold.delay / 2
        #expect((hold.remaining ?? 0) > 0)
        clock = 10 + hold.delay
        #expect(hold.remaining == 0)
        hold.cancel()
        #expect(hold.remaining == nil)
    }

    @Test("Short clicks preserve the button action; holds and right clicks build menus lazily")
    func buttonTracking() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = BrowserNavigationGlyphButton(glyph: nil, label: "")
        window.contentView?.addSubview(button)
        let target = HistoryClickTarget()
        button.target = target
        button.action = #selector(HistoryClickTarget.click(_:))
        var menuRequests = 0
        button.navigation.makeMenu = { menuRequests += 1; return nil }
        let point = button.convert(NSPoint(x: 5, y: 5), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        }
        let up = try event(.leftMouseUp)
        button.navigation.nextEvent = { _ in up }
        button.mouseDown(with: try event(.leftMouseDown))
        #expect(menuRequests == 0 && target.clicks == 1)
        var reads = 0
        let delay = button.navigation.hold.delay
        button.navigation.hold = BrowserNavigationHold(now: { reads += 1; return reads == 1 ? 0 : delay })
        button.mouseDown(with: try event(.leftMouseDown))
        #expect(menuRequests == 1 && target.clicks == 1)
        #expect(!button.isHighlighted)
        button.rightMouseDown(with: try event(.rightMouseDown))
        #expect(menuRequests == 2)
        button.isEnabled = false
        button.rightMouseDown(with: try event(.rightMouseDown))
        #expect(menuRequests == 2)
    }

    @Test("Command and middle clicks open beside the source in the background, including ephemeral profiles")
    func shellRouting() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let engine = SiteSyntheticEngine()
        let profile = await store.createProfile(name: "Synthetic history")
        let space = try await store.createSpace(name: "History", profileID: profile)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: space, engine: engine,
                                                 onClose: {}, onActivate: {})
        defer { controller.session.close(); controller.window?.close() }
        await controller.session.waitForQueuedCommands()
        for url in ["https://older.invalid/", "https://two.invalid/", "https://other.invalid/"] {
            controller.session.openTab(url: URL(string: url)!)
            await controller.session.waitForQueuedCommands()
        }
        let sourceTab = try #require(controller.session.snapshot?.tabs.first { $0.url.host == "two.invalid" })
        controller.session.selectOccurrence(sourceTab.occurrenceID)
        await controller.session.waitForQueuedCommands()
        let surface = try #require(controller.session.selectedSurface)
        let api = HistoryServices(try historyFixture())
        surface.nativePageServices = api
        #expect(engine.profiles[profile]?.persistence == .ephemeral)
        let back = try #require(controller.backButton.navigation.makeMenu?())
        back.activate(back.menu.items[0], modifiers: [])
        #expect(api.jumps == [1])
        let entry = api.history.entries.first { $0.index == 0 }!
        api.acceptsJump = false
        controller.routeHistoryEntry(entry, on: surface, adjacent: false)
        #expect(api.jumps == [1, 0])
        #expect(controller.session.selectedSurface === surface)
        controller.backButton.isEnabled = true
        let point = controller.backButton.convert(NSPoint(x: 5, y: 5), to: nil)
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [.command],
            timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        controller.backButton.navigation.nextEvent = { _ in up }
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [.command],
            timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        controller.backButton.mouseDown(with: down)
        await controller.session.waitForQueuedCommands()
        func checkAdjacent(_ host: String) throws {
            #expect(controller.session.selectedSurface === surface)
            let order = try #require(controller.session.organization?.tabNavigationItems)
            let index = try #require(order.firstIndex { $0.id == sourceTab.id })
            #expect(order[index + 1].url.host == host)
        }
        try checkAdjacent("one.invalid")
        controller.forwardButton.isEnabled = true
        let forwardEvent = try #require(NSEvent.mouseEvent(with: .otherMouseUp,
            location: controller.forwardButton.convert(NSPoint(x: 5, y: 5), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        let cgEvent = try #require(forwardEvent.cgEvent)
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        let forwardMiddle = try #require(NSEvent(cgEvent: cgEvent))
        #expect(forwardMiddle.buttonNumber == 2)
        controller.forwardButton.otherMouseDown(with: forwardMiddle)
        controller.forwardButton.otherMouseUp(with: forwardMiddle)
        await controller.session.waitForQueuedCommands()
        try checkAdjacent("three.invalid")
        let menu = try #require(controller.backButton.navigation.makeMenu?())
        menu.activate(menu.menu.items[1], modifiers: [.command])
        await controller.session.waitForQueuedCommands()
        try checkAdjacent("zero.invalid")
        #expect(api.jumps == [1, 0])
        // A previously built menu must not act on a later document generation.
        let count = controller.session.snapshot?.tabs.count
        surface.navigate(to: URL(string: "https://later.invalid/")!)
        menu.activate(menu.menu.items[0], modifiers: [.command])
        await controller.session.waitForQueuedCommands()
        #expect(controller.session.snapshot?.tabs.count == count)
        for width: CGFloat in [164, 180, 223, 224] {
            let toolbar = OrbitSidebarGeometry.Toolbar.resolve(width: width)
            #expect(toolbar.backCenterX - toolbar.hitWidth / 2 >= 0)
            #expect(toolbar.forwardCenterX + toolbar.hitWidth / 2 <= width)
        }
        let cache = controller.sidebarIcons.memoryCache
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        cache.put(icon, profile: profile, home: entry.url)
        #expect(cache.image(profile: ProfileID(), home: entry.url) == nil)
        #expect(cache.image(profile: profile, home: entry.url) === icon)
    }
}
}
