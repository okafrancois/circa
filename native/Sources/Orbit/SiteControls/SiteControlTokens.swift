import AppKit

/// Site Controls typography and fallback geometry. The system popover supplies its material:
/// Orbit's opaque PopoverBackground asset is not the background of its permission prompts.
@MainActor
enum SiteControlTokens {
    // , confidence high.
    static let primary = NSColor(name: "SiteControls.primary") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.80)
            : NSColor(displayP3Red: 0x0E / 255, green: 0x0F / 255, blue: 0x10 / 255, alpha: 0.90)
    }
    static let secondary = NSColor(name: "SiteControls.secondary") { appearance in
        (appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.white : NSColor.black).withAlphaComponent(0.50)
    }
    // Aliases: addressField 13 regular; tooltip 11 medium; sidebarSpaceTitle 13 semibold.
    static let body = NSFont.systemFont(ofSize: 13)
    static let caption = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
    // Reconstructed geometry; centralized for the PM's visual calibration.
    static let width: CGFloat = 360
    static let maximumHeight: CGFloat = 580
    static let inset: CGFloat = 16
    static let gap: CGFloat = 8
    static let rowHeight: CGFloat = 28
    static let anchorSize: CGFloat = 24
    /// VIS-1 BL-VIS1-SITE-POPOVER (): the popover hangs below its anchor and stays inside the
    /// window, `windowMargin` above the window's bottom edge, the arrow included; below `minimumHeight`
    /// it keeps that height and scrolls.
    static let windowMargin: CGFloat = 12
    static let arrowAllowance: CGFloat = 14
    static let minimumHeight: CGFloat = 160
}

/// SITE strings. Orbit shows its interface in English whatever the system language (UX-LOCALIZATION):
/// English defaults through the shared SwiftPM localization table.
func siteText(_ key: String, _ english: String) -> String {
    uiText(english)
}
