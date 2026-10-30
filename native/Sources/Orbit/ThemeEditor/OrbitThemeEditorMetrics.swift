import AppKit
import BrowserShell
import BrowserCore

@MainActor
enum OrbitThemeEditorMetrics {
    /// The color controls retain their geometry; Frost extends the bottom of both presentations.
    static let pickerSize = NSSize(width: 356, height: 566)
    static let size = NSSize(width: 356, height: 566)
    static let cornerRadius: CGFloat = 20
    static let offsetFromCard = CGPoint(x: 13, y: 13)

    static let field = NSRect(x: 8, y: 8, width: 340, height: 339)
    static let fieldCornerRadius: CGFloat = 14
    static let dotPitch: CGFloat = 4.25
    static let dotDiameter: CGFloat = 1.2

    static let modeCenterY: CGFloat = 48
    static let modeCenterXs: [CGFloat] = [138, 178, 218]
    static let modeHighlight = NSSize(width: 32, height: 32)
    static let modeHighlightRadius: CGFloat = 7
    static let modeGlyphPointSize: CGFloat = 15

    static let placeholderCenterY: CGFloat = 178
    static let placeholderFont = BrandTextStyle.ui.font(size: 13, weight: .semibold)

    static let stepperCenterY: CGFloat = 316
    static let stepperCenterXs: [CGFloat] = [158, 198]
    static let stepperSize = NSSize(width: 28, height: 28)

    static let handleDiameter: CGFloat = 44
    static let handleRing: CGFloat = 3

    static let swatchRowCenterY: CGFloat = 380
    static let swatchFirstCenterX: CGFloat = 60
    static let swatchPitch: CGFloat = 29.5
    static let swatchDiameter: CGFloat = 24
    static let swatchRing: CGFloat = 2
    static let chevronCenterXs: [CGFloat] = [24, 332]

    static let controlRowCenterY: CGFloat = 451
    static let sliderTrackX: ClosedRange<CGFloat> = 19...243
    static let sliderTrackHeight: CGFloat = 18
    static let waveAmplitude: CGFloat = 11
    static let wavePeriod: CGFloat = 38
    static let waveLineWidth: CGFloat = 6
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

    static let presentScale = OrbitTokens.Spring(response: 0.305, dampingFraction: 0.80)
    static let presentOpacity = OrbitTokens.Spring(response: 0.25, dampingFraction: 0.94)
    static let presentInitialScale: CGFloat = 0.9
    static let dismissDuration: TimeInterval = 0.12
    /// Throttle of store commits while dragging; the window itself previews every change (estimate).
    static let commitInterval: Duration = .milliseconds(120)
}

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
    static var frost: String { uiText("Frost") }
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
