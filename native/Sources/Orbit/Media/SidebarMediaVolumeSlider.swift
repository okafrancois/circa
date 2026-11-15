import AppKit

/// Continuous tab gain. The 33 pt row shares the card's bottom anchor.
@MainActor
final class SidebarMediaVolumeSlider: NSControl {
    var level: Double = 1 { didSet { needsDisplay = true } }
    var onChange: ((Double) -> Void)?
    var onInteraction: ((Bool) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 0, dy: 6) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 10, yRadius: 10).fill() }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(uiText("Adjust Tab Volume"))
        setAccessibilityIdentifier("sidebar-media-volume-slider")
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let rail = NSRect(x: 0, y: bounds.midY - 3, width: bounds.width, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rail, xRadius: 3, yRadius: 3).fill()
        let center = 10 + max(0, bounds.width - 20) * min(1, max(0, level))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: rail.minY, width: center, height: 6), xRadius: 3, yRadius: 3).fill()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: center - 10, y: bounds.midY - 10, width: 20, height: 20)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    func changeLevel(_ value: Double) {
        guard isEnabled, value.isFinite else { return }
        level = min(1, max(0, value))
        onChange?(level)
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        onInteraction?(true)
        defer { onInteraction?(false) }
        var current = event
        while true {
            let x = convert(current.locationInWindow, from: nil).x
            changeLevel((x - 10) / max(1, bounds.width - 20))
            if current.type == .leftMouseUp { break }
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            current = next
        }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return }
        switch event.charactersIgnoringModifiers {
        case "\u{f702}", "\u{f701}": changeLevel(level - 0.05)
        case "\u{f703}", "\u{f700}": changeLevel(level + 0.05)
        case "\u{f729}": changeLevel(0)
        case "\u{f72b}": changeLevel(1)
        default: super.keyDown(with: event); return
        }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    override func accessibilityValue() -> Any? { String(format: uiText("%ld%%"), Int((level * 100).rounded())) }
    override func accessibilityMinValue() -> Any? { 0 }
    override func accessibilityMaxValue() -> Any? { 100 }
    override func accessibilityPerformIncrement() -> Bool { guard isEnabled else { return false }; changeLevel(level + 0.05); return true }
    override func accessibilityPerformDecrement() -> Bool { guard isEnabled else { return false }; changeLevel(level - 0.05); return true }
}
