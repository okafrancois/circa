import AppKit

/// Compact help capsule with individually framed shortcut characters.
@MainActor
final class BrowserToolbarTooltip: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(name: String, shortcut: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill = dark ? NSColor(white: 0.88, alpha: 1) : NSColor(srgbRed: 0.937, green: 0.922, blue: 0.906, alpha: 1)
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = 14
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = dark ? .black : NSColor(srgbRed: 0.14, green: 0.12, blue: 0.10, alpha: 1)
        let width = ceil((name as NSString).size(withAttributes: [.font: label.font!]).width)
        label.frame = CGRect(x: 8, y: 6, width: width + 4, height: 17)
        addSubview(label)
        var x = width + 14
        for char in shortcut ?? "" {
            let key = NSTextField(labelWithString: String(char))
            key.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
            key.alignment = .center
            key.textColor = label.textColor
            key.wantsLayer = true
            key.layer?.cornerRadius = 3
            key.layer?.borderWidth = 1.5
            key.layer?.borderColor = (dark ? NSColor(white: 0.52, alpha: 1) : NSColor(srgbRed: 0.67, green: 0.61, blue: 0.55, alpha: 1)).cgColor
            key.layer?.backgroundColor = (dark ? NSColor(white: 0.77, alpha: 1) : NSColor(srgbRed: 0.87, green: 0.84, blue: 0.81, alpha: 1)).cgColor
            key.frame = CGRect(x: x, y: 5, width: 18, height: 18)
            addSubview(key)
            x += 21
        }
        frame.size = NSSize(width: x + (shortcut == nil ? 0 : 7), height: 28)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
}
