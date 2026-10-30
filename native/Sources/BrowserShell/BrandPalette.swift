import AppKit
import BrowserCore

/// Shared brand colours. Controls use the user’s system accent independently of these colours.
public enum BrandPalette {
    public static var controlAccent: NSColor { .controlAccentColor }
    public static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    public static let stage = rgb(0x0E0E11), stage2 = rgb(0x18181D), stage3 = rgb(0x26252B)
    public static let paper = rgb(0xF6F3EE), paper2 = rgb(0xECE8E1)
    public static let ink = rgb(0x141317), ink2 = rgb(0x5E5A66), ink3 = rgb(0x96929E)
    public static let coral = rgb(0xFF5A5F), cobalt = rgb(0x2D5BFF), violet = rgb(0x7B4DFF)
    public static let sun = rgb(0xFFD23F), mint = rgb(0x3DCCA0)
    public static let stageText = rgb(0xF4F1EC), stageMuted = rgb(0xB9B5BF)
    public static let controlBorder = rgb(0xC9C4CE), inactiveDot = rgb(0xDCD7DF)
    public static let glowColors = [stage.blended(withFraction: 0.45, of: coral)!.cgColor, stage.blended(withFraction: 0.3, of: violet)!.cgColor, stage.cgColor]
    public static let siteColors = [rgb(0xEA4335), rgb(0x4285F4), rgb(0xFF0000), ink, rgb(0x24292F), rgb(0xA259FF), NSColor.black, rgb(0x636466)]
    public static let sidebarPreviewColors = [paper.blended(withFraction: 0.7, of: coral)!.cgColor, coral.cgColor, violet.cgColor]
    public static let glowStops: [NSNumber] = [0, 0.52, 0.76]
    public struct SpaceGradient: Sendable {
        public let id: String
        public let name: String
        public let stops: [BrowserThemeColor]
        public let locations: [Double]
        public let angleDegrees: Double = 80

        public func theme(mode: BrowserSpaceTheme.Mode = .automatic) -> BrowserSpaceTheme {
            let gradient = BrowserSpaceTheme.Gradient(stops: stops, angleDegrees: angleDegrees, locations: locations)
            return BrowserSpaceTheme(presetID: "brand." + id, mode: mode, colors: [stops[0], stops[2]],
                intensity: BrowserSpaceTheme.defaultIntensity, noise: 0, light: gradient, dark: gradient)
        }
    }
    public static let spaceGradients: [SpaceGradient] = [
        .init(id: "coral", name: "Coral", stops: [0xFF8A7A, 0xFF5A5F, 0x7B4DFF].map { .init(hex: $0) }, locations: [0, 0.45, 1]),
        .init(id: "cobalt", name: "Cobalt", stops: [0x6E9BFF, 0x2D5BFF, 0x1B2C8F].map { .init(hex: $0) }, locations: [0, 0.45, 1]),
        .init(id: "sunset", name: "Sunset", stops: [0xFFE27A, 0xFF9F45, 0xFF5A5F].map { .init(hex: $0) }, locations: [0, 0.5, 1]),
        .init(id: "mint", name: "Mint", stops: [0xA7F3D6, 0x3DCCA0, 0x2D5BFF].map { .init(hex: $0) }, locations: [0, 0.5, 1]),
        .init(id: "night", name: "Night", stops: [0x3A3550, 0x1C1A26, 0x0E0E11].map { .init(hex: $0) }, locations: [0, 0.55, 1]),
        .init(id: "lilac", name: "Lilac", stops: [0xF4ECFF, 0xD9C6FF, 0xB79BFF].map { .init(hex: $0) }, locations: [0, 0.5, 1]),
    ]
    /// Public AppKit material approximates the board's blur/saturation; the API exposes no radius.
    public enum Frost {
        public static let material: NSVisualEffectView.Material = .popover
        public static let tint: CGFloat = 0.5
        public static func edge(dark: Bool) -> CGFloat { dark ? 0.18 : 0.75 }
        public static func top(dark: Bool) -> CGFloat { dark ? 0.22 : 0.9 }
        public static func highlight(dark: Bool) -> CGFloat { dark ? 0.18 : 0.5 }
        public static let highlightEnd: NSNumber = 0.4
        public static let shadowOpacity: Float = 0.45
        public static let shadowRadius: CGFloat = 30
        public static let shadowOffset = NSSize(width: 0, height: -15)
    }
}
