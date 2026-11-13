import AppKit
import BrowserShell
import CoreText

/// Display titles use cap-aligned lines with a fixed 0.95 em baseline advance.
@MainActor
final class OrbitOnboardingMomentTitle: NSTextField {
    override var isFlipped: Bool { true }
    private var displayFont: NSFont {
        attributedStringValue.length > 0
            ? attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? font ?? OrbitOnboardingFonts.title
            : font ?? OrbitOnboardingFonts.title
    }
    private var lineAdvance: CGFloat { (displayFont.pointSize * 0.95).rounded() }
    override var firstBaselineOffsetFromTop: CGFloat { displayFont.ascender }

    private func lines(width: CGFloat) -> [CTLine] {
        let text = attributedStringValue
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var result: [CTLine] = []
        var offset = 0
        while offset < text.length, maximumNumberOfLines == 0 || result.count < maximumNumberOfLines {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, offset, Double(max(1, width))))
            result.append(CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: count)))
            offset += count
        }
        return result
    }

    override func sizeThatFits(_ size: NSSize) -> NSSize {
        let lines = lines(width: size.width)
        let width = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        return NSSize(width: ceil(width), height: ceil(CGFloat(lines.count) * lineAdvance))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (index, line) in lines(width: bounds.width).enumerated() {
            context.saveGState()
            context.translateBy(x: 0, y: (lineAdvance - displayFont.ascender + displayFont.descender) / 2 + displayFont.ascender + CGFloat(index) * lineAdvance)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    func play(delay: Double, stagger: Double) {
        wantsLayer = true
        OrbitOnboardingMotion.entrance(self, y: 32, duration: 0.5, delay: delay)
    }
}
