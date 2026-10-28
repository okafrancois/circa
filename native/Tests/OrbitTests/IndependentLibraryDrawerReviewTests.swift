import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

/// Reports visibility to the animation policy without ever ordering a window on screen.
/// This exercises the real drawer/coordinator with a manually advanced display timebase;
/// it does not establish rendered frames or real display-link scheduling.
@MainActor
private final class ReviewMotionWindow: NSWindow {
    override var isVisible: Bool { true }
}

extension NativeWebKitTests {
@Suite("Independent Library drawer review", .serialized)
@MainActor
struct IndependentLibraryDrawerReviewTests {
    private func makeController(motionWindow: Bool = true, reducedMotion: Bool = false) async throws -> (BrowserWindowController<SiteSyntheticEngine>, SpaceID) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let a = await store.createProfile(name: "Review synthetic A")
        let b = await store.createProfile(name: "Review synthetic B")
        let first = try await store.createSpace(name: "Review A", profileID: a)
        let second = try await store.createSpace(name: "Review B", profileID: b)
        let identity = try await store.createWindow(activeSpaceID: first)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: first,
            engine: SiteSyntheticEngine(), restoringWindowID: identity, onClose: {}, onActivate: {})
        controller.library.drawer.prefersReducedMotion = { reducedMotion }
        await controller.session.waitForPendingCommands()
        if motionWindow {
            let original = try #require(controller.window)
            let root = try #require(original.contentView)
            original.delegate = nil
            original.contentView = nil
            let simulated = ReviewMotionWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720),
                styleMask: [.borderless], backing: .buffered, defer: false)
            simulated.isReleasedWhenClosed = false
            simulated.contentView = root
            controller.window = simulated
            simulated.delegate = controller
            original.close()
        }
        controller.session.openTab(url: URL(string: "https://review-drawer.fixture.test/document")!)
        await controller.session.waitForPendingCommands()
        return (controller, second)
    }

    @Test("Real coordinator retargets a closing drawer and cleans up once at final closure")
    func retargetAndClose() async throws {
        let (c, _) = try await makeController()
        defer { c.session.close(); c.window?.close() }
        let root = try #require(c.window?.contentView)
        let start = CACurrentMediaTime()
        var time = start
        let drawer = c.library.drawer
        drawer.animation.clock = { time }
        let cleanup = drawer.onClosed
        var count = 0
        drawer.onClosed = { count += 1; cleanup?() }
        c.showLibrary(.downloads)
        await c.session.waitForPendingCommands()
        #expect(drawer.animation.isAnimating)
        var lastX = -Double.infinity
        for step in 1...8 {
            time = start + Double(step) / 120
            drawer.animation.advance(to: time)
            root.layoutSubtreeIfNeeded()
            let frame = c.library.view.convert(c.library.view.bounds, to: root)
            #expect(frame.minX >= lastX)
            #expect(frame.minX <= 0 && frame.maxX <= 420.01)
            lastX = frame.minX
            let point = NSPoint(x: max(1, frame.maxX - 8), y: frame.midY)
            let hit = root.hitTest(point)
            if frame.maxX > 1 {
                #expect(c.sidebar.isLibraryInputSuppressed)
                #expect(hit?.isDescendant(of: c.library.view) == true)
            }
        }
        c.hideLibrary(focus: false)
        #expect(!c.library.view.acceptsLibraryInput)
        #expect(!c.library.view.isHidden)
        #expect(count == 0)
        time += 0.02
        drawer.animation.advance(to: time)
        c.showLibrary(.history)
        await c.session.waitForPendingCommands()
        #expect(c.library.isPresented && c.library.view.acceptsLibraryInput)
        #expect(count == 0)
        time += 4
        drawer.animation.advance(to: time)
        #expect(!drawer.animation.isAnimating && !c.library.view.isHidden)
        #expect(c.library.category == .history)
        #expect(count == 0)
        c.hideLibrary(focus: false)
        time += 4
        drawer.animation.advance(to: time)
        drawer.animation.advance(to: time + 4)
        #expect(count == 1)
        #expect(c.library.view.isHidden && !drawer.animation.isAnimating)
        #expect(c.library.displayedProfileID == nil)
        #expect(c.library.history.profileID == nil)
    }

    @Test("Profile switch during outgoing motion synchronously retires the old profile")
    func outgoingProfile() async throws {
        let (c, other) = try await makeController()
        defer { c.session.close(); c.window?.close() }
        let start = CACurrentMediaTime()
        var time = start
        let drawer = c.library.drawer
        drawer.animation.clock = { time }
        c.showLibrary(.downloads)
        await c.session.waitForPendingCommands()
        time = start + 1
        drawer.animation.advance(to: time)
        c.hideLibrary(focus: false)
        #expect(drawer.animation.isAnimating)
        c.session.activateSpace(other)
        await c.session.waitForPendingCommands()
        #expect(c.library.view.isHidden)
        #expect(c.library.displayedProfileID == nil)
        #expect(!drawer.animation.isAnimating)
        #expect(c.downloadsProfileID == nil)
    }

    @Test("Reduced Motion changes mid-flight and hidden window closure retire animation ownership")
    func accessibilityAndClosure() async throws {
        let (c, _) = try await makeController()
        defer { c.session.close(); c.window?.close() }
        let drawer = c.library.drawer
        var reducedMotion = false
        drawer.prefersReducedMotion = { reducedMotion }
        let start = CACurrentMediaTime()
        var time = start
        drawer.animation.clock = { time }
        c.showLibrary(.archive)
        await c.session.waitForPendingCommands()
        time = start + 0.04
        drawer.animation.advance(to: time)
        reducedMotion = true
        time += 0.01
        drawer.animation.advance(to: time)
        #expect(!drawer.animation.isAnimating && drawer.animation.value == 1)
        reducedMotion = false
        c.hideLibrary(focus: false)
        #expect(drawer.animation.isAnimating)
        c.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: c.window))
        #expect(!drawer.animation.isAnimating && drawer.animation.value == 0)
        #expect(c.library.view.isHidden && !c.library.view.acceptsLibraryInput)
        #expect(c.library.displayedProfileID == nil)
        // A stopped animation must not own a live display-link or proxy after teardown.
        let fields = Mirror(reflecting: drawer.animation).children
        for field in fields where field.label == "link" || field.label == "proxy" {
            #expect(Mirror(reflecting: field.value).children.isEmpty)
        }
    }
    @Test("Zero-distance close completion can reopen without a late deactivation")
    func reentrantCompletion() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let view = BrowserLibraryView(frame: NSRect(x: 0, y: 0, width: 420, height: 348))
        root.addSubview(view)
        let drawer = BrowserLibraryDrawer()
        drawer.prefersReducedMotion = { true }
        drawer.install(view: view, root: root, leading: view.leadingAnchor.constraint(equalTo: root.leadingAnchor))
        var count = 0
        drawer.onClosed = { count += 1; if count == 1 { drawer.setPresented(true) } }
        drawer.setPresented(false)
        #expect(count == 1)
        #expect(drawer.isPresented && !view.isHidden && view.acceptsLibraryInput)
        drawer.finishClosing()
        drawer.finishClosing()
        #expect(count == 2 && view.isHidden)
    }

    @Test("Actual small-window constraints, resize-edge hits, Escape and close command preserve the page")
    func layoutAndCommands() async throws {
        let (c, _) = try await makeController(motionWindow: false, reducedMotion: true)
        defer { c.session.close(); c.window?.close() }
        let window = try #require(c.window)
        let root = try #require(window.contentView)
        let page = try #require(c.session.selectedSurface)
        let generation = page.documentGeneration
        for size in [NSSize(width: 600, height: 400), NSSize(width: 1020, height: 720)] {
            window.setContentSize(size)
            c.showLibrary(.downloads)
            await c.session.waitForPendingCommands()
            root.layoutSubtreeIfNeeded()
            let frame = c.library.view.convert(c.library.view.bounds, to: root)
            #expect(abs(frame.minX) < 0.01)
            #expect(abs(root.bounds.maxY - frame.maxY) < 0.01)
            #expect(abs(frame.minY - root.bounds.minY) < 0.01)
            #expect(frame.width <= root.bounds.width - 32)
            #expect(!c.library.view.hasAmbiguousLayout)
            let edge = c.windowShell.resizeHandle.convert(c.windowShell.resizeHandle.bounds, to: root)
            let hit = root.hitTest(NSPoint(x: edge.midX, y: frame.midY))
            #expect(hit?.isDescendant(of: c.library.view) == true)
            #expect(c.pageCommandSurface() == nil)
            #expect(c.isSitePermissionTarget(page))
            c.closeSelectedTab()
            #expect(!c.library.isPresented)
            #expect(c.session.selectedSurface === page)
            c.showLibrary(.history)
            await c.session.waitForPendingCommands()
            c.library.view.cancelOperation(nil)
            await c.session.waitForPendingCommands()
            #expect(!c.library.isPresented)
            #expect(c.session.selectedSurface === page && page.documentGeneration == generation)
        }
    }

    @Test("Post-save retirement cancels a real coordinator flight and releases its display link")
    func retirement() async throws {
        let (c, _) = try await makeController()
        defer { c.session.close(); c.window?.close() }
        c.showLibrary(.downloads)
        await c.session.waitForPendingCommands()
        c.retireForTermination()
        #expect(!c.library.drawer.animation.isAnimating && c.library.view.isHidden)
        #expect(c.library.displayedProfileID == nil && c.downloadsProfileID == nil)
        for field in Mirror(reflecting: c.library.drawer.animation).children
            where field.label == "link" || field.label == "proxy" {
            #expect(Mirror(reflecting: field.value).children.isEmpty)
        }
    }

    @Test("Presented Peek and floating sidebar retain deliberate order across Library and palette")
    func dynamicOverlayOrder() async throws {
        let (c, _) = try await makeController(motionWindow: false, reducedMotion: true)
        defer { c.palette.dismiss(returnFocus: false); c.session.close(); c.window?.close() }
        let root = try #require(c.window?.contentView)
        func index(_ view: NSView) throws -> Int { try #require(root.subviews.firstIndex { $0 === view }) }
        c.setSidebarVisible(false, animated: false)
        c.windowShell.setFloating(true, animated: false)
        #expect(c.isSidebarFloating)
        _ = c.openPeek(URL(string: "https://review-drawer.fixture.test/peek")!)
        let peek = try #require(c.presentedPeekSurface)
        c.showLibrary(.downloads)
        await c.session.waitForPendingCommands()
        #expect(try index(c.windowShell.floatingBackdrop) < index(c.sidebar))
        #expect(try index(c.sidebar) < index(c.library.view))
        #expect(try index(c.library.view) < index(c.peek.overlay))
        #expect(try index(c.peek.overlay) < index(c.palette.view))
        #expect(c.pageCommandSurface() === peek)
        c.hideLibrary(focus: false)
        #expect(try index(c.library.view) < index(c.peek.overlay))
        #expect(try index(c.peek.overlay) < index(c.windowShell.floatingBackdrop))
        #expect(c.presentedPeekSurface === peek)
        let router = BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>(
            create: { _ in c }, present: { _, _ in }, dispose: { _ in })
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        c.palette.registry = registry
        c.showLibrary(.history)
        await c.session.waitForPendingCommands()
        c.palette.present(.newTab)
        #expect(c.palette.isPresented && !c.library.isPresented)
        #expect(c.library.view.isHidden)
        #expect(try index(c.palette.view) > index(c.peek.overlay))
        #expect(c.window?.isVisible == false)
    }

}
}
