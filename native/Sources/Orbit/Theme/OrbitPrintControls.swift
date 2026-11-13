import AppKit
import BrowserShell

/// A flat ink button with a pressed offset, retaining native target/action and keyboard routing.
@MainActor
final class OrbitNativePrintButton: NSButton {
    var shadowInk = BrandPalette.ink { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        font = BrandFonts.onboardingBody(12, weight: .bold)
    }
    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: font ?? BrandFonts.ui(14)])
        return NSSize(width: ceil(size.width) + 36, height: 32)
    }
    override func draw(_ dirtyRect: NSRect) {
        let offset: CGFloat = isHighlighted ? 0 : 3
        let face = NSRect(x: 1, y: isFlipped ? 1 : 1 + offset, width: bounds.width - 2, height: bounds.height - 5)
        shadowInk.setFill()
        NSBezierPath(roundedRect: face.offsetBy(dx: 0, dy: isFlipped ? offset : -offset), xRadius: 14, yRadius: 14).fill()
        BrandPalette.coral.setFill()
        let outline = NSBezierPath(roundedRect: face, xRadius: 14, yRadius: 14)
        outline.fill()
        BrandPalette.ink.setStroke(); outline.lineWidth = 1.5; outline.stroke()
        let text = NSAttributedString(string: title, attributes: [.font: font ?? BrandFonts.ui(14), .foregroundColor: BrandPalette.pageWhite])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: face.midY - size.height / 2))
    }
}
