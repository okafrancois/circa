import AppKit
import QuartzCore
import BrowserShell

@MainActor
enum BrowserPeekStyle {
    static let cardRadius = OrbitTokens.Radius.peek
    static let buttonSize = OrbitTokens.Metrics.Peek.controlDiameter
    static let buttonRadius = buttonSize / 2
    static let toolbarFontSize: CGFloat = 11
    static let toolbarForeground = BrandPalette.ink
    static let toolbarDisabled = BrandPalette.ink.withAlphaComponent(0.3)
    static let buttonBackground = BrandPalette.pageWhite
    static let buttonHover = BrandPalette.sky
    /// Split button: the fill never changes; hover lifts the disc and a press shrinks it.
    static let splitButtonHoverLift: CGFloat = 1
    static let splitButtonHoverDuration: CFTimeInterval = 0.05
    static let splitButtonPressedScale: CGFloat = 0.955
    static let splitButtonPressDuration: CFTimeInterval = 0.06
    static let cardBackground = OrbitTokens.Color.Surface.preview
    static let hairline = OrbitTokens.Color.Line.floatingScrimBorder
    static let shadowColor = OrbitTokens.Shadow.peek.color
    static let shadowOffsetY = OrbitTokens.Shadow.peek.offsetY
    static let shadowBlur = OrbitTokens.Shadow.peek.blur
    // Orbit fades and recedes the underlying document, exposing the window theme.
    // The overlay remains a hit shield; it does not add an independent slate wash.
    static let scrim = NSColor.clear
    static let presentSpring = BrowserPeekMotion.present
    static let dismissSpring = BrowserPeekMotion.dismiss
    static let expandSpring = BrowserPeekMotion.promote
    static let exitCompletionGrace: Double = 0.25
    static let reducedMotionCrossfade = OrbitTokens.Motion.reducedMotionCrossfade
    static var prefersReducedMotion: Bool { OrbitMotionPreferences.prefersReducedMotion }
}
