import AppKit
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Space theme contrast and variant normalization regressions", .serialized)
@MainActor
struct NativeThemeContrastRegressionTests {
    @Test("Primary sidebar titles use the representative-background foreground on every swatch", arguments: [false, true])
    func primaryContrast(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        for (_, theme) in themes() {
            let background = OrbitThemeGradient.representativeColor(theme, appearance: appearance)
            let actual = OrbitSpaceThemes.accent(for: theme).sidebarText.resolved(for: appearance)
            #expect(actual == OrbitThemeForeground.color(on: background))
        }
    }

    @Test("Multicolour previews use the same representative-background decision", arguments: [false, true])
    func legacyGradientContrastLimit(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        for (_, theme) in themes() {
            let background = OrbitThemeGradient.representativeColor(theme, appearance: appearance)
            let actual = OrbitSpaceThemes.accent(for: theme).sidebarText.resolved(for: appearance)
            #expect(actual == OrbitThemeForeground.color(on: background))
        }
    }

    @Test("Secondary sidebar icons use the shared foreground on every swatch", arguments: [false, true])
    func secondaryIconContrast(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        for (_, theme) in themes() {
            let background = OrbitThemeGradient.representativeColor(theme, appearance: appearance)
            let actual = OrbitSpaceThemes.accent(for: theme).icon.resolved(for: appearance)
            #expect(actual == OrbitThemeForeground.color(on: background))
        }
    }

    @Test("Unequal light and dark stop counts preserve each variant's independent midpoint", arguments: [false, true])
    func unequalVariantStops(shortDarkVariant: Bool) throws {
        let short = BrowserSpaceTheme.Gradient(stops: [.init(hex: 0x204060), .init(hex: 0xA0C0E0)])
        let long = BrowserSpaceTheme.Gradient(stops: [.init(hex: 0x102030), .init(hex: 0x709050), .init(hex: 0xD0E0F0)])
        let model = BrowserSpaceTheme(mode: .automatic, colors: [], intensity: 0.5, noise: 0,
                                      light: shortDarkVariant ? long : short, dark: shortDarkVariant ? short : long)
        let theme = OrbitSpaceThemes.rendered(model)
        for isDark in [false, true] {
            let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
            let painted = OrbitThemeGradient.normalizedStops(theme.stops, appearance: appearance)
            let independent = OrbitThemeGradient.normalizedStops(model.gradient(isDark: isDark).stops.map(OrbitSpaceThemes.color),
                                                               appearance: appearance)
            #expect(painted.count == independent.count)
            for (actual, expected) in zip(painted, independent) {
                let a = try #require(NSColor(cgColor: actual)?.usingColorSpace(.sRGB))
                let b = try #require(NSColor(cgColor: expected)?.usingColorSpace(.sRGB))
                #expect(zip(components(a), components(b)).allSatisfy { abs($0 - $1) < 1e-6 },
                        "dark=\(isDark), shortDarkVariant=\(shortDarkVariant): every normalized stop must match")
            }
        }
    }

    private func themes() -> [(String, OrbitTokens.SpaceTheme)] {
        var result: [(String, OrbitTokens.SpaceTheme)] = [
            ("default", .default), ("legacyFlat", .legacyFlat), ("amberCoral", .amberCoral),
            ("lavender", .lavender), ("rosePlum", .rosePlum), ("limeCitrus", .limeCitrus),
            ("storedDefault", OrbitSpaceThemes.rendered(BrowserSpaceThemePresets.default)),
        ]
        for family in BrowserSpaceThemePresets.families {
            for index in family.swatches.indices {
                if let theme = BrowserSpaceThemePresets.theme(family: family, index: index) {
                    result.append((BrowserSpaceThemePresets.presetID(family: family, index: index), OrbitSpaceThemes.rendered(theme)))
                }
            }
        }
        return result
    }

    /// Sample the exact stops sent to the fill layer, including the interior of each sRGB segment.
    private func gradientSamples(_ theme: OrbitTokens.SpaceTheme, appearance: NSAppearance) throws -> [NSColor] {
        let stops = try OrbitThemeGradient.normalizedStops(theme.stops, appearance: appearance).map {
            try #require(NSColor(cgColor: $0)?.usingColorSpace(.sRGB))
        }
        return zip(stops, stops.dropFirst()).flatMap { a, b in
            (0...64).map { index in
                let t = CGFloat(index) / 64
                return NSColor(srgbRed: a.redComponent * (1 - t) + b.redComponent * t,
                               green: a.greenComponent * (1 - t) + b.greenComponent * t,
                               blue: a.blueComponent * (1 - t) + b.blueComponent * t,
                               alpha: a.alphaComponent * (1 - t) + b.alphaComponent * t)
            }
        }
    }

    private func components(_ color: NSColor) -> [CGFloat] {
        [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    }

    private func contrast(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        let alpha = foreground.alphaComponent
        let composed = NSColor(srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
                               green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
                               blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha), alpha: 1)
        let a = luminance(composed), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
}
