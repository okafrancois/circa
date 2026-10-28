import AppKit

/// Light/dark resolution for Orbit windows. A Space theme's sun/moon/automatic mode decides the
/// window appearance (); automatic follows the system.
@MainActor
enum OrbitAppearance {
    /// `--appearance light|dark` forces Space windows, so visible validation can cover both
    /// appearances without changing System Settings. Fixed-appearance panels remain independent.
    static let launchOverride: NSAppearance.Name? = override(in: ProcessInfo.processInfo.arguments)

    static func override(in arguments: [String]) -> NSAppearance.Name? {
        guard let index = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1] {
        case "light": return .aqua
        case "dark": return .darkAqua
        default: return nil
        }
    }

    /// Appearance to assign to a window showing a Space with `mode`; nil follows the system.
    static func windowAppearance(for mode: OrbitTokens.SpaceTheme.Mode,
                                 override: NSAppearance.Name? = launchOverride) -> NSAppearance? {
        if let override { return NSAppearance(named: override) }
        switch mode {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .automatic: return nil
        }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension NSColor {
    /// Resolves a dynamic colour for a layer property under `appearance` (design rule 4: `CGColor`s
    /// of layers are resolved when the effective appearance changes).
    @MainActor
    func resolvedCGColor(for appearance: NSAppearance) -> CGColor {
        var resolved = cgColor
        appearance.performAsCurrentDrawingAppearance { resolved = self.cgColor }
        return resolved
    }

    /// The colour resolved under `appearance`, as a static sRGB colour.
    @MainActor
    func resolved(for appearance: NSAppearance) -> NSColor {
        NSColor(cgColor: resolvedCGColor(for: appearance))?.usingColorSpace(.sRGB) ?? self
    }
}
