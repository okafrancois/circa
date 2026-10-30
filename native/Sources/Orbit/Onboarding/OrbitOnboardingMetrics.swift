import AppKit
import BrowserCore
import BrowserShell

/// Measured geometry, colour and motion of the first-run onboarding (points, top-left origin of
/// the card unless stated otherwise).
@MainActor
enum OrbitOnboardingMetrics {
    static let windowSize = NSSize(width: 1200, height: 750)
    static let cardSize = NSSize(width: 960, height: 560)
    static let cardCornerRadius: CGFloat = 22

    // Left panel and its perforated edge (scallops 4.4 pt deep, 17.22 pt period, first lobe at 25 pt).
    static let leftPanelWidth: CGFloat = 380
    static let perforationCenterX: CGFloat = 380
    static let perforationAmplitude: CGFloat = 0
    static let perforationPeriod: CGFloat = 17.22
    static let perforationPhaseY: CGFloat = 25
    static let contentX: CGFloat = 36
    static let contentWidth: CGFloat = 308

    // Left panel text.
    static let titleCapTop: CGFloat = 94
    static let titleCapTopWithBack: CGFloat = 94
    static let titlePointSize: CGFloat = 40
    static let titleLineHeight: CGFloat = 40.8
    /// Baseline of the title's last line to the first body baseline.
    static let titleToBodyBaseline: CGFloat = 35
    static let bodyPointSize: CGFloat = 15
    static let bodyLineHeight: CGFloat = 22.5
    static let backCapTop: CGFloat = 36
    static let backPointSize: CGFloat = 13

    // Primary button and skip link.
    static let buttonSize = NSSize(width: 308, height: 48)
    static let buttonCornerRadius: CGFloat = 24
    static let buttonBottomInset: CGFloat = 54
    static let buttonRaiseForSkip: CGFloat = 32
    static let skipBaselineBelowButton: CGFloat = 29
    static let skipPointSize: CGFloat = 13
    static let buttonPointSize: CGFloat = 15
    static let disabledLabelAlpha: CGFloat = 0.75

    // Right panel.
    static let rightPanelX: CGFloat = 380
    static var rightPanelCenterX: CGFloat { (rightPanelX + cardSize.width) / 2 }
    /// Scroll viewport of the import list; the footer below it stays empty.
    static let importViewportBottom: CGFloat = 530
    static let importFirstRowTop: CGFloat = 70

    // Option cards.
    static let browserRowSize = NSSize(width: 512, height: 60)
    static let browserRowRadius: CGFloat = 13.6
    static let browserTileWidth: CGFloat = 52
    static let browserIconSize: CGFloat = 28
    static let browserRadioCenterX: CGFloat = 25
    static let browserLabelX: CGFloat = 50
    static let browserLabelPointSize: CGFloat = 15
    static let optionGap: CGFloat = 10
    static let choiceCardSize = NSSize(width: 512, height: 56)
    static let choiceCardRadius: CGFloat = 13
    static let choiceRadioCenterX: CGFloat = 25
    static let choiceLabelX: CGFloat = 46
    static let choicePointSize: CGFloat = 15
    static let radioDiameter: CGFloat = 18
    static let radioRing: CGFloat = 1.1
    static let radioSelectedRing: CGFloat = 1.4
    static let radioDotDiameter: CGFloat = 10
    static let selectedBorder: CGFloat = 1.25
    static let hoverScale: CGFloat = 1
    static let profileListInset: CGFloat = 12
    static let profileListGap: CGFloat = 8
    static let profileRowHeight: CGFloat = 46
    static let checkDiameter: CGFloat = 16.6

    // Theme step: the 356 × 508 colour editor shown at 294.4 × 420 pt, its top 64 pt below the card's.
    static let themeEditorScale: CGFloat = 300.0 / 356
    static let themeEditorTop: CGFloat = 44

    // Welcome (window coordinates).
    static let welcomePointSize: CGFloat = 84
    static let welcomeLineHeight: CGFloat = 80
    static let welcomeButtonSize = NSSize(width: 120, height: 48)
    static let welcomeButtonGap: CGFloat = 25

    // Step navigation: horizontal push of the left panel text, spring response 0.41 s, damping 0.82.
    static let pushDistance: CGFloat = 36
    static let push = OrbitTokens.Spring(response: 0.41, dampingFraction: 0.82)
    /// Right panel cross-fade, from the push's first frame.
    static let crossFadeDuration: CFTimeInterval = 0.32
    static let backFadeDuration: CFTimeInterval = 0.2
}

@MainActor
enum OrbitOnboardingColors {
    static let stage = BrandPalette.stage
    static var accent: NSColor { BrandPalette.controlAccent }
    static let leftPanel = NSColor.white
    static let rightPanel = BrandPalette.paper
    static let rightPanelThemed = rightPanel
    static let title = BrandPalette.ink
    static let body = BrandPalette.ink2
    static let optionSurface = NSColor.white
    static let optionBorder = BrandPalette.ink.withAlphaComponent(0.1)
    static let optionShadow = NSColor.clear
    static let radioRing = BrandPalette.controlBorder
    static let optionText = BrandPalette.ink
    static let browserLabel = BrandPalette.ink
    static let welcomeTitle = BrandPalette.stageText
    static let welcomeButton = BrandPalette.paper
    static let welcomeArrow = BrandPalette.stage
    static func accent(for theme: BrowserSpaceTheme?) -> NSColor { accent }
}

@MainActor
enum OrbitOnboardingFonts {
    static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { BrandFonts.ui(size, weight: weight) }
    static func title(_ size: CGFloat) -> NSFont { BrandTextStyle.title.font(size: size) }
    static func mono(_ size: CGFloat) -> NSFont { BrandFonts.mono(size) }
    static var title: NSFont { title(40) }
    static var welcome: NSFont { title(84) }
    static var body: NSFont { ui(15) }
    static var emphasis: NSFont { ui(13) }
    static var back: NSFont { ui(13, weight: .medium) }
    static var button: NSFont { ui(15, weight: .semibold) }
    static var skip: NSFont { ui(14) }
    static var browser: NSFont { ui(15, weight: .medium) }
    static var choiceStrong: NSFont { ui(15, weight: .semibold) }
    static var choice: NSFont { ui(15) }
    static var profile: NSFont { ui(15) }
}
