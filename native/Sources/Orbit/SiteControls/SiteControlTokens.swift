import AppKit
import BrowserShell

/// Site Controls typography and fallback geometry. The system popover supplies its material:
/// Permission prompts use native popover material.
@MainActor
enum SiteControlTokens {
    static let primary = OrbitFloatingMaterial.body
    static let secondary = OrbitFloatingMaterial.secondary
    // Aliases: addressField 13 regular; tooltip 11 medium; sidebarSpaceTitle 13 semibold.
    static let body = BrandTextStyle.ui.font(size: 13)
    static let caption = BrandTextStyle.ui.font(size: 11, weight: .medium)
    static let title = BrandTextStyle.ui.font(size: 13, weight: .semibold)
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
