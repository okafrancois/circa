import AppKit
import BrowserShell

/// A centered destructive confirmation. Presentation reuses the editor's plain native behavior.
@MainActor
final class BrowserBoostDeleteView: NSView {
    private let card = LibraryFlippedView()
    private let completion: (Bool) -> Void
    private var finished = false
    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        card.wantsLayer = true; card.layer?.cornerRadius = 18
        OrbitFloatingMaterial.install(in: card, radius: 18)
        addSubview(card)
        let icon = NSImageView(image: OrbitIcon.image(sfName: "puzzlepiece.extension", pointSize: 38, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 38, weight: .regular)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = OrbitFloatingMaterial.body
        icon.frame = NSRect(x: 40, y: 48, width: 50, height: 38); card.addSubview(icon)
        let title = NSTextField(labelWithString: uiText("Delete this Boost?"))
        title.font = BrandTextStyle.title.font(size: 18); title.textColor = OrbitFloatingMaterial.body
        title.frame = NSRect(x: 38, y: 116, width: 374, height: 28); card.addSubview(title)
        let message = NSTextField(labelWithString: uiText("This can’t be undone."))
        message.font = BrandTextStyle.ui.font(size: 14); message.textColor = OrbitFloatingMaterial.secondary
        message.frame = NSRect(x: 38, y: 156, width: 374, height: 24); card.addSubview(message)
        let cancel = BoostButton(title: uiText("Cancel"))
        cancel.setAccessibilityLabel(uiText("Cancel")); cancel.keyEquivalent = "\u{1b}"
        cancel.shortcutBadge = uiText("ESC")
        cancel.fill = .clear
        cancel.contentTintColor = OrbitFloatingMaterial.body; cancel.cornerRadius = 6
        cancel.wantsLayer = true; cancel.layer?.borderWidth = 1
        cancel.layer?.borderColor = NSColor.controlAccentColor.cgColor
        cancel.layer?.cornerRadius = 6
        cancel.frame = NSRect(x: 206, y: 208, width: 109, height: 36)
        cancel.actionBlock = { [weak self] in self?.finish(false) }; card.addSubview(cancel)
        let delete = BoostButton(title: uiText("Delete"))
        delete.setAccessibilityLabel(uiText("Delete")); delete.keyEquivalent = "\r"
        delete.shortcutBadge = "↩"; delete.outlinesShortcutBadge = true
        delete.fill = .controlAccentColor
        delete.contentTintColor = OrbitFloatingMaterial.accentText; delete.cornerRadius = 6
        delete.frame = NSRect(x: 323, y: 208, width: 99, height: 36)
        delete.actionBlock = { [weak self] in self?.finish(true) }; card.addSubview(delete)
        setAccessibilityElement(false)
        card.setAccessibilityElement(true); card.setAccessibilityRole(.group)
        card.setAccessibilitySubrole(.dialog); card.setAccessibilityLabel(uiText("Delete this Boost?"))
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        card.frame = NSRect(x: (bounds.width - 450) / 2, y: (bounds.height - 273) / 2, width: 450, height: 273)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    func finish(_ accepted: Bool) {
        guard !finished else { return }; finished = true
        removeFromSuperview(); completion(accepted)
    }
}
