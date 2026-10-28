import Foundation

/// The theme editor's swatch pages and the default Space theme (ORBIT-THEMES).
/// Swatch values:
/// (docs/native-port/design/tokens.json `themePicker`). Page order Brand → Pastel → Drab → Greyscale is a
/// reconstruction: C06 shows nine swatches between ‹ › chevrons with ‹ dimmed on the Brand page.
public enum BrowserSpaceThemePresets {
    public struct Family: Equatable, Sendable {
        public let id: String
        public let swatches: [BrowserThemeColor]
    }

    public static let defaultID = "orbit.default"

    /// 's default Space — : light #D9DBF5 → #F3E5E5 flat until 20 pt and
    /// from 1300 pt, dark #252538 → #352337 at 160 / 1380 pt, along a 43° axis of a 1512 × 949 window.
    public static let `default`: BrowserSpaceTheme = {
        let axis = 1512 * cos(43 * Double.pi / 180) + 949 * sin(43 * Double.pi / 180)
        return BrowserSpaceTheme(
            presetID: defaultID, mode: .automatic, colors: [], intensity: BrowserSpaceTheme.defaultIntensity, noise: 0,
            light: .init(stops: [.init(hex: 0xD9DBF5), .init(hex: 0xF3E5E5)], start: 20 / axis, end: 1300 / axis),
            dark: .init(stops: [.init(hex: 0x252538), .init(hex: 0x352337)], start: 160 / axis, end: 1380 / axis))
    }()

    public static let brand = Family(id: "brand", swatches: [
        .init(hex: 0xF2EAE4), .init(hex: 0xF29BBB), .init(hex: 0xA6729D), .init(hex: 0xF25E6B),
        // extendedLinearSRGB (1, 0.235, 0.098) stored by Orbit, encoded sRGB.
        .init(red: 1.0, green: 0.522, blue: 0.345),
        .init(hex: 0xF2D66D, space: .displayP3), .init(hex: 0x73E59C, space: .displayP3),
        .init(hex: 0x7EB8D6, space: .displayP3), .init(hex: 0x666786, space: .displayP3),
    ])
    public static let pastel = Family(id: "pastel", swatches: [
        0xFDFBFA, 0xFBEAF3, 0xECD2EA, 0xF7CDD2, 0xFAE1D5, 0xFEF9E7, 0xE4FCEC, 0xE0F2FB, 0xC5C6E2,
    ].map { BrowserThemeColor(hex: $0, space: .displayP3) })
    public static let drab = Family(id: "drab", swatches: [
        0x4B3B58, 0x623856, 0x854444, 0xA77048, 0xD1B46A, 0xCDCCA8, 0x84A885, 0x34604B, 0x2D4468,
    ].map { BrowserThemeColor(hex: $0, space: .displayP3) })
    public static let greyscale = Family(id: "greyscale", swatches: [
        0xFFFFFF, 0xE5E5E5, 0xCCCCCC, 0xB2B2B2, 0x808080, 0x666666, 0x333333, 0x1A1A1A, 0x000000,
    ].map { BrowserThemeColor(hex: $0, space: .displayP3) })

    public static let families = [brand, pastel, drab, greyscale]

    /// `<family>.<1-based index>`, e.g. `brand.9`.
    public static func presetID(family: Family, index: Int) -> String { "\(family.id).\(index + 1)" }

    /// A single-swatch theme at the default intensity.
    public static func theme(family: Family, index: Int, mode: BrowserSpaceTheme.Mode = .automatic) -> BrowserSpaceTheme? {
        guard family.swatches.indices.contains(index) else { return nil }
        return .composed(colors: [family.swatches[index]], mode: mode, presetID: presetID(family: family, index: index))
    }

    /// Resolves a stored preset identifier (for the editor's swatch selection).
    public static func swatch(for presetID: String) -> (family: Family, index: Int)? {
        let parts = presetID.split(separator: ".")
        guard parts.count == 2, let family = families.first(where: { $0.id == parts[0] }),
              let number = Int(parts[1]), family.swatches.indices.contains(number - 1) else { return nil }
        return (family, number - 1)
    }
}
