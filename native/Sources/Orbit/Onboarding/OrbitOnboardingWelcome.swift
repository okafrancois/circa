import AppKit
import BrowserShell

@MainActor
final class OrbitOnboardingWelcomeView: NSView {
    let headline = OrbitOnboardingMomentTitle(labelWithString: OrbitOnboardingText.welcomeHeadline)
    let body = NSTextField(wrappingLabelWithString: OrbitOnboardingText.welcomeBody)
    let button = OrbitOnboardingPrimaryButton()
    let mark = OrbitOnboardingMarkView(frame: NSRect(x: 525, y: 208, width: 150, height: 111))
    let sticker = OrbitOnboardingSticker(text: OrbitOnboardingText.welcomeSticker, color: BrandPalette.sun)
    var onContinue: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        headline.font = OrbitOnboardingFonts.welcome
        headline.textColor = OrbitOnboardingColors.welcomeTitle
        headline.alignment = .center
        headline.frame = NSRect(x: 170, y: 307, width: 860, height: 100)
        body.font = OrbitOnboardingFonts.ui(15)
        body.textColor = BrandPalette.stageMuted
        body.alignment = .center
        body.frame = NSRect(x: 345, y: 441, width: 510, height: 46)
        button.title = OrbitOnboardingText.start
        button.accent = OrbitOnboardingColors.welcomeButton
        button.frame = NSRect(x: 540, y: 494, width: 120, height: 48)
        button.labelColor = OrbitOnboardingColors.stage
        button.keyEquivalent = "\r"
        button.onPress = { [weak self] in self?.onContinue?() }
        sticker.frame = NSRect(x: 860, y: 120, width: 220, height: 38)
        for v in [mark, headline, body, button, sticker] { v.wantsLayer = true; addSubview(v) }
        sticker.stringValue = OrbitOnboardingText.welcomeSticker
        sticker.frameRotation = 8
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func play() {
        mark.land()
        headline.play(delay: 0.5, stagger: 0.08)
        OrbitOnboardingMotion.entrance(body, delay: 0.9)
        OrbitOnboardingMotion.entrance(button, delay: 1)
        OrbitOnboardingMotion.animate(sticker.layer, key: "opacity", from: 0, to: 1, duration: 0.7, delay: 1.5)
        OrbitOnboardingMotion.animate(sticker.layer, key: "transform.rotation.z", from: -.pi * 28 / 180, to: 0, duration: 0.7, delay: 1.5, stick: true)
        OrbitOnboardingMotion.animate(sticker.layer, key: "transform.scale", from: 0, to: 1, duration: 0.7, delay: 1.5, stick: true)
    }
}
