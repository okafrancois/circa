import AppKit

/// Orbit's WindowLayoutController maps pager offset/width to clamped progress between the adjacent
/// pages and supplies it to the theme renderer .
/// This is a paint input, not a selection-commit animation. Do not add a time delay or a midpoint
/// threshold from video latency; the renderer receives the current pager progress on both routes.
/// Captured endpoints retain both appearances; hot appearance changes never reuse stale CGColors.
@MainActor
struct SpaceSwipeThemeBlend {
    let source: OrbitTokens.SpaceTheme
    let destination: OrbitTokens.SpaceTheme
    let progress: CGFloat

    var theme: OrbitTokens.SpaceTheme {
        // Each endpoint owns its appearance. In particular a fixed dark destination must
        // never borrow the outgoing window's light variant before selection publication.
        let source = Self.endpoint(source)
        let destination = Self.endpoint(destination)
        let p = min(1, max(0, progress))
        if p == 0 { return source }
        if p == 1 { return destination }
        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!
        let sourceLight = OrbitThemeGradient.normalizedStops(source.stops, appearance: light)
        let targetLight = OrbitThemeGradient.normalizedStops(destination.stops, appearance: light)
        let sourceDark = OrbitThemeGradient.normalizedStops(source.stops, appearance: dark)
        let targetDark = OrbitThemeGradient.normalizedStops(destination.stops, appearance: dark)
        func blend(_ a: CGColor, _ b: CGColor) -> NSColor {
            let a = NSColor(cgColor: a)!.usingColorSpace(.sRGB)!
            let b = NSColor(cgColor: b)!.usingColorSpace(.sRGB)!
            return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * p,
                           green: a.greenComponent + (b.greenComponent - a.greenComponent) * p,
                           blue: a.blueComponent + (b.blueComponent - a.blueComponent) * p,
                           alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * p)
        }
        var result = source
        result.model = nil
        result.stops = (0..<3).map { index in
            let light = blend(sourceLight[index], targetLight[index])
            let dark = blend(sourceDark[index], targetDark[index])
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        }
        // Decide polarity from this frame's fill. Fading opposing foregrounds through grey
        // makes both endpoints unreadable around the middle of a transition.
        result.foregroundOverride = nil
        if source.meshCorners != nil || destination.meshCorners != nil {
            let points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
            result.meshCorners = points.map { point in
                let l = blend(OrbitThemeGradient.color(source, at: point, appearance: light).cgColor,
                              OrbitThemeGradient.color(destination, at: point, appearance: light).cgColor)
                let d = blend(OrbitThemeGradient.color(source, at: point, appearance: dark).cgColor,
                              OrbitThemeGradient.color(destination, at: point, appearance: dark).cgColor)
                return NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
                }
            }
        }
        func interpolate(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        result.stopRange.light = interpolate(source.stopRange.light.lowerBound, destination.stopRange.light.lowerBound)...interpolate(source.stopRange.light.upperBound, destination.stopRange.light.upperBound)
        result.stopRange.dark = interpolate(source.stopRange.dark.lowerBound, destination.stopRange.dark.lowerBound)...interpolate(source.stopRange.dark.upperBound, destination.stopRange.dark.upperBound)
        result.angle.light = interpolate(source.angle.light, destination.angle.light)
        result.angle.dark = interpolate(source.angle.dark, destination.angle.dark)
        let sourceIntensity = source.texture == .none ? 0 : source.textureIntensity
        let targetIntensity = destination.texture == .none ? 0 : destination.textureIntensity
        result.texture = .grain
        result.textureIntensity = interpolate(sourceIntensity, targetIntensity)
        return result
    }

    /// Fixed modes become appearance-independent paint; automatic endpoints remain dynamic.
    /// The window follows the system while blending so automatic does not inherit a neighbor's mode.
    private static func endpoint(_ theme: OrbitTokens.SpaceTheme) -> OrbitTokens.SpaceTheme {
        guard let appearance = OrbitAppearance.windowAppearance(for: theme.mode) else { return theme }
        return snapshot(theme, appearance: appearance)
    }

    /// Retarget from the last submitted paint, including an interrupted blend, without resolving
    /// it again after the window adopts another Space's appearance.
    static func snapshot(_ theme: OrbitTokens.SpaceTheme, appearance: NSAppearance) -> OrbitTokens.SpaceTheme {
        var result = theme
        result.stops = theme.stops.map { $0.resolved(for: appearance) }
        result.meshCorners = theme.meshCorners?.map { $0.resolved(for: appearance) }
        result.foregroundOverride = OrbitSpaceThemes.accent(for: theme).foreground.resolved(for: appearance)
        let dark = OrbitAppearance.isDark(appearance)
        let range = theme.stopRange.range(isDark: dark)
        let angle = theme.angle.degrees(isDark: dark)
        result.stopRange = .init(light: range, dark: range)
        result.angle = .init(light: angle, dark: angle)
        result.mode = .automatic
        result.model = nil
        return result
    }

}
