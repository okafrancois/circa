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
    let title = NSTextField(wrappingLabelWithString: "")
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
        counter.textColor = BrandPalette.ink3
        counter.frame = NSRect(x: 36, y: 68, width: 308, height: 16)
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
        let font = OrbitOnboardingFonts.title
        let capTop = hasBack ? M.titleCapTopWithBack : M.titleCapTop
        let titleFirstBaseline = Self.firstBaseline(of: title)
        title.frame.origin.y = capTop + font.capHeight - titleFirstBaseline
        let lines = max(1, Int((titleHeight / M.titleLineHeight).rounded()))
        let titleLastBaseline = capTop + font.capHeight + CGFloat(lines - 1) * M.titleLineHeight
        let bodyHeight = ceil(body.sizeThatFits(NSSize(width: width, height: 1000)).height)
        body.frame = NSRect(x: M.contentX, y: 0, width: width, height: bodyHeight)
        body.frame.origin.y = titleLastBaseline + M.titleToBodyBaseline - Self.firstBaseline(of: body)
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
    let textClip = NSView()
    let rightContent = NSView()
    let backButton = OrbitOnboardingLinkButton(title: OrbitOnboardingText.back, arrow: true, font: OrbitOnboardingFonts.back)
    let skipButton = OrbitOnboardingLinkButton(title: OrbitOnboardingText.skip, arrow: false, font: OrbitOnboardingFonts.skip)
    let primaryButton = OrbitOnboardingPrimaryButton()
    private(set) var page: OrbitOnboardingTextPage?
    private(set) var rightView: NSView?
    /// Number of step changes still animating (tests and capture tools wait for zero).
    private(set) var runningTransitions = 0
    private var dots: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: M.cardSize))
        wantsLayer = true
        layer?.cornerRadius = M.cardCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = OrbitOnboardingColors.rightPanel.cgColor
        rightContent.frame = NSRect(x: M.rightPanelX, y: 0, width: M.cardSize.width - M.rightPanelX, height: M.cardSize.height)
        rightContent.wantsLayer = true
        addSubview(rightContent)
        leftPanel.path = Self.leftPanelPath()
        leftPanel.fillColor = OrbitOnboardingColors.leftPanel.cgColor
        layer?.addSublayer(leftPanel)
        textClip.frame = NSRect(x: 0, y: 0, width: M.leftPanelWidth, height: M.cardSize.height)
        textClip.wantsLayer = true
        textClip.layer?.masksToBounds = true
        addSubview(textClip)
        for control in [backButton, skipButton, primaryButton] as [NSView] { addSubview(control) }
        backButton.frame.origin = NSPoint(x: M.contentX - 2, y: M.backCapTop - (backButton.frame.height - OrbitOnboardingFonts.back.capHeight) / 2)
        primaryButton.keyEquivalent = "\r"
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
        layer?.backgroundColor = (themed ? OrbitOnboardingColors.rightPanelThemed : OrbitOnboardingColors.rightPanel).cgColor
        CATransaction.commit()
        primaryButton.accent = OrbitOnboardingColors.accent
        backButton.accent = OrbitOnboardingColors.body
        skipButton.accent = OrbitOnboardingColors.body
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
        primaryButton.frame = NSRect(x: M.contentX, y: buttonY, width: M.buttonSize.width, height: M.buttonSize.height)
        skipButton.isHidden = !hasSkip
        skipButton.frame.origin = NSPoint(x: M.contentX + (M.contentWidth - skipButton.frame.width) / 2,
                                          y: primaryButton.frame.maxY + M.skipBaselineBelowButton
                                            - (skipButton.frame.height + OrbitOnboardingFonts.skip.capHeight) / 2)
        let wasShown = !backButton.isHidden && backButton.alphaValue > 0
        backButton.isHidden = false
        if hasBack != wasShown {
            if animated, !OrbitMotionPreferences.prefersReducedMotion, let layer = backButton.layer {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = hasBack ? 0 : 1
                fade.toValue = hasBack ? 1 : 0
                fade.duration = M.crossFadeDuration
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(fade, forKey: Self.fadeKey)
            }
            backButton.alphaValue = hasBack ? 1 : 0
        }
        backButton.isEnabled = hasBack
        backButton.setAccessibilityElement(hasBack)
    }

    func show(page newPage: OrbitOnboardingTextPage, right newRight: NSView?, direction: OrbitOnboardingDirection,
              animated: Bool, completion: (() -> Void)? = nil) {
        let oldPage = page, oldRight = rightView
        page = newPage; rightView = newRight
        newPage.frame.origin = .zero
        textClip.addSubview(newPage)
        for control in [backButton, skipButton, primaryButton] as [NSView] { newPage.addSubview(control) }
        if let newRight { rightContent.addSubview(newRight) }
        guard animated, oldPage != nil else {
            oldPage?.removeFromSuperview(); oldRight?.removeFromSuperview(); completion?(); return
        }
        runningTransitions += 1
        let dir: CGFloat = direction == .forward ? 1 : -1
        for (index, pair) in [(oldPage as NSView?, newPage as NSView?), (oldRight, newRight)].enumerated() {
            let (old, new) = pair
            let offset = Double(index) * 0.05
            OrbitOnboardingMotion.animate(old?.layer, key: "transform.translation.x", from: 0, to: -22 * dir, duration: 0.32, delay: Double(index) * 0.04, outgoing: true)
            OrbitOnboardingMotion.animate(old?.layer, key: "opacity", from: 1, to: 0, duration: 0.32, delay: Double(index) * 0.04, outgoing: true)
            OrbitOnboardingMotion.animate(new?.layer, key: "transform.translation.x", from: 36 * dir, to: 0, duration: 0.8, delay: 0.22 + offset)
            OrbitOnboardingMotion.animate(new?.layer, key: "opacity", from: 0, to: 1, duration: 0.8, delay: 0.22 + offset)
            let children = index == 0 ? [backButton, newPage.counter, newPage.title, newPage.body, newPage.note, primaryButton, skipButton] : new?.subviews ?? []
            for (i, child) in children.enumerated() {
                child.wantsLayer = true
                OrbitOnboardingMotion.entrance(child, y: 10, duration: 0.7, delay: 0.3 + offset + Double(i)*0.05)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (OrbitMotionPreferences.prefersReducedMotion ? 0.25 : 1.3)) { [weak self] in
            oldPage?.removeFromSuperview(); oldRight?.removeFromSuperview()
            self?.runningTransitions -= 1
            completion?()
        }
    }
}

extension OrbitOnboardingCardView {
    func updateDots(index: Int, skipped: [Int]) {
        let animated = !dots.isEmpty && !OrbitMotionPreferences.prefersReducedMotion
        if dots.isEmpty {
            dots = (0..<7).map { _ in
                let dot = CALayer(); dot.name = "orbit.onboarding.dot"; dot.cornerRadius = 3
                layer?.addSublayer(dot); return dot
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.4)
        CATransaction.setAnimationTimingFunction(OrbitOnboardingMotion.curve)
        var x: CGFloat = 36
        for (i, dot) in dots.enumerated() {
            let width: CGFloat = i == index ? 18 : 6
            dot.frame = CGRect(x: x, y: 532, width: width, height: 6)
            dot.backgroundColor = (i == index ? OrbitOnboardingColors.accent : i < index ? OrbitOnboardingColors.title : BrandPalette.inactiveDot).cgColor
            dot.opacity = skipped.contains(i) ? 0.35 : 1
            x += width + 6
        }
        CATransaction.commit()
    }
}
