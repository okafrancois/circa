import BrowserCore
import Foundation

/// Position ↔ colour of the editor's dotted field. Horizontal position controls hue
/// with a 74° offset; vertical position controls saturation (S = v^0.8, grey at the top).
/// Brightness stays at 0.675.
enum OrbitThemeFieldMapping {
    static let hueOffset = 74.0 / 360
    static let saturationExponent = 0.8
    static let brightness = 0.675

    /// `unit`: 0…1 in both axes, top-left origin.
    static func color(at unit: CGPoint) -> BrowserThemeColor {
        let u = min(1, max(0, Double(unit.x))), v = min(1, max(0, Double(unit.y)))
        let hue = (u + hueOffset).truncatingRemainder(dividingBy: 1)
        return BrowserThemeColor(hue: hue, saturation: pow(v, saturationExponent), brightness: brightness)
    }

    /// Handle position of any colour (swatches and imports keep their own brightness).
    static func position(of color: BrowserThemeColor) -> CGPoint {
        let (hue, saturation, _) = color.hsb
        var u = hue - hueOffset
        if u < 0 { u += 1 }
        return CGPoint(x: u, y: pow(saturation, 1 / saturationExponent))
    }
}

/// The editor's model, without AppKit: the draft theme, the selected handle and the swatch page.
struct OrbitThemeEditorState: Equatable {
    var theme: BrowserSpaceTheme
    var selectedIndex: Int?
    var familyIndex: Int

    init(theme: BrowserSpaceTheme) {
        self.theme = theme
        selectedIndex = theme.colors.isEmpty ? nil : theme.colors.count - 1
        familyIndex = theme.presetID.flatMap(BrowserSpaceThemePresets.swatch(for:)).flatMap { match in
            BrowserSpaceThemePresets.families.firstIndex { $0.id == match.family.id }
        } ?? 0
    }

    var hasColor: Bool { !theme.colors.isEmpty }
    var family: BrowserSpaceThemePresets.Family { BrowserSpaceThemePresets.families[familyIndex] }
    var canAddColor: Bool { hasColor && theme.colors.count < BrowserSpaceTheme.maximumColors }
    /// Removes the selected colour; without one, returns a designed preset (legacy palette) to the default.
    var canRemoveColor: Bool { hasColor || theme.presetID != BrowserSpaceThemePresets.defaultID }
    var handlePositions: [CGPoint] { theme.colors.map(OrbitThemeFieldMapping.position(of:)) }

    /// Index of the swatch on the current page that the theme was built from.
    var selectedSwatch: Int? {
        guard let match = theme.presetID.flatMap(BrowserSpaceThemePresets.swatch(for:)),
              match.family.id == family.id else { return nil }
        return match.index
    }

    /// "Tap to pick": the first tap places the first colour; later taps move the selected handle.
    mutating func pick(at unit: CGPoint) {
        let color = OrbitThemeFieldMapping.color(at: unit)
        if let index = selectedIndex, theme.colors.indices.contains(index) {
            replaceColor(at: index, with: color)
        } else {
            setColors(theme.colors + [color], intensity: theme.colors.isEmpty ? BrowserSpaceTheme.defaultIntensity : nil)
            selectedIndex = theme.colors.count - 1
        }
    }

    mutating func select(handle index: Int) {
        guard theme.colors.indices.contains(index) else { return }
        selectedIndex = index
    }

    mutating func move(handle index: Int, to unit: CGPoint) {
        guard theme.colors.indices.contains(index) else { return }
        selectedIndex = index
        replaceColor(at: index, with: OrbitThemeFieldMapping.color(at: unit))
    }

    mutating func addColor() {
        guard canAddColor, let index = selectedIndex ?? theme.colors.indices.last else { return }
        let (hue, saturation, brightness) = theme.colors[index].hsb
        let added = BrowserThemeColor(hue: (hue + 30.0 / 360).truncatingRemainder(dividingBy: 1),
                                      saturation: saturation, brightness: brightness)
        setColors(theme.colors + [added])
        selectedIndex = theme.colors.count - 1
    }

    /// "−": removes the selected colour; the last one returns the Space to the default theme.
    mutating func removeColor() {
        guard canRemoveColor else { return }
        guard hasColor else {
            setColors([])
            selectedIndex = nil
            return
        }
        var colors = theme.colors
        colors.remove(at: min(selectedIndex ?? colors.count - 1, colors.count - 1))
        setColors(colors)
        selectedIndex = colors.isEmpty ? nil : colors.count - 1
    }

    /// A swatch replaces the selected colour, or becomes the first one. A one-colour theme built from a
    /// swatch remembers it (`presetID`).
    mutating func chooseSwatch(_ index: Int) {
        guard family.swatches.indices.contains(index) else { return }
        let swatch = family.swatches[index]
        if let selected = selectedIndex, theme.colors.indices.contains(selected), theme.colors.count > 1 {
            replaceColor(at: selected, with: swatch)
            return
        }
        theme = BrowserSpaceTheme.composed(colors: [swatch], intensity: hasColor ? theme.intensity : BrowserSpaceTheme.defaultIntensity,
                                           noise: theme.noise, mode: theme.mode,
                                           presetID: BrowserSpaceThemePresets.presetID(family: family, index: index))
        selectedIndex = 0
    }

    mutating func showFamily(offset: Int) {
        familyIndex = min(BrowserSpaceThemePresets.families.count - 1, max(0, familyIndex + offset))
    }

    mutating func setMode(_ mode: BrowserSpaceTheme.Mode) { theme = theme.recomposed(mode: mode) }

    mutating func setIntensity(_ value: Double) {
        guard hasColor else { return }
        theme = theme.recomposed(intensity: min(1, max(0, value)))
    }

    mutating func setNoise(_ value: Double) {
        guard hasColor else { return }
        theme = theme.recomposed(noise: min(1, max(0, value)))
    }

    /// Keyboard and VoiceOver adjustment of a handle: hue in degrees, saturation in 0…1 steps.
    mutating func nudge(handle index: Int, hueDegrees: Double = 0, saturation: Double = 0) {
        guard theme.colors.indices.contains(index) else { return }
        selectedIndex = index
        let (hue, s, b) = theme.colors[index].hsb
        var newHue = (hue + hueDegrees / 360).truncatingRemainder(dividingBy: 1)
        if newHue < 0 { newHue += 1 }
        replaceColor(at: index, with: BrowserThemeColor(hue: newHue, saturation: min(1, max(0, s + saturation)), brightness: b))
    }

    private mutating func replaceColor(at index: Int, with color: BrowserThemeColor) {
        var colors = theme.colors
        colors[index] = color
        setColors(colors)
    }

    private mutating func setColors(_ colors: [BrowserThemeColor], intensity: Double? = nil) {
        if colors.isEmpty {
            var reset = BrowserSpaceThemePresets.default
            reset.mode = theme.mode
            theme = reset
            return
        }
        theme = BrowserSpaceTheme.composed(colors: colors, intensity: intensity ?? (hasColor ? theme.intensity : BrowserSpaceTheme.defaultIntensity),
                                           noise: hasColor ? theme.noise : 0, mode: theme.mode)
    }
}

extension BrowserSpacePalette {
    var themeModel: BrowserSpaceTheme? {
        let stops: [UInt32]
        switch self {
        case .automatic: return nil
        case .amberCoral: stops = [0xE4AA3B, 0xF17C5C, 0xF2606B]
        case .lavender: stops = [0xBDBEF1, 0xCDCDFE]
        case .rosePlum: stops = [0xF0848F, 0xA85396]
        case .limeCitrus: stops = [0xCDEB89, 0xDCE97B, 0xE6D051]
        }
        let gradient = BrowserSpaceTheme.Gradient(stops: stops.map { BrowserThemeColor(hex: $0) })
        return BrowserSpaceTheme(presetID: "legacy.\(rawValue.lowercased())", mode: .light, colors: [],
                                 intensity: BrowserSpaceTheme.defaultIntensity, noise: 0.3, light: gradient, dark: gradient)
    }
}
