import AppKit
import BrowserShell
import QuartzCore
import CoreText

/// App-level notification access follows the site's grant and never changes that grant.
@MainActor
final class NotificationSettingsPromptView: NSView {
    let card = NotificationSettingsCard()
    let dismissButton = NotificationSettingsButton()
    let settingsButton = NotificationSettingsButton()
    private var completion: ((Bool) -> Void)?
    private let motion = OrbitTimedAnimator(value: 1)
    private var dismissing = false
    private weak var previousResponder: NSResponder?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        super.init(frame: .zero)
        wantsLayer = true
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.backgroundColor = NSColor(srgbRed: 22/255, green: 25/255, blue: 42/255, alpha: 1).cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        card.shadow = shadow
        addSubview(card)
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilitySubrole(.dialog)
        card.setAccessibilityLabel(uiText("Circa Needs Notifications Permission"))
        let icon = NSImageView(frame: NSRect(x: 38, y: 44, width: 48, height: 48))
        icon.image = NSApp.applicationIconImage
        card.addSubview(icon)
        let title = NSTextField(labelWithString: uiText("Circa Needs Notifications Permission"))
        title.font = BrandTextStyle.ui.font(size: 18, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 38, y: 118, width: 380, height: 30)
        card.addSubview(title)
        let message = NSTextField(wrappingLabelWithString: uiText("You need to open System Preferences to give Circa permission to show you Notifications."))
        message.font = BrandTextStyle.ui.font(size: 14)
        message.textColor = NSColor(srgbRed: 181/255, green: 186/255, blue: 202/255, alpha: 1)
        message.frame = NSRect(x: 38, y: 156, width: 366, height: 42)
        card.addSubview(message)
        dismissButton.title = uiText("Never Mind")
        dismissButton.hint = uiText("ESC")
        dismissButton.keyEquivalent = "\u{1b}"
        dismissButton.target = self; dismissButton.action = #selector(dismissAction)
        dismissButton.frame = NSRect(x: 60, y: 228, width: 137, height: 36)
        settingsButton.title = uiText("Open System Preferences")
        settingsButton.hint = "↩"
        settingsButton.primary = true
        settingsButton.keyEquivalent = "\r"
        settingsButton.target = self; settingsButton.action = #selector(settingsAction)
        settingsButton.frame = NSRect(x: 205, y: 228, width: 217, height: 36)
        card.addSubview(dismissButton); card.addSubview(settingsButton)
        motion.onChange = { [weak self] value in
            self?.alphaValue = value
            self?.needsLayout = true
            self?.layoutSubtreeIfNeeded()
        }
        motion.onSettle = { [weak self] in
            guard let self, dismissing else { return }
            removeFromSuperview()
        }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.60).cgColor
        card.frame = NSRect(x: (bounds.width - 450) / 2, y: (bounds.height - 290) / 2 - (dismissing ? 30 * OrbitAnimationTiming(duration: 1, x1: 0.42, y1: 0, x2: 0.58, y2: 1).progress(after: 1 - motion.value) : 0), width: 450, height: 290)
    }
    func show(over root: NSView) {
        previousResponder = root.window?.firstResponder
        frame = root.bounds
        autoresizingMask = [.width, .height]
        root.addSubview(self, positioned: .above, relativeTo: nil)
        root.window?.makeFirstResponder(self)
        layoutSubtreeIfNeeded()
    }
    func cancel() {
        completion = nil
        motion.set(1)
        removeFromSuperview()
    }
    @objc private func dismissAction() { finish(openSettings: false) }
    @objc private func settingsAction() { finish(openSettings: true) }
    func finish(openSettings: Bool) {
        guard !dismissing else { return }
        dismissing = true
        let completion = completion
        self.completion = nil
        if let previousResponder { window?.makeFirstResponder(previousResponder) }
        completion?(openSettings)
        if OrbitMotionPreferences.prefersReducedMotion { removeFromSuperview() }
        else { motion.animate(to: 0, timing: .init(duration: 0.25, x1: 0, y1: 0, x2: 1, y2: 1), in: self) }
    }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\u{1b}" { finish(openSettings: false) }
        else if event.charactersIgnoringModifiers == "\r" { finish(openSettings: true) }
    }
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

@MainActor
final class NotificationSettingsButton: NSButton {
    var primary = false
    var hint = ""
    override var isFlipped: Bool { true }
    init() { super.init(frame: .zero); isBordered = false; setButtonType(.momentaryPushIn) }
    required init?(coder: NSCoder) { nil }
    private var hintLine: CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: hint, attributes: [
            .font: hint == "↩" ? NSFont.systemFont(ofSize: 12, weight: .semibold) : BrandTextStyle.mono.font(size: 12, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7)
        ]))
    }
    var keycapLayout: (cap: NSRect, glyph: NSRect) {
        let cap = NSRect(x: bounds.width - (hint == "↩" ? 39 : 46), y: 8,
                         width: hint == "↩" ? 28 : 35, height: 20)
        let ink = CTLineGetImageBounds(hintLine, nil)
        let size = hint == "↩" ? NSSize(width: 12, height: 10) : ink.size
        return (cap, NSRect(x: cap.midX - size.width / 2, y: cap.midY - size.height / 2,
                            width: size.width, height: size.height))
    }
    override func draw(_ dirtyRect: NSRect) {
        let fill = primary ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.1)
        fill.withAlphaComponent(isHighlighted ? 0.8 : 1).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke(); path.lineWidth = 1; path.stroke()
        let text = NSAttributedString(string: title, attributes: [.font: BrandTextStyle.ui.font(size: 13, weight: .medium), .foregroundColor: NSColor.white])
        text.draw(at: NSPoint(x: 11, y: (bounds.height - text.size().height) / 2))
        let (badge, glyph) = keycapLayout
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        let line = hintLine
        let ink = CTLineGetImageBounds(line, nil)
        guard ink.width > 0, ink.height > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        // Center the painted glyph, rather than its font's ascent/descent box.
        context.saveGState()
        context.translateBy(x: glyph.minX, y: glyph.maxY)
        context.scaleBy(x: glyph.width / ink.width, y: -glyph.height / ink.height)
        context.textMatrix = .identity
        context.textPosition = NSPoint(x: -ink.minX, y: -ink.minY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

@MainActor
final class NotificationSettingsCard: NSView {
    override var isFlipped: Bool { true }
}
