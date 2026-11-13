import AppKit
import BrowserShell
import QuartzCore

private typealias M = OrbitOnboardingMetrics

/// Direction of a step change: forward pushes the left panel text to the left.
enum OrbitOnboardingDirection: Equatable { case forward, backward }

/// Title and body of one step, laid out from the measured baselines. The only content that moves
/// during a step change.
@MainActor
final class OrbitOnboardingTextPage: NSView {
    let title = OrbitOnboardingMomentTitle(wrappingLabelWithString: "")
    let note = NSTextField(wrappingLabelWithString: "")
    let counter = NSTextField(labelWithString: "")
    let body = NSTextField(wrappingLabelWithString: "")

    init(title titleText: String, body bodyText: String, note: String?, hasBack: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: M.leftPanelWidth, height: M.cardSize.height))
        wantsLayer = true
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.minimumLineHeight = M.titleLineHeight
        titleStyle.maximumLineHeight = M.titleLineHeight
        titleStyle.lineBreakMode = .byWordWrapping
        title.attributedStringValue = NSAttributedString(string: titleText, attributes: [
            .font: OrbitOnboardingFonts.title, .kern: BrandTextStyle.title.tracking(size: OrbitOnboardingFonts.title.pointSize), .foregroundColor: OrbitOnboardingColors.title, .paragraphStyle: titleStyle
        ])
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.minimumLineHeight = M.bodyLineHeight
        bodyStyle.maximumLineHeight = M.bodyLineHeight
        bodyStyle.paragraphSpacing = M.bodyLineHeight
        let text = NSMutableAttributedString(string: bodyText, attributes: [
            .font: OrbitOnboardingFonts.body, .foregroundColor: OrbitOnboardingColors.body, .paragraphStyle: bodyStyle
        ])
        self.note.stringValue = note ?? ""
        self.note.isHidden = note == nil
        self.note.font = OrbitOnboardingFonts.mono(12)
        self.note.textColor = BrandPalette.ink3
        addSubview(self.note)
        body.attributedStringValue = text
        for field in [title, body] {
            field.isSelectable = false
            field.drawsBackground = false
            field.preferredMaxLayoutWidth = M.contentWidth
            addSubview(field)
        }
        counter.font = OrbitOnboardingFonts.mono(11)
        counter.textColor = BrandPalette.cobalt
        counter.frame = NSRect(x: 1030, y: 26, width: 150, height: 16)
        counter.isHidden = true
        addSubview(counter)
        setAccessibilityElement(false)
        layoutText(hasBack: hasBack)
        self.note.frame = NSRect(x: M.contentX, y: body.frame.maxY + 10, width: M.contentWidth,
                                 height: ceil(self.note.sizeThatFits(NSSize(width: M.contentWidth, height: 200)).height))
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    /// Places the first title baseline at its measured cap top, then the body's first baseline
    /// `titleToBodyBaseline` below the title's last one.
    private func layoutText(hasBack: Bool) {
        let width = M.contentWidth
        let titleHeight = ceil(title.sizeThatFits(NSSize(width: width, height: 1000)).height)
        title.frame = NSRect(x: M.contentX, y: 0, width: width, height: titleHeight)
        title.frame.origin.y = M.titleCapTop
        let bodyHeight = body.stringValue.isEmpty ? 0 : ceil(body.sizeThatFits(NSSize(width: 490.32, height: 1000)).height)
        body.frame = NSRect(x: M.contentX - 2, y: title.frame.maxY + 15.79, width: 490.32, height: bodyHeight)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    static func firstBaseline(of field: NSTextField) -> CGFloat {
        field.layoutSubtreeIfNeeded()
        return field.firstBaselineOffsetFromTop
    }
}

/// The 967 × 548 card: tinted right panel, white left panel with a perforated edge, the pushed
/// text, and the left panel's fixed controls (Back, primary button, Skip).
@MainActor
final class OrbitOnboardingCardView: NSView {
    static let pushKey = "orbit.onboarding.push"
    static let fadeKey = "orbit.onboarding.fade"
    let leftPanel = CAShapeLayer()
    let textClip = OrbitOnboardingPassthroughView()
    let rightContent = NSView()
    let backButton = OrbitOnboardingLinkButton(title: OrbitOnboardingText.back, arrow: false, font: OrbitOnboardingFonts.back)
    let skipButton = OrbitOnboardingLinkButton(title: OrbitOnboardingText.skip, arrow: false, font: OrbitOnboardingFonts.skip)
    let primaryButton = OrbitOnboardingPrimaryButton()
    private(set) var page: OrbitOnboardingTextPage?
    private(set) var rightView: NSView?
    /// Number of step changes still animating (tests and capture tools wait for zero).
    private(set) var runningTransitions = 0
    private var dots: [CALayer] = []
    private weak var fixedCounter: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: M.cardSize))
        wantsLayer = true
        layer?.borderWidth = 0
        layer?.borderColor = BrandPalette.ink.cgColor
        layer?.cornerRadius = M.cardCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        rightContent.frame = NSRect(x: M.rightPanelX, y: 0, width: M.cardSize.width - M.rightPanelX, height: M.cardSize.height)
        rightContent.wantsLayer = true
        addSubview(rightContent)
        leftPanel.path = Self.leftPanelPath()
        leftPanel.fillColor = NSColor.clear.cgColor
        layer?.addSublayer(leftPanel)
        textClip.frame = NSRect(x: 0, y: 0, width: M.leftPanelWidth, height: M.cardSize.height)
        textClip.wantsLayer = true
        textClip.layer?.masksToBounds = true
        addSubview(textClip)
        for control in [backButton, skipButton, primaryButton] as [NSView] { addSubview(control) }
        backButton.frame.origin = NSPoint(x: M.contentX - 2, y: M.backCapTop - (backButton.frame.height - OrbitOnboardingFonts.back.capHeight) / 2)
        primaryButton.keyEquivalent = "\r"
        backButton.isUnderlined = false
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    /// White panel whose right edge is a row of 4.4 pt scallops (17.22 pt period).
    static func leftPanelPath() -> CGPath {
        CGPath(rect: CGRect(x: 0, y: 0, width: M.leftPanelWidth, height: M.cardSize.height), transform: nil)
    }

    func applyAccent(_ accent: NSColor, themed: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = NSColor.clear.cgColor
        CATransaction.commit()
        primaryButton.accent = BrandPalette.coral
        backButton.accent = BrandPalette.ink
        skipButton.accent = BrandPalette.ink
    }

    /// Fixed left-panel controls change at once (measured: before the push starts).
    func layoutControls(hasBack: Bool, hasSkip: Bool, animated: Bool) {
        if animated, let page {
            for control in [backButton, skipButton, primaryButton] as [NSView] where !control.isHidden && control.alphaValue > 0 {
                if let image = NSImage(data: control.dataWithPDF(inside: control.bounds)) {
                    let snapshot = NSImageView(frame: control.frame); snapshot.image = image
                    snapshot.imageScaling = .scaleAxesIndependently; snapshot.wantsLayer = true
                    page.addSubview(snapshot)
                }
            }
        }
        let buttonY = M.cardSize.height - M.buttonBottomInset - M.buttonSize.height - (hasSkip ? M.buttonRaiseForSkip : 0)
        primaryButton.frame = NSRect(x: M.contentX, y: buttonY, width: primaryButton.intrinsicContentSize.width, height: primaryButton.intrinsicContentSize.height)
        skipButton.isHidden = !hasSkip
        skipButton.frame.origin = NSPoint(x: primaryButton.frame.maxX + 22.11, y: primaryButton.frame.minY + 32 - skipButton.frame.height / 2)
        backButton.frame.origin = NSPoint(x: hasSkip ? skipButton.frame.maxX + 22.11 : primaryButton.frame.maxX + 22.11, y: primaryButton.frame.minY + 32 - backButton.frame.height / 2)
        let wasShown = !backButton.isHidden && backButton.alphaValue > 0
        backButton.isHidden = false
        if hasBack != wasShown {
            if animated, !OrbitMotionPreferences.prefersReducedMotion, let layer = backButton.layer {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = hasBack ? 0 : 0.6
                fade.toValue = hasBack ? 0.6 : 0
                fade.duration = M.crossFadeDuration
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(fade, forKey: Self.fadeKey)
            }
        }
        backButton.alphaValue = hasBack ? 0.6 : 0
        backButton.isEnabled = hasBack
        backButton.setAccessibilityElement(hasBack)
    }

    func show(page newPage: OrbitOnboardingTextPage, right newRight: NSView?, direction: OrbitOnboardingDirection,
              animated: Bool, completion: (() -> Void)? = nil) {
        let oldPage = page, oldRight = rightView
        page = newPage; rightView = newRight
        newPage.frame.origin = .zero
        textClip.addSubview(newPage)
        fixedCounter?.removeFromSuperview()
        newPage.counter.isHidden = true
        fixedCounter = newPage.counter
        for control in [backButton, skipButton, primaryButton] as [NSView] { newPage.addSubview(control) }
        if let newRight { rightContent.addSubview(newRight) }
        guard animated, oldPage != nil else {
            oldPage?.removeFromSuperview(); oldRight?.removeFromSuperview(); completion?(); return
        }
        runningTransitions += 1
        let dir: CGFloat = direction == .forward ? 1 : -1
        for pair in [(oldPage as NSView?, newPage as NSView?), (oldRight, newRight)] {
            let (old, new) = pair
            OrbitOnboardingMotion.animate(old?.layer, key: "transform.translation.x", from: 0, to: -79 * dir, duration: 0.3, delay: 0, outgoing: true)
            OrbitOnboardingMotion.animate(old?.layer, key: "opacity", from: 1, to: 0, duration: 0.3, delay: 0, outgoing: true)
            OrbitOnboardingMotion.animate(new?.layer, key: "transform.translation.x", from: 79 * dir, to: 0, duration: 0.5, delay: 0.28)
            OrbitOnboardingMotion.animate(new?.layer, key: "opacity", from: 0, to: 1, duration: 0.5, delay: 0.28)
        }
        playContents()

        DispatchQueue.main.asyncAfter(deadline: .now() + (OrbitMotionPreferences.prefersReducedMotion ? 0.25 : 1.3)) { [weak self] in
            oldPage?.removeFromSuperview(); oldRight?.removeFromSuperview()
            self?.runningTransitions -= 1
            completion?()
        }
    }
    var footerEntranceDelay: Double = 0.59
    func playContents() {
        guard let page else { return }
        for (view, delay) in [(page.title, 0.38), (page.body, 0.45), (page.note, 0.52)] {
            view.wantsLayer = true
            OrbitOnboardingMotion.entrance(view, y: 31.58, duration: 0.5, delay: delay)
        }
        for button in [primaryButton, skipButton, backButton] as [NSView] {
            OrbitOnboardingMotion.entrance(button, y: 31.58, duration: 0.5, delay: footerEntranceDelay)
        }
        var entries = rightView?.subviews ?? []
        for scroll in entries.compactMap({ $0 as? NSScrollView }) {
            entries.removeAll { $0 === scroll }
            entries.append(contentsOf: scroll.documentView?.subviews ?? [])
        }
        for view in entries where view.identifier?.rawValue != "orbit.onboarding.preview-heading" && !(view is OrbitOnboardingSpaceArt) && !(view is OrbitOnboardingIllustrationView) && !(view is OrbitOnboardingMiniPreview) {
            OrbitOnboardingMotion.entrance(view, y: 31.58, duration: 0.5, delay: view.identifier?.rawValue == "orbit.onboarding.secondary-copy" ? 0.52 : 0.45)
        }
    }

}

extension OrbitOnboardingCardView {
    func updateDots(index: Int, skipped: [Int]) {
        // Progress is shown by the persistent progress bar and step label.
        dots.forEach { $0.removeFromSuperlayer() }
        dots.removeAll()
    }
}

@MainActor
final class OrbitOnboardingPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
