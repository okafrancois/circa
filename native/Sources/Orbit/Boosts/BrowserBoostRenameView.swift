import AppKit

/// A centered, source-attached rename sheet. Its field remains a draft until Done.
@MainActor
final class BrowserBoostRenameView: NSView, NSTextFieldDelegate {
    let nameField = NSTextField()
    let done = BoostButton(title: uiText("Done"))
    let cancel = BoostButton(title: uiText("Cancel"))
    private let card = LibraryFlippedView()
    private let shadowView = BrowserBoostRenameShadow()
    private let dim = NSView()
    private let completion: (String?) -> Void
    private var timer: Timer?
    private var began = 0.0
    private var offset: CGFloat = -32
    private(set) var isFinishing = false

    init(name: String, completion: @escaping (String?) -> Void) {
        self.completion = completion
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .aqua)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(srgbRed: 0.82, green: 0.82, blue: 0.86, alpha: 0.4).cgColor
        addSubview(dim)
        addSubview(shadowView)
        card.wantsLayer = true; card.layer?.cornerRadius = 16
        card.clipsToBounds = false; card.layer?.masksToBounds = false
        card.layer?.backgroundColor = NSColor(srgbRed: 0.985, green: 0.985, blue: 1, alpha: 1).cgColor
        addSubview(card)
        let tile = NSView(frame: NSRect(x: 38, y: 38, width: 62, height: 62))
        tile.wantsLayer = true; tile.layer?.cornerRadius = 13
        tile.layer?.backgroundColor = NSColor(srgbRed: 0.90, green: 0.90, blue: 0.935, alpha: 1).cgColor
        card.addSubview(tile)
        let icon = NSImageView(image: NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 30, weight: .medium)
        icon.contentTintColor = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
        icon.frame = NSRect(x: 13, y: 13, width: 36, height: 36); tile.addSubview(icon)
        let title = NSTextField(labelWithString: uiText("Rename Boost?"))
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)
        title.frame = NSRect(x: 38, y: 116, width: 374, height: 26); card.addSubview(title)
        let fieldBorder = NSView(frame: NSRect(x: 38, y: 162, width: 374, height: 37))
        fieldBorder.wantsLayer = true; fieldBorder.layer?.cornerRadius = 5
        fieldBorder.layer?.backgroundColor = NSColor.white.cgColor
        fieldBorder.layer?.borderWidth = 1
        fieldBorder.layer?.borderColor = NSColor(calibratedWhite: 0.9, alpha: 1).cgColor
        card.addSubview(fieldBorder)
        nameField.stringValue = name; nameField.font = .systemFont(ofSize: 14)
        nameField.isBordered = false; nameField.drawsBackground = false; nameField.focusRingType = .none
        nameField.cell?.usesSingleLineMode = true; nameField.cell?.isScrollable = true
        nameField.delegate = self
        nameField.setAccessibilityLabel(uiText("Rename Boost?"))
        nameField.setAccessibilityIdentifier("boost-rename-name")
        nameField.frame = NSRect(x: 6, y: 9, width: 362, height: 19); fieldBorder.addSubview(nameField)
        cancel.keyEquivalent = "\u{1b}"; cancel.shortcutBadge = uiText("ESC")
        cancel.fill = .white; cancel.contentTintColor = .black; cancel.cornerRadius = 6
        cancel.shortcutBadgeColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        cancel.shortcutBadgeTextColor = NSColor(calibratedWhite: 0.45, alpha: 1)
        cancel.wantsLayer = true; cancel.layer?.borderWidth = 1
        cancel.layer?.borderColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
        cancel.layer?.cornerRadius = 6
        cancel.frame = NSRect(x: 214, y: 220, width: 109, height: 36)
        cancel.actionBlock = { [weak self] in self?.finish(false) }; card.addSubview(cancel)
        done.keyEquivalent = "\r"; done.shortcutBadge = "↩"; done.outlinesShortcutBadge = true
        done.contentTintColor = .white; done.cornerRadius = 6
        done.frame = NSRect(x: 331, y: 220, width: 91, height: 36)
        done.actionBlock = { [weak self] in self?.finish(true) }; card.addSubview(done)
        nameField.nextKeyView = cancel; cancel.nextKeyView = done; done.nextKeyView = nameField
        setAccessibilityElement(false)
        card.setAccessibilityElement(true); card.setAccessibilityRole(.sheet)
        card.setAccessibilityLabel(uiText("Rename Boost?"))
        updateValidity()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        dim.frame = bounds
        card.frame = NSRect(x: (bounds.width - 450) / 2, y: (bounds.height - 284) / 2 + offset, width: 450, height: 284)
        shadowView.frame = card.frame.insetBy(dx: -64, dy: -64)
    }
    func present() {
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
        window?.defaultButtonCell = done.cell as? NSButtonCell
        animate(entering: true) {}
    }
    func controlTextDidChange(_ obj: Notification) { updateValidity() }
    private func updateValidity() {
        done.isEnabled = BrowserBoostEditorSession.canRename(to: nameField.stringValue)
        done.fill = NSColor(srgbRed: 0.25, green: 0.20, blue: 0.99, alpha: done.isEnabled ? 1 : 0.35)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { finish(false); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { finish(true); return true }
        return false
    }
    override func cancelOperation(_ sender: Any?) { finish(false) }
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    func finish(_ accepted: Bool) {
        guard !isFinishing, !accepted || BrowserBoostEditorSession.canRename(to: nameField.stringValue) else { return }
        isFinishing = true
        let result = accepted ? nameField.stringValue : nil
        nameField.isEditable = false; done.isEnabled = false; cancel.isEnabled = false
        window?.defaultButtonCell = nil
        animate(entering: false) { [weak self] in
            guard let self else { return }
            removeFromSuperview(); completion(result)
        }
    }
    func stop() { timer?.invalidate(); timer = nil; window?.defaultButtonCell = nil; removeFromSuperview() }
    private func animate(entering: Bool, completion: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        guard window?.isVisible == true, !OrbitMotionPreferences.prefersReducedMotion else {
            offset = 0; card.alphaValue = 1; shadowView.alphaValue = 1; dim.alphaValue = 1; needsLayout = true; completion(); return
        }
        // 32 pt downward entrance over 0.30 s, after a 25 ms fade lead-in.
        // Exit moves upward and fades over 0.25 s. The backdrop uses the full duration.
        let duration = entering ? 0.30 : 0.25
        began = 0
        func apply(_ t: Double) {
            let p = min(1, t / duration)
            let samples: [Double] = entering
                ? [0, 0.02, 0.07, 0.13, 0.20, 0.28, 0.38, 0.47, 0.56, 0.66, 0.75, 0.82, 0.88, 0.93, 0.97, 0.99, 1, 1, 1]
                : [0, 0.01, 0.04, 0.09, 0.15, 0.23, 0.32, 0.42, 0.52, 0.62, 0.71, 0.79, 0.87, 0.93, 0.98, 1]
            let movement = min(1, max(0, t - (entering ? 0.025 : 0)) / duration)
            let sample = movement * Double(samples.count - 1)
            let index = Int(sample), next = min(index + 1, samples.count - 1)
            let smooth = samples[index] + (samples[next] - samples[index]) * (sample - floor(sample))
            self.offset = -32 * (entering ? 1 - smooth : smooth)
            self.card.alphaValue = entering ? min(1, t / 0.15) : 1 - p
            self.shadowView.alphaValue = self.card.alphaValue
            self.dim.alphaValue = entering ? p : 1 - p
            self.needsLayout = true; self.layoutSubtreeIfNeeded()
        }
        apply(0)
        timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.began == 0 { self.began = now }
                let elapsed = now - self.began
                apply(elapsed)
                if elapsed >= duration { self.timer?.invalidate(); self.timer = nil; completion() }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
}

@MainActor
private final class BrowserBoostRenameShadow: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 64, dy: 64), xRadius: 16, yRadius: 16)
        // Keep the source fill out of the card, so its fade is composited only once.
        let exterior = NSBezierPath(rect: bounds)
        exterior.append(shape); exterior.windingRule = .evenOdd; exterior.addClip()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -16)
        shadow.set()
        NSColor(srgbRed: 0.985, green: 0.985, blue: 1, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
