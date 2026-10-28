import AppKit

extension OrbitTokens.Metrics.QuickWindow {
    static let minimumSize = NSSize(width: 480, height: 240)
    static let addressLeadingInset: CGFloat = 86
    static let controlGap: CGFloat = 8
    static let trailingInset: CGFloat = 7.25
    /// : separate accessible disclosure hit target within the 208 pt button group.
    static let disclosureWidth: CGFloat = 24
    static let cascadeOffset: CGFloat = 24
}

/// Orbit's LittleBrowserWindow inherits NSPanel and presents through
/// makeKeyAndOrderFront: . AppKit owns the window animation; there is
/// no additional content-layer zoom or alpha animation on this path.
@MainActor
final class BrowserQuickWindowPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Uses dynamic tokens when the appearance changes while a Little Orbit is open.
@MainActor
final class BrowserQuickWindowAddressField: NSTextField {
    var onActivate: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if let onActivate { onActivate() } else { super.mouseDown(with: event) }
    }

    override var wantsUpdateLayer: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateLayer() }
    override func layout() { super.layout(); updateLayer() }
    override func draw(_ dirtyRect: NSRect) {
        guard !stringValue.isEmpty, currentEditor() == nil else { super.draw(dirtyRect); return }
        let url = URL(string: stringValue)
        let text = url?.host ?? stringValue
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: textColor ?? NSColor.labelColor, .paragraphStyle: paragraph]
        let height = ceil((font ?? NSFont.systemFont(ofSize: 13)).boundingRectForFont.height)
        text.draw(in: NSRect(x: 30, y: (bounds.height - height) / 2,
                            width: max(0, bounds.width - 60), height: height), withAttributes: attributes)
    }

    override func updateLayer() {
        layer?.cornerRadius = OrbitTokens.Radius.quickWindowAddress
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
    }
}

extension OrbitTokens.Metrics.QuickWindow {
    static let openInCornerRadius: CGFloat = 6
}

@MainActor
final class BrowserQuickWindowToolbarView: NSView {
    let fill = OrbitThemeFillView(frame: .zero)
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(fill)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        fill.windowFillSize = window?.contentView?.bounds.size
        fill.frame = bounds
    }
}

@MainActor
final class BrowserQuickWindowOpenGroup: NSView {
    var accent = OrbitTokens.ThemeAccent.defaultSpace { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = OrbitTokens.Metrics.QuickWindow.openInCornerRadius
        layer?.backgroundColor = accent.menuSurface.cgColor
    }
}

/// A compact keyboard hint and disclosure separator painted without intercepting the button.
@MainActor
final class BrowserQuickWindowOpenButton: NSButton {
    var shortcut = "" { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let color = contentTintColor ?? NSColor.labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let hintWidth: CGFloat = shortcut.isEmpty ? 0 : 34
        let text = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: color.withAlphaComponent(isEnabled ? 1 : 0.4), .paragraphStyle: paragraph])
        text.draw(in: NSRect(x: 8, y: (bounds.height - text.size().height) / 2,
                            width: max(0, bounds.width - hintWidth - 14), height: text.size().height))
        guard !shortcut.isEmpty else { return }
        let hint = NSAttributedString(string: shortcut, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color.withAlphaComponent(0.65)])
        let rect = NSRect(x: bounds.maxX - hintWidth, y: (bounds.height - 20) / 2, width: 30, height: 20)
        color.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        hint.draw(at: NSPoint(x: rect.midX - hint.size().width / 2, y: rect.midY - hint.size().height / 2))
        color.withAlphaComponent(0.14).setFill()
        NSRect(x: bounds.maxX - 0.5, y: 5, width: 0.5, height: bounds.height - 10).fill()
    }
}
