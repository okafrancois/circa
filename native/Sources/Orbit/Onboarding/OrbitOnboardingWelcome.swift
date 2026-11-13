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
    let illustration = OrbitOnboardingMoonArt(frame: .zero)
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        illustration.frame = NSRect(x: 740, y: 305, width: 570, height: 570)
        mark.frame = NSRect(x: 54, y: 96, width: 120, height: 120)
        headline.attributedStringValue = BrandTextStyle.title.attributedString(OrbitOnboardingText.welcomeHeadline, size: 85, attributes: [.foregroundColor: BrandPalette.ink])
        headline.cell?.usesSingleLineMode = false
        headline.cell?.wraps = true
        headline.cell?.isScrollable = false
        headline.lineBreakMode = .byWordWrapping
        headline.alignment = .left
        headline.maximumNumberOfLines = 2
        headline.frame = NSRect(x: 54, y: 242, width: 650, height: 182)
        body.font = OrbitOnboardingFonts.ui(22)
        body.textColor = BrandPalette.ink2
        body.alignment = .left
        body.frame = NSRect(x: 54, y: 427, width: 510, height: 40)
        button.title = OrbitOnboardingText.start
        button.accent = OrbitOnboardingColors.welcomeButton
        button.frame = NSRect(origin: NSPoint(x: 54, y: 644), size: button.intrinsicContentSize)
        button.labelColor = BrandPalette.pageWhite
        button.keyEquivalent = "\r"
        button.onPress = { [weak self] in self?.onContinue?() }
        for v in [illustration, mark, headline, body, button] { v.wantsLayer = true; addSubview(v) }
        sticker.isHidden = true
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func play() {
        mark.land(delay: 0.2, drawBands: false)
        OrbitOnboardingMotion.animate(mark.layer, key: "opacity", from: 0, to: 1, duration: 0.5, delay: 0.38)
        headline.play(delay: 0.45, stagger: 0.07)
        OrbitOnboardingMotion.entrance(body, y: 32, duration: 0.5, delay: 0.52)
        OrbitOnboardingMotion.entrance(button, y: 32, duration: 0.5, delay: 0.59)
        illustration.play()
    }
}

/// Shared original artwork, rasterized at three times its vector coordinate size.
@MainActor
final class OrbitOnboardingIllustrationView: NSImageView {
    init(_ name: String) {
        super.init(frame: .zero)
        image = BrowserText.secondaryBrandResource(name, extension: "png").flatMap { NSImage(contentsOf: $0) }
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class OrbitOnboardingPlanetButton: NSButton {
    let planetIndex: Int
    var isSelectedPlanet = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    init(index: Int) {
        planetIndex = index
        super.init(frame: .zero)
        isBordered = false; title = ""
        setAccessibilityLabel(uiText(BrandPalette.spaceGradients[index].name))
        target = self; action = #selector(press)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        if isSelectedPlanet {
            BrandPalette.ink.setStroke()
            let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)); circle.lineWidth = 2; circle.stroke()
        }
        SpaceIconImages.planet(at: planetIndex)?.draw(in: bounds.insetBy(dx: 9, dy: 9))
    }
    @objc private func press() { onPress?() }
}

@MainActor
final class OrbitOnboardingMiniPreview: NSView {
    var planetIndex = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let scale = bounds.width / 232
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
        func box(_ rect: NSRect, _ color: NSColor, _ radius: CGFloat = 3) {
            color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        let tint = OrbitSpaceThemes.color(BrandPalette.spaceGradients[planetIndex].stops[0])
        box(NSRect(x: 0, y: 0, width: 232, height: 150), tint, 11)
        BrandPalette.ink.setStroke(); let outline = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 230, height: 148), xRadius: 11, yRadius: 11); outline.lineWidth = 2; outline.stroke()
        box(NSRect(x: 104, y: 5, width: 123, height: 140), BrandPalette.pageWhite, 7)
        for x in [11, 20, 29] { box(NSRect(x: x, y: 12, width: 6, height: 6), BrandPalette.ink.withAlphaComponent(0.3)) }
        for i in 0..<6 {
            box(NSRect(x: 10 + CGFloat(i % 3) * 28, y: 29 + CGFloat(i / 3) * 20, width: 24, height: 16), BrandPalette.ink.withAlphaComponent(0.08), 5)
        }
        SpaceIconImages.planet(at: planetIndex)?.draw(in: NSRect(x: 11, y: 80, width: 15, height: 15), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let name = uiText(BrandPalette.spaceGradients[planetIndex].name)
        name.draw(at: NSPoint(x: 30, y: 80), withAttributes: [.font: BrandFonts.ui(10, weight: .semibold), .foregroundColor: BrandPalette.ink])
        for (i, width) in [74, 55, 64].enumerated() { box(NSRect(x: 12, y: 103 + i * 11, width: width, height: 5), BrandPalette.ink.withAlphaComponent(0.14)) }
        let heading = BrandTextStyle.title.attributedString(uiText("Welcome home."), size: 15, attributes: [.foregroundColor: BrandPalette.ink])
        heading.draw(in: NSRect(x: 115, y: 20, width: 105, height: 40))
        for (i, width) in [74, 90, 57].enumerated() { box(NSRect(x: 115, y: 70 + i * 12, width: width, height: 5), BrandPalette.ink.withAlphaComponent(0.14)) }
        NSGraphicsContext.restoreGraphicsState()
    }
}
