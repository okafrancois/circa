import AppKit
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Space theme contrast and variant normalization regressions", .serialized)
@MainActor
struct NativeThemeContrastRegressionTests {
    @Test("Primary sidebar titles retain 4.5 contrast on every picker preset and swatch", arguments: [false, true])
    func primaryContrast(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        // The legacy rose-plum preview spans a luminance range for which neither polarity can
        // reach 4.5 everywhere; its strongest possible foreground is covered separately below.
        for (name, theme) in themes().filter({ $0.0 != "rosePlum" }) {
            let foreground = OrbitSpaceThemes.accent(for: theme).sidebarText.resolved(for: appearance)
            let minimum = try gradientSamples(theme, appearance: appearance).map { contrast(foreground, $0) }.min()!
            #expect(minimum >= 4.5, "\(name), dark=\(isDark): primary contrast \(minimum)")
        }
    }

    @Test("The legacy rose-plum preview retains the strongest possible uniform foreground", arguments: [false, true])
    func legacyGradientContrastLimit(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        let theme = OrbitTokens.SpaceTheme.rosePlum
        let samples = try gradientSamples(theme, appearance: appearance)
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let strongest = max(samples.map { contrast(black, $0) }.min()!, samples.map { contrast(white, $0) }.min()!)
        let foreground = OrbitSpaceThemes.accent(for: theme).sidebarText.resolved(for: appearance)
        #expect(strongest < 4.5, "this legacy measured gradient cannot support a uniform 4.5 foreground")
        #expect(samples.map { contrast(foreground, $0) }.min()! >= strongest - 1e-6)
    }

    @Test("Secondary sidebar icons retain 3.0 contrast on every painted preset and swatch", arguments: [false, true])
    func secondaryIconContrast(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        for (name, theme) in themes() {
            let foreground = OrbitSpaceThemes.accent(for: theme).icon.resolved(for: appearance)
            let minimum = try gradientSamples(theme, appearance: appearance).map { contrast(foreground, $0) }.min()!
            #expect(minimum >= 3, "\(name), dark=\(isDark): secondary icon contrast \(minimum)")
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
