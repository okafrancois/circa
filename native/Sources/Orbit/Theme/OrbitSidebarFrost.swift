import AppKit

/// A one-percent search keeps each Space's material as clear as its ink permits.
/// Samples include every stop, interpolants and mesh corners, ignoring blur's extra protection.
@MainActor
enum OrbitSidebarFrost {
    static let minimum: CGFloat = 0.12
    static let maximum: CGFloat = 0.85
    static let step: CGFloat = 0.01
    private struct Entry {
        let theme: OrbitTokens.SpaceTheme
        let dark: Bool
        let variant: OrbitFloatingMaterial.Variant
        let opacity: CGFloat
    }
    private static var cache: [Entry] = []

    static func samples(_ theme: OrbitTokens.SpaceTheme, appearance: NSAppearance) -> [NSColor] {
        if theme.meshCorners != nil {
            return (0...20).flatMap { y in
                (0...20).map { x in
                    OrbitThemeGradient.color(theme, at: CGPoint(x: CGFloat(x) / 20, y: CGFloat(y) / 20), appearance: appearance)
                }
            }
        }
        let stops = OrbitThemeGradient.normalizedStops(theme.stops, appearance: appearance).compactMap { NSColor(cgColor: $0) }
        return zip(stops, stops.dropFirst()).flatMap { a, b in
            (0...64).map { OrbitFloatingMaterial.composite(b, opacity: CGFloat($0) / 64, over: a) }
        }
    }

    static func passes(_ opacity: CGFloat, samples: [NSColor], style: OrbitFloatingMaterial.Style) -> Bool {
        var candidate = style
        candidate.sidebarTintOpacity = opacity
        return samples.allSatisfy { fill in
            [false, true].allSatisfy { highlight in
                let background = candidate.background(over: fill, highlight: highlight)
                return [candidate.body, candidate.secondary].allSatisfy { OrbitFloatingMaterial.contrast($0, background) >= 4.5 }
            }
        }
    }

    static func opacity(theme: OrbitTokens.SpaceTheme, appearance: NSAppearance, style: OrbitFloatingMaterial.Style) -> CGFloat {
        let dark = OrbitAppearance.isDark(appearance)
        if let entry = cache.last(where: { $0.theme == theme && $0.dark == dark && $0.variant == style.variant }) { return entry.opacity }
        let fills = samples(theme, appearance: appearance)
        // Accessibility can change after the first paint. Cache the translucent requirement,
        // even when the current surface is temporarily opaque.
        let translucent = OrbitFloatingMaterial.Style(variant: style.variant, reducesTransparency: false)
        let result = (Int((minimum * 100).rounded())...Int((maximum * 100).rounded()))
            .map { CGFloat($0) / 100 }.first { passes($0, samples: fills, style: translucent) } ?? maximum
        if cache.count >= 256 { cache.removeAll() }
        cache.append(.init(theme: theme, dark: dark, variant: style.variant, opacity: result))
        return result
    }
}
