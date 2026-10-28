import AppKit
import Testing
@testable import Orbit

@MainActor
@Suite(.serialized)
struct SidebarStallsTests {
    @Test("Floating reveal keeps the page size and the floating container bounds unchanged")
    func floatingBounds() {
        let size = CGSize(width: 1120, height: 780)
        let hidden = OrbitShellGeometry.resolve(.init(contentSize: size, dockProgress: 0,
                                                     usesFloatingFrame: true))
        for progress in [0.0, 0.1, 0.5, 1, 1.015] {
            let frame = OrbitShellGeometry.resolve(.init(contentSize: size, dockProgress: 0,
                floatProgress: progress, usesFloatingFrame: true))
            #expect(frame.cardFrame == hidden.cardFrame)
            #expect(frame.sidebarFrame.size == hidden.sidebarFrame.size)
            #expect(frame.sidebarFrame.minY == 5)
        }
        #expect(hidden.sidebarFrame.maxX == -8)
    }

    @Test("A dock transition lays out the document once and does no display-link resizing")
    func documentResize() async throws {
        let window = AnimationWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 780),
                                     styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = OrbitWindowRootView()
        let shell = OrbitWindowShell()
        shell.prepare(window: window, root: root)
        let card = BrowserContentCardView()
        let sidebar = NSView()
        for view in [card, sidebar] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        shell.installFloatingBackdrop(in: root)
        window.contentView = root
        shell.installConstraints(root: root, sidebar: sidebar, card: card,
            width: sidebar.widthAnchor.constraint(equalToConstant: 280),
            leading: sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor))
        let document = ResizeCountingView()
        document.wantsLayer = true  // ChromiumHostView is layer-backed, including its native content.
        card.present(document)
        root.layoutSubtreeIfNeeded()
        let original = document.frame.size
        document.resizeCount = 0
        shell.setDocked(false)
        let expanded = document.frame.size
        #expect(expanded.width > original.width)
        #expect(document.resizeCount == 1)
        try await Task.sleep(for: .milliseconds(180))
        #expect(!shell.isAnimating)
        #expect(document.resizeCount == 1)
        shell.setFloating(true)
        try await Task.sleep(for: .milliseconds(450))
        #expect(document.frame.size == expanded && document.resizeCount == 1)
        shell.setFloating(false)
        try await Task.sleep(for: .milliseconds(450))
        #expect(document.frame.size == expanded && document.resizeCount == 1)
        shell.setDocked(true)
        try await Task.sleep(for: .milliseconds(180))
        #expect(document.frame.size == original && document.resizeCount == 2)
    }

    @Test("Retaining the offscreen sidebar cannot expose hit targets or anchored presentations")
    func retainedSidebarInput() {
        let sidebar = BrowserSidebarView(frame: CGRect(x: 0, y: 0, width: 280, height: 780))
        sidebar.isShellHidden = true
        #expect(!sidebar.isHidden)
        #expect(sidebar.isPresentationHidden)
        #expect(sidebar.hitTest(CGPoint(x: 40, y: 100)) == nil)
        sidebar.isShellHidden = false
        #expect(!sidebar.isPresentationHidden)
    }

    @Test("Compositor motion captures the displayed geometry and keeps the native timing")
    func compositorGeometry() throws {
        let root = CALayer(), child = CALayer()
        root.addSublayer(child)
        child.position = CGPoint(x: 10, y: 20)
        child.bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let transition = OrbitSidebarLayerTransition(roots: [root])
        child.position.x = 280
        child.bounds.size.width = 530
        #expect(transition.animate(spring: nil) == 2)
        let position = try #require(child.animation(forKey: "orbit.sidebar.position") as? CABasicAnimation)
        #expect(position.duration == OrbitAnimationTiming.sidebar.duration)
        #expect(position.beginTime == 0)
        #expect((position.fromValue as? NSValue)?.pointValue == CGPoint(x: 10, y: 20))
        #expect((position.toValue as? NSValue)?.pointValue == child.position)
        transition.cancel()
        #expect(child.animation(forKey: "orbit.sidebar.position") == nil)
        #expect(child.animation(forKey: "orbit.sidebar.bounds") == nil)
    }

    @Test("Replacing a transition keeps its completion from hiding the new sidebar")
    func interruptedTransition() async throws {
        let window = AnimationWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = OrbitWindowRootView(), shell = OrbitWindowShell()
        let card = BrowserContentCardView(), sidebar = NSView()
        shell.prepare(window: window, root: root)
        for view in [card, sidebar] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        window.contentView = root
        shell.installConstraints(root: root, sidebar: sidebar, card: card,
            width: sidebar.widthAnchor.constraint(equalToConstant: 280),
            leading: sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor))
        root.layoutSubtreeIfNeeded()
        shell.setDocked(false)
        shell.setDocked(true)
        try await Task.sleep(for: .milliseconds(180))
        #expect(shell.isDocked && shell.isSidebarOnScreen && !shell.isAnimating)
        #expect(shell.hoverReveal.phase == .disabled)
    }
}

/// Exercise native transactions without ordering or activating a test window on the shared GUI.
@MainActor
private final class AnimationWindow: NSWindow {
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }
}

@MainActor
private final class ResizeCountingView: NSView {
    var resizeCount = 0
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { resizeCount += 1 }
        super.setFrameSize(newSize)
    }
}
