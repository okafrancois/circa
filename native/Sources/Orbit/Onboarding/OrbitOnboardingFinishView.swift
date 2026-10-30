import AppKit
import BrowserShell
import BrowserCore

@MainActor
final class OrbitOnboardingFinishView: NSView {
    let mark = OrbitOnboardingMarkView(frame: NSRect(x: 552, y: 135, width: 96, height: 71))
    let title = OrbitOnboardingMomentTitle(labelWithString: OrbitOnboardingText.finishTitle)
    let body = NSTextField(labelWithString: OrbitOnboardingText.finishBody)
    let button = OrbitOnboardingPrimaryButton()
    let sticker = OrbitOnboardingSticker(text: "", color: BrandPalette.mint)
    let summary = NSStackView()
    var onOpen: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = OrbitOnboardingFonts.title(72); title.textColor = OrbitOnboardingColors.welcomeTitle
        title.alignment = .center; title.frame = NSRect(x: 70, y: 201, width: 1060, height: 90)
        body.font = OrbitOnboardingFonts.ui(15); body.textColor = BrandPalette.stageMuted
        body.alignment = .center; body.frame = NSRect(x: 200, y: 309, width: 800, height: 32)
        button.title = OrbitOnboardingText.getStarted; button.accent = OrbitOnboardingColors.accent
        button.frame = NSRect(x: 520, y: 367, width: 160, height: 48)
        button.keyEquivalent = "\r"; button.onPress = { [weak self] in self?.onOpen?() }
        summary.orientation = .horizontal; summary.spacing = 8; summary.alignment = .centerY
        summary.frame = NSRect(x: 150, y: 441, width: 900, height: 34)
        sticker.frame = NSRect(x: 830, y: 110, width: 290, height: 38)
        for v in [mark, title, body, button, summary, sticker] { v.wantsLayer = true; addSubview(v) }
        sticker.frameRotation = 7
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func update(flow: OrbitOnboardingFlow) {
        body.stringValue = flow.importSummary == nil ? OrbitOnboardingText.finishBody : OrbitOnboardingText.finishImportBody
        sticker.stringValue = OrbitOnboardingText.sticker(duration: flow.importDuration, sync: flow.syncChoice == true)
        summary.arrangedSubviews.forEach { summary.removeArrangedSubview($0); $0.removeFromSuperview() }
        var chips: [String] = []
        if let imported = flow.importSummary {
            chips += [uiFormat("%d Spaces", imported.spaces), uiFormat("%d pinned tabs", imported.pinnedTabs), uiFormat("%d passwords", imported.passwords)]
        }
        if !flow.favouritesSkipped, !flow.skippedSteps.contains(.favourites), !flow.selectedFavourites.isEmpty {
            chips.append(uiFormat("%d favourites", flow.selectedFavourites.count))
        }
        if flow.syncChoice == true { chips.append(uiText("iCloud")) }
        if flow.defaultBrowserChoice == true { chips.append(uiText("Default browser")) }
        let colors = [BrandPalette.coral, BrandPalette.cobalt, BrandPalette.mint, BrandPalette.sun, BrandPalette.violet, BrandPalette.mint]
        for (index, chip) in chips.enumerated() {
            let label = NSTextField(labelWithString: chip)
            label.font = OrbitOnboardingFonts.mono(12); label.textColor = .white
            // A little slack keeps the last monospaced glyph from clipping.
            let width = ceil(label.intrinsicContentSize.width) + 4 + 44
            let view = OrbitOnboardingFlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 34))
            view.wantsLayer = true; view.layer?.cornerRadius = 17
            view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            view.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor; view.layer?.borderWidth = 1
            let dot = CALayer(); dot.frame = CGRect(x: 14, y: 13, width: 8, height: 8)
            dot.cornerRadius = 4; dot.backgroundColor = colors[index % colors.count].cgColor
            view.layer?.addSublayer(dot)
            label.frame = NSRect(x: 30, y: 9, width: width - 44, height: 18); view.addSubview(label)
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
            view.heightAnchor.constraint(equalToConstant: 34).isActive = true
            summary.addArrangedSubview(view)
        }
        let width = summary.fittingSize.width
        summary.frame = NSRect(x: (bounds.width - width) / 2, y: 441, width: width, height: 34)
    }
    func play() {
        mark.land(delay: 0, drawBands: false)
        title.play(delay: 0.3, stagger: 0.07)
        OrbitOnboardingMotion.entrance(body, delay: 0.7)
        OrbitOnboardingMotion.entrance(button, delay: 0.8)
        for (i, chip) in summary.arrangedSubviews.enumerated() {
            OrbitOnboardingMotion.entrance(chip, y: 14, duration: 0.7, delay: 1 + Double(i)*0.07)
        }
        OrbitOnboardingMotion.animate(sticker.layer, key: "opacity", from: 0, to: 1, duration: 0.7, delay: 1.4)
        OrbitOnboardingMotion.animate(sticker.layer, key: "transform.rotation.z", from: -.pi * 27 / 180, to: 0, duration: 0.7, delay: 1.4, stick: true)
        OrbitOnboardingMotion.animate(sticker.layer, key: "transform.scale", from: 0, to: 1, duration: 0.7, delay: 1.4, stick: true)
    }
}
