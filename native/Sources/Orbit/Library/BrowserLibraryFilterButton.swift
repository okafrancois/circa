import AppKit

/// The list toolbar reserves its filter affordance without adding unimplemented filtering.
@MainActor
final class BrowserLibraryFilterButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = uiText("Filter")
        isBordered = false
        isEnabled = false
        setAccessibilityLabel(uiText("Filter"))
        widthAnchor.constraint(equalToConstant: 73).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        BrowserLibraryStyle.foreground.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let ink = BrowserLibraryStyle.foreground.withAlphaComponent(0.5)
        NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))?
            .withSymbolConfiguration(.init(paletteColors: [ink]))?
            .draw(in: NSRect(x: 10, y: bounds.midY - 8, width: 16, height: 16))
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: ink])
        text.draw(in: NSRect(x: 29, y: bounds.midY - 9, width: 42, height: 18))
    }
}
