import AppKit

/// The Space header's disclosure and hover affordances share one native focus target.
@MainActor
final class SidebarSpaceDisclosure: NSControl {
    static let collapseTiming = OrbitAnimationTiming(duration: 0.12, x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
    static let expandTiming = OrbitAnimationTiming(duration: 0.22, x1: 0, y1: 0, x2: 0.58, y2: 1)
    var onToggle: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onShowMenu: (() -> Void)?
    var tint = OrbitTokens.ThemeAccent.defaultSpace.foreground { didSet { needsDisplay = true } }
    var expansion: CGFloat = 1 { didSet { needsDisplay = true } }
    var isCollapsed = false
    private(set) var isHovering = false
    private var area: NSTrackingArea?
    private var pressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityIdentifier("space-pinned-disclosure")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var mouseDownCanMoveWindow: Bool { false }
    override func accessibilityValue() -> Any? { NSNumber(value: !isCollapsed) }
    override func isAccessibilityExpanded() -> Bool { !isCollapsed }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, !isHidden else { return false }
        onToggle?()
        return true
    }
    override func accessibilityPerformShowMenu() -> Bool {
        guard isEnabled, !isHidden else { return false }
        onShowMenu?()
        return true
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.modifierFlags.contains(.control) { onShowMenu?(); return }
        window?.makeFirstResponder(self)
        pressed = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        if pressed, bounds.contains(convert(event.locationInWindow, from: nil)) { _ = accessibilityPerformPress() }
    }
    override func rightMouseDown(with event: NSEvent) { if isEnabled { onShowMenu?() } }
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r": _ = accessibilityPerformPress()
        default: interpretKeyEvents([event])
        }
    }
    override func moveLeft(_ sender: Any?) { if !isCollapsed { _ = accessibilityPerformPress() } }
    override func moveRight(_ sender: Any?) { if isCollapsed { _ = accessibilityPerformPress() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(next)
        area = next
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovering else { return }
        isHovering = hovered
        needsDisplay = true
        onHover?(hovered)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false); pressed = false }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard isHovering else { return }
        tint.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: 18, y: bounds.midY)
        context.rotate(by: expansion * .pi / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: -1.5, y: -3))
        path.line(to: NSPoint(x: 1.5, y: 0))
        path.line(to: NSPoint(x: -1.5, y: 3))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        tint.withAlphaComponent(0.6).setStroke()
        path.stroke()
        context.restoreGState()
    }
}
