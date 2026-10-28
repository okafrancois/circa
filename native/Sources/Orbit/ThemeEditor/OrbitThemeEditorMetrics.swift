import AppKit
import BrowserCore

/// Geometry of Orbit's theme editor popover, top-left origin, points.  at 2 px/pt
/// [M] unless tagged: docs/native-port/design/orbit-design-system.md §14.6 and themes-2026-10-25.md.
@MainActor
enum OrbitThemeEditorMetrics {
    ///  356 × 508, radius 20.45.
    // The original 508 pt color editor is retained above an applied-material section (26 Oct request).
    static let size = NSSize(width: 356, height: 650)
    static let cornerRadius: CGFloat = 20
    /// Placed at the content card's left edge + 13 and 13 below the window's top [M].
    static let offsetFromCard = CGPoint(x: 13, y: 13)

    /// Dotted field: the upper area, 8 pt inside the popover [M]; radius and dot pitch .
    static let field = NSRect(x: 8, y: 8, width: 340, height: 339)
    static let fieldCornerRadius: CGFloat = 14
    static let dotPitch: CGFloat = 6
    static let dotDiameter: CGFloat = 1.2

    /// Mode buttons auto / sun / moon over the field, pitch 40 [H], highlight 32 × 32 [M], radius [L].
    static let modeCenterY: CGFloat = 48
    static let modeCenterXs: [CGFloat] = [138, 178, 218]
    static let modeHighlight = NSSize(width: 32, height: 32)
    static let modeHighlightRadius: CGFloat = 7
    static let modeGlyphPointSize: CGFloat = 15

    /// "Tap to pick a color for this space" [M], semibold 13 ().
    static let placeholderCenterY: CGFloat = 178
    static let placeholderFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    /// − and + centred at the bottom of the field [M].
    static let stepperCenterY: CGFloat = 316
    static let stepperCenterXs: [CGFloat] = [158, 198]
    static let stepperSize = NSSize(width: 28, height: 28)

    /// Colour handles: 44 pt with a 3 pt white ring [M].
    static let handleDiameter: CGFloat = 44
    static let handleRing: CGFloat = 3

    /// Nine swatches at a 29.5 pitch (≈20 pt + 2 pt ring) between ‹ › chevrons [H]/[M].
    static let swatchRowCenterY: CGFloat = 380
    static let swatchFirstCenterX: CGFloat = 60
    static let swatchPitch: CGFloat = 29.5
    static let swatchDiameter: CGFloat = 20
    static let swatchRing: CGFloat = 2
    static let chevronCenterXs: [CGFloat] = [24, 332]

    /// Wavy-track slider (left) and grain dial (right) on one row [M]; wave shape .
    static let controlRowCenterY: CGFloat = 451
    static let sliderTrackX: ClosedRange<CGFloat> = 19...243
    static let sliderTrackHeight: CGFloat = 18
    static let waveAmplitude: CGFloat = 11
    static let wavePeriod: CGFloat = 32
    static let waveLineWidth: CGFloat = 3.5
    static let sliderThumb = NSSize(width: 22, height: 54)
    static let dialCenterX: CGFloat = 298
    static let dialRadius: CGFloat = 34
    static let dialInnerRadius: CGFloat = 20
    static let dialDotCount = 24
    /// The dial turns through 330° from 12 o'clock ().
    static let dialSweepDegrees: CGFloat = 330

    static func swatchCenter(_ index: Int) -> CGPoint {
        CGPoint(x: swatchFirstCenterX + CGFloat(index) * swatchPitch, y: swatchRowCenterY)
    }

    /// Opening — : zoom from the anchor (response 0.305, damping 0.80) with a
    /// fade (0.25, 0.94). Closing was not recorded: a 0.12 s fade (). Reduced motion: fades only.
    static let presentScale = OrbitTokens.Spring(response: 0.305, dampingFraction: 0.80)
    static let presentOpacity = OrbitTokens.Spring(response: 0.25, dampingFraction: 0.94)
    static let presentInitialScale: CGFloat = 0.9
    static let dismissDuration: TimeInterval = 0.12
    /// Throttle of store commits while dragging; the window itself previews every change (estimate).
    static let commitInterval: Duration = .milliseconds(120)
}

/// User-facing strings of the theme editor. Labels other than the context-menu item, the
/// placeholder and "Dark Appearance" (seen in C24/C04/C06) are reconstructions.
@MainActor
enum OrbitThemeEditorText {
    static var menuItem: String { uiText("Edit Theme Color…") }
    static var title: String { uiText("Edit Theme Color") }
    static var placeholder: String { uiText("Tap to pick a color for this space") }
    static var automatic: String { uiText("Automatic Appearance") }
    static var light: String { uiText("Light Appearance") }
    static var dark: String { uiText("Dark Appearance") }
    static var colorField: String { uiText("Theme Colors") }
    static var addColor: String { uiText("Add Color") }
    static var removeColor: String { uiText("Remove Color") }
    static var previousColors: String { uiText("Previous Colors") }
    static var nextColors: String { uiText("Next Colors") }
    static var intensity: String { uiText("Intensity") }
    static var grain: String { uiText("Grain") }
    static var undoAction: String { uiText("Change Theme") }
    static func handle(_ number: Int) -> String { uiFormat("Color %ld", number) }
    static func swatch(_ family: BrowserSpaceThemePresets.Family, _ number: Int) -> String {
        uiFormat("%@ %ld", familyName(family), number)
    }
    static func familyName(_ family: BrowserSpaceThemePresets.Family) -> String {
        switch family.id {
        case "pastel": uiText("Pastel")
        case "drab": uiText("Drab")
        case "greyscale": uiText("Greyscale")
        default: uiText("Brand")
        }
    }
    static func percent(_ value: Double) -> String { uiFormat("%ld%%", Int((value * 100).rounded())) }
}
