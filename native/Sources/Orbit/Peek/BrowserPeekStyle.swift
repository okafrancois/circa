import AppKit
import QuartzCore

/// capture C14; asset colours and bounded motion live in OrbitTokens.
@MainActor
enum BrowserPeekStyle {
    static let cardRadius = OrbitTokens.Radius.peek
    static let buttonSize = OrbitTokens.Metrics.Peek.controlDiameter
    static let buttonRadius = buttonSize / 2
    static let toolbarFontSize: CGFloat = 11
    static let toolbarForeground = NSColor.white.withAlphaComponent(0.88)
    static let toolbarDisabled = NSColor.white.withAlphaComponent(0.30)
    static let buttonBackground = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 0.96)
    static let buttonHover = NSColor(srgbRed: 0.15, green: 0.15, blue: 0.17, alpha: 1)
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
