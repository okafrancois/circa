import AppKit
import BrowserCore
import BrowserShell
import QuartzCore

/// One tab whose media keeps playing after the user left it, as the sidebar card shows it.
struct SidebarMediaPlayerItem: Equatable {
    enum Toggle: Equatable { case pause, play }
    let id: TabOccurrenceID
    var title: String
    var favicon: NSImage?
    /// The glyph of the middle control. The page pausing its own media keeps the pause glyph.
    var toggle: Toggle
    var canToggle: Bool
    var canGoBack: Bool
    var canGoForward: Bool
}

/// Card frames as a function of the hover progress (0 at rest, 1 expanded). Index 0 is the
/// oldest session: the front card at rest and the bottom card once expanded.
struct SidebarMediaPlayerLayout: Equatable {
    struct Card: Equatable {
        /// Visible rectangle in the player view (flipped, origin at its top-left).
        var frame: CGRect
        /// The card renders at its unscaled height, scaled by this factor about its centre.
        var scale: CGFloat
        var height: CGFloat
        var opacity: CGFloat
        var titleOpacity: CGFloat
    }
    typealias Tokens = OrbitTokens.MediaPlayer

    static func expandedHeight(count: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * Tokens.expandedHeight + CGFloat(count - 1) * Tokens.stackGap
    }

    /// Height kept free above the footer while the stack rests.
    static func restingHeight(count: Int) -> CGFloat {
        count == 0 ? 0 : Tokens.collapsedHeight + (count > 1 ? Tokens.stackPeek : 0)
    }

    static func cards(count: Int, width: CGFloat, progress: CGFloat) -> [Card] {
        let p = min(1, max(0, progress))
        let bottom = expandedHeight(count: count)
        let backScale = width > 0 ? max(0, width - 2 * Tokens.stackInset) / width : 1
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        return (0..<count).map { index in
            let expanded = CGRect(x: 0, y: bottom - CGFloat(index) * (Tokens.expandedHeight + Tokens.stackGap) - Tokens.expandedHeight,
                                  width: width, height: Tokens.expandedHeight)
            let rest: CGRect, restScale: CGFloat, restOpacity: CGFloat
            if index == 0 {
                rest = CGRect(x: 0, y: bottom - Tokens.collapsedHeight, width: width, height: Tokens.collapsedHeight)
                restScale = 1; restOpacity = 1
            } else {
                let height = Tokens.collapsedHeight * backScale
                rest = CGRect(x: Tokens.stackInset, y: bottom - Tokens.collapsedHeight - Tokens.stackPeek,
                              width: width * backScale, height: height)
                restScale = backScale
                // Only the second card peeks; later ones wait behind it.
                restOpacity = index == 1 ? Tokens.stackDimmedOpacity : 0
            }
            let frame = CGRect(x: lerp(rest.minX, expanded.minX), y: lerp(rest.minY, expanded.minY),
                               width: lerp(rest.width, expanded.width), height: lerp(rest.height, expanded.height))
            return Card(frame: frame, scale: lerp(restScale, 1),
                        height: lerp(Tokens.collapsedHeight, Tokens.expandedHeight),
                        opacity: lerp(restOpacity, 1), titleOpacity: p * p)
        }
    }

    /// Centre x of control `slot` (0 favicon … 4 speaker) in a card of `width`.
    static func controlCenterX(_ slot: Int, width: CGFloat) -> CGFloat {
        width / 2 + CGFloat(slot - 2) * Tokens.controlPitch
    }
}

/// The stack of cards between the Space list and the footer. The sidebar sizes it to the
/// expanded stack and reserves only the resting height; points outside the cards fall through.
@MainActor
final class SidebarMediaPlayerView: NSView {
    var onBackToTab: ((TabOccurrenceID) -> Void)?
    var onToggle: ((TabOccurrenceID) -> Void)?
    var onPrevious: ((TabOccurrenceID) -> Void)?
    var onNext: ((TabOccurrenceID) -> Void)?
    var onClose: ((TabOccurrenceID) -> Void)?
    /// The card count changed: the sidebar reserves the new resting height and resizes the view.
    var onRestingHeightChange: (() -> Void)?

    private(set) var items: [SidebarMediaPlayerItem] = []
    private var cards: [TabOccurrenceID: SidebarMediaPlayerCard] = [:]
    private let expansion = OrbitTimedAnimator(value: 0)
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?

    var restingHeight: CGFloat { SidebarMediaPlayerLayout.restingHeight(count: items.count) }
    var expandedHeight: CGFloat { SidebarMediaPlayerLayout.expandedHeight(count: items.count) }
    var progress: CGFloat { CGFloat(expansion.value) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        isHidden = true
        expansion.onChange = { [weak self] _ in self?.layoutCards() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(uiText("Media Player"))
        setAccessibilityIdentifier("sidebar-media-player")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Cards appear and leave at once (no transition); known titles and icons never flicker
    /// because a card is reused for its tab and only redraws what changed.
    func apply(_ next: [SidebarMediaPlayerItem]) {
        guard next != items else { return }
        let oldCount = items.count
        items = next
        let ids = Set(next.map(\.id))
        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperview()
            cards.removeValue(forKey: id)
        }
        for item in next {
            let card = cards[item.id] ?? makeCard()
            cards[item.id] = card
            card.apply(item)
        }
        // The oldest card is in front at rest: the newest is the bottom subview.
        let order: [NSView] = next.reversed().compactMap { cards[$0.id] }
        if subviews != order {
            for card in order { addSubview(card, positioned: .above, relativeTo: nil) }
        }
        isHidden = next.isEmpty
        if next.isEmpty { isHovered = false; expansion.set(0) }
        if oldCount != next.count { onRestingHeightChange?() }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func makeCard() -> SidebarMediaPlayerCard {
        let card = SidebarMediaPlayerCard()
        card.onBackToTab = { [weak self] in self?.onBackToTab?($0) }
        card.onToggle = { [weak self] in self?.onToggle?($0) }
        card.onPrevious = { [weak self] in self?.onPrevious?($0) }
        card.onNext = { [weak self] in self?.onNext?($0) }
        card.onClose = { [weak self] in self?.onClose?($0) }
        return card
    }

    override func layout() {
        super.layout()
        layoutCards()
    }

    private func layoutCards() {
        let frames = SidebarMediaPlayerLayout.cards(count: items.count, width: bounds.width, progress: progress)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, item) in items.enumerated() {
            guard let card = cards[item.id], frames.indices.contains(index) else { continue }
            card.place(frames[index])
        }
        CATransaction.commit()
    }

    // MARK: Hover

    /// Cards of the target state: the expanded stack while hovered, the resting deck otherwise.
    private var hotRect: CGRect {
        let frames = SidebarMediaPlayerLayout.cards(count: items.count, width: bounds.width, progress: isHovered ? 1 : 0)
        return frames.filter { $0.opacity > 0 }.reduce(CGRect.null) { $0.union($1.frame) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        guard hotRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false, animated: false) }
    }

    private func updateHover(_ event: NSEvent) {
        setHovered(!isHidden && hotRect.contains(convert(event.locationInWindow, from: nil)))
    }

    func setHovered(_ hovered: Bool, animated: Bool = true) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        let target: Double = hovered ? 1 : 0
        if animated, !OrbitMotionPreferences.prefersReducedMotion {
            expansion.animate(to: target, timing: OrbitTokens.MediaPlayer.expansion, in: self)
        } else {
            expansion.set(target)
        }
    }

    /// Test seam: the card shown for a tab.
    func card(for id: TabOccurrenceID) -> SidebarMediaPlayerCard? { cards[id] }
}

/// One card: a clipped content plate (title row on top, controls row at the bottom) over a
/// shadowed surface. Both scale together about the card's centre.
@MainActor
final class SidebarMediaPlayerCard: NSView {
    typealias Tokens = OrbitTokens.MediaPlayer
    var onBackToTab: ((TabOccurrenceID) -> Void)?
    var onToggle: ((TabOccurrenceID) -> Void)?
    var onPrevious: ((TabOccurrenceID) -> Void)?
    var onNext: ((TabOccurrenceID) -> Void)?
    var onClose: ((TabOccurrenceID) -> Void)?

    private let surface = CALayer()
    /// The outer shadow only: masked off inside the card so it never darkens the translucent fill.
    private let shadowCaster = CAShapeLayer()
    private let shadowMask = CAShapeLayer()
    private let plate = SidebarMediaPlayerPlate()
    let titleView = SidebarMediaPlayerTitle()
    let closeButton = SidebarMediaPlayerButton(symbol: "xmark", pointSize: Tokens.closeGlyphSize, label: uiText("Close"))
    let faviconButton = SidebarMediaPlayerButton(symbol: nil, pointSize: Tokens.faviconSize, label: uiText("Back to Tab"))
    let previousButton = SidebarMediaPlayerButton(symbol: "backward.end.fill", pointSize: Tokens.glyphSize, label: uiText("Previous Track"))
    let toggleButton = SidebarMediaPlayerButton(symbol: "pause.fill", pointSize: Tokens.glyphSize, label: uiText("Pause"))
    let nextButton = SidebarMediaPlayerButton(symbol: "forward.end.fill", pointSize: Tokens.glyphSize, label: uiText("Next Track"))
    /// Per-tab volume needs an engine API that does not exist yet: the control stays disabled.
    let volumeButton = SidebarMediaPlayerButton(symbol: "speaker.wave.3.fill", pointSize: Tokens.glyphSize, label: uiText("Adjust Tab Volume"))
    private(set) var item: SidebarMediaPlayerItem?
    private(set) var placement: SidebarMediaPlayerLayout.Card?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        surface.cornerRadius = Tokens.cornerRadius
        surface.cornerCurve = .continuous
        // The shadow comes from `shadowPath`; an unfilled caster leaves no edge under the card.
        shadowCaster.fillColor = NSColor.clear.cgColor
        shadowCaster.shadowOffset = .zero
        shadowCaster.shadowRadius = Tokens.shadowRadius
        shadowCaster.shadowOpacity = 1
        shadowMask.fillRule = .evenOdd
        shadowCaster.mask = shadowMask
        layer?.addSublayer(shadowCaster)
        layer?.addSublayer(surface)
        addSubview(plate)
        for view in [titleView, closeButton, faviconButton, previousButton, toggleButton, nextButton, volumeButton] {
            plate.addSubview(view)
        }
        faviconButton.onPress = { [weak self] in if let self, let id = item?.id { onBackToTab?(id) } }
        previousButton.onPress = { [weak self] in if let self, let id = item?.id { onPrevious?(id) } }
        toggleButton.onPress = { [weak self] in if let self, let id = item?.id { onToggle?(id) } }
        nextButton.onPress = { [weak self] in if let self, let id = item?.id { onNext?(id) } }
        closeButton.onPress = { [weak self] in if let self, let id = item?.id { onClose?(id) } }
        faviconButton.setAccessibilityIdentifier("sidebar-media-back-to-tab")
        previousButton.setAccessibilityIdentifier("sidebar-media-previous")
        toggleButton.setAccessibilityIdentifier("sidebar-media-toggle")
        nextButton.setAccessibilityIdentifier("sidebar-media-next")
        volumeButton.setAccessibilityIdentifier("sidebar-media-volume")
        closeButton.setAccessibilityIdentifier("sidebar-media-close")
        volumeButton.isEnabled = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refreshColors()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func apply(_ next: SidebarMediaPlayerItem) {
        guard next != item else { return }
        item = next
        titleView.title = next.title
        faviconButton.favicon = next.favicon
        let pausing = next.toggle == .pause
        toggleButton.symbol = pausing ? "pause.fill" : "play.fill"
        toggleButton.label = uiText(pausing ? "Pause" : "Play")
        toggleButton.isEnabled = next.canToggle
        previousButton.isEnabled = next.canGoBack
        nextButton.isEnabled = next.canGoForward
        setAccessibilityLabel(next.title)
    }

    func place(_ card: SidebarMediaPlayerLayout.Card) {
        guard card != placement else { return }
        placement = card
        let width = card.scale > 0 ? card.frame.width / card.scale : card.frame.width
        let size = CGSize(width: width, height: card.height)
        frame = CGRect(x: card.frame.midX - size.width / 2, y: card.frame.midY - size.height / 2,
                       width: size.width, height: size.height)
        alphaValue = card.opacity
        isHidden = card.opacity <= 0
        if let layer {
            let pivot = CGPoint(x: size.width * (0.5 - layer.anchorPoint.x), y: size.height * (0.5 - layer.anchorPoint.y))
            var transform = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
            transform = CATransform3DScale(transform, card.scale, card.scale, 1)
            transform = CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
            layer.sublayerTransform = transform
        }
        surface.frame = CGRect(origin: .zero, size: size)
        let outline = CGPath(roundedRect: surface.bounds, cornerWidth: Tokens.cornerRadius,
                             cornerHeight: Tokens.cornerRadius, transform: nil)
        shadowCaster.frame = surface.frame
        shadowCaster.path = outline
        shadowCaster.shadowPath = outline
        let ring = CGMutablePath()
        ring.addRect(surface.bounds.insetBy(dx: -4 * Tokens.shadowRadius, dy: -4 * Tokens.shadowRadius))
        ring.addPath(outline)
        shadowMask.path = ring
        plate.frame = CGRect(origin: .zero, size: size)
        let controlsY = size.height - Tokens.controlsCenterFromBottom
        let slot = CGSize(width: Tokens.controlPitch, height: Tokens.collapsedHeight)
        for (index, button) in [faviconButton, previousButton, toggleButton, nextButton, volumeButton].enumerated() {
            let x = SidebarMediaPlayerLayout.controlCenterX(index, width: size.width)
            button.frame = CGRect(x: x - slot.width / 2, y: controlsY - slot.height / 2, width: slot.width, height: slot.height)
        }
        let closeX = SidebarMediaPlayerLayout.controlCenterX(4, width: size.width)
        closeButton.frame = CGRect(x: closeX - slot.width / 2, y: Tokens.titleCenterFromTop - slot.height / 2,
                                   width: slot.width, height: slot.height)
        // The title stops short of the close button's hover square.
        let titleRight = closeX - Tokens.hoverSquare / 2 - 6
        titleView.frame = CGRect(x: Tokens.titleOriginX, y: 0, width: max(0, titleRight - Tokens.titleOriginX),
                                 height: Tokens.titleCenterFromTop * 2)
        titleView.alphaValue = card.titleOpacity
        closeButton.alphaValue = card.titleOpacity
        closeButton.isHidden = card.titleOpacity <= 0
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    /// A Space switch restyles the card in the same frame as the window.
    private func refreshColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.backgroundColor = Tokens.surface.resolvedCGColor(for: effectiveAppearance)
        shadowCaster.shadowColor = Tokens.shadow.resolvedCGColor(for: effectiveAppearance)
        CATransaction.commit()
    }
}

/// Clips the rows to the card's rounded outline.
@MainActor
final class SidebarMediaPlayerPlate: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = OrbitTokens.MediaPlayer.cornerRadius
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
}

/// The tab title, truncated with an ellipsis, on the title row's centre line.
@MainActor
final class SidebarMediaPlayerTitle: NSView {
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    private var font: NSFont { BrandTextStyle.ui.font(size: OrbitTokens.MediaPlayer.titleFontSize) }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: OrbitTokens.MediaPlayer.title,
                                                         .paragraphStyle: paragraph]
        // Cap-height centre on the row's centre line.
        let baseline = bounds.midY + font.capHeight / 2
        let rect = NSRect(x: 0, y: baseline - font.ascender, width: bounds.width, height: ceil(font.ascender - font.descender))
        NSAttributedString(string: title, attributes: attributes)
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// A card control: a 24 pt hover square and a tinted glyph, or the tab's favicon.
/// Disabled controls show neither a hover square nor help.
@MainActor
final class SidebarMediaPlayerButton: OrbitGlyphButton {
    typealias Tokens = OrbitTokens.MediaPlayer
    var onPress: (() -> Void)?
    private let pointSize: CGFloat
    var symbol: String? { didSet { if symbol != oldValue { refreshGlyph() } } }
    var label: String { didSet { if label != oldValue { refreshHelp() } } }
    var favicon: NSImage? { didSet { if favicon !== oldValue { needsDisplay = true } } }

    init(symbol: String?, pointSize: CGFloat, label: String) {
        self.symbol = symbol
        self.pointSize = pointSize
        self.label = label
        super.init(glyph: nil, label: label)
        tint = Tokens.glyph
        disabledTint = Tokens.disabledGlyph
        hoverFill = HoverFill(color: OrbitTokens.Color.State.rowCloseButtonHover, side: Tokens.hoverSquare,
                              radius: OrbitTokens.Radius.closeButton)
        target = self
        action = #selector(press)
        refreshGlyph()
        refreshHelp()
        if symbol == nil {
            customDrawing = { [weak self] _, rect in self?.drawFavicon(in: rect) }
        }
    }
    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool {
        get { super.isEnabled }
        set { super.isEnabled = newValue; refreshHelp() }
    }

    private func refreshGlyph() {
        glyph = symbol.flatMap { OrbitGlyph.symbol($0, pointSize: pointSize, weight: .regular) }
    }

    private func refreshHelp() {
        setAccessibilityLabel(label)
        toolTip = isEnabled && symbol != "xmark" ? label : nil
    }

    @objc private func press() { onPress?() }

    private func drawFavicon(in rect: NSRect) {
        let side = Tokens.faviconSize
        let target = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        guard let favicon, !favicon.isTemplate else {
            if let image = favicon ?? OrbitGlyph.faviconPlaceholder {
                OrbitGlyph.draw(image, centeredIn: rect, tint: Tokens.glyph, in: self)
            }
            return
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        shadow.shadowColor = Tokens.faviconShadow
        shadow.set()
        favicon.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
