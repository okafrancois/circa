import AppKit

@MainActor
enum OrbitWindowChrome {
    static func configure(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
        window.isMovableByWindowBackground = false
        window.minSize = OrbitTokens.Metrics.Window.minimumSize
        window.collectionBehavior.insert(.fullScreenPrimary)
    }
}

@MainActor
final class OrbitTrafficLights {
    private weak var window: NSWindow?
    private(set) var lastCenters: [CGPoint] = []
    private(set) var lastVisible = true
    /// Centre spacing the system gave this window's buttons, or the token when it gave none.
    let pitch: CGFloat

    /// Last spacing read from the system; nil until a window was measured.
    private(set) static var systemPitch: CGFloat?
    static var pitch: CGFloat { systemPitch ?? OrbitTokens.Metrics.Window.trafficLightPitch }

    init(window: NSWindow) {
        self.window = window
        let measured = Self.measurePitch(in: window)
        if let measured { Self.systemPitch = measured }
        pitch = measured ?? Self.pitch
    }

    /// Centre spacing of the standard buttons as laid out by AppKit; nil when the buttons are missing or
    /// not evenly spaced (already moved, or not laid out yet).
    static func measurePitch(in window: NSWindow) -> CGFloat? {
        let frames = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
            window.standardWindowButton($0)?.frame
        }
        guard frames.count == 3 else { return nil }
        let first = frames[1].midX - frames[0].midX, second = frames[2].midX - frames[1].midX
        guard first >= OrbitTokens.Metrics.Window.trafficLightDiameter, abs(first - second) < 0.5 else { return nil }
        return first
    }

    var buttons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    var animationLayer: CALayer? { buttons.first?.superview?.superview?.layer }

    /// `centers` are in content coordinates with the origin at the window's top-left.
    func apply(centers: [CGPoint], visible: Bool, isFullScreen: Bool, animating: Bool = false) {
        lastCenters = centers
        lastVisible = visible
        let buttons = buttons
        guard let window, !buttons.isEmpty else { return }
        if isFullScreen {
            for button in buttons where button.isHidden { button.isHidden = false }
            return
        }
        let displayed = visible || animating
        for button in buttons where button.isHidden == displayed { button.isHidden = !displayed }
        guard displayed, let titlebar = buttons[0].superview, let container = titlebar.superview,
              let lowest = centers.map(\.y).max() else { return }
        // Move the native container with the sidebar. Its bounds and its three controls remain
        // fixed, so AppKit does not rebuild title-bar tracking and backing stores every frame.
        let offsetX = (centers.first?.x ?? 20) - OrbitTokens.Metrics.Window.trafficLightFirstCenterX
        let buttonHeight = buttons[0].frame.height
        // The title-bar container must contain the buttons for hit testing.
        let height = (lowest + buttonHeight / 2 + 4).rounded(.up)
        // A full-width transparent title bar intercepts clicks on content controls, including
        // Split headers. Only the system buttons need to remain inside this native container.
        let rightEdge = zip(buttons, centers).map { $0.1.x + $0.0.frame.width / 2 + 4 }.max() ?? 0
        let width = min(window.frame.width, (rightEdge - offsetX).rounded(.up))
        let containerFrame = NSRect(x: offsetX, y: window.frame.height - height, width: width, height: height)
        if container.frame != containerFrame { container.frame = containerFrame }
        if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
        for (button, center) in zip(buttons, centers) {
            let size = button.frame.size
            let y = titlebar.isFlipped ? center.y - size.height / 2 : height - center.y - size.height / 2
            let origin = NSPoint(x: center.x - offsetX - size.width / 2, y: y)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    /// AppKit lays the title bar out again on resize, key changes and full-screen exit.
    func reapply(isFullScreen: Bool) {
        apply(centers: lastCenters, visible: lastVisible, isFullScreen: isFullScreen)
    }
}

/// Content view of an Orbit window. Theme gaps and empty sidebar areas drag the window, a
/// double-click in the top strip performs the system title-bar action, and the shell is told when
/// AppKit re-lays out or invalidates tracking areas.
@MainActor
final class OrbitWindowRootView: NSView {
    var onLayout: (() -> Void)?
    var onTrackingAreasInvalidated: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        onTrackingAreasInvalidated?()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let fromTop = bounds.height - point.y
        if event.clickCount == 2, fromTop <= OrbitTokens.Metrics.Sidebar.addressTop {
            performTitleBarDoubleClick(window)
            return
        }
        window.performDrag(with: event)
    }

    /// Honours System Settings › Desktop & Dock › "Double-click a window's title bar to".
    private func performTitleBarDoubleClick(_ window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

/// The sidebar/card boundary: `resizeLeftRight` cursor (tokens.json cursor.sidebarEdge), live
/// resize 1:1 between 164 and 500, instant drag-to-hide once the pointer passes 82 pt from the window
/// edge (+ ).
@MainActor
final class OrbitSidebarResizeHandle: NSView {
    var currentWidth: () -> CGFloat = { OrbitTokens.Metrics.Sidebar.widthDefault }
    var onResize: ((CGFloat) -> Void)?
    var onCollapse: (() -> Void)?
    var onEnd: (() -> Void)?
    private var dragStart: (x: CGFloat, width: CGFloat)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: OrbitTokens.Cursor.sidebarEdge)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragStart = (event.locationInWindow.x, currentWidth())
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let pointer = event.locationInWindow.x
        switch OrbitShellGeometry.resize(proposedWidth: start.width + pointer - start.x, pointerX: pointer) {
        case .width(let width):
            onResize?(width)
        case .collapse:
            dragStart = nil
            onCollapse?()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        onEnd?()
    }
}
