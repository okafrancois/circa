import AppKit
import BrowserCore
import BrowserShell

/// Measured geometry, colour and motion of the first-run onboarding (points, top-left origin of
/// the card unless stated otherwise).
@MainActor
enum OrbitOnboardingMetrics {
    static let windowSize = NSSize(width: 1200, height: 714)
    static let cardSize = NSSize(width: 1200, height: 714)
    static let cardCornerRadius: CGFloat = 14

    // Left panel and its perforated edge (scallops 4.4 pt deep, 17.22 pt period, first lobe at 25 pt).
    static let leftPanelWidth: CGFloat = 1200
    static let perforationCenterX: CGFloat = 380
    static let perforationAmplitude: CGFloat = 0
    static let perforationPeriod: CGFloat = 17.22
    static let perforationPhaseY: CGFloat = 25
    static let contentX: CGFloat = 53.68
    static let contentWidth: CGFloat = 587.37

    // Left panel text.
    static let titleCapTop: CGFloat = 94.74
    static let titleCapTopWithBack: CGFloat = 94.74
    static let titlePointSize: CGFloat = 63.16
    static let titleLineHeight: CGFloat = 60
    /// Baseline of the title's last line to the first body baseline.
    static let titleToBodyBaseline: CGFloat = 48
    static let bodyPointSize: CGFloat = 22.11
    static let bodyLineHeight: CGFloat = 32.05
    static let backCapTop: CGFloat = 36
    static let backPointSize: CGFloat = 13

    // Primary button and skip link.
    static let buttonSize = NSSize(width: 210, height: 64)
    static let buttonCornerRadius: CGFloat = 32
    static let buttonBottomInset: CGFloat = 41.05
    static let buttonRaiseForSkip: CGFloat = 0
    static let skipBaselineBelowButton: CGFloat = 29
    static let skipPointSize: CGFloat = 13
    static let buttonPointSize: CGFloat = 22
    static let disabledLabelAlpha: CGFloat = 0.75

    // Right panel.
    static let rightPanelX: CGFloat = 0
    static var rightPanelCenterX: CGFloat { (rightPanelX + cardSize.width) / 2 }
    /// Scroll viewport of the import list; the footer below it stays empty.
    static let importViewportBottom: CGFloat = 584
    static let importFirstRowTop: CGFloat = 240

    // Option cards.
    static let browserRowSize = NSSize(width: 230.53, height: 60.56)
    static let browserRowRadius: CGFloat = 17.37
    static let browserTileWidth: CGFloat = 52
    static let browserIconSize: CGFloat = 28
    static let browserRadioCenterX: CGFloat = 30
    static let browserLabelX: CGFloat = 51.68
    static let browserLabelPointSize: CGFloat = 22.11
    static let optionGap: CGFloat = 14.21
    static let choiceCardSize = NSSize(width: 521.05, height: 77.03)
    static let choiceCardRadius: CGFloat = 20.53
    static let choiceRadioCenterX: CGFloat = 25
    static let choiceLabelX: CGFloat = 25.26
    static let choicePointSize: CGFloat = 15
    static let radioDiameter: CGFloat = 22.11
    static let radioRing: CGFloat = 2.37
    static let radioSelectedRing: CGFloat = 1.4
    static let radioDotDiameter: CGFloat = 12.63
    static let selectedBorder: CGFloat = 3.16
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
    static let leftPanel = BrandPalette.sky
    static let rightPanel = BrandPalette.paper
    static let rightPanelThemed = rightPanel
    static let title = BrandPalette.ink
    static let body = BrandPalette.ink2
    static let optionSurface = BrandPalette.pageWhite.withAlphaComponent(0.6)
    static let optionBorder = BrandPalette.ink
    static let optionShadow = BrandPalette.ink
    static let radioRing = BrandPalette.controlBorder
    static let optionText = BrandPalette.ink
    static let browserLabel = BrandPalette.ink
    static let welcomeTitle = BrandPalette.stageText
    static let welcomeButton = BrandPalette.coral
    static let welcomeArrow = BrandPalette.stage
    static func accent(for theme: BrowserSpaceTheme?) -> NSColor { accent }
}

@MainActor
enum OrbitOnboardingFonts {
    static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { BrandFonts.onboardingBody(size, weight: weight) }
    static func title(_ size: CGFloat) -> NSFont { BrandFonts.display(size, opticalSize: size / (1200.0 / 760)) }
    static func mono(_ size: CGFloat) -> NSFont { BrandTextStyle.mono.font(size: size) }
    static var title: NSFont { title(63.16) }
    static var welcome: NSFont { title(84) }
    static var body: NSFont { ui(22.11) }
    static var emphasis: NSFont { ui(13) }
    static var back: NSFont { ui(19.74, weight: .semibold) }
    static var button: NSFont { ui(22.11, weight: .bold) }
    static var skip: NSFont { ui(19.74, weight: .semibold) }
    static var browser: NSFont { ui(22.11, weight: .semibold) }
    static var choiceStrong: NSFont { title(30) }
    static var choice: NSFont { ui(23.68) }
    static var profile: NSFont { ui(15) }
}
