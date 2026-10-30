import AppKit
import BrowserShell

/// Opaque paper notice over the Space gradient; installer admission stays with the updater.
@MainActor
final class SidebarUpdateCard: NSView {
    static let height: CGFloat = 154
    private let paper = CALayer()
    let icon = NSImageView()
    let title = NSTextField(labelWithString: uiText("An update is ready!"))
    let body = NSTextField(labelWithString: uiText("Click to restart"))
    let restart = SidebarUpdateRestartButton(title: uiText("Restart and Update"), target: nil, action: nil)
    let sticker = SidebarUpdateSticker(text: uiText("New"))
    var onRestart: (() -> Void)?
    var accent = OrbitTokens.ThemeAccent.defaultPurple

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        layer?.addSublayer(paper)
        paper.cornerRadius = 14
        paper.backgroundColor = NSColor.white.withAlphaComponent(0.94).cgColor
        paper.shadowColor = NSColor.black.cgColor
        paper.shadowOpacity = 0.4
        paper.shadowRadius = 15
        paper.shadowOffset = CGSize(width: 0, height: -8)
        icon.image = BrandFonts.mark
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = BrandTextStyle.ui.font(size: 13, weight: .semibold)
        body.font = BrandTextStyle.body.font(size: 12)
        title.textColor = BrandPalette.ink; body.textColor = BrandPalette.ink2
        title.alignment = .center; body.alignment = .center
        title.lineBreakMode = .byTruncatingTail; body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 2
        restart.isBordered = false
        restart.font = BrandTextStyle.ui.font(size: 12, weight: .semibold)
        restart.target = self; restart.action = #selector(performRestart)
        restart.setAccessibilityIdentifier("sidebar-restart-update")
        for view in [icon, title, body, restart, sticker] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(uiText("An update is ready!"))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 8)
        paper.frame = NSRect(x: 0, y: 20, width: width, height: bounds.height - 20)
        icon.frame = NSRect(x: (width - 26) / 2, y: 34, width: 26, height: 20)
        title.frame = NSRect(x: 12, y: 60, width: max(0, width - 24), height: 22)
        body.frame = NSRect(x: 12, y: 84, width: max(0, width - 24), height: 16)
        restart.frame = NSRect(x: 12, y: bounds.height - 42, width: max(0, width - 24), height: 30)
        sticker.frame = NSRect(x: bounds.width - 46, y: 8, width: 46, height: 24)
        sticker.frameRotation = 8
    }
    @objc private func performRestart() { onRestart?() }
}

@MainActor
final class SidebarUpdateRestartButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        BrandPalette.ink.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let text = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

@MainActor
final class SidebarUpdateSticker: NSView {
    let stringValue: String
    init(text: String) { stringValue = text; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
        BrandPalette.mint.setFill(); shape.fill()
        NSColor.white.setStroke(); shape.lineWidth = 4; shape.stroke()
        let text = NSAttributedString(string: stringValue, attributes: [.font: BrandTextStyle.ui.font(size: 10, weight: .bold), .foregroundColor: BrandPalette.ink])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
