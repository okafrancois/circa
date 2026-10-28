import AppKit
import BrowserCore

/// Hook between the Space model and the window fill (ORBIT-THEMES).
/// A Space's stored theme (`BrowserSpace.theme`, session version 4) wins; a never-themed Space falls
/// back to its legacy Settings palette, then to `resolver` — `SpaceTheme.default` ('s
/// default two-stop gradient, ). The `--theme-preview` validation flag cycles
/// the examples measured in S-DEMO across never-themed Spaces so the gradient, grain and Space-switch
/// fade can be checked visibly.
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
        let theme = OrbitTokens.SpaceTheme(
            stops: stops, mode: mode, texture: model.noise > 0 ? .grain : .none, textureIntensity: CGFloat(model.noise),
            stopRange: .init(light: CGFloat(model.light.start)...CGFloat(model.light.end),
                             dark: CGFloat(model.dark.start)...CGFloat(model.dark.end)),
            angle: .init(light: CGFloat(model.light.angleDegrees), dark: CGFloat(model.dark.angleDegrees)),
            model: model, surface: model.surface)
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

    /// Accent family of a theme. The default Space uses the family measured on 's default
    /// Space (, D32). A stored theme follows its model's provisional rule
    /// (`BrowserSpaceTheme.accentFamily`, C06 [L]); other token themes derive theirs from the hue of
    /// their most saturated stop (S/B pairs measured on the default Space, mapping  C06).
    private static var accentThemes: [(theme: OrbitTokens.SpaceTheme, accent: OrbitTokens.ThemeAccent)] = []

    static func accent(for theme: OrbitTokens.SpaceTheme) -> OrbitTokens.ThemeAccent {
        if let cached = accentThemes.last(where: { $0.theme == theme }) { return cached.accent }
        var accent = adjusted(accentFamily(for: theme), theme: theme, overlays: [], iconHover: nil)
        accent.contrastTheme = theme
        if accentThemes.count >= 256 { accentThemes.removeAll() }
        accentThemes.append((theme, accent))
        return accent
    }

    private struct OverlayAccent {
        let source: OrbitTokens.ThemeAccent
        let overlays: [NSColor]
        let iconHover: NSColor?
        let result: OrbitTokens.ThemeAccent
    }
    private static var overlayAccents: [OverlayAccent] = []

    /// Reconstruction: foregrounds follow the actual source-over background, preserving measured fills.
    /// The extra button hover is included in the icon range without changing the row's text tier.
    /// Cache both appearances together; pointer state changes never repeat the gradient optimisation.
    static func accent(_ source: OrbitTokens.ThemeAccent, over overlays: [NSColor],
                       iconHover: NSColor? = nil) -> OrbitTokens.ThemeAccent {
        guard let theme = source.contrastTheme, !overlays.isEmpty || iconHover != nil else { return source }
        if let cached = overlayAccents.last(where: {
            $0.source == source && $0.overlays == overlays && $0.iconHover == iconHover
        }) { return cached.result }
        let result = adjusted(source, theme: theme, overlays: overlays, iconHover: iconHover)
        if overlayAccents.count >= 1024 { overlayAccents.removeAll() }
        overlayAccents.append(OverlayAccent(source: source, overlays: overlays, iconHover: iconHover, result: result))
        return result
    }

    private struct InactiveIconOpacity {
        let accent: OrbitTokens.ThemeAccent
        let isDark: Bool
        let minimum: CGFloat
        let opacity: CGFloat
    }
    private static var inactiveIconOpacities: [InactiveIconOpacity] = []

    /// Inactive Space buttons remain enabled. Keep their measured dimming only when the painted
    /// result still reaches the secondary contrast tier, including the button's hover background.
    static func inactiveSpaceIconOpacity(for accent: OrbitTokens.ThemeAccent, appearance: NSAppearance,
                                         minimum: CGFloat) -> CGFloat {
        guard let theme = accent.contrastTheme else { return minimum }
        let isDark = OrbitAppearance.isDark(appearance)
        if let cached = inactiveIconOpacities.last(where: {
            $0.accent == accent && $0.isDark == isDark && $0.minimum == minimum
        }) { return cached.opacity }
        let stops = OrbitThemeGradient.normalizedStops(theme.stops, appearance: appearance).map {
            NSColor(cgColor: $0)!.usingColorSpace(.sRGB)!
        }
        let hover = OrbitTokens.Color.State.standaloneButton.resolved(for: appearance)
        var backgrounds: [NSColor] = []
        for (a, b) in zip(stops, stops.dropFirst()) {
            for index in 0...32 {
                let base = blended(a, b, fraction: CGFloat(index) / 32)
                backgrounds.append(base)
                backgrounds.append(composite(hover, on: base))
            }
        }
        let icon = accent.icon.resolved(for: appearance)
        func contrast(at opacity: CGFloat) -> CGFloat {
            backgrounds.map { background in
                let a = luminance(blended(background, icon, fraction: opacity)), b = luminance(background)
                return (max(a, b) + 0.05) / (min(a, b) + 0.05)
            }.min() ?? 1
        }
        let result: CGFloat
        if contrast(at: minimum) >= 3.05 { result = minimum }
        else if contrast(at: 1) < 3.05 { result = 1 }
        else {
            var start = minimum, end: CGFloat = 1
            for _ in 0..<24 {
                let middle = (start + end) / 2
                if contrast(at: middle) >= 3.05 { end = middle } else { start = middle }
            }
            result = end
        }
        if inactiveIconOpacities.count >= 256 { inactiveIconOpacities.removeAll() }
        inactiveIconOpacities.append(InactiveIconOpacity(accent: accent, isDark: isDark, minimum: minimum, opacity: result))
        return result
    }

    private static func adjusted(_ source: OrbitTokens.ThemeAccent, theme: OrbitTokens.SpaceTheme,
                                 overlays: [NSColor], iconHover: NSColor?) -> OrbitTokens.ThemeAccent {
        var accent = source
        let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
        func paintedStops(_ appearance: NSAppearance) -> [CGColor] {
            OrbitThemeGradient.normalizedStops(theme.stops, appearance: appearance).map { stop in
                var base = NSColor(cgColor: stop)!.usingColorSpace(.sRGB)!
                for overlay in overlays { base = composite(overlay.resolved(for: appearance), on: base) }
                return base.cgColor
            }
        }
        let lightStops = paintedStops(light), darkStops = paintedStops(dark)
        let lightRange = luminanceRange(lightStops), darkRange = luminanceRange(darkStops)
        func iconRange(_ stops: [CGColor], appearance: NSAppearance,
                       base: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
            guard let iconHover else { return base }
            let hover = iconHover.resolved(for: appearance)
            let range = luminanceRange(stops.map { composite(hover, on: NSColor(cgColor: $0)!.usingColorSpace(.sRGB)!).cgColor })
            return min(base.lowerBound, range.lowerBound)...max(base.upperBound, range.upperBound)
        }
        func corrected(_ preferred: NSColor, role: String, minimum: CGFloat,
                       lightRange: ClosedRange<CGFloat>, darkRange: ClosedRange<CGFloat>) -> NSColor {
            let a = preferred.resolved(for: light), b = preferred.resolved(for: dark)
            let correctedLight = contrasting(a, against: lightRange, minimum: minimum)
            let correctedDark = contrasting(b, against: darkRange, minimum: minimum)
            guard correctedLight != a || correctedDark != b else { return preferred }
            let name = "Orbit.Accent.contrast.\(role).\(colorKey(correctedLight)).\(colorKey(correctedDark))"
            return NSColor(name: NSColor.Name(name)) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? correctedDark : correctedLight
            }
        }
        accent.sidebarText = corrected(accent.sidebarText, role: "primary", minimum: 4.5,
                                       lightRange: lightRange, darkRange: darkRange)
        accent.icon = corrected(accent.icon, role: "secondary", minimum: 3,
                                lightRange: iconRange(lightStops, appearance: light, base: lightRange),
                                darkRange: iconRange(darkStops, appearance: dark, base: darkRange))
        let lightIcon = luminance(accent.icon.resolved(for: light)), darkIcon = luminance(accent.icon.resolved(for: dark))
        accent.iconFill = corrected(accent.iconFill, role: "iconFill", minimum: 3,
                                    lightRange: lightIcon...lightIcon, darkRange: darkIcon...darkIcon)
        return accent
    }

    private static func composite(_ overlay: NSColor, on base: NSColor) -> NSColor {
        let alpha = overlay.alphaComponent
        return NSColor(srgbRed: overlay.redComponent * alpha + base.redComponent * (1 - alpha),
                       green: overlay.greenComponent * alpha + base.greenComponent * (1 - alpha),
                       blue: overlay.blueComponent * alpha + base.blueComponent * (1 - alpha), alpha: 1)
    }

    private static func accentFamily(for theme: OrbitTokens.SpaceTheme) -> OrbitTokens.ThemeAccent {
        if let model = theme.model {
            switch model.accentFamily {
            case .defaultSpace: return .defaultSpace
            case let .derived(hue, saturation, strong):
                return .derived(hue: CGFloat(hue), saturation: CGFloat(saturation), strong: strong.map(color))
            }
        }
        guard theme != .default else { return .defaultSpace }
        let colours = theme.stops.compactMap { $0.usingColorSpace(.sRGB) }
        guard let base = colours.max(by: { $0.saturationComponent < $1.saturationComponent }),
              base.saturationComponent > 0.05 else { return .defaultSpace }
        return .derived(hue: base.hueComponent)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            let value = min(1, max(0, value))
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }

    private static func blended(_ a: NSColor, _ b: NSColor, fraction: CGFloat) -> NSColor {
        NSColor(srgbRed: a.redComponent * (1 - fraction) + b.redComponent * fraction,
                green: a.greenComponent * (1 - fraction) + b.greenComponent * fraction,
                blue: a.blueComponent * (1 - fraction) + b.blueComponent * fraction, alpha: 1)
    }

    /// Relative luminance is convex along each encoded-sRGB gradient segment. Its maximum lies at
    /// a stop, but its minimum can lie inside the segment (for example, a red-to-green gradient).
    private static func luminanceRange(_ stops: [CGColor]) -> ClosedRange<CGFloat> {
        let colors = stops.compactMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
        var lower = colors.map(luminance).min() ?? 0
        let upper = colors.map(luminance).max() ?? 1
        for (a, b) in zip(colors, colors.dropFirst()) {
            var start: CGFloat = 0, end: CGFloat = 1
            for _ in 0..<40 {
                let first = start + (end - start) / 3, second = end - (end - start) / 3
                if luminance(blended(a, b, fraction: first)) < luminance(blended(a, b, fraction: second)) {
                    end = second
                } else {
                    start = first
                }
            }
            lower = min(lower, luminance(blended(a, b, fraction: (start + end) / 2)))
        }
        return lower...upper
    }

    private static func contrasting(_ preferred: NSColor, against range: ClosedRange<CGFloat>, minimum: CGFloat) -> NSColor {
        func ratio(_ color: NSColor) -> CGFloat {
            let value = luminance(color)
            if range.contains(value) { return 1 }
            return value < range.lowerBound ? (range.lowerBound + 0.05) / (value + 0.05)
                                           : (value + 0.05) / (range.upperBound + 0.05)
        }
        guard ratio(preferred) < minimum else { return preferred }
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let extreme = ratio(black) >= ratio(white) ? black : white
        // A custom gradient can have no uniform foreground meeting the tier (the legacy rosePlum
        // preview also has this limitation). Keep the strongest polarity and preserve measured fills;
        // the default and all picker swatches meet their tiers on the tested row overlays.
        guard ratio(extreme) >= minimum + 0.02 else { return extreme }
        var start: CGFloat = 0, end: CGFloat = 1
        for _ in 0..<32 {
            let middle = (start + end) / 2
            if ratio(blended(preferred, extreme, fraction: middle)) >= minimum + 0.02 { end = middle }
            else { start = middle }
        }
        return blended(preferred, extreme, fraction: end)
    }
}

/// Gradient geometry of the window fill.
enum OrbitThemeGradient {
    /// Unit start and end points (unflipped layer: origin at the bottom-left) of a theme painted over a
    /// window-sized fill of `size`. : the axis runs at 43° in points from the
    /// top-left corner; the first stop sits at `range.lowerBound` and the last at `range.upperBound` of the
    /// window's projection on the axis, the layer keeping the extreme colours flat beyond them. Other
    /// angles start from the window corner with the lowest projection (stored themes, ORBIT-THEMES).
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
