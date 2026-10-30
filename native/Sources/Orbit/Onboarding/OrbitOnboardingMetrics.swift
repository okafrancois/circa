import AppKit
import BrowserCore

/// Measured geometry, colour and motion of the first-run onboarding (points, top-left origin of
/// the card unless stated otherwise).
@MainActor
enum OrbitOnboardingMetrics {
    static let windowSize = NSSize(width: 1280, height: 800)
    static let cardSize = NSSize(width: 967, height: 548)
    static let cardCornerRadius: CGFloat = 20.6

    // Left panel and its perforated edge (scallops 4.4 pt deep, 17.22 pt period, first lobe at 25 pt).
    static let leftPanelWidth: CGFloat = 355
    static let perforationCenterX: CGFloat = 356.5
    static let perforationAmplitude: CGFloat = 2.2
    static let perforationPeriod: CGFloat = 17.22
    static let perforationPhaseY: CGFloat = 25
    static let contentX: CGFloat = 50
    static let contentWidth: CGFloat = 256

    // Left panel text.
    static let titleCapTop: CGFloat = 53
    static let titleCapTopWithBack: CGFloat = 88.4
    static let titlePointSize: CGFloat = 36
    static let titleLineHeight: CGFloat = 36.5
    /// Baseline of the title's last line to the first body baseline.
    static let titleToBodyBaseline: CGFloat = 45.8
    static let bodyPointSize: CGFloat = 15
    static let bodyLineHeight: CGFloat = 22.4
    static let backCapTop: CGFloat = 53.4
    static let backPointSize: CGFloat = 14

    // Primary button and skip link.
    static let buttonSize = NSSize(width: 256, height: 40)
    static let buttonCornerRadius: CGFloat = 7.2
    static let buttonBottomInset: CGFloat = 50
    static let buttonRaiseForSkip: CGFloat = 36
    static let skipBaselineBelowButton: CGFloat = 32.4
    static let skipPointSize: CGFloat = 13
    static let buttonPointSize: CGFloat = 15
    static let disabledLabelAlpha: CGFloat = 0.75

    // Right panel.
    static let rightPanelX: CGFloat = 357
    static var rightPanelCenterX: CGFloat { (rightPanelX + cardSize.width) / 2 }
    /// Scroll viewport of the import list; the footer below it stays empty.
    static let importViewportBottom: CGFloat = 484
    static let importFirstRowTop: CGFloat = 81.8

    // Option cards.
    static let browserRowSize = NSSize(width: 274, height: 90)
    static let browserRowRadius: CGFloat = 13.6
    static let browserTileWidth: CGFloat = 91
    static let browserIconSize: CGFloat = 44
    static let browserRadioCenterX: CGFloat = 33.4
    static let browserLabelX: CGFloat = 65
    static let browserLabelPointSize: CGFloat = 15
    static let optionGap: CGFloat = 24
    static let choiceCardSize = NSSize(width: 342, height: 67)
    static let choiceCardRadius: CGFloat = 13
    static let choiceRadioCenterX: CGFloat = 35
    static let choiceLabelX: CGFloat = 65.6
    static let choicePointSize: CGFloat = 17
    static let radioDiameter: CGFloat = 21
    static let radioRing: CGFloat = 1.1
    static let radioSelectedRing: CGFloat = 1.4
    static let radioDotDiameter: CGFloat = 13.9
    static let selectedBorder: CGFloat = 1.25
    static let hoverScale: CGFloat = 1.05
    static let profileListInset: CGFloat = 12
    static let profileListGap: CGFloat = 17.8
    static let profileRowHeight: CGFloat = 44.8
    static let checkDiameter: CGFloat = 16.6

    // Theme step: the 356 × 508 colour editor shown at 294.4 × 420 pt, its top 64 pt below the card's.
    static let themeEditorScale: CGFloat = 294.4 / 356
    static let themeEditorTop: CGFloat = 64

    // Welcome (window coordinates).
    static let welcomePointSize: CGFloat = 64
    static let welcomeLineHeight: CGFloat = 64.7
    static let welcomeButtonSize = NSSize(width: 67, height: 40)
    static let welcomeButtonGap: CGFloat = 25

    // Step navigation: horizontal push of the left panel text, spring response 0.41 s, damping 0.82.
    static let pushDistance: CGFloat = 403
    static let push = OrbitTokens.Spring(response: 0.41, dampingFraction: 0.82)
    /// Right panel cross-fade, from the push's first frame.
    static let crossFadeDuration: CFTimeInterval = 0.35
    static let backFadeDuration: CFTimeInterval = 0.2
}

@MainActor
enum OrbitOnboardingColors {
    /// Default accent of the onboarding (primary button, links, selection).
    static let accent = NSColor(srgbRed: 0.192, green: 0.224, blue: 0.984, alpha: 1)
    static let leftPanel = NSColor(srgbRed: 253 / 255, green: 253 / 255, blue: 253 / 255, alpha: 1)
    static let rightPanel = NSColor(srgbRed: 224 / 255, green: 225 / 255, blue: 1, alpha: 1)
    /// Right panel once a theme colour is chosen.
    static let rightPanelThemed = NSColor(srgbRed: 247 / 255, green: 247 / 255, blue: 248 / 255, alpha: 1)
    static let title = NSColor.black
    /// Measured on white: body copy, browser names and profile names.
    static let body = NSColor(srgbRed: 96 / 255, green: 96 / 255, blue: 96 / 255, alpha: 1)
    static let optionSurface = NSColor(srgbRed: 253 / 255, green: 253 / 255, blue: 253 / 255, alpha: 1)
    static let optionBorder = NSColor(white: 0, alpha: 0.12)
    static let optionShadow = NSColor(white: 0, alpha: 0.08)
    static let radioRing = NSColor(white: 0, alpha: 0.25)
    static let optionText = NSColor(srgbRed: 17 / 255, green: 17 / 255, blue: 19 / 255, alpha: 1)
    static let browserLabel = NSColor(srgbRed: 96 / 255, green: 96 / 255, blue: 96 / 255, alpha: 1)
    static let welcomeTitle = NSColor.white
    static let welcomeButton = NSColor(srgbRed: 212 / 255, green: 215 / 255, blue: 249 / 255, alpha: 1)
    static let welcomeArrow = NSColor(srgbRed: 0.192, green: 0.224, blue: 0.984, alpha: 1)

    /// Accent of a chosen theme: its hue at full saturation, darkened to a relative luminance of
    /// 0.070 (both measured theme picks land there); the default theme keeps `accent`.
    static func accent(for theme: BrowserSpaceTheme?) -> NSColor {
        guard let theme, !(theme.colors.isEmpty && theme.presetID == BrowserSpaceThemePresets.defaultID) else { return accent }
        switch theme.accentFamily {
        case .defaultSpace: return accent
        case let .derived(hue, saturation, strong):
            let base = strong?.hsb.hue ?? hue
            let chroma = saturation < BrowserSpaceTheme.neutralSaturation ? 0 : 1.0
            return darkened(hue: base, saturation: chroma, luminance: 0.070)
        }
    }

    static func darkened(hue: Double, saturation: Double, luminance target: Double) -> NSColor {
        func luminance(_ brightness: Double) -> Double {
            let color = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).usingColorSpace(.sRGB)!
            func linear(_ c: CGFloat) -> Double { let v = Double(c); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if luminance(mid) < target { low = mid } else { high = mid }
        }
        return NSColor(hue: hue, saturation: saturation, brightness: (low + high) / 2, alpha: 1).usingColorSpace(.sRGB)!
    }
}

@MainActor
enum OrbitOnboardingFonts {
    static let title = NSFont.systemFont(ofSize: OrbitOnboardingMetrics.titlePointSize, weight: .heavy)
    static let welcome = NSFont.systemFont(ofSize: OrbitOnboardingMetrics.welcomePointSize, weight: .heavy)
    static let body = NSFont.systemFont(ofSize: OrbitOnboardingMetrics.bodyPointSize, weight: .regular)
    static let emphasis = NSFont.systemFont(ofSize: OrbitOnboardingMetrics.bodyPointSize, weight: .bold)
    static let back = NSFont.systemFont(ofSize: OrbitOnboardingMetrics.backPointSize, weight: .medium)
    static let button = NSFont.systemFont(ofSize: OrbitOnboardingMetrics.buttonPointSize, weight: .semibold)
    static let skip = NSFont.systemFont(ofSize: OrbitOnboardingMetrics.skipPointSize, weight: .medium)
    static let browser = NSFont.systemFont(ofSize: OrbitOnboardingMetrics.browserLabelPointSize, weight: .semibold)
    static let choiceStrong = NSFont.systemFont(ofSize: OrbitOnboardingMetrics.choicePointSize, weight: .heavy)
    static let choice = NSFont.systemFont(ofSize: OrbitOnboardingMetrics.choicePointSize, weight: .regular)
    static let profile = NSFont.systemFont(ofSize: OrbitOnboardingMetrics.bodyPointSize, weight: .medium)
}
