import AppKit
import BrowserCore

@MainActor
final class BrowserBoostColorControls: NSView {
    private let session: BrowserBoostEditorSession
    init(session: BrowserBoostEditorSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 224, height: 202))
        let labels = [uiText("Contrast"), uiText("Brightness"), uiText("Original Saturation")]
        let colors = session.boost.content.colorScheme
        let values = [colors?.contrast, colors?.brightness, colors?.originalSaturation]
        for index in 0..<3 {
            let label = NSTextField(labelWithString: labels[index]); label.font = .systemFont(ofSize: 12)
            label.frame = NSRect(x: 18, y: 164 - index * 62, width: 188, height: 18)
            addSubview(label)
            let slider = NSSlider(value: values[index] ?? 0.5, minValue: 0, maxValue: 1, target: self, action: #selector(change(_:)))
            slider.tag = index; slider.isContinuous = true
            slider.setAccessibilityLabel(labels[index])
            slider.frame = NSRect(x: 18, y: 145 - index * 62, width: 188, height: 20)
            addSubview(slider)
        }
    }
    required init?(coder: NSCoder) { nil }
    @objc private func change(_ sender: NSSlider) {
        let index = sender.tag, value = sender.doubleValue
        session.edit {
            var colors = $0.colorScheme ?? .init()
            switch index {
            case 0: colors.contrast = value
            case 1: colors.brightness = value
            default: colors.originalSaturation = value
            }
            $0.colorScheme = colors
        }
    }
}

@MainActor
final class BrowserBoostIntroductionView: NSView {
    static let accent = NSColor(srgbRed: 0.26, green: 0.21, blue: 1, alpha: 1)
    var onContinue: (() -> Void)?
    var onLater: (() -> Void)?
    init(host: String) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        let card = NSView(frame: NSRect(x: 0, y: 288, width: 183, height: 300))
        card.wantsLayer = true; card.layer?.backgroundColor = NSColor.white.cgColor
        addSubview(card)
        let glyph = NSImageView(frame: NSRect(x: 65, y: 254, width: 58, height: 58))
        glyph.image = NSImage(systemSymbolName: "paintbrush.pointed.fill", accessibilityDescription: nil)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = Self.accent; addSubview(glyph)
        let heading = NSTextField(wrappingLabelWithString: uiText("Edit the Internet with Boosts"))
        heading.font = .systemFont(ofSize: 21, weight: .bold); heading.textColor = Self.accent; heading.alignment = .center
        heading.frame = NSRect(x: 14, y: 346, width: 155, height: 84); addSubview(heading)
        let subtitle = NSTextField(wrappingLabelWithString: uiFormat("Make %@ your own!", host))
        subtitle.font = .systemFont(ofSize: 13); subtitle.textColor = .secondaryLabelColor; subtitle.alignment = .center
        subtitle.frame = NSRect(x: 12, y: 430, width: 159, height: 32); addSubview(subtitle)
        let bottom = NSView(frame: NSRect(x: 0, y: 468, width: 183, height: 120))
        bottom.wantsLayer = true; bottom.layer?.backgroundColor = NSColor(srgbRed: 0.81, green: 0.86, blue: 1, alpha: 1).cgColor
        addSubview(bottom)
        let start = BoostButton(title: uiText("Make a Boost")); start.fill = Self.accent; start.contentTintColor = .white
        start.frame = NSRect(x: 14, y: 496, width: 155, height: 38)
        start.actionBlock = { [weak self] in self?.onContinue?() }; addSubview(start)
        let later = BoostButton(title: uiText("Maybe Later")); later.fill = .clear
        later.frame = NSRect(x: 14, y: 548, width: 155, height: 28)
        later.actionBlock = { [weak self] in self?.onLater?() }; addSubview(later)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
}
