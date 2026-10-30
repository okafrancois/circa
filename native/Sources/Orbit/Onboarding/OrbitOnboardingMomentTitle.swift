import AppKit
import BrowserShell

/// Word-sized clipping keeps the display title's reveal independent of its typeface.
@MainActor
final class OrbitOnboardingMomentTitle: NSTextField {
    private var words: [NSView] = []
    override func draw(_ dirtyRect: NSRect) {
        if words.isEmpty { super.draw(dirtyRect) }
    }
    func play(delay: Double, stagger: Double) {
        words.forEach { $0.removeFromSuperview() }; words = []
        guard !OrbitMotionPreferences.prefersReducedMotion, let font else {
            OrbitOnboardingMotion.entrance(self, delay: delay); return
        }
        clipsToBounds = false; layer?.masksToBounds = false
        let components = stringValue.split(separator: " ").map(String.init)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: -font.pointSize * 0.02]
        let widths = components.map { ceil(($0 as NSString).size(withAttributes: attributes).width) }
        let space = (" " as NSString).size(withAttributes: attributes).width
        var x = (bounds.width - widths.reduce(0, +) - CGFloat(max(0, components.count - 1)) * space) / 2
        for (index, word) in components.enumerated() {
            let horizontal = font.pointSize * 0.08, top = font.pointSize * 0.06, bottom = font.pointSize * 0.16
            let clip = OrbitOnboardingFlippedView(frame: NSRect(x: x - horizontal, y: -top,
                width: widths[index] + horizontal * 2, height: bounds.height + top + bottom))
            clip.wantsLayer = true; clip.layer?.masksToBounds = true
            let label = NSTextField(labelWithString: word)
            label.font = font; label.textColor = textColor
            var styled = attributes; styled[.foregroundColor] = textColor
            label.attributedStringValue = NSAttributedString(string: word, attributes: styled)
            label.frame = NSRect(x: horizontal - 2, y: top, width: widths[index] + 8, height: bounds.height)
            label.wantsLayer = true; clip.addSubview(label); addSubview(clip); words.append(clip)
            OrbitOnboardingMotion.animate(label.layer, key: "transform.translation.y", from: font.pointSize * 0.95 * 1.1, to: 0,
                duration: 1.1, delay: delay + Double(index) * stagger)
            x += widths[index] + space
        }
        needsDisplay = true
    }
}
