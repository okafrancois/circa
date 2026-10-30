// Shared appearance and motion tokens. Units: points and seconds.

import AppKit
import BrowserShell
import BrowserCore
import QuartzCore

public enum OrbitTokens {}

// MARK: - Colour helpers

extension NSColor {
    /// Builds an sRGB colour from a 0xRRGGBB literal.
    fileprivate static func orbitSRGB(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    /// Builds a Display P3 colour from a 0xRRGGBB literal (components as stored by Orbit).
    fileprivate static func orbitP3(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(displayP3Red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    /// Appearance-dependent colour resolved at draw time (light = aqua, dark = darkAqua).
    fileprivate static func orbitDynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name("Orbit." + name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

// MARK: - Colours

extension OrbitTokens {
    public enum Color {
        // MARK: Text tiers
        public enum Text {
            ///  — primary labels outside the themed sidebar.
            /// Sidebar tab/folder titles are theme-tinted: use `ThemeAccent.sidebarText` ().
            public static let primary = NSColor.orbitDynamic("Text.primary", light: .orbitP3(0x0E0F10, 0.90), dark: .orbitSRGB(0xFFFFFF, 0.80))
            public static let secondary = NSColor.orbitDynamic("Text.secondary", light: .orbitSRGB(0x000000, 0.50), dark: .orbitSRGB(0xFFFFFF, 0.50))
            ///  — disabled toolbar glyphs.
            public static let tertiary = NSColor.orbitDynamic("Text.tertiary", light: .orbitSRGB(0x000000, 0.30), dark: .orbitSRGB(0xFFFFFF, 0.30))
            ///  — address text, enabled toolbar/footer glyphs.
            public static let baseSecondary = NSColor.orbitDynamic("Text.baseSecondary", light: .orbitSRGB(0x000000, 0.70), dark: .orbitSRGB(0xFFFFFF, 0.70))
            public static let splitToolbar = NSColor.orbitDynamic("Text.splitToolbar", light: baseSecondary, dark: .orbitSRGB(0xFFFFFF, 0.65))
            public static let splitToolbarEmphasized = NSColor.orbitDynamic("Text.splitToolbarEmphasized", light: baseSecondary, dark: .orbitSRGB(0x000000, 0.55))
            public static let sidebar = NSColor.orbitDynamic("Text.sidebar", light: .orbitSRGB(0x000000, 0.30), dark: .orbitSRGB(0xFFFFFF, 0.45))
            public static let sidebarLabel = NSColor.orbitDynamic("Text.sidebarLabel", light: .orbitSRGB(0x000000, 0.50), dark: .orbitSRGB(0xFFFFFF, 0.50))
            ///  +  — "New Tab" label and "+" glyph,
            /// hover-revealed controls.
            public static let sidebarDarker = NSColor.orbitDynamic("Text.sidebarDarker", light: .orbitSRGB(0x000000, 0.45), dark: .orbitSRGB(0xFFFFFF, 0.45))
            ///  — "Search or Enter URL…".
            public static let placeholder = NSColor.orbitDynamic("Text.placeholder", light: .orbitSRGB(0x000000, 0.30), dark: .orbitSRGB(0xFFFFFF, 0.30))
            public static let commandBarPrimary = NSColor.orbitDynamic("Text.commandBarPrimary", light: .orbitSRGB(0x000000, 0.80), dark: .orbitSRGB(0xFFFFFF, 0.80))
            ///  — "Switch to Tab", URL suffix.
            public static let commandBarSecondary = NSColor.orbitDynamic("Text.commandBarSecondary", light: .orbitSRGB(0x000000, 0.33), dark: .orbitSRGB(0xFFFFFF, 0.33))
            public static let vibrant = NSColor.orbitDynamic("Text.vibrant", light: .orbitSRGB(0x0C50FF), dark: .orbitSRGB(0x2AB6F6))
            ///  — text on a selected command-bar row.
            public static let onAccent = NSColor.white
            // THEME lot additions
            ///  — tab and folder titles of the default Space, opaque and identical on a
            /// selected or unselected row. Themed Spaces use their `ThemeAccent.sidebarText`.
            public static var sidebarTitle: NSColor { ThemeAccent.defaultSpace.sidebarText }
            public static var sidebarNewTab: NSColor { sidebarDarker }
        }

        // MARK: Surfaces
        public enum Surface {
            /// : mid-point of the default Space gradient (SpaceTheme.default).
            /// Flat fallback only — the default Space itself is a two-stop gradient.
            public static let windowDefault = NSColor.orbitDynamic("Surface.windowDefault", light: .orbitSRGB(0xE6E0ED), dark: .orbitSRGB(0x2D2438))
            public static let contentEmptyPage = NSColor.orbitDynamic("Surface.contentEmptyPage", light: .orbitSRGB(0xFFFFFF, 0.70), dark: .orbitSRGB(0xFFFFFF, 0.10))
            ///  — sidebar "+" menu, popovers.
            public static let popover = NSColor.orbitDynamic("Surface.popover", light: .orbitSRGB(0xFAFBFF), dark: .orbitSRGB(0x151C30))
            public static let commandBar = NSColor.orbitDynamic("Surface.commandBar", light: .orbitSRGB(0xF9F9F9), dark: .orbitSRGB(0x313131))
            public static let commandBarTint = NSColor.orbitDynamic("Surface.commandBarTint", light: .orbitSRGB(0xFFFFFF, 0.12), dark: .orbitSRGB(0x000000, 0.12))
            public static let preview = NSColor.orbitDynamic("Surface.preview", light: .orbitSRGB(0xFFFFFF), dark: .orbitSRGB(0x212222))
            public static let splitToolbar = NSColor.orbitDynamic("Surface.splitToolbar", light: preview, dark: NSColor(white: 0.31, alpha: 1))
            public static let splitToolbarEmphasized = NSColor.orbitDynamic("Surface.splitToolbarEmphasized", light: preview, dark: .orbitSRGB(0xFFFFFF))
            ///  — Little Orbit input.
            public static let secondaryWindowInput = NSColor.orbitDynamic("Surface.secondaryWindowInput", light: .orbitSRGB(0xFAFBFF), dark: .orbitSRGB(0x0E0F10))
            public static let menu = NSColor.orbitDynamic("Surface.menu", light: .orbitSRGB(0xFAFBFF), dark: .orbitSRGB(0x393841))
            public static let libraryBackground = NSColor.orbitDynamic("Surface.libraryBackground", light: .orbitSRGB(0xF7F7F7), dark: .orbitSRGB(0x1E1E1F))
        }

        // MARK: Interaction states (overlays drawn on top of the Space fill)
        public enum State {
            ///  — address field and Favorite rest, tab hover.
            public static let sidebarItem = NSColor.orbitDynamic("State.sidebarItem", light: .orbitP3(0x0E0F10, 0.05), dark: .orbitP3(0xFAFBFF, 0.10))
            ///  — hover on filled items.
            public static let sidebarItemHovered = NSColor.orbitDynamic("State.sidebarItemHovered", light: .orbitP3(0x0E0F10, 0.10), dark: .orbitP3(0xFAFBFF, 0.15))
            public static let tabCurrent = NSColor.orbitDynamic("State.tabCurrent", light: .orbitSRGB(0xF6F6F6, 0.88), dark: .orbitP3(0xFAFBFF, 0.20))
            ///  — visible split member.
            public static let tabContentVisible = NSColor.orbitDynamic("State.tabContentVisible", light: .orbitSRGB(0xFFFFFF, 0.70), dark: .orbitP3(0xFAFBFF, 0.15))
            public static let tabPrevious = NSColor.orbitDynamic("State.tabPrevious", light: .orbitSRGB(0xFFFFFF, 0.32), dark: .orbitP3(0xFAFBFF, 0.08))
            public static let tabPreviousHovered = NSColor.orbitDynamic("State.tabPreviousHovered", light: .orbitSRGB(0xFFFFFF, 0.50), dark: .orbitP3(0xFAFBFF, 0.12))
            public static let tabPressed = NSColor.orbitDynamic("State.tabPressed", light: .orbitSRGB(0x000000, 0.10), dark: .orbitSRGB(0xFFFFFF, 0.10))
            public static let tabMultiselected = NSColor.orbitDynamic("State.tabMultiselected", light: .orbitSRGB(0x000000, 0.10), dark: .orbitP3(0xFAFBFF, 0.10))
            public static let tabChild = NSColor.orbitDynamic("State.tabChild", light: .orbitSRGB(0x000000, 0.07), dark: .orbitSRGB(0xFFFFFF, 0.07))
            ///  — glyph button hover square.
            public static let standaloneButton = NSColor.orbitDynamic("State.standaloneButton", light: .orbitSRGB(0x000000, 0.08), dark: .orbitSRGB(0xFFFFFF, 0.15))
            ///  — 24 × 24 hover square of the × close button in a tab row.
            public static let rowCloseButtonHover = NSColor.orbitDynamic("State.rowCloseButtonHover", light: .orbitSRGB(0x000000, 0.07), dark: .orbitSRGB(0xFFFFFF, 0.075))
            public static let commandBarRowSelected = NSColor.orbitDynamic("State.commandBarRowSelected", light: .orbitSRGB(0x000000, 0.10), dark: .orbitSRGB(0xFFFFFF, 0.10))
            public static let commandBarRowHover = NSColor.orbitDynamic("State.commandBarRowHover", light: .orbitSRGB(0x000000, 0.05), dark: .orbitSRGB(0xFFFFFF, 0.05))
            ///  — arrow chip.
            public static let commandBarAccessory = NSColor.orbitDynamic("State.commandBarAccessory", light: .orbitSRGB(0x000000, 0.05), dark: .orbitSRGB(0xFFFFFF, 0.05))
            public static let commandBarAccessoryForeground = NSColor.orbitDynamic("State.commandBarAccessoryForeground", light: .orbitSRGB(0x000000, 0.50), dark: .orbitSRGB(0xFFFFFF, 0.66))
            ///  — white icon tile on the selected row.
            public static let commandBarIconActive = NSColor.orbitDynamic("State.commandBarIconActive", light: .orbitSRGB(0xFFFFFF), dark: .orbitSRGB(0x1A1A1A))
            public static let littleInput = NSColor.orbitDynamic("State.littleInput", light: .orbitSRGB(0x0E0F10, 0.06), dark: .orbitSRGB(0xFAFBFF, 0.10))
            public static let littleInputHovered = NSColor.orbitDynamic("State.littleInputHovered", light: .orbitSRGB(0x0E0F10, 0.10), dark: .orbitSRGB(0xFAFBFF, 0.15))
            ///  /
            public static let dragHint = NSColor.orbitDynamic("State.dragHint", light: .orbitSRGB(0x000000, 0.20), dark: .orbitSRGB(0xFFFFFF, 0.20))
            public static let dragHintHighlighted = NSColor.orbitDynamic("State.dragHintHighlighted", light: .orbitSRGB(0x000000, 0.50), dark: .orbitSRGB(0xFFFFFF, 0.50))
            public static let floatingSidebarDim = NSColor.orbitSRGB(0x000000, 0.12)
            ///  — split divider handle (2 × 24), white 20 % at rest, 50 % on hover.
            public static let splitDividerHandle = NSColor.orbitSRGB(0xFFFFFF, 0.20)
            public static let splitDividerHandleHovered = NSColor.orbitSRGB(0xFFFFFF, 0.50)
            ///  — loading capsule in the top margin: black 21 % track, black 78 % fill, neutral.
            public static let loadingTrack = NSColor.orbitSRGB(0x000000, 0.21)
            public static let loadingFill = NSColor.orbitSRGB(0x000000, 0.78)
        }

        // MARK: Lines
        public enum Line {
            ///  — 1 device pixel.
            public static let sidebarSeparator = NSColor.orbitDynamic("Line.sidebarSeparator", light: .orbitSRGB(0x000000, 0.15), dark: .orbitSRGB(0xFFFFFF, 0.15))
            public static let tabListOverlap = NSColor.orbitDynamic("Line.tabListOverlap", light: .orbitSRGB(0x000000, 0.05), dark: .orbitSRGB(0xFFFFFF, 0.05))
            ///  +  — inner 1 pt light edge of the floating sidebar.
            public static let sidebarBorder = NSColor.orbitSRGB(0xFFFFFF, 0.30)
            ///  — card, Peek, floating sidebar hairline.
            public static let floatingScrimBorder = NSColor.orbitDynamic("Line.floatingScrimBorder", light: .orbitSRGB(0x000000, 0.10), dark: .orbitSRGB(0xFFFFFF, 0.20))
            public static let commandBarMaterialOuterStroke = NSColor.orbitDynamic("Line.commandBarMaterialOuterStroke", light: .orbitSRGB(0x000000, 0.25), dark: .orbitSRGB(0x000000, 0.90))
            public static let commandBarMaterialInnerStroke = NSColor.orbitDynamic("Line.commandBarMaterialInnerStroke", light: .orbitSRGB(0x000000, 0.10), dark: .orbitSRGB(0xFFFFFF, 0.10))
            public static let commandBarHairline = NSColor.orbitDynamic("Line.commandBarHairline", light: .orbitSRGB(0x000000, 0.10), dark: .orbitSRGB(0xFFFFFF, 0.10))
            public static let commandBarOuterStroke = NSColor.orbitDynamic("Line.commandBarOuterStroke", light: .orbitSRGB(0x000000, 0.25), dark: .orbitSRGB(0x000000, 0.98))
            public static let commandBarInnerStroke = NSColor.orbitDynamic("Line.commandBarInnerStroke", light: .orbitSRGB(0xFFFFFF, 0.0), dark: .orbitSRGB(0xFFFFFF, 0.23))
            public static let popoverBorder = NSColor.orbitDynamic("Line.popoverBorder", light: .orbitSRGB(0xFFFFFF, 0.0), dark: .orbitSRGB(0xD3CEED, 0.20))
        }

        public enum FrameBrightness {
            public static let keyWindow: CGFloat = 1
            public static let nonKeyWindow: CGFloat = 1
            public static let observedRatio: CGFloat = 0.95
        }

        // MARK: Shadow colours
        public enum ShadowColor {
            ///  — none in dark.
            public static let tabSelected = NSColor.orbitDynamic("Shadow.tabSelected", light: .orbitSRGB(0x000000, 0.20), dark: .orbitSRGB(0x000000, 0.0))
            public static let popover = NSColor.orbitDynamic("Shadow.popover", light: .orbitP3(0x151C32, 0.30), dark: .orbitP3(0x151C32, 0.80))
            ///  — neutral black 50 %, identical in both appearances.
            public static let commandBar = NSColor.orbitSRGB(0x000000, 0.50)
            ///  — black 24 %, same relative depth in dark.
            public static let contentCard = NSColor.orbitSRGB(0x000000, 0.24)
        }

        // MARK: Accents
        public enum Accent {
            public static var focusRing: NSColor { .controlAccentColor }
            /// . : draws no glow
            /// around the card — loading is the capsule of `State.loadingTrack/loadingFill`.
            public static let loadingBorder = NSColor.orbitDynamic("Accent.loadingBorder", light: .orbitSRGB(0x0C50FF), dark: .orbitSRGB(0x2AB6F6))
            public static let brandBlue = NSColor.orbitP3(0x3139FB)
            public static var primaryButton: NSColor { .controlAccentColor }
            public static var primaryButtonHovered: NSColor { .controlAccentColor }
            public static var primaryButtonPressed: NSColor { .controlAccentColor }
            public static let destructive = NSColor.orbitSRGB(0xF53714)
            public static let error = NSColor.orbitP3(0xC93333)
            public static let lockInsecure = NSColor.orbitDynamic("Accent.lockInsecure", light: .orbitSRGB(0xF53714), dark: .orbitSRGB(0xF25E6B))
        }

        // MARK: Radix-like scales —
        public enum Scale {
            public static let grayLight: [UInt32] = [0xFCFCFC, 0xF8F8F8, 0xF3F3F3, 0xEDEDED, 0xE8E8E8, 0xE2E2E2, 0xDBDBDB, 0xC7C7C7, 0x8F8F8F, 0x858585, 0x6F6F6F, 0x171717]
            public static let grayDark: [UInt32] = [0x161616, 0x1C1C1C, 0x232323, 0x282828, 0x2E2E2E, 0x343434, 0x3E3E3E, 0x505050, 0x707070, 0x7E7E7E, 0xA0A0A0, 0xEDEDED]
            public static let indigoLight: [UInt32] = [0xFFFFFF, 0xF7F8FF, 0xF0F0FF, 0xE8E9FF, 0xD9DAFC, 0xC8CAFA, 0xAEB0F5, 0x8E91F0, 0x3138F9, 0x393ECC, 0x3438B2, 0x101245]
            public static let indigoDark: [UInt32] = [0x141421, 0x16162E, 0x191A40, 0x1C1D4F, 0x1F215C, 0x22246E, 0x272A8A, 0x2E32B2, 0x3239FA, 0x5458E8, 0x8589FF, 0xEDEEFC]

            /// Step 1…12 of the gray scale for the current appearance.
            public static func gray(_ step: Int) -> NSColor {
                precondition((1...12).contains(step))
                return .orbitDynamic("Scale.gray\(step)", light: .orbitSRGB(grayLight[step - 1]), dark: .orbitSRGB(grayDark[step - 1]))
            }
        }

        // MARK: Space theme picker swatches —
        public enum ThemePicker {
            public static let pastel: [NSColor] = [0xFDFBFA, 0xFBEAF3, 0xECD2EA, 0xF7CDD2, 0xFAE1D5, 0xFEF9E7, 0xE4FCEC, 0xE0F2FB, 0xC5C6E2].map { .orbitP3($0) }
            public static let drab: [NSColor] = [0x4B3B58, 0x623856, 0x854444, 0xA77048, 0xD1B46A, 0xCDCCA8, 0x84A885, 0x34604B, 0x2D4468].map { .orbitP3($0) }
            public static let greyscale: [NSColor] = [0xFFFFFF, 0xE5E5E5, 0xCCCCCC, 0xB2B2B2, 0x808080, 0x666666, 0x333333, 0x1A1A1A, 0x000000].map { .orbitP3($0) }
            /// Brand row; item 5 is stored as extended linear sRGB (1, 0.235, 0.098) ≈ sRGB #FF8558.
            public static let brand: [NSColor] = [
                .orbitSRGB(0xF2EAE4), .orbitSRGB(0xF29BBB), .orbitSRGB(0xA6729D), .orbitSRGB(0xF25E6B),
                NSColor(colorSpace: .extendedSRGB, components: [1.0, 0.522, 0.345, 1.0], count: 4),
                .orbitP3(0xF2D66D), .orbitP3(0x73E59C), .orbitP3(0x7EB8D6), .orbitP3(0x666786),
            ]
        }
    }
}

// MARK: - Space themes

extension OrbitTokens {
    /// One to three gradient stops with optional texture, painted behind the sidebar and frame.
    public struct SpaceTheme: Equatable, Sendable {
        public enum Mode: Sendable { case light, dark, automatic }
        public enum Texture: Sendable { case none, grain, denim, sand, tweed }

        public struct StopRange: Equatable, Sendable {
            public var light: ClosedRange<CGFloat>
            public var dark: ClosedRange<CGFloat>

            /// : multi-stop example themes run from corner to corner.
            public static let fullDiagonal = StopRange(light: 0...1, dark: 0...1)

            public func range(isDark: Bool) -> ClosedRange<CGFloat> { isDark ? dark : light }
        }

        /// Axis angle of each appearance's gradient (degrees from +x toward +y, top-left origin, points).
        public struct Angle: Equatable, Sendable {
            public var light: CGFloat
            public var dark: CGFloat

            /// : 43° (43.5° light / 42° dark fitted, one value kept).
            public static let measured = Angle(light: Gradient.angleDegrees, dark: Gradient.angleDegrees)

            public func degrees(isDark: Bool) -> CGFloat { isDark ? dark : light }
        }

        var frostAmount: CGFloat = 0
        var foregroundOverride: NSColor? = nil
        var meshCorners: [NSColor]? = nil
        public var stops: [NSColor]
        public var mode: Mode
        public var texture: Texture
        public var textureIntensity: CGFloat   //  0…1
        public var stopRange: StopRange = .fullDiagonal
        public var angle: Angle = .measured
        /// The stored Space theme this was rendered from; nil for built-in token themes.
        /// Accent derivation reads it; equality includes it.
        public var model: BrowserSpaceTheme?

        /// Default Space of — : two-stop gradient, light #D9DBF5 → #F3E5E5
        /// dark #252538 → #352337 (see Gradient). Whether every new Space gets it or a rotating default is
        /// not established.
        public static let `default` = SpaceTheme(
            stops: [NSColor.orbitDynamic("Theme.default.0", light: .orbitSRGB(0xD9DBF5), dark: .orbitSRGB(0x252538)),
                    NSColor.orbitDynamic("Theme.default.1", light: .orbitSRGB(0xF3E5E5), dark: .orbitSRGB(0x352337))],
            mode: .automatic, texture: .none, textureIntensity: 0,
            stopRange: StopRange(light: Gradient.startFraction.light...Gradient.endFraction.light,
                                 dark: Gradient.startFraction.dark...Gradient.endFraction.dark))
        public static let legacyFlat = SpaceTheme(stops: [.orbitSRGB(0xE6E6E8)], mode: .light, texture: .none, textureIntensity: 0)

        /// Gradient geometry of the default Space —  at window 1512 × 949.
        /// Axis at `angleDegrees` from +x toward +y (top-left → bottom-right, in points); the start colour is
        /// flat until `startDistance`, the end colour from `endDistance` (distances from the window's top-left
        /// corner along the axis). Scaling with the window size is unknown (one size captured): the fill keeps
        /// the same fractions of the window's projection on the axis ( for other sizes).
        public enum Gradient {
            public static let angleDegrees: CGFloat = 43
            public static let referenceSize = CGSize(width: 1512, height: 949)
            public static let startDistance: (light: CGFloat, dark: CGFloat) = (20, 160)
            public static let endDistance: (light: CGFloat, dark: CGFloat) = (1300, 1380)

            /// Projection of a window of `size` on the axis (top-left corner → bottom-right corner at 43°;
            /// for another angle, between the window corners with the lowest and highest projection).
            public static func axisLength(for size: CGSize, angleDegrees: CGFloat = angleDegrees) -> CGFloat {
                let angle = angleDegrees * .pi / 180
                return abs(size.width * cos(angle)) + abs(size.height * sin(angle))
            }

            public static var startFraction: (light: CGFloat, dark: CGFloat) {
                let length = axisLength(for: referenceSize)
                return (startDistance.light / length, startDistance.dark / length)
            }
            public static var endFraction: (light: CGFloat, dark: CGFloat) {
                let length = axisLength(for: referenceSize)
                return (endDistance.light / length, endDistance.dark / length)
            }
        }

        public static let amberCoral = SpaceTheme(stops: [.orbitSRGB(0xE4AA3B), .orbitSRGB(0xF17C5C), .orbitSRGB(0xF2606B)], mode: .light, texture: .grain, textureIntensity: 0.3)
        public static let lavender = SpaceTheme(stops: [.orbitSRGB(0xBDBEF1), .orbitSRGB(0xCDCDFE)], mode: .light, texture: .grain, textureIntensity: 0.3)
        public static let rosePlum = SpaceTheme(stops: [.orbitSRGB(0xF0848F), .orbitSRGB(0xA85396)], mode: .light, texture: .grain, textureIntensity: 0.3)
        public static let limeCitrus = SpaceTheme(stops: [.orbitSRGB(0xCDEB89), .orbitSRGB(0xDCE97B), .orbitSRGB(0xE6D051)], mode: .light, texture: .grain, textureIntensity: 0.3)
    }

    public struct ThemeAccent: Equatable, Sendable {
        public var strong: NSColor
        public var icon: NSColor
        public var iconFill: NSColor
        public var selection: NSColor
        public var soft: NSColor
        public var menuShortcut: NSColor
        public var menuSurface: NSColor
        public var sidebarText: NSColor
        var contrastTheme: SpaceTheme? = nil

        public var foreground: NSColor { sidebarText }
        public var sidebarSecondaryText: NSColor { icon }

        /// Focus follows the macOS control accent independently of the Space surface.
        public var splitFocusBorder: NSColor {
            .controlAccentColor
        }

        public static let defaultPurple = ThemeAccent(
            strong: .orbitSRGB(0x643EBC), icon: .orbitSRGB(0x503394), iconFill: .orbitSRGB(0xFAF7FE),
            selection: .orbitSRGB(0xB49EE4), soft: .orbitSRGB(0xE4DCF6), menuShortcut: .orbitSRGB(0xB49EE4),
            menuSurface: Color.Surface.popover, sidebarText: Color.Text.primary)

        public static let defaultSpace: ThemeAccent = {
            var accent = derived(hue: 237.0 / 360.0)
            accent.selection = .orbitDynamic("Accent.default.selection", light: .orbitSRGB(0x8F95FF), dark: .orbitSRGB(0x464DDC))
            accent.soft = .orbitDynamic("Accent.default.soft", light: .orbitSRGB(0xD3D4FF), dark: .orbitSRGB(0x2E3391))
            accent.menuShortcut = .orbitDynamic("Accent.default.menuShortcut", light: .orbitSRGB(0xA5AAFF), dark: .orbitSRGB(0x8F95FF))
            accent.menuSurface = .orbitDynamic("Accent.default.menuSurface", light: .orbitSRGB(0xFDFDFF), dark: .orbitSRGB(0x050627))
            accent.sidebarText = .orbitDynamic("Accent.default.sidebarText", light: .orbitSRGB(0x080C4E), dark: .orbitSRGB(0xDEDFFF))
            return accent
        }()

        public static func derived(hue: CGFloat) -> ThemeAccent {
            // sRGB HSB: the pairs were on sRGB pixels (calibrated HSB would brighten them, 0.31 → 0.38).
            func hsb(_ s: CGFloat, _ b: CGFloat) -> NSColor { NSColor(hue: hue, saturation: s, brightness: b, alpha: 1) }
            // Dynamic colours are named per hue so two derived families never share a name.
            let tag = Int((hue * 3600).rounded())
            func pair(_ name: String, _ light: (CGFloat, CGFloat), _ dark: (CGFloat, CGFloat)) -> NSColor {
                .orbitDynamic("\(name).\(tag)", light: hsb(light.0, light.1), dark: hsb(dark.0, dark.1))
            }
            return ThemeAccent(strong: hsb(0.67, 0.74),
                               icon: pair("Accent.icon", (0.65, 0.58), (0.13, 1.00)),
                               iconFill: pair("Accent.iconFill", (0.03, 1.00), (0.68, 0.15)),
                               selection: pair("Accent.selection", (0.44, 1.00), (0.68, 0.86)),
                               soft: pair("Accent.soft", (0.17, 1.00), (0.68, 0.57)),
                               menuShortcut: pair("Accent.menuShortcut", (0.35, 1.00), (0.44, 1.00)),
                               menuSurface: pair("Accent.menuSurface", (0.01, 1.00), (0.87, 0.15)),
                               sidebarText: pair("Accent.sidebarText", (0.90, 0.31), (0.13, 1.00)))
        }

        public static func derived(hue: CGFloat, saturation: CGFloat, strong: NSColor?) -> ThemeAccent {
            var accent: ThemeAccent
            if saturation < CGFloat(BrowserSpaceTheme.neutralSaturation) {
                accent = neutral
            } else {
                accent = derived(hue: hue)
                if saturation < CGFloat(BrowserSpaceTheme.greyishSaturation) {
                    let tag = Int((hue * 3600).rounded())
                    accent.sidebarText = .orbitDynamic("Accent.sidebarText.greyish.\(tag)",
                                                     light: NSColor(hue: hue, saturation: 0.26, brightness: 0.12, alpha: 1),
                                                     dark: NSColor(hue: hue, saturation: 0.05, brightness: 0.87, alpha: 1))
                }
            }
            if let strong { accent.strong = strong }
            return accent
        }

        /// Accent of a theme without hue (greyscale swatches) — .
        public static let neutral: ThemeAccent = {
            func grey(_ brightness: CGFloat) -> NSColor { NSColor(white: brightness, alpha: 1) }
            func pair(_ name: String, _ light: CGFloat, _ dark: CGFloat) -> NSColor {
                .orbitDynamic("Accent.neutral.\(name)", light: grey(light), dark: grey(dark))
            }
            return ThemeAccent(strong: grey(0.40), icon: pair("icon", 0.45, 0.88), iconFill: pair("iconFill", 1.0, 0.12),
                               selection: pair("selection", 0.69, 0.45), soft: pair("soft", 0.90, 0.30),
                               menuShortcut: pair("menuShortcut", 0.62, 0.70), menuSurface: pair("menuSurface", 0.99, 0.12),
                               sidebarText: pair("sidebarText", 0.12, 0.88))
        }()
    }
}


extension OrbitTokens {
    /// NSFont is not Sendable: fonts are main-actor tokens.
    @MainActor
    public enum Typography {
        ///  14 regular
        public static let sidebarTabTitle = BrandTextStyle.ui.font(size: 14, weight: .regular)
        ///  14 semibold
        public static let sidebarFolderTitle = BrandTextStyle.ui.font(size: 14, weight: .semibold)
        ///  13 semibold
        public static let sidebarSpaceTitle = BrandTextStyle.ui.font(size: 13, weight: .semibold)
        ///  14 regular
        public static let sidebarNewTab = BrandTextStyle.ui.font(size: 14, weight: .regular)
        ///  13 regular
        public static let addressField = BrandTextStyle.ui.font(size: 13, weight: .regular)
        public static let sidebarClear = BrandTextStyle.ui.font(size: 11, weight: .semibold)
        public static let commandBarInput = BrandTextStyle.ui.font(size: 18, weight: .medium)
        ///  13 medium
        public static let commandBarRowTitle = BrandTextStyle.ui.font(size: 13, weight: .medium)
        ///  13 medium
        public static let commandBarAccessory = BrandTextStyle.ui.font(size: 13, weight: .medium)
        ///  13 medium — sidebar "+" menu
        public static let menuItem = BrandTextStyle.ui.font(size: 13, weight: .medium)
        public static let menuShortcut = BrandTextStyle.mono.font(size: 13, weight: .regular)
        ///  — Space tooltip "Work ⌃2"
        public static let tooltip = BrandTextStyle.ui.font(size: 11, weight: .medium)
        public static let quickWindowDomain = BrandTextStyle.ui.font(size: 12, weight: .medium)
        public static let emptyStateTitle = BrandTextStyle.title.font(size: 22)
        public static let emptyStateDetail = BrandTextStyle.ui.font(size: 13, weight: .regular)
        ///  — page-zoom percentage shown inside the address field.
        public static let addressAccessory = BrandTextStyle.mono.font(size: 11, weight: .medium)
    }
}

// MARK: - Metrics (points; reference window 1024 × 640)

extension OrbitTokens {
    public enum Metrics {
        public enum Window {
            public static let trafficLightDiameter: CGFloat = 12
            public static let trafficLightPitch: CGFloat = 23
            public static let trafficLightFirstCenterX: CGFloat = 20
            public static let trafficLightCenterY: CGFloat = 24       // , from window top
            public static let minimumSize = NSSize(width: 600, height: 400)
            ///  — Little Orbit window buttons at 17 / 40 / 63, y 23.5.
            public static let quickWindowTrafficLightFirstCenterX: CGFloat = 17
            public static let quickWindowTrafficLightCenterY: CGFloat = 23.5
        }

        public enum Toolbar {
            public static let rowCenterY: CGFloat = 24
            /// : the sidebar toggle sits 27.25 after the third window button
            /// (87 with a pitch of 20, 93.25 with 23).
            public static let sidebarToggleFromThirdLight: CGFloat = 27.25
            public static func sidebarToggleCenterX(trafficLightPitch pitch: CGFloat) -> CGFloat {
                Window.trafficLightFirstCenterX + 2 * pitch + sidebarToggleFromThirdLight
            }
            /// The toggle position with the fallback pitch; the shell uses the system pitch.
            public static var sidebarToggleCenterX: CGFloat { sidebarToggleCenterX(trafficLightPitch: Window.trafficLightPitch) }
            /// : navigation cluster anchored to the sidebar's right edge.
            public static let backFromRight: CGFloat = 90.25
            public static let forwardFromRight: CGFloat = 56.25
            public static let reloadFromRight: CGFloat = 22
            public static let navPitch: CGFloat = 34
            public static let glyphSize: CGFloat = 15
            public static let compactBelowWidth: CGFloat = 224
            public static let compactBackFromRight: CGFloat = 76
            public static let compactForwardFromRight: CGFloat = 48
            public static let compactOverflowFromRight: CGFloat = 20
            ///  — compact arrows 13 × 10.5, overflow dots 13 × 3.
            public static let compactArrowGlyphSize = NSSize(width: 13, height: 10.5)
            public static let compactOverflowGlyphSize = NSSize(width: 13, height: 3)
            /// : full screen hides the window buttons; the toggle moves to x 28.6.
            public static let fullScreenSidebarToggleCenterX: CGFloat = 28.6
            public static let buttonHitSize: CGFloat = 28
        }

        public enum Sidebar {
            public static let widthDefault: CGFloat = 228
            public static let widthMin: CGFloat = 164                 //  clamp
            public static let widthMax: CGFloat = 500                 //  clamp
            public static let collapsePointerX: CGFloat = 82
            ///  — hover-revealed floating sidebar: 5 pt from the left and top edges.
            public static let floatingInset: CGFloat = 5
            public static let paddingX: CGFloat = 8
            public static let addressTop: CGFloat = 46
            public static let addressHeight: CGFloat = 36
            public static let addressTextInsetX: CGFloat = 12
            public static let favoritesTopGap: CGFloat = 8
            public static let favoriteTileHeight: CGFloat = 47
            public static let favoriteGap: CGFloat = 8
            public static let favoriteIconSize: CGFloat = 20
            public static let spaceTitleCenterFromFavorites: CGFloat = 27.5
            public static let firstRowCenterFromSpaceTitle: CGFloat = 36
            public static let rowHeight: CGFloat = 36
            public static let rowPitch: CGFloat = 41
            public static var rowSpacing: CGFloat { rowPitch - rowHeight }
            public static let rowInsetX: CGFloat = 10
            public static let faviconSize: CGFloat = 16
            public static let faviconCenterX: CGFloat = 26            // , window coords
            public static let titleOriginX: CGFloat = 44              // , window coords
            public static let iconTitleGap: CGFloat = 10
            public static let folderIconSize: CGFloat = 18
            public static let folderChildIndent: CGFloat = 16         // ; no chevrons
            public static let closeGlyphSize: CGFloat = 10.5
            public static let closeCenterFromRowRight: CGFloat = 18
            public static let closeButtonSize: CGFloat = 24
            /// : Space title x without a Space icon (44 with an icon, round 1).
            public static let spaceTitleOriginXWithoutIcon: CGFloat = 16
            /// : separator centre below the Space title when there is no pinned row
            /// (drawn only when Today is not empty).
            public static let separatorCenterFromSpaceTitle: CGFloat = 27.25
            public static let newTabCenterFromSeparator: CGFloat = 29.25
            /// : Today empty and no pinned tab → no separator at all.
            public static let newTabCenterFromSpaceTitleWhenEmpty: CGFloat = 40.5
            public static let clearTextRightInset: CGFloat = 19       // , from W
            /// : the separator stops 10.5 before the "Clear" text.
            public static let clearSeparatorGap: CGFloat = 10.5
            public static let favoriteRowGap: CGFloat = 8
            public static let separatorInsetX: CGFloat = 18
            public static let separatorCenterToRowCenter: CGFloat = 29 // , last pinned row → separator
            public static let newTabGlyphSize: CGFloat = 13
            public static let footerCenterFromBottom: CGFloat = 25
            public static let footerSideButtonCenterInset: CGFloat = 24
            public static let footerSpaceIconPitch: CGFloat = 34
            public static let footerGlyphSize: CGFloat = 15
            public static let footerInactiveSpaceOpacity: CGFloat = 0.45
            public static let plusMenuWidth: CGFloat = 210            //  fixed, right edge W − 8
            public static let plusMenuRightInset: CGFloat = 8
            public static let plusMenuArrowSize = NSSize(width: 12, height: 6)
            public static let plusMenuArrowCenterFromRight: CGFloat = 27
            public static let plusMenuItemPitch: CGFloat = 40
            public static let plusMenuHighlightInset: CGFloat = 8
            public static let plusMenuIconSize: CGFloat = 18
            public static let plusMenuTextOriginX: CGFloat = 50       // , from panel left
            public static let plusMenuSeparatorExtraGap: CGFloat = 17
            public static let favoriteSelectedRingWidth: CGFloat = 2

            public static let favoriteMinimumTileWidth: CGFloat = 45
            public static let favoriteMaximumColumns = 4
            public static func favoriteColumns(count: Int, sidebarWidth: CGFloat, minimumTileWidth: CGFloat = favoriteMinimumTileWidth) -> Int {
                guard count > 0 else { return 1 }
                let inner = sidebarWidth - 2 * paddingX
                // User report (2026-10-27): Orbit never shows more than 4 Favorites per row.
                let maxColumns = min(favoriteMaximumColumns, max(1, Int((inner + favoriteGap) / (max(1, minimumTileWidth) + favoriteGap))))
                let rows = (count + maxColumns - 1) / maxColumns
                return (count + rows - 1) / rows
            }

            // THEME lot additions — every value below is an estimate or derived from the measures above.
            /// Former name of `collapsePointerX` (round 1: proposed width < 90).
            public static var collapseWidth: CGFloat { collapsePointerX }
            public static var resizeHandleWidth: CGFloat { paddingX }
            public static var footerHeight: CGFloat { 2 * footerCenterFromBottom }
            public static let footerSpaceDotDiameter: CGFloat = 8
            public static let footerSpaceIconMinimumPitch: CGFloat = 24
            public static let footerSpaceDotPitch: CGFloat = 18
            public static let footerSpaceDotMinimumDiameter: CGFloat = 3
            ///  — hit square of footer glyphs and Space icons (= toolbar hit size).
            public static let footerButtonSize: CGFloat = 28
            ///  — Space-title centre below the address field when there is no Favorite
            /// (bottom of the Favorites + 27.5, the Favorites gap collapsing with them).
            public static var spaceTitleCenterFromAddressWithoutFavorites: CGFloat { spaceTitleCenterFromFavorites }
            public static var separatorCenterFromSpaceTitleWithoutPinned: CGFloat { separatorCenterFromSpaceTitle }
            public static let spaceIconSize: CGFloat = 16
            ///  — gap kept between the title and the hover-revealed close button.
            public static let titleTrailingGap: CGFloat = 4
        }

        public enum Content {
            public static let cardInset: CGFloat = 10
            public static let cardInsetSidebarHidden: CGFloat = 10
            public static let fullscreenHiddenSidebarInset: CGFloat = 0 // , radius 0
            public static let splitGap: CGFloat = 10                  //  (round 1 video: 8)
            public static let splitFocusBorderWidth: CGFloat = 2      // , inside the pane
            public static let splitDividerHandle = NSSize(width: 2, height: 24)
            public static let splitPaneToolbarHeight: CGFloat = 32    // , 0.5 pt hairline
            // THEME lot additions
            /// User report (2026-10-28): Orbit draws no border around the page card, in windowed or full
            /// screen; the earlier 0.5 pt reading (S-NT) was the shadow's edge. The card keeps its shadow only.
            public static let cardHairlineWidth: CGFloat = 0
            ///  — the card corners follow the inset to 0 in full screen with the sidebar hidden.
            public static let cardRadiusFullscreenHidden: CGFloat = 0
            public static let loadingCapsuleHeight: CGFloat = 4
            public static let loadingCapsuleWaitingWidth: CGFloat = 47
            public static let loadingCapsuleProgressWidth: CGFloat = 127.5
        }

        public enum CommandBar {
            public static let width: CGFloat = 765                    //  fixed at windows 1024 and 1512
            /// : fixed offset above the vertical centre (152 @640, 305.75 @949).
            public static let topOffsetAboveCenter: CGFloat = 168.5
            public static func top(windowHeight: CGFloat) -> CGFloat { windowHeight / 2 - topOffsetAboveCenter }
            /// The top at the reference height 640 (round 1 value 152); use `top(windowHeight:)`.
            public static var top: CGFloat { top(windowHeight: 640) }
            public static let searchRowHeight: CGFloat = 64
            public static let rowHeight: CGFloat = 46
            public static let rowPitch: CGFloat = 50
            public static let rowInsetX: CGFloat = 10
            public static let firstRowGap: CGFloat = 6
            public static let bottomPadding: CGFloat = 12
            public static let iconTileSize: CGFloat = 24
            public static let iconTileInsetX: CGFloat = 10
            public static let titleOriginX: CGFloat = 52
            public static let accessoryChipSize: CGFloat = 24
            public static let infoButtonSize: CGFloat = 24
            ///  — the outline is one device pixel (dark: plus one inner pixel).
            public static let outlineDevicePixels: CGFloat = 1
        }

        public enum QuickWindow {
            public static let toolbarHeight: CGFloat = 47             // ; page edge to edge below
            public static let defaultSize = NSSize(width: 1038, height: 909) //  may be remembered
            public static let addressPillHeight: CGFloat = 31         // , centre y 23.5
            public static let addressPillCenterY: CGFloat = 23.5
            public static let openInButtonSize = NSSize(width: 208, height: 30)
            /// : no card, no corner radius — the page fills the window below the bar.
            public static let pageIsEdgeToEdge = true
        }

        public enum Peek {
            ///  at window 1512: panel width = card width − 2 × 110, centred on the card.
            public static let panelInsetFromCardX: CGFloat = 110
            public static let panelTop: CGFloat = 12                  // , from the window top
            public static let underlyingCardRecede: CGFloat = 9       // , top/left/right
            public static let controlDiameter: CGFloat = 34           // , black circles right of the panel
            public static let controlPitch: CGFloat = 43.5
            public static let controlGapFromPanel: CGFloat = 13.25
            public static let controlTopInset: CGFloat = 7.5
            public static let controlGlyphSize: CGFloat = 16
            public static let hasInternalToolbar = false
            /// : page dim ≈63 % of a dark theme tint; the overlay also covers the sidebar.
            public static let cardDimOpacity: CGFloat = 0.63
        }

        public enum Split {
            ///  — the focused pane's 2 pt border is the theme's base swatch
            /// (`ThemeAccent.strong` for a swatch theme), drawn inside the pane; inactive panes keep the card shadow.
            public static var focusBorderWidth: CGFloat { Content.splitFocusBorderWidth }
        }
    }
}

// MARK: - Radii

extension OrbitTokens {
    public enum Radius {
        public static let contentCard: CGFloat = 6
        public static let splitPane: CGFloat = 6
        public static let addressField: CGFloat = 12
        public static let favoriteTile: CGFloat = 12
        public static let tabRow: CGFloat = 11
        public static let commandBar: CGFloat = 27
        public static let commandBarRow: CGFloat = 8
        public static let commandBarIconTile: CGFloat = 6
        public static let plusMenu: CGFloat = 12
        public static let plusMenuRow: CGFloat = 8
        public static let floatingSidebar: CGFloat = 12
        public static let peek: CGFloat = 8
        public static let findBar: CGFloat = 6
        public static let zoomHud: CGFloat = 9.5
        public static let toast: CGFloat = 11
        public static let themeEditor: CGFloat = 20
        public static let quickWindowAddress: CGFloat = 5
        public static let toolbarButtonHover: CGFloat = 6
        public static let closeButton: CGFloat = 6
        public static let tooltip: CGFloat = 7
    }
}

// MARK: - Shadows (blur = CSS blur = 2σ; CALayer.shadowRadius = blur / 2)

extension OrbitTokens {
    public struct ShadowSpec: Sendable {
        public var color: NSColor
        public var offsetY: CGFloat     // positive = downwards on screen
        public var blur: CGFloat

        /// Applies to a layer-backed view's layer. Flipped coordinate systems need -offsetY.
        @MainActor
        public func apply(to layer: CALayer, isFlipped: Bool = false, appearance: NSAppearance? = nil) {
            var cg: CGColor = color.cgColor
            (appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance { cg = color.cgColor }
            layer.shadowColor = cg
            layer.shadowOpacity = 1
            layer.shadowOffset = CGSize(width: 0, height: isFlipped ? offsetY : -offsetY)
            layer.shadowRadius = blur / 2
        }
    }

    public enum Shadow {
        ///  black 20 %, y 1, σ 1; none in dark.
        public static let tabSelected = ShadowSpec(color: Color.ShadowColor.tabSelected, offsetY: 1, blur: 2)
        ///  black 24 %; pair with Color.Line.floatingScrimBorder hairline.
        public static let contentCard = ShadowSpec(color: Color.ShadowColor.contentCard, offsetY: 1, blur: 6)
        ///  black 50 %, σ 48, RMS 0.54/255; no scrim behind the command bar.
        public static let commandBar = ShadowSpec(color: Color.ShadowColor.commandBar, offsetY: 24, blur: 96)
        ///  — sidebar "+" menu.
        public static let popover = ShadowSpec(color: .orbitSRGB(0x000000, 0.20), offsetY: 1, blur: 6)
        /// , RMS 0.18
        public static let floatingSidebar = ShadowSpec(color: .orbitSRGB(0x000000, 0.175), offsetY: 0, blur: 8)
        public static let peek = ShadowSpec(color: .orbitSRGB(0x000000, 0.30), offsetY: 1, blur: 8)
        ///  — light halo outside the focused split pane.
        public static let splitActiveHalo = ShadowSpec(color: .orbitSRGB(0xFFFFFF, 0.35), offsetY: 0, blur: 16)
        public static let findBar = ShadowSpec(color: .orbitSRGB(0x000000, 0.70), offsetY: 3, blur: 10)
        public static let dragPreview = ShadowSpec(color: .orbitSRGB(0x000000, 0.25), offsetY: 8, blur: 24)
    }
}

// MARK: - Materials

extension OrbitTokens {
    /// Orbit paints its window with an opaque Metal gradient (theme) — not vibrancy.
    /// Only system-owned surfaces (NSMenu, NSToolTip) keep their native material.
    public enum Material {
        case opaqueThemeFill          // window, docked & floating sidebar —
        case opaqueSurface(NSColor)
        case systemMenu               // NSMenu —
    }
}

// MARK: - Motion

extension OrbitTokens {
    /// SwiftUI-style spring. .
    public struct Spring: Equatable, Sendable {
        public var response: CFTimeInterval
        public var dampingFraction: CGFloat

        public var stiffness: CGFloat { let w = 2 * .pi / CGFloat(response); return w * w }
        public var damping: CGFloat { 4 * .pi * dampingFraction / CGFloat(response) }

        public func animation(keyPath: String) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = 1
            animation.stiffness = stiffness
            animation.damping = damping
            animation.initialVelocity = 0
            animation.duration = animation.settlingDuration
            return animation
        }
    }

    public enum Motion {
        /// PageSwipeController -> Motion.SpringAnimation, / .
        /// CoreVideo timestamps govern elapsed spring time; response is not wall-clock duration.
        public static let spaceSwitchSidebar = Spring(response: 0.4, dampingFraction: 1)
        /// PageSwipeController consumes half the AppKit scrolling delta .
        /// The sign is retained here because Orbit's list coordinates oppose Orbit's pager position.
        public static let spaceSwipeScrollScale: Double = 0.5
        /// : the page swaps instantly, no slide.
        public static let spaceSwitchContentIsInstant = true
        /// : command bar appears within one frame.
        public static let commandBarPresentIsInstant = true
        /// : ⌘S visible motion 73–85 ms, no visible overshoot; indicative fit 0.11 / 0.9.
        /// The single tunable of the ⌘S motion (hide and show, docking from the floating panel).
        public static let sidebarToggle = Spring(response: 0.11, dampingFraction: 0.9)
        /// WindowLayoutController passes style 5 to frame/frameOrigin spring animation
        /// . SpringAnimationStyle tables: /868.
        /// Native CASpringAnimation, response 0.18, dampingRatio 0.8; wall-clock time.
        public static let sidebarHoverReveal = Spring(response: 0.18, dampingFraction: 0.8)
        public static let sidebarHoverExit = sidebarHoverReveal
        public static let sidebarHoverEdgeTrigger: CGFloat = 5
        public static let sidebarHoverDwell: TimeInterval = 0.10  //  105–157 ms incl. ≤1 frame
        public static let sidebarHoverLeaveDelay: TimeInterval = 0.05 //  0–85 ms (fast exit)
        /// : resize tracks the pointer 1:1; collapse below the threshold is instant.
        public static let sidebarCollapseIsInstant = true
        /// : the following rows slide one pitch (RMS 0.22 pt); the new row appears
        /// at full height and fades in place; a closed row fades in place; the selection jumps.
        public static let tabInsertNeighbourSlide = Spring(response: 0.14, dampingFraction: 0.885)
        public static let tabInsertFade = Spring(response: 0.164, dampingFraction: 0.83)
        public static let tabCloseFade = Spring(response: 0.152, dampingFraction: 0.825)
        public static let tabSelectionIsInstant = true
        /// Former single insert/remove spring (round 1 estimate 0.25 / 1.0): now the neighbour slide.
        /// Use `tabInsertNeighbourSlide`, `tabInsertFade` and `tabCloseFade`.
        public static var tabInsertRemove: Spring { tabInsertNeighbourSlide }
        public static let folderExpand = Spring(response: 0.25, dampingFraction: 1.0)
        public static let rowReorder = Spring(response: 0.25, dampingFraction: 0.9)
        public static let hoverFillDuration: TimeInterval = 0
        public static let libraryCategoryFade: TimeInterval = 0.12
        public static let hoverControlsRevealDuration: TimeInterval = 0.12
        /// : Peek zooms out of the clicked link's rectangle (not a 0.94 scale);
        /// indicative fits for the frame, the page dim (≈34.5 %) and the dismiss dim.
        public static let peekPresent = Spring(response: 0.255, dampingFraction: 0.86)
        public static let peekDim = Spring(response: 0.23, dampingFraction: 0.90)
        public static let peekDismissDim = Spring(response: 0.265, dampingFraction: 0.82)
        public static let peekZoomsFromSourceRect = true
        /// : Peek → Split swaps the layout in one frame, then the newly visible
        /// pane's dim fades; focus moves with a ≈0.1 s border cross-fade; resize is 1:1; close is instant.
        public static let splitLayoutIsInstant = true
        public static let splitDimFade = Spring(response: 0.26, dampingFraction: 0.84)
        public static let splitFocusCrossfade: TimeInterval = 0.10
        /// Former split spring (estimate 0.30 / 0.9, contradicted): the layout is instant, the dim fades.
        public static var splitCreate: Spring { splitDimFade }
        /// : light ↔ dark repaints in one frame (no cross-fade).
        public static let themeModeSwitchIsInstant = true
        /// : theme editor zooms from its anchor and fades in (native popover-like).
        public static let themeEditorScale = Spring(response: 0.305, dampingFraction: 0.80)
        public static let themeEditorOpacity = Spring(response: 0.25, dampingFraction: 0.94)
        /// : Clear fades the rows (≈0.09 s), then the toast springs in.
        public static let clearTodayRowFade: TimeInterval = 0.09
        public static let clearToast = Spring(response: 0.33, dampingFraction: 0.60)
        /// : loading capsule in the top margin (no glow around the card).
        public static let loadingPulsePeriod: TimeInterval = 1.59
        public static let loadingSweepPeriod: TimeInterval = 1.12
        public static let loadingExpand = Spring(response: 0.78, dampingFraction: 0.90)
        public static let themeModeIconDurations: (sun: TimeInterval, moon: TimeInterval, automatic: TimeInterval) = (1.0, 1.5, 1.5)
        public static let reducedMotionCrossfade: TimeInterval = 0.12
        /// Honour "Reduce motion": springs become short cross-fades ().
        /// Reads the system setting each time, plus the `--reduce-motion` validation flag.
        @MainActor public static var prefersReducedMotion: Bool { OrbitMotionPreferences.prefersReducedMotion }
    }
}

// MARK: - Cursors

extension OrbitTokens {
    @MainActor
    public enum Cursor {
        /// : arrow over rows and buttons — never pointingHand.
        public static let rows = NSCursor.arrow
        public static let sidebarEdge = NSCursor.resizeLeftRight
        public static let tooltipDelay: TimeInterval = 0.5
    }
}
