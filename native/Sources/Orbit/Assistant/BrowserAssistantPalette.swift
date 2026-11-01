import AppKit
import SwiftUI

/// Every assistant colour, derived from the selected Space. Polarity follows the Space ink, which can
/// differ from the window appearance. Reading ink stays in the brand pair and one Space accent marks
/// activity; keyboard focus stays on the macOS accent.
struct BrowserAssistantPalette: Equatable {
    /// Where the dock sits in the window fill: the right side, over its full height.
    static let dockSamples = [CGPoint(x: 0.72, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0.72, y: 0.5),
                              CGPoint(x: 1, y: 0.5), CGPoint(x: 0.72, y: 1), CGPoint(x: 1, y: 1)]
    static let lightTintOpacity: CGFloat = 0.72
    static let darkTintOpacity: CGFloat = 0.66

    let isDark: Bool
    /// The opaque tint painted over the Space fill, and the resulting surface at each sample.
    let tint: NSColor
    let surfaces: [NSColor]
    let ink: NSColor
    let secondary: NSColor
    let tertiary: NSColor
    let line: NSColor
    let hover: NSColor
    let press: NSColor
    let wash: NSColor
    let accentInk: NSColor
    let strong: NSColor
    let onStrong: NSColor
    let composer: NSColor
    let composerLine: NSColor
    let composerFocusLine: NSColor
    let popover: NSColor
    let popoverSolid: NSColor
    let popoverEdge: NSColor
    var warning: NSColor { NSColor(srgbRed: 1, green: 159.0 / 255, blue: 10.0 / 255, alpha: 1) }
    var critical: NSColor { NSColor(srgbRed: 1, green: 59.0 / 255, blue: 48.0 / 255, alpha: 1) }
    var appearance: NSAppearance { NSAppearance(named: isDark ? .darkAqua : .aqua)! }

    /// `polarity` overrides the Space ink for a surface that already follows the window appearance.
    @MainActor
    init(theme: OrbitTokens.SpaceTheme, appearance: NSAppearance, polarity: Bool? = nil,
         samples: [CGPoint] = BrowserAssistantPalette.dockSamples) {
        let spaceInk = OrbitSpaceThemes.accent(for: theme).foreground.resolved(for: appearance)
        let dark = polarity ?? !OrbitThemeForeground.isLight(on: spaceInk)
        let style = OrbitFloatingMaterial.Style(variant: dark ? .dark : .light, reducesTransparency: false,
                                                sidebarTintOpacity: dark ? Self.darkTintOpacity : Self.lightTintOpacity)
        let polar = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let surfaces = samples.map { style.background(over: OrbitThemeGradient.color(theme, at: $0, appearance: appearance)) }
        let family = OrbitSpaceThemes.baseAccent(for: theme)
        func mix(_ color: NSColor, _ opacity: CGFloat, _ surface: NSColor) -> NSColor {
            OrbitFloatingMaterial.composite(color, opacity: opacity, over: surface)
        }
        let soft = family.soft.resolved(for: polar)
        let washOpacity: CGFloat = dark ? 0.32 : 0.46
        let reading = dark ? NSColor.white : style.body

        self.isDark = dark
        self.surfaces = surfaces
        tint = style.tint.withAlphaComponent(style.tintOpacity)
        ink = style.body
        secondary = style.secondary
        tertiary = style.secondary.withAlphaComponent(0.72)
        line = reading.withAlphaComponent(0.10)
        hover = reading.withAlphaComponent(dark ? 0.09 : 0.06)
        press = reading.withAlphaComponent(dark ? 0.14 : 0.10)
        wash = soft.withAlphaComponent(washOpacity)
        composer = NSColor.white.withAlphaComponent(dark ? 0.055 : 0.92)
        composerLine = reading.withAlphaComponent(0.10)
        composerFocusLine = reading.withAlphaComponent(0.24)
        popover = dark ? NSColor(srgbRed: 20.0 / 255, green: 18.0 / 255, blue: 24.0 / 255, alpha: 0.90)
            : NSColor.white.withAlphaComponent(0.84)
        popoverSolid = dark ? NSColor(srgbRed: 23.0 / 255, green: 22.0 / 255, blue: 26.0 / 255, alpha: 1)
            : NSColor(srgbRed: 250.0 / 255, green: 250.0 / 255, blue: 251.0 / 255, alpha: 1)
        popoverEdge = NSColor.white.withAlphaComponent(dark ? 0.18 : 0.75)

        let backgrounds = surfaces + surfaces.map { mix(soft, washOpacity, $0) }
        accentInk = Self.guardedAccentInk(family.icon.resolved(for: polar), on: backgrounds, dark: dark)
        // A pale or very dark swatch must never produce an invisible send button.
        let derived: NSColor
        if case let .derived(hue, saturation, _)? = theme.model?.accentFamily {
            derived = OrbitTokens.ThemeAccent.derived(hue: CGFloat(hue), saturation: CGFloat(saturation), strong: nil).strong
        } else { derived = family.strong }
        let candidates = [family.strong, derived, family.selection.resolved(for: polar), style.body]
        let fill = candidates.first { candidate in
            surfaces.allSatisfy { OrbitFloatingMaterial.contrast(candidate, $0) >= 3 }
        } ?? style.body
        strong = fill.usingColorSpace(.sRGB) ?? fill
        onStrong = OrbitFloatingMaterial.contrastingInk(on: fill)
    }

    /// Keeps the hue and moves brightness until accent text passes 4.5:1 on every background.
    private static func guardedAccentInk(_ base: NSColor, on backgrounds: [NSColor], dark: Bool) -> NSColor {
        let start = base.usingColorSpace(.sRGB)!
        let hue = start.hueComponent
        var saturation = start.saturationComponent, brightness = start.brightnessComponent
        var color = start
        for _ in 0..<26 where backgrounds.contains(where: { OrbitFloatingMaterial.contrast(color, $0) < 4.5 }) {
            if dark {
                saturation = max(0, saturation - 0.04)
                brightness = min(1, brightness + 0.04)
            } else {
                brightness = max(0, brightness - 0.04)
            }
            color = NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        }
        return color
    }
}

extension NSColor {
    var swiftUI: Color { Color(nsColor: self) }
}

private struct BrowserAssistantPaletteKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = BrowserAssistantPalette(theme: .default, appearance: NSAppearance(named: .aqua)!)
}

extension EnvironmentValues {
    var assistantPalette: BrowserAssistantPalette {
        get { self[BrowserAssistantPaletteKey.self] }
        set { self[BrowserAssistantPaletteKey.self] = newValue }
    }
}
