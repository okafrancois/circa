import Foundation

/// A theme colour as Orbit stores it: encoded components in a named RGB space.
/// Engine- and AppKit-independent; the shell builds its `NSColor`s from these components.
public struct BrowserThemeColor: Codable, Hashable, Sendable {
    public enum Space: String, Codable, Sendable { case sRGB, displayP3 }

    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public var space: Space

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1, space: Space = .sRGB) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.space = space
    }

    /// A 0xRRGGBB literal, components as stored by Orbit.
    public init(hex: UInt32, space: Space = .sRGB) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, space: space)
    }

    /// `#rrggbb` (case-insensitive); nil for anything else.
    public init?(hexString: String, space: Space = .sRGB) {
        guard hexString.wholeMatch(of: /#[0-9A-Fa-f]{6}/) != nil,
              let value = UInt32(hexString.dropFirst(), radix: 16) else { return nil }
        self.init(hex: value, space: space)
    }

    /// sRGB colour from hue, saturation and brightness (all 0…1, hue wraps).
    public init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        let h = (hue - hue.rounded(.down)) * 6
        let s = min(1, max(0, saturation)), v = min(1, max(0, brightness))
        let sector = Int(h) % 6, f = h - h.rounded(.down)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double) = switch sector {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        self.init(red: r, green: g, blue: b, alpha: alpha, space: .sRGB)
    }

    public var isValid: Bool {
        [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    /// The colour in sRGB. Display P3 goes through linear light (same transfer curve) and is
    /// clamped to the sRGB gamut.
    public var sRGB: BrowserThemeColor {
        guard space == .displayP3 else { return self }
        let linear = [red, green, blue].map(Self.linearized)
        let m = Self.displayP3ToSRGB
        let converted = (0..<3).map { row in
            Self.encoded(min(1, max(0, m[row][0] * linear[0] + m[row][1] * linear[1] + m[row][2] * linear[2])))
        }
        return BrowserThemeColor(red: converted[0], green: converted[1], blue: converted[2], alpha: alpha, space: .sRGB)
    }

    /// `#rrggbb` of the sRGB colour.
    public var hexString: String {
        let c = sRGB
        return "#" + [c.red, c.green, c.blue].map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }

    /// Hue, saturation and brightness of the sRGB colour (hue 0…1; 0 for greys).
    public var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let c = sRGB
        let maximum = max(c.red, c.green, c.blue), minimum = min(c.red, c.green, c.blue)
        let delta = maximum - minimum
        guard maximum > 0, delta > 1e-9 else { return (0, 0, maximum) }
        var hue: Double
        if maximum == c.red { hue = (c.green - c.blue) / delta }
        else if maximum == c.green { hue = 2 + (c.blue - c.red) / delta }
        else { hue = 4 + (c.red - c.green) / delta }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / maximum, maximum)
    }

    static func linearized(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    static let displayP3ToSRGB: [[Double]] = {
        let p3ToXYZ = [[0.4865709486, 0.2656676932, 0.1982172852],
                       [0.2289745641, 0.6917385218, 0.0792869141],
                       [0.0000000000, 0.0451133819, 1.0439443689]]
        let xyzToSRGB = [[3.2404542, -1.5371385, -0.4985314],
                         [-0.9692660, 1.8760108, 0.0415560],
                         [0.0556434, -0.2040259, 1.0572252]]
        return (0..<3).map { row in (0..<3).map { column in (0..<3).reduce(0) { $0 + xyzToSRGB[row][$1] * p3ToXYZ[$1][column] } } }
    }()
}

/// Applied to one Space only. The old secondary settings draft is never imported implicitly.
public struct BrowserThemeSurface: Codable, Hashable, Sendable {
    public enum Material: String, Codable, CaseIterable, Sendable { case solid, frosted, liquidGlass }
    public var material: Material
    /// 0 is opaque; 1 leaves a 12% gradient veil over the native material. Not window alpha.
    public var transparency: Double
    public init(material: Material = .liquidGlass, transparency: Double = 0.65) {
        self.material = material
        self.transparency = transparency
    }
    public var isValid: Bool { transparency.isFinite && (0...1).contains(transparency) }
}

public struct BrowserSpaceTheme: Codable, Hashable, Sendable {
    public static let maximumColors = 3
    /// : the default gradient's axis runs at 43° from the top-left corner.
    public static let defaultAngleDegrees = 43.0

    public enum Mode: String, Codable, CaseIterable, Sendable {
        case automatic, light, dark
    }

    public struct Gradient: Codable, Hashable, Sendable {
        /// One to three stops, first at `start` and last at `end` along the axis.
        public var stops: [BrowserThemeColor]
        /// Axis angle in degrees from +x toward +y, top-left origin, in points.
        public var angleDegrees: Double
        /// Positions of the first and last stop as fractions of the window's projection on the axis.
        public var start: Double
        public var end: Double

        public init(stops: [BrowserThemeColor], angleDegrees: Double = BrowserSpaceTheme.defaultAngleDegrees,
                    start: Double = 0, end: Double = 1) {
            self.stops = stops
            self.angleDegrees = angleDegrees
            self.start = start
            self.end = end
        }

        public var isValid: Bool {
            (1...BrowserSpaceTheme.maximumColors).contains(stops.count) && stops.allSatisfy(\.isValid)
                && angleDegrees.isFinite && (0..<360).contains(angleDegrees)
                && start.isFinite && end.isFinite && 0 <= start && start < end && end <= 1
        }
    }

    /// Nil preserves the pre-existing shell policy; older documents decode without migration.
    public var surface: BrowserThemeSurface?
    public var presetID: String?
    public var mode: Mode
    public var colors: [BrowserThemeColor]
    public var intensity: Double
    public var noise: Double
    public var light: Gradient
    public var dark: Gradient

    public init(presetID: String? = nil, mode: Mode, colors: [BrowserThemeColor], intensity: Double, noise: Double,
                light: Gradient, dark: Gradient, surface: BrowserThemeSurface? = nil) {
        self.surface = surface
        self.presetID = presetID
        self.mode = mode
        self.colors = colors
        self.intensity = intensity
        self.noise = noise
        self.light = light
        self.dark = dark
    }

    public var isValid: Bool {
        (surface?.isValid ?? true) && colors.count <= Self.maximumColors && colors.allSatisfy(\.isValid)
            && intensity.isFinite && (0...1).contains(intensity) && noise.isFinite && (0...1).contains(noise)
            && light.isValid && dark.isValid && presetID.map(Self.isValidPresetID) ?? true
    }

    public func validate() throws {
        guard isValid else { throw BrowserSessionError.invalidSpaceTheme }
    }

    static func isValidPresetID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x2E || byte == 0x2D
        }
    }

    public func gradient(isDark: Bool) -> Gradient { isDark ? dark : light }
}


extension BrowserSpaceTheme {
    public static let defaultIntensity = 0.78

    public static func composed(colors: [BrowserThemeColor], intensity: Double = defaultIntensity, noise: Double = 0,
                                mode: Mode = .automatic, presetID: String? = nil) -> BrowserSpaceTheme {
        let colors = Array(colors.prefix(maximumColors))
        guard !colors.isEmpty else {
            var theme = BrowserSpaceThemePresets.default
            theme.mode = mode
            return theme
        }
        let intensity = min(1, max(0, intensity.isFinite ? intensity : defaultIntensity))
        let noise = min(1, max(0, noise.isFinite ? noise : 0))
        let light = colors.map { lightStop(for: $0, intensity: intensity) }
        let dark = colors.map { darkStop(for: $0, intensity: intensity) }
        return BrowserSpaceTheme(presetID: presetID, mode: mode, colors: colors, intensity: intensity, noise: noise,
                                 light: Gradient(stops: light), dark: Gradient(stops: dark))
    }

    public static func lightStop(for color: BrowserThemeColor, intensity: Double) -> BrowserThemeColor {
        let (h, s, b) = color.hsb
        return BrowserThemeColor(hue: h, saturation: s * 0.8 * intensity, brightness: b)
    }

    public static func darkStop(for color: BrowserThemeColor, intensity: Double) -> BrowserThemeColor {
        let (h, s, b) = color.hsb
        return BrowserThemeColor(hue: h, saturation: min(1, 0.25 + 0.8 * intensity * s), brightness: 0.12 + 0.10 * b)
    }

    /// The same picks with another mode, intensity, grain or colour list.
    public func recomposed(colors: [BrowserThemeColor]? = nil, intensity: Double? = nil, noise: Double? = nil,
                           mode: Mode? = nil) -> BrowserSpaceTheme {
        let colors = colors ?? self.colors
        let mode = mode ?? self.mode
        // A designed preset keeps its painted variants while nothing is picked.
        if colors.isEmpty {
            var theme = self.colors.isEmpty ? self : BrowserSpaceThemePresets.default
            theme.mode = mode
            theme.surface = surface
            return theme
        }
        var result = Self.composed(colors: colors, intensity: intensity ?? self.intensity, noise: noise ?? self.noise,
                                   mode: mode, presetID: colors == self.colors ? presetID : nil)
        result.surface = surface
        return result
    }
}


/// Which accent family a theme gets; the shell maps it to its colour tokens.
public enum BrowserThemeAccentFamily: Equatable, Sendable {
    case defaultSpace
    case derived(hue: Double, saturation: Double, strong: BrowserThemeColor?)
}

extension BrowserSpaceTheme {
    /// Below this light-variant saturation, sidebar titles use the greyish pair on the mauve,
    /// green and grey-mauve Spaces (S 0.22–0.30, B 0.11–0.13). .
    public static let greyishSaturation = 0.2
    /// Below this, a theme has no usable hue: accents are neutral greys. .
    public static let neutralSaturation = 0.05

    /// Provisional rule: hue of the most saturated painted stop of the light variant; the default
    /// preset keeps its family.
    public var accentFamily: BrowserThemeAccentFamily {
        if colors.isEmpty, presetID == BrowserSpaceThemePresets.defaultID { return .defaultSpace }
        let stops = light.stops.map(\.hsb)
        guard let base = stops.max(by: { $0.saturation < $1.saturation }) else { return .defaultSpace }
        let strong = colors.max { $0.hsb.saturation < $1.hsb.saturation }
        return .derived(hue: base.hue, saturation: base.saturation, strong: strong)
    }
}
