import AppKit
import QuartzCore

private typealias M = OrbitOnboardingMetrics

/// Direction of a step change: forward pushes the left panel text to the left.
enum OrbitOnboardingDirection: Equatable { case forward, backward }

/// Title and body of one step, laid out from the measured baselines. The only content that moves
/// during a step change.
@MainActor
final class OrbitOnboardingTextPage: NSView {
    let title = NSTextField(wrappingLabelWithString: "")
    let body = NSTextField(wrappingLabelWithString: "")

    init(title titleText: String, body bodyText: String, note: String?, hasBack: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: M.leftPanelWidth, height: M.cardSize.height))
        wantsLayer = true
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.minimumLineHeight = M.titleLineHeight
        titleStyle.maximumLineHeight = M.titleLineHeight
        titleStyle.lineBreakMode = .byWordWrapping
        title.attributedStringValue = NSAttributedString(string: titleText, attributes: [
            .font: OrbitOnboardingFonts.title, .foregroundColor: OrbitOnboardingColors.title, .paragraphStyle: titleStyle
        ])
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.minimumLineHeight = M.bodyLineHeight
        bodyStyle.maximumLineHeight = M.bodyLineHeight
        bodyStyle.paragraphSpacing = M.bodyLineHeight
        let text = NSMutableAttributedString(string: bodyText, attributes: [
            .font: OrbitOnboardingFonts.body, .foregroundColor: OrbitOnboardingColors.body, .paragraphStyle: bodyStyle
        ])
        if let note {
            text.append(NSAttributedString(string: "\n" + note, attributes: [
                .font: OrbitOnboardingFonts.emphasis, .foregroundColor: OrbitOnboardingColors.body, .paragraphStyle: bodyStyle
            ]))
        }
        body.attributedStringValue = text
        for field in [title, body] {
            field.isSelectable = false
            field.drawsBackground = false
            field.preferredMaxLayoutWidth = M.contentWidth
            addSubview(field)
        }
        setAccessibilityElement(false)
        layoutText(hasBack: hasBack)
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
        let path = CGMutablePath()
        path.move(to: .zero)
        var y: CGFloat = 0
        while y <= M.cardSize.height {
            let x = M.perforationCenterX - M.perforationAmplitude * cos(2 * .pi * (y - M.perforationPhaseY) / M.perforationPeriod)
            if y == 0 { path.addLine(to: CGPoint(x: x, y: 0)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            y += 0.5
        }
        path.addLine(to: CGPoint(x: 0, y: M.cardSize.height))
        path.closeSubpath()
        return path
    }

    func applyAccent(_ accent: NSColor, themed: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = (themed ? OrbitOnboardingColors.rightPanelThemed : OrbitOnboardingColors.rightPanel).cgColor
        CATransaction.commit()
        primaryButton.accent = accent
        backButton.accent = accent
        skipButton.accent = accent
    }

    /// Fixed left-panel controls change at once (measured: before the push starts).
    func layoutControls(hasBack: Bool, hasSkip: Bool, animated: Bool) {
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

    /// Replaces the text page and the right panel. Animated: the text pushes 403 pt with the
    /// measured spring, the right panel cross-fades (0.35 s ease-in-out from the push's start).
    /// Both pages keep their final frame inside the panel (AppKit only draws views it can show);
    /// each layer is translated by the same spring, so the two stay 403 pt apart.
    func show(page newPage: OrbitOnboardingTextPage, right newRight: NSView?, direction: OrbitOnboardingDirection,
              animated: Bool, completion: (() -> Void)? = nil) {
        let oldPage = page, oldRight = rightView
        page = newPage
        rightView = newRight
        let animates = animated && oldPage != nil && !OrbitMotionPreferences.prefersReducedMotion
        let offset = direction == .forward ? M.pushDistance : -M.pushDistance
        newPage.frame.origin = .zero
        textClip.addSubview(newPage)
        if let newRight { rightContent.addSubview(newRight) }
        textClip.layoutSubtreeIfNeeded()
        guard animates, let oldLayer = oldPage?.layer, let newLayer = newPage.layer else {
            oldPage?.removeFromSuperview()
            oldRight?.removeFromSuperview()
            completion?()
            return
        }
        runningTransitions += 1
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                oldPage?.removeFromSuperview()
                oldRight?.removeFromSuperview()
                newLayer.removeAnimation(forKey: Self.pushKey)
                self.runningTransitions -= 1
                completion?()
            }
        }
        for (layer, from, to) in [(oldLayer, CGFloat(0), -offset), (newLayer, offset, CGFloat(0))] {
            let push = M.push.animation(keyPath: "transform.translation.x")
            push.fromValue = from
            push.toValue = to
            push.isRemovedOnCompletion = false
            push.fillMode = .both
            layer.add(push, forKey: Self.pushKey)
        }
        if let layer = oldRight?.layer { Self.fade(layer, from: 1, to: 0) }
        if let layer = newRight?.layer { Self.fade(layer, from: 0, to: 1) }
        CATransaction.commit()
    }

    private static func fade(_ layer: CALayer, from: Float, to: Float) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = M.crossFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = to
        layer.add(fade, forKey: fadeKey)
    }
}

/// The welcome screen: two-line headline and the small arrow button, centred in the window.
/// The intro that precedes it belongs to `OrbitOnboardingWindowController.intro`.
@MainActor
final class OrbitOnboardingWelcomeView: NSView {
    let headline = NSTextField(wrappingLabelWithString: "")
    let button = NSButton()
    var onContinue: (() -> Void)?
    static let headlineWrapWidth: CGFloat = 470

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.minimumLineHeight = M.welcomeLineHeight
        style.maximumLineHeight = M.welcomeLineHeight
        headline.attributedStringValue = NSAttributedString(string: OrbitOnboardingText.welcomeHeadline, attributes: [
            .font: OrbitOnboardingFonts.welcome, .foregroundColor: OrbitOnboardingColors.welcomeTitle, .paragraphStyle: style
        ])
        headline.isSelectable = false
        headline.drawsBackground = false
        headline.preferredMaxLayoutWidth = Self.headlineWrapWidth
        addSubview(headline)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.title = ""
        button.wantsLayer = true
        button.layer?.backgroundColor = OrbitOnboardingColors.welcomeButton.cgColor
        button.layer?.cornerRadius = M.buttonCornerRadius
        button.layer?.cornerCurve = .continuous
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(.init(paletteColors: [OrbitOnboardingColors.welcomeArrow]))
        button.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        button.imagePosition = .imageOnly
        button.keyEquivalent = "\r"
        button.target = self
        button.action = #selector(press)
        button.setAccessibilityLabel(OrbitOnboardingText.getStarted)
        button.focusRingType = .none
        addSubview(button)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    /// Headline cap top to button bottom is one centred group (measured 64.7 pt line pitch, the
    /// button 38.5 pt below the last baseline).
    override func layout() {
        super.layout()
        let font = OrbitOnboardingFonts.welcome
        let size = headline.sizeThatFits(NSSize(width: Self.headlineWrapWidth, height: 1000))
        let lines = max(1, Int((size.height / M.welcomeLineHeight).rounded()))
        let group = font.capHeight + CGFloat(lines - 1) * M.welcomeLineHeight + 38.5 + M.welcomeButtonSize.height
        // Measured: the group sits 4.4 pt below the window's centre.
        let capTop = (bounds.height - group) / 2 + 4.4
        headline.frame = NSRect(x: (bounds.width - Self.headlineWrapWidth) / 2, y: 0, width: Self.headlineWrapWidth, height: ceil(size.height))
        headline.layoutSubtreeIfNeeded()
        headline.frame.origin.y = capTop + font.capHeight - headline.firstBaselineOffsetFromTop
        let lastBaseline = capTop + font.capHeight + CGFloat(lines - 1) * M.welcomeLineHeight
        button.frame = NSRect(x: (bounds.width - M.welcomeButtonSize.width) / 2, y: lastBaseline + 38.5,
                              width: M.welcomeButtonSize.width, height: M.welcomeButtonSize.height)
    }

    @objc private func press() { onContinue?() }
}
