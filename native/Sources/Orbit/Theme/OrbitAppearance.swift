import AppKit

/// Daylight chrome, independent of the system appearance used by web content.
@MainActor
enum OrbitAppearance {
    /// Synthetic probes use this input to exercise both system appearances.
    static let launchOverride: NSAppearance.Name? = override(in: ProcessInfo.processInfo.arguments)

    static func override(in arguments: [String]) -> NSAppearance.Name? {
        guard let index = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1] {
        case "light": return .aqua
        case "dark": return .darkAqua
        default: return nil
        }
    }

    /// Circa-owned windows always use daylight. Stored mode and test input never alter chrome.
    /// Keep NSApp's appearance inherited: Chromium reads it for website colour-scheme preferences.
    static func windowAppearance(for mode: OrbitTokens.SpaceTheme.Mode,
                                 override: NSAppearance.Name? = launchOverride) -> NSAppearance? {
        NSAppearance(named: .aqua)
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

/// App-owned windows cannot inherit a dark system appearance. Web content retains its engine's
/// system preference; this deliberately does not set NSApplication.appearance.
@MainActor
class OrbitDaylightWindow: NSWindow {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        super.appearance = NSAppearance(named: .aqua)
    }

    override var appearance: NSAppearance? {
        get { NSAppearance(named: .aqua) }
        set { super.appearance = NSAppearance(named: .aqua) }
    }
}

@MainActor
class OrbitDaylightPanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        super.appearance = NSAppearance(named: .aqua)
    }

    override var appearance: NSAppearance? {
        get { NSAppearance(named: .aqua) }
        set { super.appearance = NSAppearance(named: .aqua) }
    }
}
