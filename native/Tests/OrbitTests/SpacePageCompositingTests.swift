import AppKit
import BrowserCore
import QuartzCore
import Testing
@testable import Orbit

@MainActor
private final class CompositingWindow: NSWindow {
    // Never ordered on screen; visibility overrides let the native spring run in tests.
    override var isKeyWindow: Bool { true }
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }
}

@MainActor
private final class CompositingDrawingLeaf: NSView {
    override func draw(_ dirtyRect: NSRect) {}
}

@MainActor
private final class CompositingDrawingContainer: NSView {
    override func draw(_ dirtyRect: NSRect) {}
}

@MainActor private var compositingScrollTime: UInt64 = 1_000_000_000

@MainActor
private func compositingScroll(_ phase: NSEvent.Phase, x: Int32 = 0) throws -> NSEvent {
    let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: 0, wheel2: x * 2, wheel3: 0))
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    cg.setIntegerValueField(.scrollWheelEventScrollPhase,
                            value: phase.contains(.began) ? 1 : phase.contains(.changed) ? 2 : phase.contains(.ended) ? 4 : phase.contains(.cancelled) ? 8 : 0)
    compositingScrollTime += 20_000_000
    cg.timestamp = compositingScrollTime
    return try #require(NSEvent(cgEvent: cg))
}

@MainActor
private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

/// Visible (layer tree) and native (view geometry) rectangles of a control in window coordinates.
@MainActor
private func windowRects(_ view: NSView, in window: NSWindow) throws -> (native: CGRect, visible: CGRect) {
    let content = try #require(window.contentView)
    view.superview?.layoutSubtreeIfNeeded()
    let native = view.convert(view.bounds, to: nil)
    let layer = try #require(view.layer), root = try #require(content.layer)
    let visible = layer.convert(layer.bounds, to: root)
    // The content layer is flipped relative to window coordinates.
    return (native, CGRect(x: visible.minX, y: content.isFlipped ? content.bounds.height - visible.maxY : visible.minY,
                           width: visible.width, height: visible.height))
}

private func same(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SpacePageCompositingTests {
    private func fixture() async throws -> (CompositingWindow, BrowserSidebarView, BrowserSessionDocument, BrowserCatalogSnapshot, SpaceID, SpaceID) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic compositing")
        let first = try await store.createSpace(name: "First", profileID: profile)
        let second = try await store.createSpace(name: "Second", profileID: profile)
        let windowID = try await store.createWindow(activeSpaceID: first)
        let context = try await store.captureContext(in: windowID)
        _ = try await store.openTab(url: URL(string: "https://synthetic.invalid/first")!, from: context, activate: true)
        let window = CompositingWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 640),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.wantsLayer = true
        let sidebar = BrowserSidebarView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(sidebar)
        let catalog = await store.catalogSnapshot()
        let opened = try await store.captureContext(in: windowID)
        sidebar.render(catalog: catalog, activeSpaceID: first, organization: try await store.organizationSnapshot(from: opened))
        sidebar.layoutSubtreeIfNeeded()
        sidebar.displayIfNeeded()
        let document = await store.sessionDocument()
        sidebar.spaceSwipe.loadDocument = { document }
        sidebar.spaceSwipe.clock = { 10 }
        sidebar.spaceSwipe.automaticallyAdvances = false
        return (window, sidebar, document, catalog, first, second)
    }

    @Test("Compositing clips only draw(_:) leaves and restores exactly the views it changed")
    func compositingSelectsDrawingLeaves() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let container = NSView(frame: root.bounds)
        let leaf = CompositingDrawingLeaf(frame: NSRect(x: 4, y: 4, width: 20, height: 20))
        let label = NSTextField(labelWithString: "Synthetic")
        let plain = NSView(frame: NSRect(x: 30, y: 4, width: 20, height: 20))
        let hosting = OrbitSurfaceBackgroundView(cornerRadius: 6)
        let drawingContainer = CompositingDrawingContainer(frame: NSRect(x: 60, y: 60, width: 80, height: 80))
        let nested = CompositingDrawingLeaf(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        let alreadyClipping = CompositingDrawingLeaf(frame: NSRect(x: 100, y: 4, width: 20, height: 20))
        alreadyClipping.clipsToBounds = true
        drawingContainer.addSubview(nested)
        for view in [leaf, label, plain, hosting, drawingContainer, alreadyClipping] { container.addSubview(view) }
        root.addSubview(container)
        let compositing = SpacePageCompositing()
        compositing.include(container)
        #expect(leaf.clipsToBounds && nested.clipsToBounds)
        #expect(!label.clipsToBounds && !plain.clipsToBounds && !hosting.clipsToBounds)
        #expect(!drawingContainer.clipsToBounds && !container.clipsToBounds)
        #expect(compositing.clippedViewCount == 2)
        // A descendant laid out after the first move joins on the next moved frame.
        let late = CompositingDrawingLeaf(frame: NSRect(x: 4, y: 40, width: 20, height: 20))
        container.addSubview(late)
        #expect(!late.clipsToBounds)
        compositing.include(container)
        #expect(late.clipsToBounds)
        #expect(compositing.clippedViewCount == 3)
        compositing.restore()
        #expect(!leaf.clipsToBounds && !nested.clipsToBounds && !late.clipsToBounds)
        #expect(alreadyClipping.clipsToBounds)
        #expect(!compositing.isActive && compositing.clippedViewCount == 0)
    }

    @Test("Space swipe composites the moving page while native, accessibility and hit geometry follow it")
    func swipeCompositesWithNativeGeometry() async throws {
        let (window, sidebar, _, _, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let label = sidebar.page.titleLabel
        let newTab = sidebar.page.list.newTabRow
        let resting = try [label, newTab].map { try windowRects($0, in: window).native }
        let restingAccessibility = [label, newTab].map { $0.accessibilityFrame() }
        #expect(sidebar.compositedSpaceViews.isEmpty)
        _ = sidebar.spaceSwipe.handleScroll(try compositingScroll(.began), inside: true)
        for _ in 0..<10 { await Task.yield() }
        var clipped: [NSView] = []
        for (step, expected) in [(-60, -60.0), (-30, -90.0), (25, -65.0)] {
            _ = sidebar.spaceSwipe.handleScroll(try compositingScroll(.changed, x: Int32(step)), inside: true)
            sidebar.layoutSubtreeIfNeeded(); sidebar.displayIfNeeded()
            #expect(sidebar.page.frame.minX == CGFloat(expected))
            clipped = sidebar.compositedSpaceViews
            #expect(clipped.contains { $0 is OrbitGlyphButton && $0.isDescendant(of: newTab) })
            #expect(clipped.allSatisfy { $0.clipsToBounds && $0.subviews.isEmpty && !$0.wantsUpdateLayer })
            #expect(sidebar.page.layer?.affineTransform() == .identity)
            for (index, view) in [label, newTab].enumerated() {
                // What is drawn (layer tree) is where AppKit hit-tests and reports accessibility.
                let rects = try windowRects(view, in: window)
                #expect(same(rects.native, rects.visible))
                #expect(same(rects.native, resting[index].offsetBy(dx: CGFloat(expected), dy: 0)))
                #expect(same(view.accessibilityFrame(), restingAccessibility[index].offsetBy(dx: CGFloat(expected), dy: 0)))
                let hit = try #require(window.contentView?.hitTest(NSPoint(x: rects.native.midX, y: rects.native.midY)))
                #expect(hit === view || hit.isDescendant(of: view))
            }
        }
        sidebar.spaceSwipe.cancel()
        #expect(sidebar.compositedSpaceViews.isEmpty)
        #expect(!clipped.isEmpty && clipped.allSatisfy { !$0.clipsToBounds })
        #expect(sidebar.page.frame.minX == 0)
    }

    @Test("Composited settling follows the Space spring at every 120 Hz tick with layers on native frames")
    func settlingMotionIsUnchanged() async throws {
        let (window, sidebar, _, _, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        _ = sidebar.spaceSwipe.handleScroll(try compositingScroll(.began), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.handleScroll(try compositingScroll(.changed, x: -60), inside: true)
        sidebar.layoutSubtreeIfNeeded(); sidebar.displayIfNeeded()
        #expect(sidebar.page.frame.minX == -60)
        _ = sidebar.spaceSwipe.handleScroll(try compositingScroll(.cancelled), inside: true)
        #expect(sidebar.spaceSwipe.isSettling)
        let spring = SidebarSlotMotion(from: -60, to: 0, at: 10, spring: OrbitTokens.Motion.spaceSwitchSidebar, velocity: 0)
        var ticks = 0
        for tick in 1...120 where sidebar.spaceSwipe.isSettling {
            let time = 10 + Double(tick) / 120
            sidebar.spaceSwipe.advance(to: time)
            sidebar.layoutSubtreeIfNeeded(); sidebar.displayIfNeeded()
            let expected = spring.isSettled(at: time) ? 0 : spring.value(at: time)
            #expect(sidebar.page.frame.minX == expected)
            let rects = try windowRects(sidebar.page.titleLabel, in: window)
            #expect(same(rects.native, rects.visible))
            if sidebar.spaceSwipe.isSettling { #expect(!sidebar.compositedSpaceViews.isEmpty) }
            ticks += 1
        }
        #expect(ticks > 30 && !sidebar.spaceSwipe.isActive)
        #expect(sidebar.page.frame.minX == 0 && sidebar.compositedSpaceViews.isEmpty)
    }

    @Test("Ordinary Space switch composites both moving pages and restores native drawing at rest")
    func ordinarySwitchCompositesAndRestores() async throws {
        let (window, sidebar, _, catalog, _, second) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        OrbitMotionPreferences.overrideReducedMotion = false
        defer { OrbitMotionPreferences.overrideReducedMotion = nil }
        let outgoing = sidebar.page
        let restingAccessibility = outgoing.titleLabel.accessibilityFrame()
        sidebar.render(catalog: catalog, activeSpaceID: second, organization: nil)
        #expect(sidebar.isSwitchingSpace)
        let incoming = sidebar.page
        #expect(incoming !== outgoing)
        var clipped: [NSView] = []
        var frames = 0
        let deadline = Date().addingTimeInterval(3)
        while sidebar.isSwitchingSpace && Date() < deadline {
            try await Task.sleep(for: .milliseconds(8))
            guard sidebar.isSwitchingSpace, outgoing.frame.minX != 0 else { continue }
            frames += 1
            clipped = sidebar.compositedSpaceViews
            #expect(clipped.contains { $0.isDescendant(of: outgoing) } && clipped.contains { $0.isDescendant(of: incoming) })
            for page in [outgoing, incoming] {
                let rects = try windowRects(page.titleLabel, in: window)
                #expect(same(rects.native, rects.visible))
            }
            #expect(same(outgoing.titleLabel.accessibilityFrame(), restingAccessibility.offsetBy(dx: outgoing.frame.minX, dy: 0)))
        }
        #expect(frames > 0)
        #expect(!sidebar.isSwitchingSpace)
        #expect(sidebar.page === incoming && incoming.frame.minX == 0)
        #expect(sidebar.compositedSpaceViews.isEmpty)
        #expect(!clipped.isEmpty && clipped.allSatisfy { !$0.clipsToBounds })
    }
}
}
