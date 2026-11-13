import AppKit
import BrowserShell

/// A flat ink button with a pressed offset, retaining native target/action and keyboard routing.
@MainActor
final class OrbitNativePrintButton: NSButton {
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
        let offset: CGFloat = isHighlighted ? 0 : 2
        let face = bounds.insetBy(dx: 1, dy: 1).offsetBy(dx: 0, dy: offset)
        BrandPalette.ink.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).fill()
        BrandPalette.coral.setFill()
        NSBezierPath(roundedRect: face, xRadius: 14, yRadius: 14).fill()
        let text = NSAttributedString(string: title, attributes: [.font: font ?? BrandFonts.ui(14), .foregroundColor: BrandPalette.pageWhite])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2 + offset))
    }
}
