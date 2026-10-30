import AppKit
import BrowserShell
import BrowserEngine

@MainActor
final class BrowserPasswordPromptView: NSView {
    private let dimmer = NSView()
    private let panel = NSView()
    private let motion = OrbitTimedAnimator(value: 0)
    private var decide: ((BrowserPasswordDecision) -> Void)?
    private var completion: (() -> Void)?
    private var closing = false
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private var buttons: [NSButton] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(prompt: BrowserPasswordPrompt, decide: @escaping (BrowserPasswordDecision) -> Void) {
        self.decide = decide
        let updating = prompt.state == .update
        let site = URL(string: prompt.origin)?.host ?? ""
        titleLabel = NSTextField(labelWithString: updating ? uiText("Update password?") : (site.isEmpty ? uiText("Save this password?") : uiFormat("Save password for %@?", site)))
        detailLabel = NSTextField(labelWithString: uiText("That way, it’ll be auto-filled next time"))
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier("password-prompt")
        setAccessibilityRole(.group)
        setAccessibilityLabel(titleLabel.stringValue)
        dimmer.wantsLayer = true
        dimmer.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(dimmer)
        panel.wantsLayer = true
        OrbitFloatingMaterial.install(in: panel, radius: 16)
        panel.layer?.cornerRadius = 16
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Self.color(55, 60, 76).cgColor
        panel.shadow = NSShadow()
        panel.layer?.shadowColor = NSColor.black.cgColor
        panel.layer?.shadowOpacity = 0.4
        panel.layer?.shadowRadius = 22
        panel.layer?.shadowOffset = CGSize(width: 0, height: -12)
        addSubview(panel)
        let icon = NSView(frame: NSRect(x: 38, y: 174, width: 62, height: 62))
        icon.wantsLayer = true
        icon.layer?.backgroundColor = Self.color(49, 54, 80).cgColor
        icon.layer?.cornerRadius = 13
        let key = NSImageView(frame: NSRect(x: 16, y: 13, width: 30, height: 36))
        key.image = OrbitIcon.image(sfName: "key.fill", pointSize: 30, accessibilityDescription: nil)
        key.contentTintColor = .white
        key.imageScaling = .scaleProportionallyDown
        // The key is vertical, with its teeth pointing down.
        icon.addSubview(key)
        panel.addSubview(icon)
        titleLabel.font = BrandTextStyle.title.font(size: 22)
        titleLabel.textColor = OrbitFloatingMaterial.body
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.frame = NSRect(x: 36, y: 132, width: 374, height: 30)
        panel.addSubview(titleLabel)
        detailLabel.font = BrandTextStyle.ui.font(size: 14, weight: .medium)
        detailLabel.textColor = OrbitFloatingMaterial.secondary
        detailLabel.frame = NSRect(x: 36, y: 98, width: 384, height: 22)
        panel.addSubview(detailLabel)
        if !updating { addButton(uiText("Never on this site"), hint: nil, decision: .never, x: 28, width: 130) }
        addButton(updating ? uiText("No Thanks") : uiText("No"), hint: uiText("ESC"), decision: .notNow,
                  x: updating ? 124 : 240, width: updating ? 122 : 86)
        addButton(updating ? uiText("Update Password") : uiText("Save"), hint: "↩", decision: .save,
                  x: updating ? 254 : 334, width: updating ? 170 : 90)
        for (index, button) in buttons.enumerated() { button.nextKeyView = buttons[(index + 1) % buttons.count] }
        nextKeyView = buttons.first
        motion.onChange = { [weak self] value in self?.apply(value) }
        motion.onSettle = { [weak self] in
            guard let self, closing else { return }
            removeFromSuperview(); completion?(); completion = nil
        }
    }

    required init?(coder: NSCoder) { nil }

    private func addButton(_ title: String, hint: String?, decision: BrowserPasswordDecision, x: CGFloat, width: CGFloat) {
        let button = PasswordPromptButton(title: title, hint: hint, primary: decision == .save)
        button.frame = NSRect(x: x, y: 28, width: width, height: 36)
        button.tag = Int(decision.rawValue)
        button.target = self
        button.action = #selector(choose(_:))
        button.setAccessibilityIdentifier("password-prompt-\(decision.rawValue)")
        panel.addSubview(button)
        buttons.append(button)
    }

    override func layout() { super.layout(); apply(motion.value) }

    private func apply(_ value: Double) {
        dimmer.frame = bounds
        dimmer.alphaValue = 0.6 * value
        let position = OrbitAnimationTiming(duration: 1, x1: 0.42, y1: 0, x2: 0.58, y2: 1).progress(after: value)
        panel.frame = NSRect(x: (bounds.width - 450) / 2, y: (bounds.height - 274) / 2 - 34 * (1 - position), width: 450, height: 274)
        // Content appears before the dimmer completes its transition.
        panel.alphaValue = closing ? value : min(1, value * 2.5)
    }

    func present() {
        apply(0)
        if OrbitMotionPreferences.prefersReducedMotion { motion.set(1); return }
        motion.animate(to: 1, timing: .init(duration: 0.3, x1: 0, y1: 0, x2: 1, y2: 1), in: self)
    }

    func dismiss(animated: Bool, completion: @escaping () -> Void) {
        decide = nil
        buttons.forEach { $0.isEnabled = false }
        self.completion = completion
        closing = true
        if animated && !OrbitMotionPreferences.prefersReducedMotion {
            motion.animate(to: 0, timing: .init(duration: 0.3, x1: 0, y1: 0, x2: 1, y2: 1), in: self)
        } else { motion.set(0); removeFromSuperview(); completion(); self.completion = nil }
    }

    @objc private func choose(_ sender: NSButton) {
        guard let decision = BrowserPasswordDecision(rawValue: Int32(sender.tag)), let decide else { return }
        self.decide = nil
        decide(decision)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { buttons.first { $0.tag == Int(BrowserPasswordDecision.notNow.rawValue) }?.performClick(nil) }
        else if event.characters == "\r" { buttons.last?.performClick(nil) }
        else if event.characters == "\t" { window?.selectNextKeyView(self) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 53 { cancelOperation(nil); return true }
        if event.characters == "\r" { buttons.last?.performClick(nil); return true }
        return false
    }
    override func cancelOperation(_ sender: Any?) {
        buttons.first { $0.tag == Int(BrowserPasswordDecision.notNow.rawValue) }?.performClick(nil)
    }
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    fileprivate static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }
}

@MainActor
private final class PasswordPromptButton: NSButton {
    let hint: String?
    let primary: Bool
    init(title: String, hint: String?, primary: Bool) {
        self.hint = hint; self.primary = primary
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        focusRingType = .none
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (primary ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.10)).setFill()
        path.fill()
        BrowserPasswordPromptView.color(100, 94, 172).setStroke(); path.lineWidth = 1; path.stroke()
        let font = BrandTextStyle.ui.font(size: 13, weight: .medium)
        let ink = primary ? OrbitFloatingMaterial.accentText : OrbitFloatingMaterial.body
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let textWidth = (title as NSString).size(withAttributes: attributes).width
        let badgeWidth: CGFloat = hint == nil ? 0 : hint == "↩" ? 28 : 35
        let total = textWidth + (hint == nil ? 0 : badgeWidth + 8)
        let x = (bounds.width - total) / 2
        (title as NSString).draw(at: NSPoint(x: x, y: 10), withAttributes: attributes)
        if let hint {
            let rect = NSRect(x: x + textWidth + 8, y: 9, width: badgeWidth, height: 20)
            NSColor.white.withAlphaComponent(0.18).setFill()
            let badge = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            badge.fill()
            if primary { NSColor.white.withAlphaComponent(0.2).setStroke(); badge.lineWidth = 1; badge.stroke() }
            let hintAttributes: [NSAttributedString.Key: Any] = [.font: BrandTextStyle.mono.font(size: hint == "↩" ? 18 : 10, weight: hint == "↩" ? .regular : .bold), .foregroundColor: ink]
            let size = (hint as NSString).size(withAttributes: hintAttributes)
            (hint as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: hintAttributes)
        }
        if isHighlighted { NSColor.white.withAlphaComponent(0.12).setFill(); path.fill() }
        if window?.firstResponder === self { NSColor.white.setStroke(); path.lineWidth = 2; path.stroke() }
    }
}
