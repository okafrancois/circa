import AppKit
import BrowserCore

/// Shared brand colours. Controls use the user’s system accent independently of these colours.
public enum BrandPalette {
    public static var controlAccent: NSColor { cobalt }
    public static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    public static let stage = rgb(0xF6F1E7), stage2 = rgb(0x1B2057), stage3 = rgb(0x292F6B)
    public static let paper = rgb(0xF6F1E7), paper2 = rgb(0xFFFDF7)
    public static let ink = rgb(0x1B2057), ink2 = rgb(0x515580), ink3 = rgb(0x777B9C)
    public static let coral = rgb(0xFF5A36), cobalt = rgb(0x2F4FE3), violet = rgb(0xFF9DB8)
    public static let sun = rgb(0xFFC83D), mint = rgb(0xCFDCFA)
    public static let stageText = rgb(0x1B2057), stageMuted = rgb(0x515580)
    public static let controlBorder = rgb(0x1B2057), inactiveDot = rgb(0xDCD7DF)
    public static let sky = rgb(0xCFDCFA), pageWhite = rgb(0xFFFDF7)
    public static let glowColors = [sky.cgColor, paper.cgColor, paper.cgColor]
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
                intensity: BrowserSpaceTheme.defaultIntensity, noise: 0.3, light: gradient, dark: gradient)
        }
    }
    public static let spaceGradients: [SpaceGradient] = [
        .init(id: "coral", name: "Work", stops: Array(repeating: .init(hex: 0xFBDFD5), count: 3), locations: [0, 0.5, 1]),
        .init(id: "cobalt", name: "Home", stops: Array(repeating: .init(hex: 0xDCE3FB), count: 3), locations: [0, 0.5, 1]),
        .init(id: "sunset", name: "Reading", stops: Array(repeating: .init(hex: 0xFAEBBB), count: 3), locations: [0, 0.5, 1]),
        .init(id: "lilac", name: "Side project", stops: Array(repeating: .init(hex: 0xFBDCE5), count: 3), locations: [0, 0.5, 1]),
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
