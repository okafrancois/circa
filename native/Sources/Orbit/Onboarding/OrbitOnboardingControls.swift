import AppKit
import QuartzCore
import BrowserShell

private typealias M = OrbitOnboardingMetrics

/// The card's primary button: accent fill, white label; disabled keeps the fill and dims the label.
@MainActor
final class OrbitOnboardingPrimaryButton: NSButton {
    var accent: NSColor = OrbitOnboardingColors.accent { didSet { refresh() } }
    var labelColor: NSColor = .white { didSet { refresh() } }
    var onPress: (() -> Void)?

    init() {
        super.init(frame: NSRect(origin: .zero, size: M.buttonSize))
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = M.buttonCornerRadius
        layer?.cornerCurve = .continuous
        target = self
        action = #selector(press)
        focusRingType = .exterior
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override var title: String { didSet { refresh() } }
    override var isEnabled: Bool { didSet { refresh() } }
    override var wantsUpdateLayer: Bool { true }

    func refresh() {
        layer?.backgroundColor = accent.cgColor
        let alpha = isEnabled ? 1 : M.disabledLabelAlpha
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [labelColor])))
        imagePosition = .imageTrailing; imageHugsTitle = true
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: OrbitOnboardingFonts.button, .foregroundColor: labelColor.withAlphaComponent(alpha), .paragraphStyle: paragraph
        ])
    }

    @objc private func press() { onPress?() }
}

/// "← Back" and "Skip for now": borderless accent text.
@MainActor
final class OrbitOnboardingLinkButton: NSButton {
    var accent: NSColor = OrbitOnboardingColors.accent { didSet { refresh() } }
    var onPress: (() -> Void)?
    private let showsArrow: Bool
    private let titleFont: NSFont

    init(title: String, arrow: Bool, font: NSFont) {
        showsArrow = arrow
        titleFont = font
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        self.title = title
        target = self
        action = #selector(press)
        focusRingType = .exterior
        imagePosition = .imageLeading
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        attributedTitle = NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: accent])
        if showsArrow {
            let configuration = NSImage.SymbolConfiguration(pointSize: titleFont.pointSize - 1, weight: .medium)
                .applying(.init(paletteColors: [accent]))
            image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            imageHugsTitle = true
        }
        sizeToFit()
    }

    @objc private func press() { onPress?() }
}

/// A selectable card of the right panel: radio choice rows and browser rows share selection,
/// hover scale (×1.05), keyboard and VoiceOver behaviour.
@MainActor
class OrbitOnboardingOptionCard: NSView {
    var isSelected = false { didSet { refresh() } }
    var isEnabled = true { didSet { refresh() } }
    var accent: NSColor = OrbitOnboardingColors.accent { didSet { refresh() } }
    var onSelect: (() -> Void)?
    let surface = CALayer()
    let radio = CAShapeLayer()
    let dot = CAShapeLayer()
    private var tracking: NSTrackingArea?
    private(set) var isHovered = false

    init(size: NSSize, radius: CGFloat) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.masksToBounds = false
        surface.frame = bounds
        surface.cornerRadius = radius
        surface.cornerCurve = .continuous
        surface.backgroundColor = OrbitOnboardingColors.optionSurface.cgColor
        surface.shadowColor = NSColor.black.cgColor
        surface.shadowOpacity = 1
        surface.shadowRadius = 6
        surface.shadowOffset = CGSize(width: 0, height: -2)
        surface.masksToBounds = false
        layer?.addSublayer(surface)
        radio.fillColor = nil
        dot.fillColor = nil
        layer?.addSublayer(radio)
        layer?.addSublayer(dot)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }

    func placeRadio(centerX: CGFloat) {
        let d = M.radioDiameter
        let frame = NSRect(x: centerX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        radio.frame = frame
        radio.path = CGPath(ellipseIn: CGRect(origin: .zero, size: frame.size).insetBy(dx: M.radioRing / 2, dy: M.radioRing / 2), transform: nil)
        let inset = (d - M.radioDotDiameter) / 2
        dot.frame = frame
        dot.path = CGPath(ellipseIn: CGRect(origin: .zero, size: frame.size).insetBy(dx: inset, dy: inset), transform: nil)
    }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.borderWidth = isSelected ? M.selectedBorder : 1
        surface.borderColor = (isSelected ? accent : OrbitOnboardingColors.optionBorder).cgColor
        surface.shadowColor = OrbitOnboardingColors.optionShadow.cgColor
        radio.strokeColor = (isSelected ? accent : OrbitOnboardingColors.radioRing).cgColor
        radio.lineWidth = isSelected ? M.radioSelectedRing : M.radioRing
        dot.fillColor = isSelected ? accent.cgColor : nil
        alphaValue = isEnabled ? 1 : 0.45
        applyHoverScale()
        CATransaction.commit()
        setAccessibilityValue(isSelected ? 1 : 0)
        setAccessibilityEnabled(isEnabled)
    }

    /// Scales about the card's centre while the pointer is over it (measured 1.04–1.05).
    private func applyHoverScale() {
        guard let layer else { return }
        let scale = isHovered && isEnabled ? M.hoverScale : 1
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
        layer.sublayerTransform = transform
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; refresh() }
    override func mouseExited(with event: NSEvent) { isHovered = false; refresh() }

    func setHovered(_ hovered: Bool) { isHovered = hovered; refresh() }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSelect?()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", isEnabled { onSelect?() } else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onSelect?()
        return true
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: surface.cornerRadius, yRadius: surface.cornerRadius).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// "YES, …" / "NO, …" card: strong first word, regular remainder.
@MainActor
final class OrbitOnboardingChoiceCard: OrbitOnboardingOptionCard {
    let label = NSTextField(labelWithString: "")
    private let strong: String
    private let detail: String

    init(strong: String, detail: String) {
        self.strong = strong
        self.detail = detail
        super.init(size: M.choiceCardSize, radius: M.choiceCardRadius)
        placeRadio(centerX: M.choiceRadioCenterX)
        label.frame = NSRect(x: M.choiceLabelX, y: 0, width: bounds.width - M.choiceLabelX - 16, height: bounds.height)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        addSubview(label)
        setAccessibilityLabel(strong + " " + detail)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func refresh() {
        super.refresh()
        let color = isSelected ? accent : OrbitOnboardingColors.optionText
        let text = NSMutableAttributedString(string: strong, attributes: [.font: OrbitOnboardingFonts.choiceStrong, .foregroundColor: color])
        text.append(NSAttributedString(string: " " + detail, attributes: [.font: OrbitOnboardingFonts.choice, .foregroundColor: color]))
        label.attributedStringValue = text
        let height = ceil(text.size().height)
        label.frame = NSRect(x: M.choiceLabelX, y: (bounds.height - height) / 2, width: bounds.width - M.choiceLabelX - 16, height: height)
    }
}

/// A browser row of the import step: radio, name, and the browser's icon on a tinted tile.
@MainActor
final class OrbitOnboardingBrowserRow: OrbitOnboardingOptionCard {
    let label = NSTextField(labelWithString: "")
    let tile = CALayer()
    let icon = CALayer()

    init(title: String, icon image: NSImage?, tint: NSColor, multiline: Bool = false) {
        super.init(size: M.browserRowSize, radius: M.browserRowRadius)
        placeRadio(centerX: M.browserRadioCenterX)
        surface.masksToBounds = false
        let clip = CALayer()
        clip.frame = bounds
        clip.cornerRadius = M.browserRowRadius
        clip.cornerCurve = .continuous
        clip.masksToBounds = true
        layer?.insertSublayer(clip, above: surface)
        if let image {
            tile.frame = NSRect(x: bounds.width - M.browserTileWidth, y: 0, width: M.browserTileWidth, height: bounds.height)
            tile.backgroundColor = tint.cgColor
            clip.addSublayer(tile)
            let side = M.browserIconSize
            icon.frame = NSRect(x: tile.frame.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            icon.contents = image.layerContents(forContentsScale: NSScreen.main?.backingScaleFactor ?? 2)
            icon.contentsGravity = .resizeAspect
            clip.addSublayer(icon)
        }
        label.stringValue = title
        label.font = OrbitOnboardingFonts.browser
        if let newline = title.firstIndex(of: "\n") {
            let attributed = NSMutableAttributedString(string: title, attributes: [.font: OrbitOnboardingFonts.browser, .foregroundColor: OrbitOnboardingColors.browserLabel])
            attributed.addAttributes([.font: OrbitOnboardingFonts.mono(11), .foregroundColor: BrandPalette.ink3], range: NSRange(title.index(after: newline)..<title.endIndex, in: title))
            label.attributedStringValue = attributed
        }
        label.textColor = OrbitOnboardingColors.browserLabel
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        let width = bounds.width - M.browserLabelX - (image == nil ? 20 : M.browserTileWidth + 12)
        let height = ceil(label.sizeThatFits(NSSize(width: width, height: 100)).height)
        label.frame = NSRect(x: M.browserLabelX, y: (bounds.height - height) / 2, width: width, height: height)
        addSubview(label)
        setAccessibilityLabel(title)
        refresh()
    }

    required init?(coder: NSCoder) { nil }
}

/// Profiles of the selected browser: one is imported (each import creates one Orbit profile).
@MainActor
final class OrbitOnboardingProfileList: NSView {
    var accent: NSColor = OrbitOnboardingColors.accent { didSet { refresh() } }
    var selectedProfiles: Set<String> = [] { didSet { refresh() } }
    var onSelect: ((String) -> Void)?
    private(set) var rows: [OrbitOnboardingProfileRow] = []

    init(profiles: [OrbitOnboardingSource.Profile], width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(profiles.count) * M.profileRowHeight))
        wantsLayer = true
        layer?.backgroundColor = OrbitOnboardingColors.optionSurface.cgColor
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        for (index, profile) in profiles.enumerated() {
            let row = OrbitOnboardingProfileRow(profile: profile, width: width, separator: index > 0)
            row.frame.origin.y = CGFloat(index) * M.profileRowHeight
            row.onSelect = { [weak self] in self?.onSelect?(profile.directory) }
            addSubview(row)
            rows.append(row)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(OrbitOnboardingText.profileListLabel)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func refresh() {
        for row in rows {
            row.accent = accent
            row.isSelected = selectedProfiles.contains(row.profile.directory)
        }
    }
}

@MainActor
final class OrbitOnboardingProfileRow: NSView {
    let profile: OrbitOnboardingSource.Profile
    var accent: NSColor = OrbitOnboardingColors.accent { didSet { refresh() } }
    var isSelected = false { didSet { refresh() } }
    var onSelect: (() -> Void)?
    private let check = CAShapeLayer()
    private let mark = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")

    init(profile: OrbitOnboardingSource.Profile, width: CGFloat, separator: Bool) {
        self.profile = profile
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: M.profileRowHeight))
        wantsLayer = true
        if separator {
            let line = CALayer()
            line.frame = CGRect(x: 0, y: 0, width: width, height: 1)
            line.backgroundColor = OrbitOnboardingColors.optionBorder.cgColor
            layer?.addSublayer(line)
        }
        let d = M.checkDiameter
        let circle = CGRect(x: 20, y: (bounds.height - d) / 2, width: d, height: d)
        check.frame = circle
        check.path = CGPath(ellipseIn: CGRect(origin: .zero, size: circle.size).insetBy(dx: 0.55, dy: 0.55), transform: nil)
        check.lineWidth = 1.1
        layer?.addSublayer(check)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: d * 0.28, y: d * 0.52))
        path.addLine(to: CGPoint(x: d * 0.44, y: d * 0.68))
        path.addLine(to: CGPoint(x: d * 0.72, y: d * 0.34))
        mark.frame = circle
        mark.path = path
        mark.fillColor = nil
        mark.strokeColor = NSColor.white.cgColor
        mark.lineWidth = 1.8
        mark.lineCap = .round
        mark.lineJoin = .round
        layer?.addSublayer(mark)
        label.stringValue = profile.name
        label.font = OrbitOnboardingFonts.profile
        label.textColor = OrbitOnboardingColors.browserLabel
        label.lineBreakMode = .byTruncatingTail
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: circle.maxX + 12, y: (bounds.height - height) / 2, width: width - circle.maxX - 24, height: height)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(profile.name)
        refresh()
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        check.fillColor = isSelected ? accent.cgColor : nil
        check.strokeColor = (isSelected ? accent : OrbitOnboardingColors.radioRing).cgColor
        mark.isHidden = !isSelected
        CATransaction.commit()
        setAccessibilityValue(isSelected ? 1 : 0)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSelect?()
    }

    override func mouseDown(with event: NSEvent) {}

    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
}
