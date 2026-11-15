import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// View > Show/Hide Toolbar: a page-coloured row at the top of the content card with history
/// controls, the page address and site/split actions. All metrics are points from the card's
/// top-left corner; the row is 32 pt high over a 1 pt separator.
@MainActor
final class BrowserOptionalToolbar: NSView {
    enum Metrics {
        static let rowHeight: CGFloat = 32
        static let separatorHeight: CGFloat = 1
        static let height = rowHeight + separatorHeight
        static let centerY: CGFloat = 16
        /// Button centres, optically corrected so each glyph's ink lands on the measured centre.
        static let back = CGPoint(x: 20.75, y: 16.25)
        static let forward = CGPoint(x: 57.75, y: 16.25)
        static let reload = CGPoint(x: 95, y: 15.5)
        static let siteFromRight = CGPoint(x: 57.25, y: 16)
        static let splitFromRight = CGPoint(x: 20.25, y: 15.75)
        static let buttonSize = NSSize(width: 30, height: 28)
        /// The address text is centred in the card; the link glyph sits 15 pt left of it.
        static let linkCenterFromText: CGFloat = 14
        static let linkCenterY: CGFloat = 16.5
        static let textBaseline: CGFloat = 20.25
        static let fontSize: CGFloat = 13
        static let addressLeadingLimit: CGFloat = 132
        static let addressTrailingLimit: CGFloat = 80
        static let pillPaddingX: CGFloat = 5.5
        static let pillHeight: CGFloat = 24
        static let pillRadius: CGFloat = 5
    }

    /// Foreground opacities over the page colour, calibrated so rendered pixels match the
    /// measured ink on a white page.
    enum Ink {
        static let icon: CGFloat = 0.59
        static let disabledIcon: CGFloat = 0.33
        static let host: CGFloat = 0.65
        static let path: CGFloat = 0.53
        static let hover: Float = 0.073
        static let pressed: Float = 0.096
        static let separator: CGFloat = 0.058
    }

    /// Ease-in-out fades of the address fill, calibrated against recorded frame timing.
    enum Motion {
        static let hoverIn: CFTimeInterval = 0.2
        static let hoverOut: CFTimeInterval = 0.1
        static let pressIn: CFTimeInterval = 0.13
        static let pressOut: CFTimeInterval = 0.1
    }

    static var height: CGFloat { Metrics.height }

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onAddress: (() -> Void)?
    var onSiteControls: ((NSView) -> Void)?
    var onSplit: (() -> Void)?

    let back = NSButton()
    let forward = NSButton()
    let reload = NSButton()
    let site = NSButton()
    let split = NSButton()
    let address = BrowserToolbarAddressView()
    private let background = OrbitThemeFillView()
    private let separator = CALayer()
    private(set) var pageTint: BrowserPageTint?
    private(set) var foreground: NSColor = .black

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 590, height: Metrics.height))
        setAccessibilityIdentifier("optional-toolbar")
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(uiText("Toolbar"))
        wantsLayer = true
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)
        separator.backgroundColor = NSColor.black.withAlphaComponent(Ink.separator).cgColor
        layer?.addSublayer(separator)
        for (button, symbol, size, label, id, action) in [
            (back, "arrow.left", 14.0, uiText("Back"), "optional-toolbar-back", #selector(goBack)),
            (forward, "arrow.right", 14.0, uiText("Forward"), "optional-toolbar-forward", #selector(goForward)),
            (reload, "arrow.clockwise", 14.0, uiText("Reload"), "optional-toolbar-reload", #selector(reloadPage)),
            (site, "slider.horizontal.2.square", 17.5, uiText("Site Controls"), "optional-toolbar-site", #selector(showSiteControls)),
            (split, "square.split.2x1", 16.0, uiText("Split View"), "optional-toolbar-split", #selector(showSplit))
        ] as [(NSButton, String, CGFloat, String, String, Selector)] {
            button.image = OrbitGlyph.symbol(symbol, pointSize: size, weight: .regular)
            button.imageScaling = .scaleNone
            button.isBordered = false
            (button.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
            button.setAccessibilityIdentifier(id)
            addSubview(button)
        }
        // Straight arrows belong to this row; sidebar navigation keeps its compact chevrons.
        back.image = OrbitToolbarGlyphs.backArrow
        forward.image = OrbitToolbarGlyphs.forwardArrow
        reload.image = OrbitGlyph.reload
        address.onActivate = { [weak self] in self?.onAddress?() }
        addSubview(address)
        background.onAppearanceChange = { [weak self] in self?.refreshTint() }
        apply(theme: .default)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func goBack() { onBack?() }
    @objc private func goForward() { onForward?() }
    @objc private func reloadPage() { onReload?() }
    @objc private func showSiteControls() { onSiteControls?(site) }
    @objc private func showSplit() { onSplit?() }

    func update(url: URL?, canGoBack: Bool, canGoForward: Bool) {
        back.isEnabled = canGoBack
        forward.isEnabled = canGoForward
        reload.isEnabled = url != nil
        address.url = url
        refreshButtonInk()
        needsLayout = true
    }

    func apply(theme: OrbitTokens.SpaceTheme) {
        background.apply(theme)
        refreshTint()
    }

    func updateTint(_ tint: BrowserPageTint?) {
        guard pageTint != tint else { return }
        pageTint = tint
        refreshTint()
    }

    /// Page colour when known, otherwise the Space fill; black or white ink by contrast.
    private func refreshTint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.isHidden = pageTint != nil
        let tint: BrowserPageTint
        if let pageTint {
            tint = pageTint
            layer?.backgroundColor = NSColor(srgbRed: CGFloat(tint.red) / 255, green: CGFloat(tint.green) / 255,
                                             blue: CGFloat(tint.blue) / 255, alpha: 1).cgColor
        } else {
            layer?.backgroundColor = nil
            let stops = background.resolvedStops.compactMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
            let rgb = (stops.isEmpty ? NSColor.windowBackgroundColor : stops[stops.count / 2]).usingColorSpace(.sRGB) ?? .white
            tint = BrowserPageTint(red: UInt8(max(0, min(255, rgb.redComponent * 255))),
                                   green: UInt8(max(0, min(255, rgb.greenComponent * 255))),
                                   blue: UInt8(max(0, min(255, rgb.blueComponent * 255))))
        }
        foreground = tint.prefersWhiteForeground ? .white : .black
        address.foreground = foreground
        refreshButtonInk()
        CATransaction.commit()
    }

    private func refreshButtonInk() {
        for button in [back, forward, reload, site, split] {
            button.contentTintColor = foreground.withAlphaComponent(button.isEnabled ? Ink.icon : Ink.disabledIcon)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        separator.frame = CGRect(x: 0, y: Metrics.rowHeight, width: bounds.width, height: Metrics.separatorHeight)
        CATransaction.commit()
        let size = Metrics.buttonSize
        func place(_ button: NSButton, _ center: CGPoint) {
            button.frame = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }
        place(back, Metrics.back)
        place(forward, Metrics.forward)
        place(reload, Metrics.reload)
        place(site, CGPoint(x: bounds.width - Metrics.siteFromRight.x, y: Metrics.siteFromRight.y))
        place(split, CGPoint(x: bounds.width - Metrics.splitFromRight.x, y: Metrics.splitFromRight.y))
        let leading = Metrics.addressLeadingLimit
        let trailing = max(leading, bounds.width - Metrics.addressTrailingLimit)
        let natural = address.naturalTextWidth
        let width = min(natural, trailing - leading)
        let x = max(leading, min((bounds.width - natural) / 2, trailing - width))
        address.frame = NSRect(x: x - Metrics.linkCenterFromText - 10, y: 0,
                               width: width + Metrics.linkCenterFromText + 10 + Metrics.pillPaddingX, height: Metrics.rowHeight)
        address.textInset = Metrics.linkCenterFromText + 10
    }
}

/// The link glyph and the page address. Hovering shows a rounded fill around the text;
/// pressing deepens it; a click asks the window to open the Command Bar.
@MainActor
final class BrowserToolbarAddressView: NSView {
    typealias Metrics = BrowserOptionalToolbar.Metrics
    typealias Ink = BrowserOptionalToolbar.Ink
    typealias Motion = BrowserOptionalToolbar.Motion

    var onActivate: (() -> Void)?
    var url: URL? {
        didSet {
            guard url != oldValue else { return }
            setAccessibilityValue(url?.absoluteString ?? "")
            invalidateText()
        }
    }
    var foreground: NSColor = .black {
        didSet {
            guard foreground != oldValue else { return }
            link.contentTintColor = foreground.withAlphaComponent(Ink.icon)
            pill.backgroundColor = foreground.cgColor
            invalidateText()
        }
    }
    /// Distance from the view's leading edge to the text.
    var textInset: CGFloat = 25 { didSet { if textInset != oldValue { needsLayout = true; needsDisplay = true } } }
    private let link = NSImageView()
    private let pill = CALayer()
    private var tracking: NSTrackingArea?
    private(set) var isHovered = false
    private(set) var isPressed = false
    private var cachedText: NSAttributedString?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("optional-toolbar-address")
        setAccessibilityLabel(uiText("Address"))
        pill.backgroundColor = NSColor.black.cgColor
        pill.opacity = 0
        pill.cornerRadius = Metrics.pillRadius
        pill.cornerCurve = .continuous
        layer?.addSublayer(pill)
        link.image = OrbitGlyph.symbol("link", pointSize: 12.5, weight: .regular)
        link.imageScaling = .scaleNone
        link.contentTintColor = NSColor.black.withAlphaComponent(Ink.icon)
        addSubview(link)
    }
    required init?(coder: NSCoder) { nil }

    /// Scheme-less address: the host in semibold, the rest regular and lighter.
    var displayText: NSAttributedString {
        if let cachedText { return cachedText }
        let text = Self.displayText(for: url, foreground: foreground)
        cachedText = text
        return text
    }

    var naturalTextWidth: CGFloat { ceil(displayText.size().width) }

    static func displayText(for url: URL?, foreground: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let regular: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Metrics.fontSize, weight: .regular),
            .foregroundColor: foreground.withAlphaComponent(Ink.path), .paragraphStyle: paragraph
        ]
        guard let url else { return NSAttributedString(string: "", attributes: regular) }
        var full = url.absoluteString
        if let scheme = url.scheme, full.lowercased().hasPrefix(scheme.lowercased() + "://") {
            full.removeFirst(scheme.count + 3)
        }
        let result = NSMutableAttributedString(string: full, attributes: regular)
        if let host = url.host(percentEncoded: false) ?? url.host, !host.isEmpty,
           let range = full.range(of: host) {
            result.addAttributes([.font: NSFont.systemFont(ofSize: Metrics.fontSize, weight: .semibold),
                                  .foregroundColor: foreground.withAlphaComponent(Ink.host)],
                                 range: NSRange(range, in: full))
        }
        return result
    }

    private func invalidateText() {
        cachedText = nil
        superview?.needsLayout = true
        needsDisplay = true
    }

    var pillFrame: CGRect {
        CGRect(x: textInset - Metrics.pillPaddingX, y: Metrics.centerY - Metrics.pillHeight / 2,
               width: max(0, bounds.width - textInset) + Metrics.pillPaddingX, height: Metrics.pillHeight)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = pillFrame
        CATransaction.commit()
        let image = link.image?.size ?? .zero
        let center = CGPoint(x: textInset - Metrics.linkCenterFromText, y: Metrics.linkCenterY)
        link.frame = CGRect(x: center.x - image.width / 2, y: center.y - image.height / 2,
                            width: image.width, height: image.height)
        updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = displayText
        guard text.length > 0, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return }
        let rect = CGRect(x: textInset, y: Metrics.textBaseline - font.ascender,
                          width: max(0, bounds.width - textInset - Metrics.pillPaddingX), height: ceil(font.ascender - font.descender) + 1)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return pillFrame.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: pillFrame, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func mouseDown(with event: NSEvent) {
        setPressed(true)
        guard let window else { return }
        var inside = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = pillFrame.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { break }
            setPressed(inside)
        }
        setPressed(false)
        if inside { onActivate?() }
    }

    override func accessibilityPerformPress() -> Bool { onActivate?(); return true }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        animatePill(duration: hovered ? Motion.hoverIn : Motion.hoverOut)
    }

    func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        animatePill(duration: pressed ? Motion.pressIn : Motion.pressOut)
    }

    var pillOpacity: Float { isPressed ? Ink.pressed : isHovered ? Ink.hover : 0 }

    private func animatePill(duration: CFTimeInterval) {
        let target = pillOpacity
        let current = pill.presentation()?.opacity ?? pill.opacity
        pill.removeAnimation(forKey: "opacity")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.opacity = target
        CATransaction.commit()
        guard window?.isVisible == true, !OrbitMotionPreferences.prefersReducedMotion else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pill.add(animation, forKey: "opacity")
    }
}
