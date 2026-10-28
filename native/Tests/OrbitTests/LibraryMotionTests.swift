import AppKit
import BrowserCore
import QuartzCore
import Testing
@testable import Orbit

@Test("Library contact applies Orbit's half scroll delta and reverses continuously")
func libraryMotionProgress() {
    var swipe = LibrarySwipeGesture(presented: false, visibleWidth: 0, width: 420)
    swipe.update(x: 80, y: 1, time: 1)
    #expect(swipe.takesBoundary && swipe.visibleWidth == 40)
    swipe.update(x: -30, y: 0, time: 1.1)
    #expect(swipe.visibleWidth == 25)
    #expect(!swipe.destination(at: 1.3, cancelled: false))
    swipe.update(x: 800, y: 0, time: 1.4)
    #expect(swipe.visibleWidth == 420)
    #expect(swipe.destination(at: 1.6, cancelled: false))
}

@Test("Library release selects the nearest page or follows a recent velocity, and cancellation restores the source")
func libraryMotionThresholds() {
    var short = LibrarySwipeGesture(presented: false, visibleWidth: 0, width: 420)
    short.update(x: 418, y: 0, time: 1)
    #expect(!short.destination(at: 1.2, cancelled: false))
    short.update(x: 4, y: 0, time: 1.3)
    #expect(short.destination(at: 1.5, cancelled: false))
    #expect(!short.destination(at: 1.5, cancelled: true))
    short.update(x: -8, y: 0, time: 1.31)
    #expect(!short.destination(at: 1.31, cancelled: false))
    var flick = LibrarySwipeGesture(presented: false, visibleWidth: 0, width: 420)
    flick.update(x: 20, y: 0, time: 1)
    flick.update(x: 40, y: 0, time: 1.01)
    #expect(flick.destination(at: 1.01, cancelled: false))
    #expect(!flick.destination(at: 1.2, cancelled: false))
    var closing = LibrarySwipeGesture(presented: true, visibleWidth: 420, width: 420)
    closing.update(x: -500, y: 0, time: 1)
    #expect(closing.visibleWidth == 170)
    #expect(!closing.destination(at: 1.2, cancelled: false))
    #expect(closing.destination(at: 1.2, cancelled: true))
}

@Test("Library began seeds velocity without displacing the native page")
func libraryMotionBegan() {
    var swipe = LibrarySwipeGesture(presented: false, visibleWidth: 0, width: 417)
    swipe.update(x: 4, y: 0, time: 1, began: true)
    #expect(swipe.gesture.intent == .horizontal && !swipe.takesBoundary && swipe.visibleWidth == 0)
    swipe.update(x: 4, y: 0, time: 1.01)
    #expect(swipe.visibleWidth == 2)
    #expect(abs(swipe.gesture.releaseVelocity(at: 1.01) - 200) < 0.001)
}

@Test("Library leaves vertical input and the next Space to their existing owners")
func libraryMotionAxisOwnership() {
    var vertical = LibrarySwipeGesture(presented: false, visibleWidth: 0, width: 420)
    vertical.update(x: 1, y: 18, time: 1)
    #expect(!vertical.takesBoundary)
    var next = LibrarySwipeGesture(presented: false, visibleWidth: 0, width: 420)
    next.update(x: -80, y: 0, time: 1)
    #expect(!next.takesBoundary)
}

@MainActor
private final class LibraryMotionWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isVisible: Bool { true }
}

extension NativeWebKitTests {
@Suite("Library interactive motion", .serialized)
@MainActor
struct LibraryMotionTests {
    @Test("An external close cannot be undone by a late gesture cancellation")
    func externalCloseWins() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic motion profile")
        let space = try await store.createSpace(name: "Synthetic motion Space", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: space,
            engine: SiteSyntheticEngine(), restoringWindowID: window, onClose: {}, onActivate: {})
        defer { controller.session.close(); controller.window?.close() }
        await controller.session.waitForPendingCommands()
        controller.showLibrary()
        await controller.session.waitForPendingCommands()
        #expect(controller.library.isPresented && controller.library.drawer.isPresented)
        controller.hideLibrary()
        controller.library.swipe.finish?(true, 0)
        #expect(!controller.library.isPresented && !controller.library.drawer.isPresented)
        #expect(controller.library.view.isHidden)
    }

    private func event(_ phase: Int64, _ x: Int32 = 0, y: Int32 = 0) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                     wheel1: y, wheel2: x, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test("The real boundary hook tracks the drawer then settles cancellation and commitment")
    func boundaryController() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = LibraryMotionWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = try #require(window.contentView)
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 780))
        let view = BrowserLibraryView(frame: NSRect(x: 0, y: 0, width: 420, height: 780))
        root.addSubview(sidebar); root.addSubview(view)
        let drawer = BrowserLibraryDrawer()
        drawer.install(view: view, root: root, leading: view.leadingAnchor.constraint(equalTo: root.leadingAnchor))
        let swipe = BrowserLibrarySwipeController()
        defer { swipe.detach(); sidebar.spaceSwipe.detach(); window.close() }
        var time = 10.0
        drawer.animation.clock = { time }
        swipe.canOpen = { true }; swipe.canInteract = { true }
        swipe.beginOpening = { drawer.setPresented(true) }
        var cancelledVelocity: Double?
        swipe.finish = { presented, velocity in cancelledVelocity = velocity; drawer.setPresented(presented, velocity: velocity) }
        swipe.install(view: view, drawer: drawer, sidebar: sidebar)
        #expect(!swipe.handleOpening(try event(1, 4), inside: true))
        #expect(!swipe.handleOpening(try event(2), inside: true))
        #expect(drawer.animation.value == 0 && !swipe.ownsGesture)
        #expect(sidebar.spaceSwipe.handleScroll(try event(2, 80), inside: true))
        #expect(abs(drawer.animation.value * 420 - 40) < 0.001)
        #expect(!drawer.animation.isAnimating && swipe.ownsGesture)
        #expect(sidebar.spaceSwipe.handleScroll(try event(8), inside: true))
        #expect(cancelledVelocity == 0)
        time = 12
        drawer.animation.advance(to: time)
        #expect(!drawer.isPresented && view.isHidden && drawer.animation.value == 0)
        #expect(!swipe.ownsGesture)
        #expect(!swipe.handleOpening(try event(1), inside: true))
        #expect(sidebar.spaceSwipe.handleScroll(try event(2, 520), inside: true))
        #expect(sidebar.spaceSwipe.handleScroll(try event(4), inside: true))
        time = 14
        drawer.animation.advance(to: time)
        #expect(drawer.isPresented && !view.isHidden && drawer.animation.value == 1)
    }

    @Test("Library maps the native pager coordinate to centred scale, inward translation and early fade")
    func nativeParameters() {
        #expect(LibraryMotion.spring.response == 0.4)
        #expect(LibraryMotion.spring.dampingFraction == 1)
        #expect(LibraryMotion.sidebarScale(at: 0) == 1)
        #expect(LibraryMotion.sidebarScale(at: 1) == 0.9)
        #expect(LibraryMotion.sidebarTranslation(at: 1) == 26)
        #expect(LibraryMotion.sidebarOpacity(at: 0) == 1)
        #expect(LibraryMotion.sidebarOpacity(at: 0.25) == 0.5)
        #expect(LibraryMotion.sidebarOpacity(at: 0.5) == 0)
        #expect(LibraryMotion.sidebarOpacity(at: 1) == 0)
        let panel = OrbitSpringAnimator(value: 0)
        var time = 10.0
        panel.clock = { time }
        panel.beginSegment(to: 1, spring: LibraryMotion.spring, velocity: 0)
        time += 0.1
        panel.advance(to: time)
        #expect(abs(panel.value - 0.46558) < 0.0001)
        #expect(abs(LibraryMotion.sidebarScale(at: panel.value) - 0.95344) < 0.0001)
        #expect(abs(LibraryMotion.sidebarOpacity(at: panel.value) - 0.06883) < 0.0001)
        time += 1
        panel.advance(to: time)
        #expect(panel.value == 1 && !panel.isAnimating)
    }

    @Test("Library resolves native point position and point velocity independently")
    func nativeResolution() {
        let panel = LibrarySpringAnimator()
        panel.pointsPerUnit = 417
        panel.clock = { 10 }
        panel.beginSegment(to: 1, spring: LibraryMotion.spring, velocity: 0)
        panel.advance(to: 10.86)
        #expect(abs(panel.value - 1) * 417 < 0.01)
        #expect(abs(panel.currentState(at: 10.86).velocity) * 417 > 0.01)
        #expect(panel.isAnimating)
        panel.advance(to: 11.1)
        #expect(panel.value == 1 && !panel.isAnimating)
    }
}
}
