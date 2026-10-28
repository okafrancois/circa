import AppKit
import QuartzCore

/// Space gradient and optional grain. The shell opts into a native behind-window material;
/// opaque remains the default for document shields and standalone gradient rendering. CAP-1c C01
/// informs the gradient axis and stops, not the runtime material. Glass is a reconstruction choice
/// requested by the user; see design/glass-design-r1.md.
/// Decorative: it never takes mouse events or makes sidebar controls vibrant.
@MainActor
final class OrbitThemeFillView: NSView {
    private let host = CALayer()
    /// A light neutral wash accompanies AppKit's adaptive behind-window frost.
    private let readability = CALayer()
    private(set) var materialView: OrbitGlassMaterialView?
    /// Retained across theme switches, swipes and accessibility fallback; never a shared instance.
    private(set) var liquidGlassView: NSView?
    var materialCornerRadius: CGFloat = 0 { didSet { updateMaterialCornerRadius() } }
    var usesNativeLiquidGlass: Bool { liquidGlassView?.isHidden == false }
    private func updateMaterialCornerRadius() {
        if #available(macOS 26.0, *), let glass = liquidGlassView as? OrbitLiquidGlassView {
            glass.cornerRadius = materialCornerRadius
        }
    }
    private(set) var materialRole: OrbitGlassRole = .opaque
    private let materialObservers = OrbitGlassObservers()
    private let windowObservers = OrbitGlassObservers()
    private(set) var glassStyle = OrbitGlassStyle.resolve(role: .opaque, isDark: false, isActive: false,
                                                       reduceTransparency: false, increaseContrast: false)
    var onMaterialChange: (() -> Void)?
    private let gradient = CAGradientLayer()
    private let grain = OrbitGrainLayer()
    private(set) var theme: OrbitTokens.SpaceTheme = .default
    /// Test seams: interactive swipe frames must not redo material or grain work.
    private(set) var materialRefreshCount = 0
    var grainNeedsDisplay: Bool { grain.needsDisplay() }
    /// The window-sized gradient this view shows a part of. The floating sidebar backdrop sets the
    /// window content size and its own top-left offset so its fill matches the window fill.
    var windowFillSize: CGSize? { didSet { needsLayout = true } }
    var offsetInWindowFill: CGPoint = .zero { didSet { needsLayout = true } }
    var onAppearanceChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.addSublayer(gradient)
        host.addSublayer(grain)
        wantsLayer = true
        // A layer-backed view may host the material subview and a separate tint layer. Keep the
        // tint above AppKit's material layers without making the controls vibrant descendants.
        host.zPosition = 1
        layer?.addSublayer(host)
        readability.zPosition = 0.5
        readability.opacity = 0
        layer?.addSublayer(readability)
        gradient.locations = [0, 0.5, 1]
        grain.isHidden = true
        refreshColors()
        layoutLayers()
    }

    convenience init(materialRole: OrbitGlassRole) {
        self.init(frame: .zero)
        self.materialRole = materialRole
        if materialRole != .opaque {
            let material = OrbitGlassMaterialView(frame: bounds)
            material.autoresizingMask = [.width, .height]
            addSubview(material, positioned: .below, relativeTo: nil)
            materialView = material
            if #available(macOS 26.0, *) {
                let glass = OrbitLiquidGlassView(frame: bounds)
                glass.autoresizingMask = [.width, .height]
                glass.isHidden = true
                addSubview(glass, positioned: .above, relativeTo: material)
                liquidGlassView = glass
            }
            let center = NSWorkspace.shared.notificationCenter
            let token = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                           object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMaterial() }
            }
            materialObservers.tokens.append((center, token))
        }
        refreshMaterial()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for (center, token) in windowObservers.tokens { center.removeObserver(token) }
        windowObservers.tokens.removeAll()
        if let window, materialRole != .opaque {
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshMaterial() }
                }
                windowObservers.tokens.append((center, token))
            }
        }
        refreshMaterial()
    }

    /// Re-resolves on appearance, activation and accessibility changes; no preference writes.
    func useOpaqueBackground() {
        materialRole = .opaque
        refreshMaterial()
    }

    func refreshMaterial() {
        materialRefreshCount += 1
        let workspace = NSWorkspace.shared
        applyMaterialStyle(.resolve(role: materialRole, isDark: OrbitAppearance.isDark(effectiveAppearance),
                                    isActive: window?.isKeyWindow == true,
                                    reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                                    increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
                                    surface: theme.surface))
    }

    /// The resolved-style seam also allows deterministic, hidden accessibility regression tests.
    func applyMaterialStyle(_ style: OrbitGlassStyle) {
        glassStyle = style
        if !style.usesMaterial {
            host.removeAnimation(forKey: Self.themeFadeKey)
            readability.removeAnimation(forKey: Self.themeFadeKey)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.opacity = style.tintOpacity
        readability.backgroundColor = (OrbitAppearance.isDark(effectiveAppearance) ? NSColor.black : NSColor.white).cgColor
        readability.opacity = style.readabilityOpacity
        // The HUD material is AppKit's thinner behind-window frost. The standard window
        // material substantially mutes the backdrop even after the theme tint is reduced.
        let backdrop: NSVisualEffectView.Material = style.requestsLiquidGlass ? .hudWindow : .underWindowBackground
        if materialView?.material != backdrop { materialView?.material = backdrop }
        let nativeGlass = style.usesMaterial && style.requestsLiquidGlass && liquidGlassView != nil
        liquidGlassView?.isHidden = !nativeGlass
        // NSGlassEffectView decorates its local backdrop. It does not replace the explicit
        // behind-window sampler: hiding that view made Liquid Glass lose the desktop blur.
        materialView?.isHidden = !style.usesMaterial
        CATransaction.commit()
        onMaterialChange?()
    }

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
        let size = windowFillSize ?? bounds.size
        // Layer coordinates of a hosted root layer have their origin at the bottom-left.
        let fill = CGRect(x: -offsetInWindowFill.x,
                          y: offsetInWindowFill.y + bounds.height - size.height,
                          width: size.width, height: size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        materialView?.frame = bounds
        liquidGlassView?.frame = bounds
        host.frame = bounds
        readability.frame = bounds
        gradient.frame = fill
        applyEndpoints()
        grain.frame = host.bounds
        CATransaction.commit()
    }

    /// The axis depends on the window size and, for the default theme, on the appearance (its flat
    /// start differs in light and dark).
    private func applyEndpoints() {
        let size = windowFillSize ?? bounds.size
        let isDark = OrbitAppearance.isDark(effectiveAppearance)
        let points = OrbitThemeGradient.endpoints(size: size, range: theme.stopRange.range(isDark: isDark),
                                                angleDegrees: theme.angle.degrees(isDark: isDark))
        if gradient.startPoint != points.start { gradient.startPoint = points.start }
        if gradient.endPoint != points.end { gradient.endPoint = points.end }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // : light ↔ dark is instant — a Space cross-fade in flight must not keep
        // painting the previous appearance's colours.
        gradient.removeAnimation(forKey: Self.themeFadeKey)
        host.removeAnimation(forKey: Self.themeFadeKey)
        readability.removeAnimation(forKey: Self.themeFadeKey)
        refreshColors()
        refreshMaterial()
        onAppearanceChange?()
    }

    static let themeFadeKey = "orbit.themeFade"
    /// True while a Space-switch cross-fade runs (tests).
    var isCrossfading: Bool { gradient.animation(forKey: Self.themeFadeKey) != nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        host.contentsScale = scale
        grain.contentsScale = scale
        grain.setNeedsDisplay()
    }

    /// Colours of the current theme under the current appearance.
    var resolvedStops: [CGColor] { OrbitThemeGradient.normalizedStops(theme.stops, appearance: effectiveAppearance) }

    /// Switches theme; `fade` cross-fades the gradient ( C16: the fill changes with the
    /// Space list, over the list spring's settling time; reduced motion: 0.12 s).
    func apply(_ newTheme: OrbitTokens.SpaceTheme, fade: TimeInterval? = nil) {
        apply(newTheme, fade: fade, refreshesMaterial: true)
    }

    private func apply(_ newTheme: OrbitTokens.SpaceTheme, fade: TimeInterval?, refreshesMaterial: Bool) {
        guard newTheme != theme else { return }
        let previous = (gradient.presentation() ?? gradient).colors
        let previousTint = (host.presentation() ?? host).opacity
        let previousWash = (readability.presentation() ?? readability).opacity
        let surfaceChanged = newTheme.surface != theme.surface
        theme = newTheme
        refreshColors()
        if refreshesMaterial || surfaceChanged { refreshMaterial() }
        if let fade, fade > 0, let previous {
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = previous
            animation.toValue = gradient.colors
            animation.duration = fade
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            gradient.add(animation, forKey: Self.themeFadeKey)
            for (layer, opacity) in [(host, previousTint), (readability, previousWash)] where opacity != layer.opacity {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = opacity
                fade.toValue = layer.opacity
                fade.duration = animation.duration
                fade.timingFunction = animation.timingFunction
                layer.add(fade, forKey: Self.themeFadeKey)
            }
        }
    }

    /// Progress-driven fills must replace, rather than queue behind, a previous theme fade.
    /// Orbit's Metal configuration setter invalidates its layer
    /// its asynchronous display path does not attach a separate Core Animation colour fade.
    /// Runs on every swipe display callback: only the gradient colours change. Material inputs
    /// (appearance, key state, accessibility) have their own observers, so it is re-resolved only
    /// when the blended surface itself changes.
    func applyInteractiveTheme(_ newTheme: OrbitTokens.SpaceTheme) {
        gradient.removeAnimation(forKey: Self.themeFadeKey)
        host.removeAnimation(forKey: Self.themeFadeKey)
        readability.removeAnimation(forKey: Self.themeFadeKey)
        apply(newTheme, fade: nil, refreshesMaterial: false)
    }

    private func refreshColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = resolvedStops
        applyEndpoints()
        // The tiled grain does not depend on the colours: redrawing this full-window CPU layer
        // on every swipe frame is wasted work. Bounds and backing-scale changes redraw it separately.
        let intensity = theme.texture == .none ? 0 : theme.textureIntensity
        if grain.intensity != intensity {
            grain.intensity = intensity
        }
        grain.isHidden = intensity <= 0
        CATransaction.commit()
    }
}

/// Procedural grain tiled over the fill. Orbit ships grain/denim/sand/tweed bitmaps; they are not
/// embedded (design §6.1): every texture is approximated by the same seeded noise ().
final class OrbitGrainLayer: CALayer {
    /// Strength is composited by Core Animation; editing it must not redraw the tiled backing.
    var intensity: CGFloat = 0 {
        didSet { opacity = Float(min(1, max(0, intensity))) }
    }

    override init() {
        super.init()
        opacity = 0
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        intensity = (layer as? OrbitGrainLayer)?.intensity ?? 0
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(in context: CGContext) {
        guard let tile = Self.tile else { return }
        let side = CGFloat(Self.tileSide) / max(1, contentsScale)
        context.draw(tile, in: CGRect(x: 0, y: 0, width: side, height: side), byTiling: true)
    }

    static let tileSide = 128

    /// Seeded speckles: about a tenth of the pixels are lightened or darkened, at most 10 % alpha
    /// before the theme intensity ().
    static let tile: CGImage? = {
        let side = tileSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 33
        }
        for index in 0..<(side * side) {
            let roll = next() % 1000
            guard roll < 110 else { continue }
            let alpha = UInt8(8 + next() % 18)
            let light = roll % 2 == 0
            let value: UInt8 = light ? alpha : 0
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
            pixels[index * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}

/// The hover-revealed sidebar's panel (): the window's theme fill darkened by
/// a black 10 % overlay (≈ −25/255 per channel, D40), rounded 12 and shadowed (black 17.5 %, y 0,
/// blur 8) above the content, with the 1 pt inner light edge of .
/// Decorative: the sidebar view above it takes the events.
@MainActor
final class OrbitFloatingSidebarBackdrop: NSView {
    let fill = OrbitThemeFillView(materialRole: .floatingSidebar)
    private let dim = CALayer()
    private let edge = CAShapeLayer()
    var cornerRadius: CGFloat = OrbitTokens.Radius.floatingSidebar { didSet { needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        fill.translatesAutoresizingMaskIntoConstraints = true
        fill.autoresizingMask = [.width, .height]
        fill.frame = bounds
        addSubview(fill)
        fill.layer?.masksToBounds = true
        dim.zPosition = 2
        edge.zPosition = 3
        edge.fillColor = nil
        edge.lineWidth = 1
        fill.layer?.addSublayer(dim)
        fill.layer?.addSublayer(edge)
        fill.onMaterialChange = { [weak self] in self?.refreshColors() }
        refreshColors()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        fill.frame = bounds
        // : a 1 pt ring, inside the panel.
        let edgeWidth: CGFloat = fill.glassStyle.emphasizesBoundary ? 2 : 1
        let inset = edgeWidth / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.materialCornerRadius = cornerRadius
        fill.layer?.cornerRadius = cornerRadius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        dim.frame = fill.bounds
        edge.lineWidth = edgeWidth
        edge.frame = fill.bounds
        edge.path = CGPath(roundedRect: fill.bounds.insetBy(dx: inset, dy: inset),
                           cornerWidth: max(0, cornerRadius - inset), cornerHeight: max(0, cornerRadius - inset), transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        guard let layer else { return }
        OrbitTokens.Shadow.floatingSidebar.apply(to: layer, appearance: effectiveAppearance)
        edge.strokeColor = (fill.glassStyle.emphasizesBoundary ? NSColor.labelColor : OrbitTokens.Color.Line.sidebarBorder)
            .resolvedCGColor(for: effectiveAppearance)
        needsLayout = true
        dim.backgroundColor = OrbitTokens.Color.State.floatingSidebarDim.resolvedCGColor(for: effectiveAppearance)
    }

    /// Overlay that darkens the theme fill inside the panel (tests).
    var dimColor: CGColor? { dim.backgroundColor }
}
