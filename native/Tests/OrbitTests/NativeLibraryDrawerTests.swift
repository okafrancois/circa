import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

/// User-requested drawer behavior; exact Orbit dimensions and easing are separate evidence.
extension NativeWebKitTests {
@Suite("Library left drawer regression", .serialized)
@MainActor
struct NativeLibraryDrawerTests {
    @Test("Closing a drawer disables input and delivers cleanup only once")
    func closeAuthority() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1020, height: 720))
        let view = BrowserLibraryView(frame: NSRect(x: 0, y: 0, width: 420, height: 668))
        root.addSubview(view)
        let leading = view.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        let drawer = BrowserLibraryDrawer()
        drawer.install(view: view, root: root, leading: leading)
        var closed = 0
        drawer.onClosed = { closed += 1 }
        drawer.setPresented(true)
        #expect(view.acceptsLibraryInput && !view.isHidden)
        drawer.finishClosing()
        drawer.finishClosing()
        #expect(!view.acceptsLibraryInput && view.isHidden)
        #expect(leading.constant == -420)
        #expect(closed == 1)
        drawer.setPresented(true)
        #expect(leading.constant == 0)
        #expect(view.acceptsLibraryInput && !view.isHidden)
        drawer.setPresented(false)
        #expect(closed == 2)
    }

    @Test("Reduced motion selects the drawer's final geometry without hiding the document")
    func reducedMotion() {
        let previous = OrbitMotionPreferences.overrideReducedMotion
        OrbitMotionPreferences.overrideReducedMotion = true
        defer { OrbitMotionPreferences.overrideReducedMotion = previous }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1020, height: 720))
        let view = BrowserLibraryView(frame: NSRect(x: 0, y: 0, width: 420, height: 668))
        root.addSubview(view)
        let leading = view.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        let drawer = BrowserLibraryDrawer()
        drawer.install(view: view, root: root, leading: leading)
        drawer.setPresented(true)
        #expect(leading.constant == 0 && !drawer.animation.isAnimating)
        drawer.setPresented(false)
        #expect(leading.constant == -420 && view.isHidden)
        #expect(!drawer.animation.isAnimating)
    }

    @Test("Library opens from the left while the current document stays visible and alive")
    func preservesVisibleDocument() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic drawer profile")
        let space = try await store.createSpace(name: "Synthetic drawer Space", profileID: profile)
        let identity = try await store.createWindow(activeSpaceID: space)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: space,
            engine: SiteSyntheticEngine(), restoringWindowID: identity, onClose: {}, onActivate: {})
        defer { controller.session.close(); controller.window?.close() }
        await controller.session.waitForPendingCommands()
        controller.session.openTab(url: URL(string: "https://drawer.fixture.test/document")!)
        await controller.session.waitForPendingCommands()
        let surface = try #require(controller.session.selectedSurface)
        let generation = surface.documentGeneration
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1020, height: 720))
        let root = try #require(window.contentView)

        controller.sidebar.onShowLibrary?()
        await controller.session.waitForPendingCommands()
        root.layoutSubtreeIfNeeded()
        #expect(controller.library.isPresented)
        #expect(!controller.library.view.isHidden)
        #expect(!controller.contentCard.isHidden, "A drawer must not replace the document with a full-page Library")
        let panel = controller.library.view.convert(controller.library.view.bounds, to: root)
        let document = controller.contentCard.convert(controller.contentCard.bounds, to: root)
        #expect(panel.minX < document.minX, "The Library must occupy the left side instead of the document card")
        #expect(panel.maxX < root.bounds.maxX, "The Library must leave part of the document visible")
        #expect(controller.session.selectedSurface === surface)
        #expect(surface.documentGeneration == generation)
        #expect(controller.window?.isVisible == false)
        #expect(controller.windowShell.allowsHoverReveal() == false)
        #expect(controller.windowShell.allowsResize() == false)
        func index(_ view: NSView) throws -> Int { try #require(root.subviews.firstIndex { $0 === view }) }
        #expect(try index(controller.sidebar) < index(controller.library.view))
        #expect(try index(controller.library.view) < index(controller.peek.overlay))

        controller.library.view.onBack?()
        await controller.session.waitForPendingCommands()
        #expect(!controller.library.isPresented)
        #expect(!controller.contentCard.isHidden)
        #expect(controller.session.selectedSurface === surface)
        #expect(surface.documentGeneration == generation)
        #expect(try index(controller.library.view) < index(controller.peek.overlay))
        #expect(try index(controller.peek.overlay) < index(controller.windowShell.floatingBackdrop))
        #expect(controller.windowShell.allowsResize() == true)
    }
}
}
