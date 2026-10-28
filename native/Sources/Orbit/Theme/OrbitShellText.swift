import Foundation

/// User-visible strings of the window shell (UX-LOCALIZATION, VIS-1 BL-VIS1-LOCALE).
/// shows its interface and menus in English whatever the system language, so every
/// default below is English: Orbit's own string where one was observed (menu titles of the command
/// catalog, "New Tab" in capture C01, the command-bar placeholder asset), an English reconstruction
/// otherwise. Each string goes through the shared SwiftPM Localizable table, so a later localization
/// can override it without touching the views. Feature helpers retain their existing call sites.
enum OrbitShellText {
    static func string(_ key: String, _ english: String) -> String {
        uiText(english)
    }

    // Toolbar row (accessibility labels; Orbit shows no tooltips there).
    /// Orbit menu title (M-33).
    static var toggleSidebar: String { string("toolbar.toggleSidebar", "Show/Hide Sidebar") }
    static var back: String { string("toolbar.back", "Back") }
    static var forward: String { string("toolbar.forward", "Forward") }
    static var reload: String { string("toolbar.reload", "Reload") }
    /// Compact toolbar overflow ("•••").
    static var moreToolbarItems: String { string("toolbar.more", "More") }

    // Address field.
    static var addressPlaceholder: String { string("address.placeholder", "Search or Enter URL…") }
    static var resetZoom: String { string("address.resetZoom", "Actual Size") }

    // Sidebar.
    static var sidebar: String { string("sidebar.accessibility", "Sidebar") }
    ///  — "New Tab" row.
    static var newTab: String { string("sidebar.newTab", "New Tab") }
    /// Orbit menu title (M-1195).
    static var newSpace: String { string("sidebar.newSpace", "New Space…") }
    /// Orbit menu title (M-442).
    static var renameSpace: String { string("sidebar.renameSpace", "Rename Space…") }
    static var untitledSpace: String { string("sidebar.untitledSpace", "Space") }
    static var moveSpaceLeft: String { string("sidebar.moveSpaceLeft", "Move Left") }
    static var moveSpaceRight: String { string("sidebar.moveSpaceRight", "Move Right") }
    static var library: String { string("sidebar.library", "Library") }
    static var create: String { string("sidebar.create", "New") }
    static var selected: String { string("sidebar.selected", "Selected") }
    static func space(_ name: String) -> String { String(format: string("sidebar.space", "Space %@"), name) }
    static func closeTab(_ title: String) -> String { String(format: string("sidebar.closeTab", "Close %@"), title) }

    // Content card.
    static var emptySpaceTitle: String { string("card.emptySpaceTitle", "New Space") }
    static var emptySpaceDetail: String { string("card.emptySpaceDetail", "Open a tab to get started.") }
}
