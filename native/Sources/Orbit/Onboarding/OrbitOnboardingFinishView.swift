import AppKit
import BrowserShell
import BrowserCore

@MainActor
final class OrbitOnboardingFinishView: NSView {
    let mark = OrbitOnboardingMarkView(frame: NSRect(x: 552, y: 135, width: 96, height: 71))
    let title = OrbitOnboardingMomentTitle(labelWithString: OrbitOnboardingText.finishTitle)
    let body = NSTextField(wrappingLabelWithString: OrbitOnboardingText.finishBody)
    let button = OrbitOnboardingPrimaryButton()
    let back = OrbitOnboardingLinkButton(title: OrbitOnboardingText.back, arrow: false, font: OrbitOnboardingFonts.back)
    let sticker = OrbitOnboardingSticker(text: "", color: BrandPalette.mint)
    let summary = NSStackView()
    var onOpen: (() -> Void)?
    let illustration = OrbitOnboardingHorizonArt(frame: .zero)
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        illustration.frame = NSRect(x: 0, y: 398.21, width: 1200, height: 315.79)
        title.attributedStringValue = BrandTextStyle.title.attributedString(OrbitOnboardingText.finishTitle, size: 78.95, opticalSize: 50, attributes: [.foregroundColor: BrandPalette.ink])
        title.maximumNumberOfLines = 2
        title.alignment = .left; title.frame = NSRect(x: 54, y: 96, width: 726.32, height: 150)
        body.font = OrbitOnboardingFonts.ui(22.11); body.textColor = BrandPalette.ink.withAlphaComponent(0.82)
        body.alignment = .left
        body.preferredMaxLayoutWidth = 486.32
        body.maximumNumberOfLines = 0
        button.title = OrbitOnboardingText.getStarted; button.accent = BrandPalette.coral
        back.isUnderlined = true; back.isEnabled = false; back.alphaValue = 1
        back.accent = BrandPalette.ink
        layoutCopy()
        button.keyEquivalent = "\r"; button.onPress = { [weak self] in self?.onOpen?() }
        for v in [illustration, title, body, button, back] { v.wantsLayer = true; addSubview(v) }
        mark.isHidden = true; sticker.isHidden = true; summary.isHidden = true
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func update(flow: OrbitOnboardingFlow) {
        body.stringValue = flow.importSummary == nil ? OrbitOnboardingText.finishBody : OrbitOnboardingText.finishImportBody
        layoutCopy()
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
            label.font = OrbitOnboardingFonts.mono(12); label.textColor = BrandPalette.ink
            // A little slack keeps the last monospaced glyph from clipping.
            let width = ceil(label.intrinsicContentSize.width) + 4 + 44
            let view = OrbitOnboardingFlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 34))
            view.wantsLayer = true; view.layer?.cornerRadius = 17
            view.layer?.backgroundColor = BrandPalette.pageWhite.cgColor
            view.layer?.borderColor = BrandPalette.ink.cgColor; view.layer?.borderWidth = 1
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
    private func layoutCopy() {
        let titleHeight = ceil(title.sizeThatFits(NSSize(width: title.frame.width, height: 1000)).height)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 32.05; style.maximumLineHeight = 32.05
        body.attributedStringValue = NSAttributedString(string: body.stringValue, attributes: [.font: OrbitOnboardingFonts.ui(22.11), .foregroundColor: BrandPalette.ink.withAlphaComponent(0.82), .paragraphStyle: style])
        let bodyHeight = ceil(body.sizeThatFits(NSSize(width: 490.32, height: 1000)).height)
        body.frame = NSRect(x: 52, y: title.frame.minY + titleHeight + 15.79, width: 490.32, height: bodyHeight)
        button.frame = NSRect(origin: NSPoint(x: 54, y: body.frame.maxY + 34.74), size: button.intrinsicContentSize)
        back.frame.origin = NSPoint(x: button.frame.maxX + 22.11, y: button.frame.minY + 32 - back.frame.height / 2)
    }
    func play() {
        title.play(delay: 0.38, stagger: 0.07)
        OrbitOnboardingMotion.entrance(body, y: 31.58, duration: 0.5, delay: 0.45)
        for view in [button, back] as [NSView] { OrbitOnboardingMotion.entrance(view, y: 31.58, duration: 0.5, delay: 0.52) }
        illustration.play()
    }
}
