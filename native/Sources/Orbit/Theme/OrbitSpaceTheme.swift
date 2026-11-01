import AppKit
import BrowserCore

@MainActor
enum OrbitSpaceThemes {
    typealias Resolver = @MainActor (_ space: BrowserSpace, _ index: Int) -> OrbitTokens.SpaceTheme

    static var resolver: Resolver = { _, index in defaultTheme(at: index) }
    /// Dedicated charcoal appearance, independent of the selected normal Space or system mode.
    static let privateWindow = OrbitTokens.SpaceTheme(stops: [
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)
    ], mode: .dark, texture: .none, textureIntensity: 0)

    static let previewFlag = ProcessInfo.processInfo.arguments.contains("--theme-preview")
    static let previewThemes: [OrbitTokens.SpaceTheme] = [.default, .amberCoral, .lavender, .rosePlum, .limeCitrus]

    static func defaultTheme(at index: Int, preview: Bool = previewFlag) -> OrbitTokens.SpaceTheme {
        preview ? previewThemes[index % previewThemes.count] : .default
    }

    /// Theme of a Space: stored theme, else `legacy` (the Settings palette), else the resolver; the
    /// default fill while the catalog is unknown.
    static func theme(forSpace id: SpaceID?, in catalog: BrowserCatalogSnapshot?,
                      legacy: OrbitTokens.SpaceTheme? = nil) -> OrbitTokens.SpaceTheme {
        guard let catalog, let index = catalog.spaces.firstIndex(where: { $0.id == id }) else { return legacy ?? .default }
        let space = catalog.spaces[index]
        if let stored = space.theme { return rendered(stored) }
        return legacy ?? resolver(space, index)
    }

    // MARK: Stored themes

    private static var renderedThemes: [BrowserSpaceTheme: OrbitTokens.SpaceTheme] = [:]

    /// Fill of a stored theme. Each stop is one dynamic colour (light variant under aqua, dark under
    /// darkAqua); its name encodes both components exactly, because `NSColor` compares dynamic colours
    /// by name. Cached so an unchanged model always yields an equal fill (no needless repaint).
    static func rendered(_ model: BrowserSpaceTheme) -> OrbitTokens.SpaceTheme {
        if let cached = renderedThemes[model] { return cached }
        var lightStops = model.light.stops.map(color)
        var darkStops = model.dark.stops.map(color)
        if lightStops.count != darkStops.count {
            // Normalize each gradient independently before pairing dynamic stops. Padding a shorter
            // variant with its last stop would move that endpoint to the middle of the painted fill.
            let appearance = NSAppearance(named: .aqua)!
            lightStops = OrbitThemeGradient.normalizedStops(lightStops, appearance: appearance).map { NSColor(cgColor: $0)! }
            darkStops = OrbitThemeGradient.normalizedStops(darkStops, appearance: appearance).map { NSColor(cgColor: $0)! }
        }
        let stops = zip(lightStops, darkStops).map { lightColor, darkColor -> NSColor in
            let light = colorKey(lightColor), dark = colorKey(darkColor)
            let name = "Orbit.Theme.space.\(light).\(dark)"
            return NSColor(name: NSColor.Name(name)) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
            }
        }
        let mode: OrbitTokens.SpaceTheme.Mode = switch model.mode {
        case .automatic: .automatic
        case .light: .light
        case .dark: .dark
        }
        var theme = OrbitTokens.SpaceTheme(
            stops: stops, mode: mode, texture: model.noise > 0 ? .grain : .none, textureIntensity: CGFloat(model.noise),
            stopRange: .init(light: CGFloat(model.light.start)...CGFloat(model.light.end),
                             dark: CGFloat(model.dark.start)...CGFloat(model.dark.end)),
            angle: .init(light: CGFloat(model.light.angleDegrees), dark: CGFloat(model.dark.angleDegrees)),
            model: model)
        // Retain the legacy stored field for decoding, but never apply material to controls.
        theme.frostAmount = 0
        if model.paletteVersion == 2, model.colors.count == 3 {
            theme.meshCorners = OrbitThemeMesh.corners(model).map(color)
        }
        if renderedThemes.count >= 256 { renderedThemes.removeAll() }
        renderedThemes[model] = theme
        return theme
    }

    /// AppKit colour of a stored component set, in its own colour space.
    static func color(_ value: BrowserThemeColor) -> NSColor {
        let (r, g, b, a) = (CGFloat(value.red), CGFloat(value.green), CGFloat(value.blue), CGFloat(value.alpha))
        switch value.space {
        case .sRGB: return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        case .displayP3: return NSColor(displayP3Red: r, green: g, blue: b, alpha: a)
        }
    }

    private static func colorKey(_ value: NSColor) -> String {
        let components = value.usingColorSpace(.sRGB) ?? value
        return [components.redComponent, components.greenComponent, components.blueComponent, components.alphaComponent]
            .map { String(Double($0)) }.joined(separator: "-")
    }

    // MARK: Accent

    private static var accentCache: [(theme: OrbitTokens.SpaceTheme, accent: OrbitTokens.ThemeAccent)] = []

    static func accent(for theme: OrbitTokens.SpaceTheme) -> OrbitTokens.ThemeAccent {
        if let cached = accentCache.last(where: { $0.theme == theme }) { return cached.accent }
        var accent: OrbitTokens.ThemeAccent
        if let model = theme.model {
            switch model.accentFamily {
            case .defaultSpace: accent = .defaultSpace
            case let .derived(hue, saturation, strong):
                accent = .derived(hue: CGFloat(hue), saturation: CGFloat(saturation), strong: strong.map(color))
            }
        } else if theme == .default { accent = .defaultSpace }
        else if let base = theme.stops.compactMap({ $0.usingColorSpace(.sRGB) }).max(by: { $0.saturationComponent < $1.saturationComponent }) {
            accent = .derived(hue: base.hueComponent)
        } else { accent = .defaultSpace }
        let foreground = theme.foregroundOverride ?? NSColor(name: nil) { appearance in
            MainActor.assumeIsolated {
                let background = OrbitThemeGradient.representativeColor(theme, appearance: appearance)
                return OrbitThemeForeground.color(on: background)
            }
        }
        accent.sidebarText = foreground
        accent.icon = foreground
        accent.iconFill = NSColor(name: nil) { appearance in
            MainActor.assumeIsolated { OrbitThemeGradient.representativeColor(theme, appearance: appearance) }
        }
        accent.contrastTheme = theme
        if accentCache.count >= 256 { accentCache.removeAll() }
        accentCache.append((theme, accent))
        return accent
    }

    /// Overlays never make a separate foreground decision.
    static func accent(_ source: OrbitTokens.ThemeAccent, over overlays: [NSColor],
                       iconHover: NSColor? = nil) -> OrbitTokens.ThemeAccent { source }

    static func inactiveSpaceIconOpacity(for accent: OrbitTokens.ThemeAccent, appearance: NSAppearance,
                                         minimum: CGFloat) -> CGFloat { minimum }

}

/// Gradient geometry of the window fill.
enum OrbitThemeGradient {
    @MainActor
    static func representativeColor(_ theme: OrbitTokens.SpaceTheme, appearance: NSAppearance) -> NSColor {
        color(theme, at: CGPoint(x: 210.0 / 1512, y: 217.0 / 949), appearance: appearance)
    }

    @MainActor
    static func color(_ theme: OrbitTokens.SpaceTheme, at point: CGPoint, appearance: NSAppearance) -> NSColor {
        let corners = theme.meshCorners?.map { $0.resolved(for: appearance) }
        func mix(_ a: NSColor, _ b: NSColor, _ p: CGFloat) -> NSColor {
            NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * p,
                    green: a.greenComponent + (b.greenComponent - a.greenComponent) * p,
                    blue: a.blueComponent + (b.blueComponent - a.blueComponent) * p, alpha: 1)
        }
        if let c = corners {
            return mix(mix(c[0], c[1], point.x), mix(c[2], c[3], point.x), point.y)
        }
        let stops = normalizedStops(theme.stops, appearance: appearance).map { NSColor(cgColor: $0)!.usingColorSpace(.sRGB)! }
        let dark = OrbitAppearance.isDark(appearance), range = theme.stopRange.range(isDark: dark)
        let f = axisFraction(of: CGPoint(x: point.x * 1512, y: point.y * 949), in: CGSize(width: 1512, height: 949),
                             angleDegrees: theme.angle.degrees(isDark: dark))
        let t = min(1, max(0, (f - range.lowerBound) / (range.upperBound - range.lowerBound)))
        let locations = theme.model?.gradient(isDark: dark).locations ?? [0, 0.5, 1]
        if locations.count == 3 {
            let i = t < CGFloat(locations[1]) ? 0 : 1
            let lower = CGFloat(locations[i]), upper = CGFloat(locations[i + 1])
            return mix(stops[i], stops[i + 1], (t - lower) / (upper - lower))
        }
        let index = min(1, Int(t * 2))
        return mix(stops[index], stops[index + 1], t * 2 - CGFloat(index))
    }

    /// Unit start and end points (unflipped layer: origin at the bottom-left) of a theme painted over a
    /// window-sized fill of `size`. : the axis runs at 43° in points from the
    /// top-left corner; the first stop sits at `range.lowerBound` and the last at `range.upperBound` of the
    /// window's projection on the axis, the layer keeping the extreme colours flat beyond them. Other
    /// angles start from the window corner with the lowest projection (stored themes).
    /// `CAGradientLayer` interpolates in its unit square stretched over the bounds (isolines are
    /// perpendicular in unit space), so the points-space axis is converted: with u = x / W, v = y / H,
    /// the axis coordinate f = (W·cos a·u + H·sin a·v − min) / L is linear in unit space along g.
    static func endpoints(size: CGSize, range: ClosedRange<CGFloat>,
                          angleDegrees: CGFloat = OrbitTokens.SpaceTheme.Gradient.angleDegrees) -> (start: CGPoint, end: CGPoint) {
        guard size.width > 0, size.height > 0 else { return (CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)) }
        let angle = angleDegrees * .pi / 180
        let length = OrbitTokens.SpaceTheme.Gradient.axisLength(for: size, angleDegrees: angleDegrees)
        let g = CGPoint(x: size.width * cos(angle) / length, y: size.height * sin(angle) / length)
        let norm = g.x * g.x + g.y * g.y
        let origin = CGPoint(x: g.x < 0 ? 1 : 0, y: g.y < 0 ? 1 : 0)
        func point(_ fraction: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + fraction * g.x / norm, y: 1 - (origin.y + fraction * g.y / norm))
        }
        return (point(range.lowerBound), point(range.upperBound))
    }

    /// Fraction of the axis at a window point (top-left origin, points): 0 at the corner with the lowest
    /// projection (top-left at 43°), 1 at the opposite one. Used by tests and diagnostics.
    static func axisFraction(of point: CGPoint, in size: CGSize,
                             angleDegrees: CGFloat = OrbitTokens.SpaceTheme.Gradient.angleDegrees) -> CGFloat {
        let angle = angleDegrees * .pi / 180
        let minimum = min(0, size.width * cos(angle)) + min(0, size.height * sin(angle))
        return (point.x * cos(angle) + point.y * sin(angle) - minimum)
            / OrbitTokens.SpaceTheme.Gradient.axisLength(for: size, angleDegrees: angleDegrees)
    }

    /// Three stops for every theme, so `CAGradientLayer` can animate `colors` between themes with a
    /// different stop count. A two-stop gradient gets its exact linear midpoint.
    @MainActor
    static func normalizedStops(_ stops: [NSColor], appearance: NSAppearance) -> [CGColor] {
        let resolved = stops.map { $0.resolved(for: appearance) }
        switch resolved.count {
        case 0:
            let fill = OrbitTokens.Color.Surface.windowDefault.resolvedCGColor(for: appearance)
            return [fill, fill, fill]
        case 1:
            return Array(repeating: resolved[0].cgColor, count: 3)
        case 2:
            let a = resolved[0], b = resolved[1]
            let middle = NSColor(srgbRed: (a.redComponent + b.redComponent) / 2, green: (a.greenComponent + b.greenComponent) / 2,
                                 blue: (a.blueComponent + b.blueComponent) / 2, alpha: (a.alphaComponent + b.alphaComponent) / 2)
            return [a.cgColor, middle.cgColor, b.cgColor]
        default:
            return resolved.prefix(3).map(\.cgColor)
        }
    }
}

/// One encoded Rec. 709 luma decision for all chrome consumers.
enum OrbitThemeForeground {
    enum Consumer: CaseIterable {
        case sidebarText, icons, urlText, urlIcons, newTab, footer, spaceTitle, buttons, scrollIndicators, frameEdges
    }
    static func isLight(on color: NSColor) -> Bool {
        let c = color.usingColorSpace(.sRGB)!
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 128.0 / 255
    }
    static func color(on color: NSColor) -> NSColor {
        NSColor(srgbRed: isLight(on: color) ? 244.0 / 255 : 32.0 / 255,
                green: isLight(on: color) ? 244.0 / 255 : 32.0 / 255,
                blue: isLight(on: color) ? 244.0 / 255 : 32.0 / 255, alpha: 1)
    }

    static func contrastRatio(_ foreground: NSColor, on background: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            let c = color.usingColorSpace(.sRGB)!
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func composite(_ overlay: NSColor, on background: NSColor) -> NSColor {
        let a = overlay.usingColorSpace(.sRGB)!, b = background.usingColorSpace(.sRGB)!, p = a.alphaComponent
        return NSColor(srgbRed: a.redComponent * p + b.redComponent * (1 - p),
                       green: a.greenComponent * p + b.greenComponent * (1 - p),
                       blue: a.blueComponent * p + b.blueComponent * (1 - p), alpha: 1)
    }

    /// Keep the shared ink decision legible on state overlays too. Use the existing overlay
    /// variant for that ink polarity, reducing opacity only when the composited contrast needs it.
    @MainActor
    static func rowOverlay(_ overlay: NSColor?, theme: OrbitTokens.SpaceTheme, foreground: NSColor) -> NSColor? {
        guard let overlay else { return nil }
        return NSColor(name: nil) { appearance in
            MainActor.assumeIsolated {
                let ink = foreground.resolved(for: appearance)
                let mode = NSAppearance(named: isLight(on: ink) ? .aqua : .darkAqua)!
                let tint = overlay.resolved(for: mode)
                let fill = OrbitThemeGradient.representativeColor(theme, appearance: appearance)
                if contrastRatio(ink, on: composite(tint, on: fill)) >= 3 { return tint }
                var lower: CGFloat = 0, upper = tint.alphaComponent
                for _ in 0..<16 {
                    let alpha = (lower + upper) / 2
                    if contrastRatio(ink, on: composite(tint.withAlphaComponent(alpha), on: fill)) >= 3 {
                        lower = alpha
                    } else { upper = alpha }
                }
                return tint.withAlphaComponent(lower)
            }
        }
    }

}

/// Bilinear two-axis fill. Coefficients are expressed in top-left unit window coordinates.
enum OrbitThemeMesh {
    static func weights(at p: CGPoint) -> [Double] {
        let x = Double(p.x), y = Double(p.y)
        let a = 0.208462371 + 0.610695848 * x - 0.204683029 * y - 0.465096687 * x * y
        let b = 0.017415097 - 0.053193210 * x + 0.903819437 * y + 0.005882076 * x * y
        return [a, b, 1 - a - b]
    }
    static func corners(_ model: BrowserSpaceTheme) -> [BrowserThemeColor] {
        let colors = model.colors.map { BrowserRadialThemePalette.intensityAdjusted($0.sRGB, intensity: model.intensity, calibratedAt: 1) }
        return [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map { point in
            let w = weights(at: point)
            func channel(_ component: (BrowserThemeColor) -> Double) -> Double {
                let value = zip(w, colors).reduce(0) { $0 + $1.0 * component($1.1) }
                return min(1, max(0, value - 8.0 / 255 + (model.mode == .light ? 15.0 / 255 : 0)))
            }
            return BrowserThemeColor(red: channel { $0.red }, green: channel { $0.green }, blue: channel { $0.blue })
        }
    }
}
