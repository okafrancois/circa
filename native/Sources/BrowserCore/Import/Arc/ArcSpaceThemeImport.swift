import Foundation

public enum ArcSpaceThemeImport {
    public static func theme(for appearance: ArcSpaceAppearance) -> BrowserSpaceTheme? {
        let root = appearance.theme.flatMap { try? ArcJSON.parse(Data($0.utf8)) }
        var colors: [BrowserThemeColor] = []
        var intensity: Double?
        var noise: Double?
        var mode: BrowserSpaceTheme.Mode = .automatic
        if let root {
            let style = (root["background"]?.unwrapped["single"]?.unwrapped["style"] ?? root["style"])?.unwrapped
            let colorStyle = style?["color"]?.unwrapped ?? style
            let gradient = (colorStyle?["blendedGradient"] ?? root["blendedGradient"])?.unwrapped
            for item in gradient?["baseColors"]?.array ?? root["baseColors"]?.array ?? [] {
                if let color = Self.color(item) { colors.append(color) }
            }
            if colors.isEmpty, let basic = (colorStyle?["basicColor"] ?? root["basicColor"])?.unwrapped,
               let color = Self.color(basic) {
                colors = [color]
            }
            intensity = (gradient?["intensityFactor"] ?? root["intensityFactor"] ?? gradient?["modifiers"]?["intensityFactor"])?.number
            noise = (gradient?["noiseFactor"] ?? root["noiseFactor"] ?? gradient?["modifiers"]?["noiseFactor"])?.number
            mode = Self.mode(root["windowAppearance"] ?? root["colorScheme"] ?? root["appearance"])
        }
        if colors.isEmpty, let hex = appearance.colorHex, let color = BrowserThemeColor(hexString: hex) {
            colors = [color]
        }
        guard !colors.isEmpty else { return nil }
        let theme = BrowserSpaceTheme.composed(
            colors: Array(colors.prefix(BrowserSpaceTheme.maximumColors)),
            intensity: intensity.map { min(1, max(0, $0)) } ?? BrowserSpaceTheme.defaultIntensity,
            noise: noise.map { min(1, max(0, $0)) } ?? 0, mode: mode)
        return theme.isValid ? theme : nil
    }

    /// `{red, green, blue[, alpha][, colorSpace]}` (or `r/g/b`), possibly under `color` / `_0`.
    static func color(_ raw: ArcJSON) -> BrowserThemeColor? {
        var value = raw.unwrapped
        if let nested = value["color"] { value = nested.unwrapped }
        if let text = value.string { return BrowserThemeColor(hexString: text) }
        let components = [value["red"] ?? value["r"], value["green"] ?? value["g"], value["blue"] ?? value["b"]].map { $0?.number }
        guard components.allSatisfy({ $0 != nil }) else { return nil }
        let space: BrowserThemeColor.Space = (value["colorSpace"]?.string?.lowercased().contains("p3") == true) ? .displayP3 : .sRGB
        // Extended-range components are clamped to the encoded gamut.
        let clamped = components.map { min(1, max(0, $0!)) }
        let color = BrowserThemeColor(red: clamped[0], green: clamped[1], blue: clamped[2],
                                      alpha: min(1, max(0, value["alpha"]?.number ?? 1)), space: space)
        return color.isValid ? color : nil
    }

    static func mode(_ raw: ArcJSON?) -> BrowserSpaceTheme.Mode {
        guard let raw else { return .automatic }
        let value = raw.unwrapped
        let name = value.string?.lowercased() ?? value.object?.keys.sorted().first?.lowercased() ?? ""
        if name.contains("dark") { return .dark }
        if name.contains("light") { return .light }
        return .automatic
    }
}

public extension BrowserSpaceAppearanceDocument {
    /// IMPORT's sidecar next to a session (`Import/space-appearance.json`), read through the import
    /// directory's descriptor-relative reader; nil when absent, unreadable or of another schema.
    static func load(at location: ArcImportDataLocation) -> BrowserSpaceAppearanceDocument? {
        guard let document = ArcImportFiles.read(Self.self, from: location.appearanceFile), document.version == 1 else { return nil }
        return document
    }
}
