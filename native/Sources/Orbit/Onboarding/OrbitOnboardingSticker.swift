import AppKit

@MainActor
final class OrbitOnboardingSticker: NSView {
    let label = NSTextField(labelWithString: "")
    var stringValue: String {
        get { label.stringValue }
        set {
            let text = NSMutableAttributedString(string: newValue, attributes: [.font: OrbitOnboardingFonts.ui(15, weight: .bold), .foregroundColor: OrbitOnboardingColors.title])
            if newValue.first?.isNumber == true, let separator = newValue.range(of: " · ") {
                text.addAttribute(.font, value: OrbitOnboardingFonts.mono(15), range: NSRange(newValue.startIndex..<separator.lowerBound, in: newValue))
            }
            label.attributedStringValue = text
            setFrameSize(NSSize(width: ceil(label.intrinsicContentSize.width) + 44, height: 38))
            needsLayout = true
        }
    }
    init(text: String, color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 19
        layer?.borderWidth = 4; layer?.borderColor = NSColor.white.cgColor
        label.stringValue = text; label.alignment = .center
        label.font = OrbitOnboardingFonts.ui(15, weight: .bold)
        label.textColor = OrbitOnboardingColors.title
        addSubview(label)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 12, y: (bounds.height - height) / 2, width: bounds.width - 24, height: height)
    }
}
