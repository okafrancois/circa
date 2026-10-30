import AppKit
import BrowserCore
import BrowserShell

/// A captured tab's home URL draft. Cancellation never submits an organization command.
@MainActor
final class PinnedURLEditor: NSViewController, NSTextFieldDelegate {
    let field = NSTextField()
    let saveButton = BoostButton(title: uiText("Save"))
    let cancelButton = BoostButton(title: uiText("Cancel"))
    private var finished = false
    private let save: (URL) -> Void
    var onClose: (() -> Void)?
    private weak var host: NSView?
    private weak var previousResponder: NSResponder?
    private let card = NSView()
    private var offset: CGFloat = 32
    private var finishing = false
    private var animating = false

    init(url: URL, save: @escaping (URL) -> Void) {
        self.save = save
        super.init(nibName: nil, bundle: nil)
        field.stringValue = url.absoluteString
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let overlay = PinnedURLOverlay()
        overlay.onCancel = { [weak self] in self?.complete(save: false) }
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        card.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 26
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        card.shadow = shadow
        OrbitFloatingMaterial.install(in: card, radius: 12)
        let title = NSTextField(labelWithString: uiText("Edit Pinned URL"))
        title.font = BrandTextStyle.ui.font(size: 17, weight: .semibold)
        title.textColor = OrbitFloatingMaterial.body
        title.frame = NSRect(x: 38, y: 188, width: 317, height: 24)
        let detail = NSTextField(wrappingLabelWithString: uiText("This is what opens first when you click this tab or its favicon."))
        detail.font = BrandTextStyle.body.font(size: 14)
        detail.textColor = OrbitFloatingMaterial.secondary
        detail.frame = NSRect(x: 38, y: 134, width: 317, height: 40)
        field.frame = NSRect(x: 38, y: 86, width: 317, height: 36)
        field.font = BrandTextStyle.ui.font(size: 13)
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityIdentifier("pinned-url-draft")
        field.setAccessibilityLabel(uiText("Pinned URL"))
        for (button, x) in [(cancelButton, CGFloat(157)), (saveButton, CGFloat(275))] {
            button.frame = NSRect(x: x, y: 26, width: button === saveButton ? 90 : 109, height: 36)
            button.font = BrandTextStyle.ui.font(size: 13)
            card.addSubview(button)
        }
        saveButton.actionBlock = { [weak self] in self?.complete(save: true) }
        saveButton.shortcutBadge = "↩"
        saveButton.outlinesShortcutBadge = true
        saveButton.fill = .controlAccentColor
        saveButton.contentTintColor = OrbitFloatingMaterial.accentText
        saveButton.keyEquivalent = "\r"
        saveButton.bezelColor = .controlAccentColor
        cancelButton.actionBlock = { [weak self] in self?.complete(save: false) }
        cancelButton.shortcutBadge = uiText("ESC")
        cancelButton.contentTintColor = OrbitFloatingMaterial.body
        cancelButton.fill = .quaternaryLabelColor
        cancelButton.keyEquivalent = "\u{1b}"
        for child in [title, detail, field] { card.addSubview(child) }
        card.setAccessibilityRole(.sheet)
        card.setAccessibilityLabel(uiText("Edit Pinned URL"))
        overlay.addSubview(card)
        overlay.onLayout = { [weak self] in self?.layoutCard() }
        view = overlay
        refreshValidation()
    }

    private func layoutCard() {
        guard !finishing, !animating else { return }
        card.frame = NSRect(x: (view.bounds.width - 393) / 2, y: (view.bounds.height - 265) / 2 + offset, width: 393, height: 265)
    }

    var draftURL: URL? {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text),
              let scheme = url.scheme, !scheme.isEmpty else { return nil }
        return url
    }
    func refreshValidation() {
        saveButton.isEnabled = draftURL != nil && (field.currentEditor() as? NSTextView)?.hasMarkedText() != true
    }
    func controlTextDidChange(_ notification: Notification) { refreshValidation() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { complete(save: false); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { complete(save: true); return true }
        return false
    }

    func complete(save shouldSave: Bool) {
        guard !finished else { return }
        if shouldSave {
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, let url = draftURL else { return }
            save(url)
        }
        finished = true
        dismiss()
    }

    func show(in host: NSView) {
        guard let window = host.window, !finished, view.superview == nil else { return }
        self.host = host
        previousResponder = window.firstResponder
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        layoutCard()
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.125
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.animator().alphaValue = 1
        }
        animating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            card.animator().setFrameOrigin(NSPoint(x: card.frame.minX, y: card.frame.minY - offset))
        }, completionHandler: { [weak self] in self?.animating = false })
        offset = 0
        window.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func dismiss() {
        guard host != nil else { onClose?(); return }
        finishing = true
        field.isEditable = false
        saveButton.isEnabled = false
        cancelButton.isEnabled = false
        let window = host?.window
        window?.makeFirstResponder(previousResponder)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.animator().alphaValue = 0
            card.animator().setFrameOrigin(NSPoint(x: card.frame.minX, y: card.frame.minY + 32))
        }, completionHandler: { [self] in
            view.removeFromSuperview()
            onClose?()
        })
    }
}

@MainActor
private final class PinnedURLOverlay: NSView {
    var onCancel: (() -> Void)?
    var onLayout: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func mouseDown(with event: NSEvent) { }
    override func rightMouseDown(with event: NSEvent) { }
    override func scrollWheel(with event: NSEvent) { }
}
