import Foundation

/// Calibrated radial picker. Angles run clockwise from red; the centre is black and the rim white.
/// Encoded-sRGB interpolation keeps the saturated middle ring separate from the pale outer ring.
public enum BrowserRadialThemePalette {
    static let radii = [0.0, 0.2, 0.6, 0.95, 1.0]
    static let picks: [[UInt32]] = [
        [0x720000, 0xFF0018, 0xFFDADB],
        [0x6D4D00, 0xFFC800, 0xFFF6D9],
        [0x1B6A00, 0x6DFF00, 0xE9FFD9],
        [0x006A01, 0x00FF44, 0xD3FFE3],
        [0x006A69, 0x00FFFF, 0xD3FFFF],
        [0x001B6C, 0x1465FF, 0xDAE5FF],
        [0x3A006C, 0xA423FF, 0xF1DBFF],
        [0x720050, 0xFF00D0, 0xFFDAF8],
    ]
    static let fills: [[UInt32]] = [
        [0x8B393C, 0xF44F57, 0xE7CACB],
        [0x846F35, 0xE9BE45, 0xE3DCC9],
        [0x568233, 0x8AE43E, 0xD3E2C9],
        [0x1A8349, 0x00E672, 0xC6E3D0],
        [0x1A8382, 0x00E6E4, 0xC6E3E2],
        [0x3A5085, 0x527FE9, 0xCAD1E4],
        [0x663C85, 0xAA58EA, 0xD8CBE4],
        [0x8B3973, 0xF44FC5, 0xE7CADD],
    ]

    static func mix(_ a: BrowserThemeColor, _ b: BrowserThemeColor, _ p: Double) -> BrowserThemeColor {
        BrowserThemeColor(red: a.red + (b.red - a.red) * p, green: a.green + (b.green - a.green) * p,
                          blue: a.blue + (b.blue - a.blue) * p)
    }

    static func sample(angle: Double, radius: Double, rendered: Bool) -> BrowserThemeColor {
        let a = (angle - floor(angle)) * 8, sector = Int(a) % 8
        let r = min(1, max(0, radius)), table = rendered ? fills : picks
        let segment = min(3, radii.dropFirst().firstIndex(where: { r <= $0 })! - 1)
        func ring(_ index: Int) -> BrowserThemeColor {
            if index == 0 { return BrowserThemeColor(hex: rendered ? 0x433F3F : 0) }
            if index == 4 { return BrowserThemeColor(hex: rendered ? 0xE2E2E2 : 0xFFFFFF) }
            return mix(BrowserThemeColor(hex: table[sector][index - 1]),
                       BrowserThemeColor(hex: table[(sector + 1) % 8][index - 1]), a - floor(a))
        }
        return mix(ring(segment), ring(segment + 1), (r - radii[segment]) / (radii[segment + 1] - radii[segment]))
    }

    public static func color(at point: CGPoint) -> BrowserThemeColor {
        let x = Double(point.x) * 2 - 1, y = Double(point.y) * 2 - 1
        return sample(angle: atan2(y, x) / (2 * .pi), radius: hypot(x, y), rendered: false)
    }

    /// Inverse also accepts imported colours: the closest visible wheel colour preserves their intent.
    public static func position(of color: BrowserThemeColor) -> CGPoint {
        let c = color.sRGB
        func error(_ a: Double, _ r: Double) -> Double {
            let v = sample(angle: a, radius: r, rendered: false)
            return pow(c.red - v.red, 2) + pow(c.green - v.green, 2) + pow(c.blue - v.blue, 2)
        }
        var best = (angle: 0.0, radius: 0.0, error: Double.infinity)
        for a in 0..<64 {
            for r in 0...20 {
                let angle = Double(a) / 64, radius = Double(r) / 20, e = error(angle, radius)
                if e < best.error { best = (angle, radius, e) }
            }
        }
        var step = 1.0 / 32
        for _ in 0..<14 {
            for da in [-step, 0, step] {
                for dr in [-step, 0, step] {
                    let a = best.angle + da, r = min(1, max(0, best.radius + dr)), e = error(a, r)
                    if e < best.error { best = (a, r, e) }
                }
            }
            step /= 2
        }
        return CGPoint(x: 0.5 + cos(best.angle * 2 * .pi) * best.radius / 2,
                       y: 0.5 + sin(best.angle * 2 * .pi) * best.radius / 2)
    }

    /// Intensity changes saturation and value independently; `calibratedAt` identifies the source fill.
    public static func intensityAdjusted(_ color: BrowserThemeColor, intensity: Double, calibratedAt: Double) -> BrowserThemeColor {
        let gains = [0.28, 0.48, 0.61, 0.82, 1.0], values = [0.931, 0.927, 0.931, 0.963, 1.0]
        func sample(_ v: [Double], _ position: Double) -> Double {
            let t = min(1, max(0, position)) * 4, i = min(3, Int(t))
            return v[i] + (v[i + 1] - v[i]) * (t - Double(i))
        }
        let (h, s, b) = color.hsb
        return BrowserThemeColor(hue: h, saturation: min(1, s * sample(gains, intensity) / sample(gains, calibratedAt)),
                                 brightness: min(1, b * sample(values, intensity) / sample(values, calibratedAt)))
    }

    public static func rendered(_ color: BrowserThemeColor, intensity: Double, mode: BrowserSpaceTheme.Mode) -> BrowserThemeColor {
        let p = position(of: color), x = Double(p.x) * 2 - 1, y = Double(p.y) * 2 - 1
        let base = sample(angle: atan2(y, x) / (2 * .pi), radius: hypot(x, y), rendered: true)
        let result = intensityAdjusted(base, intensity: intensity, calibratedAt: 0.78)
        let lift = mode == .light ? 15.0 / 255 : 0
        return BrowserThemeColor(red: min(1, result.red + lift), green: min(1, result.green + lift), blue: min(1, result.blue + lift))
    }
}
