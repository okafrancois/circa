import AppKit

/// Drag previews never write playback position. Release sends exactly one clamped seek;
/// incoming engine samples stay current for cancellation while the thumb is held.
struct SidebarMediaSeekState {
    var duration: Double?
    var position: Double? { didSet { if position != oldValue { sampledAt = ProcessInfo.processInfo.systemUptime } } }
    var playbackRate: Double? = nil
    private var sampledAt = ProcessInfo.processInfo.systemUptime
    var offered = false
    private(set) var preview: Double?
    private var lastPreview = -Double.infinity
    var finiteDuration: Double? { duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
    var canSeek: Bool { offered && finiteDuration != nil && position?.isFinite == true }
    var displayed: Double? { (preview ?? position).flatMap { $0.isFinite ? $0 : nil } }
    func currentPosition(now: Double = ProcessInfo.processInfo.systemUptime, interpolate: Bool) -> Double? {
        guard preview == nil, interpolate, let position, let rate = playbackRate, rate.isFinite,
              let duration = finiteDuration else { return displayed }
        return min(duration, max(0, position + max(0, now - sampledAt) * rate))
    }
    mutating func update(fraction: Double, now: Double, force: Bool = false) {
        guard canSeek, let duration = finiteDuration, force || now - lastPreview >= 1 / 30.0 else { return }
        preview = min(duration, max(0, fraction * duration)); lastPreview = now
    }
    mutating func finish(cancel: Bool) -> Double? {
        defer { preview = nil; lastPreview = -.infinity }
        return cancel ? nil : preview
    }
    static func time(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let value = Int(min(seconds, Double(Int.max / 2)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

@MainActor
final class SidebarMediaTimeline: NSControl {
    var seek = SidebarMediaSeekState() { didSet { needsDisplay = true } }
    var onSeek: ((Double) -> Void)?
    var onPreview: (() -> Void)?
    var onInteraction: ((Bool) -> Void)?
    private var hovering = false
    private var clock: Timer?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { seek.canSeek }
    override var focusRingType: NSFocusRingType { get { .exterior } set {} }
    override var focusRingMaskBounds: NSRect { NSRect(x: 0, y: 4, width: bounds.width, height: 12) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill() }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(uiText("Playback position"))
        setAccessibilityIdentifier("sidebar-media-seek")
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clock?.invalidate(); clock = nil
        guard window != nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isHiddenOrHasHiddenAncestor, self.seek.playbackRate != nil,
                      !OrbitMotionPreferences.prefersReducedMotion else { return }
                self.needsDisplay = true
            }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let secondary = NSColor.secondaryLabelColor
        let text: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: secondary]
        guard let duration = seek.finiteDuration else {
            var liveText = text
            liveText[.font] = NSFont.systemFont(ofSize: 10)
            (uiText("Live") as NSString).draw(at: NSPoint(x: 0, y: 10), withAttributes: liveText)
            let label = uiText("No timeline") as NSString
            label.draw(at: NSPoint(x: bounds.width - label.size(withAttributes: liveText).width, y: 10), withAttributes: liveText)
            return
        }
        let rail = NSRect(x: 0, y: 10.5, width: bounds.width, height: 3)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rail, xRadius: 1.5, yRadius: 1.5).fill()
        let displayed = seek.currentPosition(interpolate: !OrbitMotionPreferences.prefersReducedMotion)
        let fraction = min(1, max(0, (displayed ?? 0) / duration))
        NSColor.controlAccentColor.withAlphaComponent(seek.canSeek ? 1 : 0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: rail.minY, width: rail.width * fraction, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        if seek.canSeek && (hovering || window?.firstResponder === self || seek.preview != nil) {
            NSBezierPath(ovalIn: NSRect(x: rail.width * fraction - 3, y: 9, width: 6, height: 6)).fill()
        }
        (SidebarMediaSeekState.time(displayed) as NSString).draw(at: NSPoint(x: 0, y: 20), withAttributes: text)
        let end = SidebarMediaSeekState.time(duration) as NSString
        end.draw(at: NSPoint(x: bounds.width - end.size(withAttributes: text).width, y: 20), withAttributes: text)
    }
    override func mouseDown(with event: NSEvent) {
        guard seek.canSeek, let window else { return }
        window.makeFirstResponder(self)
        onInteraction?(true)
        defer { onInteraction?(false) }
        var current = event
        while true {
            let x = convert(current.locationInWindow, from: nil).x
            seek.update(fraction: x / max(1, bounds.width), now: current.timestamp, force: current.type == .leftMouseUp)
            onPreview?()
            if current.type == .leftMouseUp { break }
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) else { break }
            if next.type == .keyDown {
                if next.characters == "\u{1b}" { _ = seek.finish(cancel: true); return }
                continue
            }
            current = next
        }
        if let seconds = seek.finish(cancel: false) { onSeek?(seconds) }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    override func keyDown(with event: NSEvent) {
        guard seek.canSeek, let duration = seek.finiteDuration else { return }
        let step = event.modifierFlags.contains(.shift) ? 10.0 : 5.0
        let position = seek.displayed ?? 0
        let next: Double
        switch event.charactersIgnoringModifiers {
        case "\u{f702}": next = position - step
        case "\u{f703}": next = position + step
        case "\u{f729}": next = 0
        case "\u{f72b}": next = duration
        case "\u{1b}": _ = seek.finish(cancel: true); return
        default: super.keyDown(with: event); return
        }
        let value = min(duration, max(0, next))
        onSeek?(value)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
    override func accessibilityValue() -> Any? { SidebarMediaSeekState.time(seek.displayed) }
    override func accessibilityMinValue() -> Any? { 0 }
    override func accessibilityMaxValue() -> Any? { seek.finiteDuration }
}
