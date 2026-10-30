import AppKit
import QuartzCore

@MainActor
final class OrbitThemeFillView: NSView {
    private let host = CALayer()
    private let gradient = CAGradientLayer()
    private let mesh = CALayer()
    private let grain = OrbitGrainLayer()
    private(set) var theme: OrbitTokens.SpaceTheme = .default
    var grainNeedsDisplay: Bool { grain.needsDisplay() }
    /// The window-sized gradient this view shows a part of. The floating sidebar backdrop sets the
    /// window content size and its own top-left offset so its fill matches the window fill.
    var windowFillSize: CGSize? { didSet { needsLayout = true } }
    var offsetInWindowFill: CGPoint = .zero { didSet { needsLayout = true } }
    var onAppearanceChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.addSublayer(gradient)
        host.addSublayer(mesh)
        host.addSublayer(grain)
        wantsLayer = true
        layer?.addSublayer(host)
        gradient.locations = [0, 0.5, 1]
        grain.isHidden = true
        refreshColors()
        layoutLayers()
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
        let size = windowFillSize ?? bounds.size
        // Layer coordinates of a hosted root layer have their origin at the bottom-left.
        let fill = CGRect(x: -offsetInWindowFill.x,
                          y: offsetInWindowFill.y + bounds.height - size.height,
                          width: size.width, height: size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.frame = bounds
        gradient.frame = fill
        mesh.frame = fill
        applyEndpoints()
        grain.frame = host.bounds
        CATransaction.commit()
    }

    /// The axis depends on the window size and, for the default theme, on the appearance (its flat
    /// start differs in light and dark).
    private func applyEndpoints() {
        let size = windowFillSize ?? bounds.size
        let isDark = OrbitAppearance.isDark(effectiveAppearance)
        if let positions = theme.model?.gradient(isDark: isDark).locations, positions.count == 3 {
            gradient.locations = positions.map { NSNumber(value: $0) }
        } else { gradient.locations = [0, 0.5, 1] }
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
        refreshColors()
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

    func apply(_ newTheme: OrbitTokens.SpaceTheme, fade: TimeInterval? = nil) {
        guard newTheme != theme else { return }
        let previous = (gradient.presentation() ?? gradient).colors
        theme = newTheme
        refreshColors()
        if let fade, fade > 0, let previous {
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = previous
            animation.toValue = gradient.colors
            animation.duration = fade
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            gradient.add(animation, forKey: Self.themeFadeKey)
        }
    }

    /// Progress-driven fills must replace, rather than queue behind, a previous theme fade.
    /// Orbit's Metal configuration setter invalidates its layer
    /// its asynchronous display path does not attach a separate Core Animation colour fade.
    func applyInteractiveTheme(_ newTheme: OrbitTokens.SpaceTheme) {
        gradient.removeAnimation(forKey: Self.themeFadeKey)
        apply(newTheme, fade: nil)
    }

    static func meshImage(_ colors: [NSColor]) -> CGImage? {
        let side = 64
        let c = colors.map { [$0.redComponent, $0.greenComponent, $0.blueComponent] }
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let u = CGFloat(x) / CGFloat(side - 1), v = CGFloat(y) / CGFloat(side - 1)
                for channel in 0..<3 {
                    let top = c[0][channel] * (1 - u) + c[1][channel] * u
                    let bottom = c[2][channel] * (1 - u) + c[3][channel] * u
                    bytes[(y * side + x) * 4 + channel] = UInt8((min(1, max(0, top * (1 - v) + bottom * v)) * 255).rounded())
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func refreshColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = resolvedStops
        gradient.isHidden = theme.meshCorners != nil
        mesh.isHidden = theme.meshCorners == nil
        if let corners = theme.meshCorners {
            mesh.contents = Self.meshImage(corners.map { $0.resolved(for: effectiveAppearance) })
        } else { mesh.contents = nil }
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

final class OrbitGrainLayer: CALayer {
    /// Strength is composited by Core Animation; editing it must not redraw the tiled backing.
    var intensity: CGFloat = 0 {
        didSet { opacity = Float(min(1, max(0, intensity)) * Self.maximumOpacity) }
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

    static let tileSide = 512
    static let maximumOpacity: CGFloat = 0.15

    /// Fine RGB noise. Strength scales its mean and variation together without changing the
    /// texture or invalidating the backing store. Channels remain independent at Retina resolution.
    static let tile: CGImage? = {
        let side = tileSide
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func uniform() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(seed >> 11) + 0.5) / 9_007_199_254_740_992
        }
        let kernel = [-0.04, 0.22, 1, 0.22, -0.04]
        let variance = kernel.reduce(0) { $0 + $1 * $1 }
        let means = [0.57, 0.532, 0.524], deviations = [0.284, 0.244, 0.244]
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for channel in 0..<3 {
            var noise = [Double](repeating: 0, count: side * side)
            for i in stride(from: 0, to: noise.count, by: 2) {
                let radius = sqrt(-2 * log(uniform())), angle = 2 * Double.pi * uniform()
                noise[i] = radius * cos(angle)
                noise[i + 1] = radius * sin(angle)
            }
            var horizontal = noise
            for y in 0..<side {
                for x in 0..<side {
                    horizontal[y * side + x] = kernel.indices.reduce(0) { sum, k in
                        sum + kernel[k] * noise[y * side + (x + k - 2 + side) % side]
                    }
                }
            }
            for y in 0..<side {
                for x in 0..<side {
                    let sample = kernel.indices.reduce(0) { sum, k in
                        sum + kernel[k] * horizontal[((y + k - 2 + side) % side) * side + x]
                    } / variance
                    let value = min(1, max(0, means[channel] + deviations[channel] * sample))
                    pixels[(y * side + x) * 4 + channel] = UInt8((value * 255).rounded())
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}

@MainActor
final class OrbitFloatingSidebarBackdrop: NSView {
    let fill = OrbitThemeFillView()
    private let dim = CALayer()
    private let edge = CAShapeLayer()
    private let observers = OrbitWorkspaceObservers()
    var foreground: NSColor = OrbitTokens.Color.Text.primary { didSet { refreshColors() } }
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
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshColors() }
        }
        observers.tokens.append((center, observer))
        refreshColors()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        fill.frame = bounds
        // : a 1 pt ring, inside the panel.
        let edgeWidth: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1
        let inset = edgeWidth / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
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
        edge.strokeColor = foreground.withAlphaComponent(0.12)
            .resolvedCGColor(for: effectiveAppearance)
        needsLayout = true
        dim.backgroundColor = OrbitTokens.Color.State.floatingSidebarDim.resolvedCGColor(for: effectiveAppearance)
    }

    /// Overlay that darkens the theme fill inside the panel (tests).
    var dimColor: CGColor? { dim.backgroundColor }
}
