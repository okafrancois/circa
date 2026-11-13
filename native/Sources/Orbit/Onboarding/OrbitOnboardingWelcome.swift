import AppKit
import BrowserShell
import BrowserCore
import CoreText

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
        illustration.frame = NSRect(x: 742.11, y: 290.53, width: 568.42, height: 549.47)
        mark.frame = NSRect(x: 53.68, y: 94.74, width: 120, height: 120)
        headline.attributedStringValue = BrandTextStyle.title.attributedString(OrbitOnboardingText.welcomeHeadline, size: 85.26, opticalSize: 54, attributes: [.foregroundColor: BrandPalette.ink])
        headline.cell?.usesSingleLineMode = false
        headline.cell?.wraps = true
        headline.cell?.isScrollable = false
        headline.lineBreakMode = .byWordWrapping
        headline.alignment = .left
        headline.maximumNumberOfLines = 2
        headline.frame = NSRect(x: 53.68, y: 243.16, width: 587.37, height: 162)
        body.font = OrbitOnboardingFonts.ui(22.11)
        body.textColor = BrandPalette.ink.withAlphaComponent(0.82)
        body.alignment = .left
        body.frame = NSRect(x: 51.68, y: 421.05, width: 490.32, height: 32.05)
        button.title = OrbitOnboardingText.start
        button.accent = OrbitOnboardingColors.welcomeButton
        button.frame = NSRect(origin: NSPoint(x: 53.68, y: 608.95), size: button.intrinsicContentSize)
        button.labelColor = BrandPalette.rgb(0xFFF8E6)
        button.keyEquivalent = "\r"
        button.onPress = { [weak self] in self?.onContinue?() }
        for v in [illustration, mark, headline, body, button] { v.wantsLayer = true; addSubview(v) }
        sticker.isHidden = true
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func play(animateCopy: Bool = true) {
        mark.land(delay: 0.2, drawBands: false)
        OrbitOnboardingMotion.animate(mark.layer, key: "opacity", from: 0, to: 1, duration: 0.5, delay: 0.38)
        if animateCopy {
        headline.play(delay: 0.45, stagger: 0.07)
        OrbitOnboardingMotion.entrance(body, y: 31.58, duration: 0.5, delay: 0.52)
        OrbitOnboardingMotion.entrance(button, y: 31.58, duration: 0.5, delay: 0.59)
        }
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
    static let images: [NSImage?] = (0..<4).map { index in
        BrowserText.secondaryBrandResource("onboarding-planet-" + String(index), extension: "png").flatMap { NSImage(contentsOf: $0) }
    }
    var onCustomize: (() -> Void)?
    let planetIndex: Int
    private let ring = CAShapeLayer()
    private var tracking: NSTrackingArea?
    var isSelectedPlanet = false { didSet { updateRing(from: oldValue) } }
    var onPress: (() -> Void)?
    init(index: Int) {
        planetIndex = index
        super.init(frame: .zero)
        isBordered = false; title = ""
        wantsLayer = true
        layer?.masksToBounds = false
        ring.fillColor = nil; ring.strokeColor = BrandPalette.ink.cgColor; ring.lineWidth = 3.16
        ring.opacity = 0; layer?.addSublayer(ring)
        setAccessibilityLabel(uiText(BrandPalette.spaceGradients[index].name))
        target = self; action = #selector(press)
        let menu = NSMenu()
        let edit = NSMenuItem(title: uiText("Edit Theme Color…"), action: #selector(customize), keyEquivalent: "")
        edit.target = self; menu.addItem(edit); self.menu = menu
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        Self.images[planetIndex]?.draw(in: bounds.insetBy(dx: 11.05, dy: 11.05), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    override func layout() {
        super.layout()
        ring.bounds = NSRect(origin: .zero, size: bounds.size)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.58, dy: 1.58), transform: nil)
    }
    private func updateRing(from old: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.opacity = isSelectedPlanet ? 1 : 0
        ring.transform = CATransform3DMakeScale(isSelectedPlanet ? 1 : 0.7, isSelectedPlanet ? 1 : 0.7, 1)
        CATransaction.commit()
        needsLayout = true
        guard window != nil, old != isSelectedPlanet, !OrbitMotionPreferences.prefersReducedMotion else { return }
        let opacity = CABasicAnimation(keyPath: "opacity"); opacity.fromValue = old ? 1 : 0; opacity.toValue = isSelectedPlanet ? 1 : 0
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = old ? 1 : 0.7; scale.toValue = isSelectedPlanet ? 1 : 0.7
        opacity.duration = 0.25; scale.duration = 0.25
        opacity.timingFunction = CAMediaTimingFunction(name: .linear); scale.timingFunction = CAMediaTimingFunction(name: .linear)
        let group = CAAnimationGroup(); group.animations = [opacity, scale]; group.duration = 0.25
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.8, 0.5, 1)
        ring.add(group, forKey: "orbit.planetRing")
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    private func hover(_ value: CGFloat) {
        guard let layer else { return }
        var target = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        target = CATransform3DScale(target, value, value, 1)
        target = CATransform3DTranslate(target, -bounds.midX, -bounds.midY, 0)
        let previous = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.transform = target; CATransaction.commit()
        guard !OrbitMotionPreferences.prefersReducedMotion else { return }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: previous); animation.toValue = NSValue(caTransform3D: target)
        animation.duration = 0.25; animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.8, 0.5, 1)
        layer.add(animation, forKey: "orbit.planetHover")
    }
    override func mouseEntered(with event: NSEvent) { hover(1.1) }
    override func mouseExited(with event: NSEvent) { hover(1) }
    @objc private func press() { onPress?() }
    @objc private func customize() { onCustomize?() }
}

@MainActor
final class OrbitOnboardingMiniPreview: NSView {
    private let outlineLayer = CAShapeLayer()
    private let planetViews = (0..<4).map { index -> NSImageView in
        let view = NSImageView(); view.image = OrbitOnboardingPlanetButton.images[index]
        view.imageScaling = .scaleProportionallyUpOrDown; view.wantsLayer = true
        return view
    }
    var planetIndex = 0 { didSet { updatePlanet(animated: window != nil); needsDisplay = true } }
    var sites: [BrowserOnboardingFavourite] = [] { didSet { needsDisplay = true; needsLayout = true } }
    var icons: [URL: NSImage] = [:] { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        outlineLayer.fillColor = nil; outlineLayer.strokeColor = BrandPalette.ink.cgColor
        layer?.addSublayer(outlineLayer)
        layer?.masksToBounds = false
        for view in planetViews { addSubview(view) }
        updatePlanet(animated: false)
    }
    required init?(coder: NSCoder) { nil }
    private func updatePlanet(animated: Bool) {
        let color = OrbitSpaceThemes.color(BrandPalette.spaceGradients[planetIndex].stops[0])
        let previous = (layer?.presentation() ?? layer)?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB) ?? color
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = color.cgColor
        CATransaction.commit()
        if animated, !OrbitMotionPreferences.prefersReducedMotion {
            let tint = CAKeyframeAnimation(keyPath: "backgroundColor")
            tint.values = (0...60).map { frame -> CGColor in
                let t = 1 - pow(1 - Double(frame) / 60, 2)
                return NSColor(srgbRed: previous.redComponent + (color.redComponent - previous.redComponent) * t,
                    green: previous.greenComponent + (color.greenComponent - previous.greenComponent) * t,
                    blue: previous.blueComponent + (color.blueComponent - previous.blueComponent) * t, alpha: 1).cgColor
            }
            tint.timingFunction = CAMediaTimingFunction(name: .linear)
            tint.duration = 0.4; layer?.add(tint, forKey: "orbit.miniTint")
        }
        for (index, view) in planetViews.enumerated() {
            let from = view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
            let target: CGFloat = index == planetIndex ? 1 : 0
            view.alphaValue = target
            if animated, !OrbitMotionPreferences.prefersReducedMotion {
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = (0...60).map { frame in Double(from) + (Double(target) - Double(from)) * (1 - pow(1 - Double(frame) / 60, 2)) }
                fade.timingFunction = CAMediaTimingFunction(name: .linear)
                fade.duration = 0.25; view.layer?.add(fade, forKey: "orbit.miniPlanet")
            }
        }
    }
    override func layout() {
        super.layout()
        let scale = bounds.width / 232
        layer?.cornerRadius = 11 * scale
        outlineLayer.frame = bounds
        outlineLayer.lineWidth = 2 * scale
        outlineLayer.path = CGPath(roundedRect: bounds.insetBy(dx: -scale, dy: -scale), cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil)
        let selected = sites.filter(\.selected).count
        let nameY = 22 + CGFloat(max(1, (selected + 2) / 3)) * 19 + 3
        for view in planetViews { view.frame = NSRect(x: 9 * scale, y: nameY * scale, width: 14 * scale, height: 14 * scale) }
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let scale = bounds.width / 232
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
        func box(_ rect: NSRect, _ color: NSColor, _ radius: CGFloat = 3) {
            color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        box(NSRect(x: 106.56, y: 4, width: 121.44, height: 142), BrandPalette.pageWhite, 7)
        for x in [9, 18, 27] { box(NSRect(x: x, y: 10, width: 6, height: 6), BrandPalette.ink.withAlphaComponent(0.3)) }
        let selected = sites.filter(\.selected)
        for i in selected.indices {
            let x = 9 + CGFloat(i % 3) * 30.52, y = 22 + CGFloat(i / 3) * 19
            box(NSRect(x: x, y: y, width: 27.52, height: 16), BrandPalette.ink.withAlphaComponent(0.08), 5)
            if let icon = icons[selected[i].url] {
                icon.draw(in: NSRect(x: x + 9.76, y: y + 4, width: 8, height: 8), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        let nameY = 22 + CGFloat(max(1, (selected.count + 2) / 3)) * 19 + 3

        OrbitOnboardingFirstSpace.name.draw(at: NSPoint(x: 28, y: nameY), withAttributes: [.font: BrandFonts.ui(10, weight: .bold), .foregroundColor: BrandPalette.ink])
        for (i, width) in [74, 55, 64].enumerated() { box(NSRect(x: 9, y: nameY + 20 + CGFloat(i) * 11, width: CGFloat(width), height: 5), BrandPalette.ink.withAlphaComponent(0.14)) }
        let heading = BrandTextStyle.title.attributedString(uiText("Welcome home."), size: 15, opticalSize: 15, attributes: [.foregroundColor: BrandPalette.ink])
        let typesetter = CTTypesetterCreateWithAttributedString(heading)
        let font = BrandFonts.display(15, opticalSize: 15)
        let lineHeight: CGFloat = 17.733
        let baseline = (lineHeight - font.ascender + font.descender) / 2 + font.ascender
        var offset = 0, row = 0
        while offset < heading.length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, offset, 99.44))
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: count))
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.translateBy(x: 117.56, y: 16 + baseline + CGFloat(row) * lineHeight)
                context.scaleBy(x: 1, y: -1); context.textMatrix = .identity; context.textPosition = .zero
                CTLineDraw(line, context); context.restoreGState()
            }
            offset += count; row += 1
        }
        for (i, width) in [69.6, 85.5, 53.7].enumerated() { box(NSRect(x: 117.56, y: 16 + CGFloat(row) * lineHeight + 8 + CGFloat(i) * 11, width: width, height: 5), BrandPalette.ink.withAlphaComponent(0.14)) }
        NSGraphicsContext.restoreGraphicsState()
    }
}
