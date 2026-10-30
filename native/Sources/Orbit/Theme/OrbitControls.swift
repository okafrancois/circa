import AppKit
import QuartzCore

/// Opt-in synthetic diagnostics; ordinary UI work never retains counters or control identities.
@MainActor
enum OrbitUIWorkCounters {
    static var enabled = false
    static var values: [String: Int] = [:]
    static func record(_ name: String) {
        if enabled { values[name, default: 0] += 1 }
    }
    static func reset() { values.removeAll() }
}

@MainActor
enum OrbitGlyph {
    private final class SymbolIdentity: NSObject {
        let name: String
        let pointSize: CGFloat
        let weight: NSFont.Weight
        init(_ name: String, _ pointSize: CGFloat, _ weight: NSFont.Weight) {
            self.name = name; self.pointSize = pointSize; self.weight = weight
        }
    }
    private static let identities = NSMapTable<NSImage, SymbolIdentity>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    /// Snapshot configuration as well as identity: callers can replace a configured symbol
    /// with an equivalent image, or mutate an existing image's size before assigning it again.
    struct Configuration: Equatable {
        let name: String?
        let pointSize: CGFloat?
        let weight: NSFont.Weight?
        let otherImage: ObjectIdentifier?
        let size: NSSize
        let isTemplate: Bool
        let symbol: NSImage.SymbolConfiguration?
    }
    static func configuration(of image: NSImage?) -> Configuration? {
        guard let image else { return nil }
        let source = identities.object(forKey: image)
        return Configuration(name: source?.name, pointSize: source?.pointSize, weight: source?.weight,
            otherImage: source == nil ? ObjectIdentifier(image) : nil, size: image.size,
            isTemplate: image.isTemplate, symbol: image.symbolConfiguration)
    }

    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        let image = OrbitIcon.image(sfName: name, pointSize: pointSize, weight: weight)
        if let image { identities.setObject(SymbolIdentity(name, pointSize, weight), forKey: image) }
        return image
    }

    /// 19×14 for the ≈18.7×14.9 toggle.
    static var sidebarToggle: NSImage? { symbol("sidebar.left", pointSize: 13) }
    /// 15×12 for the 14.4×11.7 arrows.
    static var back: NSImage? { symbol("arrow.left", pointSize: 12) }
    static var forward: NSImage? { symbol("arrow.right", pointSize: 12) }
    /// 13×10.5 arrows of the compact toolbar ().
    static var backCompact: NSImage? { symbol("arrow.left", pointSize: 10.5) }
    static var forwardCompact: NSImage? { symbol("arrow.right", pointSize: 10.5) }
    /// ≈13×3 "•••" overflow of the compact toolbar ().
    static var toolbarOverflow: NSImage? { symbol("ellipsis", pointSize: 12, weight: .bold) }
    /// 15×17 for the 14.4×17.6 reload glyph.
    static var reload: NSImage? { symbol("arrow.clockwise", pointSize: 14) }
    /// 10×10 for the 10.5 close cross.
    static var close: NSImage? { symbol("xmark", pointSize: 10, weight: .semibold) }
    /// 13 for the New Tab "+".
    static var newTab: NSImage? { symbol("plus", pointSize: 12) }
    /// ≈14 for the footer "+", and the "×" it becomes while its menu is open ().
    static var footerPlus: NSImage? { symbol("plus", pointSize: 13) }
    static var footerClose: NSImage? { symbol("xmark", pointSize: 12) }
    /// Library entry of the footer (: own glyph).
    static var library: NSImage? { symbol("archivebox", pointSize: 13) }
    /// Placeholder until the engine publishes favicons ().
    static var faviconPlaceholder: NSImage? { symbol("globe", pointSize: 12, weight: .regular) }

    static var siteControlCenter: NSImage {
        symbol("slider.horizontal.3", pointSize: 18) ?? NSImage()
    }

    /// Draws a template glyph centred in `rect`, tinted with a (dynamic) colour.
    static func draw(_ glyph: NSImage, centeredIn rect: NSRect, tint: NSColor, in view: NSView) {
        let size = glyph.size
        let target = view.backingAlignedRect(
            NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
            options: .alignAllEdgesNearest)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(in: target, auxiliaryInfo: nil)
        glyph.draw(in: target)
        tint.set()
        target.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

@MainActor
class OrbitGlyphButton: NSButton {
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue, OrbitUIWorkCounters.enabled {
                OrbitUIWorkCounters.record("glyphDirty")
                OrbitUIWorkCounters.record("glyphDirty.\(ObjectIdentifier(self))")
                let cause = dirtyCause ?? "untracked.\(type(of: self))"
                OrbitUIWorkCounters.record("glyphDirty.cause." + cause)
                pendingCauses.insert(cause)
            }
            super.needsDisplay = newValue
        }
    }
    /// Diagnostics only: why the next draw happens. A draw with no recorded cause was requested by
    /// AppKit itself (a new backing store, or a frame moved to another sub-pixel phase).
    private var dirtyCause: String?
    private var pendingCauses: Set<String> = []
    private func invalidate(_ cause: String) {
        dirtyCause = cause
        needsDisplay = true
        dirtyCause = nil
    }
    private var glyphConfiguration: OrbitGlyph.Configuration?
    var glyph: NSImage? {
        didSet {
            let next = OrbitGlyph.configuration(of: glyph)
            if next != glyphConfiguration { glyphConfiguration = next; invalidate("glyph") }
        }
    }
    var tint: NSColor = OrbitTokens.Color.Text.baseSecondary { didSet { if tint != oldValue { invalidate("tint") } } }
    var disabledTint: NSColor = OrbitTokens.Color.Text.tertiary { didSet { if disabledTint != oldValue { invalidate("disabledTint") } } }
    var showsHoverFill = true { didSet { if showsHoverFill != oldValue { invalidate("showsHoverFill") } } }
    /// Hover square drawn under the glyph.
    struct HoverFill: Equatable {
        var color: NSColor
        /// Side of the centred square; nil fills the bounds.
        var side: CGFloat?
        var radius: CGFloat

        ///  radius on  — toolbar and footer glyphs.
        static let standalone = HoverFill(color: OrbitTokens.Color.State.standaloneButton, side: nil,
                                          radius: OrbitTokens.Radius.toolbarButtonHover)
        ///  — × of a sidebar row: 24 × 24, black 7 % / white 7.5 %.
        static let rowClose = HoverFill(color: OrbitTokens.Color.State.rowCloseButtonHover,
                                        side: OrbitTokens.Metrics.Sidebar.closeButtonSize, radius: OrbitTokens.Radius.closeButton)
    }
    var hoverFill = HoverFill.standalone { didSet { if hoverFill != oldValue { invalidate("hoverFill") } } }
    /// Footer Space icons draw their own content.
    var customDrawing: ((OrbitGlyphButton, NSRect) -> Void)?
    private(set) var isHovering = false { didSet { if isHovering != oldValue { invalidate("hover") } } }
    private var hoverArea: NSTrackingArea?

    init(glyph: NSImage?, label: String) {
        self.glyph = glyph
        self.glyphConfiguration = OrbitGlyph.configuration(of: glyph)
        super.init(frame: NSRect(x: 0, y: 0, width: OrbitTokens.Metrics.Toolbar.buttonHitSize, height: OrbitTokens.Metrics.Toolbar.buttonHitSize))
        title = ""
        isBordered = false
        imagePosition = .noImage
        setButtonType(.momentaryPushIn)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool {
        get { super.isEnabled }
        set { if newValue != super.isEnabled { super.isEnabled = newValue; invalidate("enabled") } }
    }
    override var isHighlighted: Bool {
        get { super.isHighlighted }
        set { if newValue != super.isHighlighted { super.isHighlighted = newValue; invalidate("highlighted") } }
    }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovering = false }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidate("appearance")
    }

    override func draw(_ dirtyRect: NSRect) {
        OrbitUIWorkCounters.record("glyphDraw")
        if OrbitUIWorkCounters.enabled {
            OrbitUIWorkCounters.record("glyphDraw.cause." + (pendingCauses.isEmpty ? "appKit" : pendingCauses.sorted().joined(separator: "+")))
        }
        if !pendingCauses.isEmpty { pendingCauses.removeAll() }
        if showsHoverFill, isEnabled, isHovering || isHighlighted {
            hoverFill.color.setFill()
            let rect = hoverFill.side.map { side in
                NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            } ?? bounds
            NSBezierPath(roundedRect: rect, xRadius: hoverFill.radius, yRadius: hoverFill.radius).fill()
        }
        if let customDrawing { return customDrawing(self, bounds) }
        guard let glyph else { return }
        OrbitGlyph.draw(glyph, centeredIn: bounds, tint: isEnabled ? tint : disabledTint, in: self)
    }
}

@MainActor
final class OrbitSurfaceBackgroundView: NSView {
    private let host = CALayer()
    private let fill = CALayer()
    private let shadowCaster = CALayer()
    private let shadowMask = CAShapeLayer()
    private(set) var frost: OrbitFrostView?
    var fillColor: NSColor? { didSet { refresh() } }
    var cornerRadius: CGFloat { didSet { needsLayout = true } }
    var outerShadow: OrbitTokens.ShadowSpec? { didSet { refresh(); needsLayout = true } }
    var borderColor: NSColor? { didSet { refresh() } }
    var borderWidth: CGFloat = 0 { didSet { refresh() } }

    func applyFrost(_ accent: OrbitTokens.ThemeAccent, selected: Bool = false) {
        let amount = accent.contrastTheme?.frostAmount ?? 0
        if amount > 0, frost == nil {
            frost = OrbitFloatingMaterial.install(in: self, radius: cornerRadius)
        }
        if let frost {
            frost.sidebarForeground = accent.foreground
            frost.selectedSidebarSurface = selected
            frost.isHidden = amount == 0
            frost.alphaValue = amount
        }
        // Retain the old overlay below the material during a progress-driven transition.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.opacity = Float(1 - amount)
        CATransaction.commit()
    }

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        host.masksToBounds = false
        shadowMask.fillRule = .evenOdd
        shadowCaster.mask = shadowMask
        host.addSublayer(shadowCaster)
        host.addSublayer(fill)
        layer = host
        wantsLayer = true
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = bounds
        fill.frame = bounds
        fill.cornerRadius = cornerRadius
        let margin = (outerShadow.map { $0.blur + abs($0.offsetY) } ?? 0) + 2
        shadowCaster.frame = bounds.insetBy(dx: -margin, dy: -margin)
        let shape = CGRect(x: margin, y: margin, width: bounds.width, height: bounds.height)
        shadowCaster.shadowPath = CGPath(roundedRect: shape, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let mask = CGMutablePath()
        mask.addRect(shadowCaster.bounds)
        mask.addPath(CGPath(roundedRect: shape, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        shadowMask.frame = shadowCaster.bounds
        shadowMask.path = mask
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let appearance = effectiveAppearance
        fill.backgroundColor = fillColor?.resolvedCGColor(for: appearance)
        fill.borderColor = borderColor?.resolvedCGColor(for: appearance)
        fill.borderWidth = borderWidth
        if let outerShadow {
            shadowCaster.isHidden = false
            outerShadow.apply(to: shadowCaster, isFlipped: false, appearance: appearance)
        } else {
            shadowCaster.isHidden = true
        }
        CATransaction.commit()
    }
}

/// Target of a button that pops up a menu below itself (buttons hold their target weakly).
@MainActor
final class OrbitMenuButtonTarget: NSObject {
    private let menu: @MainActor () -> NSMenu?
    init(menu: @escaping @MainActor () -> NSMenu?) { self.menu = menu }

    @objc func show(_ sender: NSButton) {
        guard let menu = menu() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }
}

/// Single-line behaviour of the sidebar address field (VIS-1 BL-VIS1-ADDRESS): one line at rest with
/// a tail ellipsis, horizontal scrolling while editing, never a wrap — even with a selection.
/// `usesSingleLineMode` alone leaves `wraps` on, and the field editor then tracks the field width and
/// breaks the URL over several clipped lines. The line-break mode is set last: `isScrollable`
/// resets it to clipping.
@MainActor
enum OrbitAddressFieldStyle {
    static func applySingleLine(to field: NSTextField) {
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
    }
}
