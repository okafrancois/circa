import AppKit
import BrowserCore
import BrowserEngine

enum SidebarListCommands {
    static let definitions: [BrowserCommandDefinition] = [
        .init(id: .sidebarChangeTabIcon, title: "Change Icon…", menu: "Sidebar", shortcuts: [], scope: .browser,
              requirement: .window, owner: "OBJECT-EDITING", sources: ["Browser command"]),
        .init(id: .sidebarEditPinnedURL, title: "Edit Pinned Page", menu: "Sidebar", shortcuts: [], scope: .browser,
              requirement: .window, owner: "OBJECT-EDITING", sources: ["Browser command"]),
        .init(id: .sidebarArchiveTabsAbove, title: "Archive Tabs Above", menu: "Sidebar", shortcuts: [], scope: .browser,
              requirement: .window, owner: "MENUS", sources: ["Browser command"]),
        .init(id: .sidebarArchiveTabsBelow, title: "Archive Tabs Below", menu: "Sidebar", shortcuts: [], scope: .browser,
              requirement: .window, owner: "MENUS", sources: ["Browser command"]),
        .init(id: .sidebarMuteTab, title: "Mute Tab", menu: "Sidebar", shortcuts: [], scope: .browser,
              requirement: .window, owner: "MENUS", sources: ["Browser command"]),
        .init(id: .sidebarCopyLinks, title: "Copy URLs", menu: "Sidebar", shortcuts: [], scope: .browser,
              requirement: .window, owner: "MENUS", sources: ["Browser command"]),
        .init(id: .sidebarCopyMarkdownLinks, title: "Copy Link as Markdown", menu: "Sidebar", shortcuts: [], scope: .browser,
              requirement: .window, owner: "MENUS", sources: ["Browser command"]),
        .init(id: .sidebarDuplicate, title: "Duplicate", menu: "Sidebar", shortcuts: [], scope: .browser,
              requirement: .window, owner: "MENUS", sources: ["menu.declaration.context"]),
        .init(id: .sidebarArchiveOtherTabs, title: "Archive Other Tabs", menu: "Sidebar", shortcuts: [], scope: .browser,
              requirement: .window, owner: "MENUS", sources: ["Browser command"]),
        .init(id: .sidebarAddToFavorites, title: "Add to Favorites", menu: "Sidebar", shortcuts: [], scope: .browser,
              requirement: .window, owner: "SB-LIST", sources: ["Browser command"]),
        .init(id: .sidebarCloseItems, title: "Close Tabs", menu: "Sidebar", shortcuts: [], scope: .browser,
              requirement: .window, owner: "SB-LIST", sources: ["Browser command"]),
        .init(id: .sidebarConvertFolderToSpace, title: "Turn Folder into Space", menu: "Sidebar", shortcuts: [], scope: .browser,
              requirement: .window, owner: "SPACE-FOLDER-CONVERSION", sources: ["Browser command"]),
        .init(id: .sidebarDeleteFolder, title: "Delete Folder", menu: "Sidebar", shortcuts: [], scope: .browser,
              requirement: .window, owner: "SB-LIST", sources: ["Browser command"]),
        .init(id: .sidebarDeleteFolderAndTabs, title: "Delete Folder and Archive Its Tabs", menu: "Sidebar", shortcuts: [],
              scope: .browser, requirement: .window, owner: "SB-LIST",
              sources: ["Browser command"])
    ]

    @MainActor
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        typealias Controller = BrowserWindowController<Engine>
        func window(_ id: BrowserCommandID, validate: @escaping (Controller) -> Bool,
                    _ action: @escaping (Controller) -> Void) {
            try! registry.register(id, validate: validate) { controller, origin in
                // A row menu's action applies to its rows only: once they are gone (menu closed
                // and delivery deferred), it never falls back to the selection.
                if origin == .contextMenu, controller.sidebar.contextMenuNodes.isEmpty { return }
                action(controller)
            }
        }
        window(.sidebarChangeTabIcon, validate: { $0.sidebarSingleTab != nil }) { $0.presentTabIconPicker() }
        window(.sidebarEditPinnedURL, validate: { $0.sidebarSingleTab?.pinnedURL != nil }) { $0.presentPinnedURLEditor() }
        window(.sidebarCopyLinks, validate: { !$0.sidebarLinkTargets.isEmpty }) { $0.copySidebarLinks(markdown: false) }
        window(.sidebarCopyMarkdownLinks, validate: { !$0.sidebarLinkTargets.isEmpty }) { $0.copySidebarLinks(markdown: true) }
        window(.sidebarDuplicate, validate: { $0.sidebarTabTargets.count == 1 || $0.sidebarFolderTarget != nil
                || $0.sidebar.commandTargets().count == 1 && $0.sidebar.commandTargets().first?.splitID != nil }) { controller in
            if let folder = controller.sidebarFolderTarget { controller.session.duplicateFolder(folder); return }
            if let group = controller.sidebar.commandTargets().first?.splitID {
                controller.session.duplicateSplit(group)
                return
            }
            guard let id = controller.sidebarTabTargets.first, let tab = controller.session.organization?.tab(id) else { return }
            controller.hideLibrary()
            controller.duplicateSidebarTab(tab.id)
        }
        window(.sidebarArchiveOtherTabs, validate: { !$0.sidebarOtherTodayTabs.isEmpty }) { controller in
            controller.closeSidebarTabs(controller.sidebarOtherTodayTabs)
        }
        for (command, above) in [(BrowserCommandID.sidebarArchiveTabsAbove, true), (.sidebarArchiveTabsBelow, false)] {
            window(command, validate: { !$0.sidebarRelativeTodayTabs(above: above).isEmpty }) { controller in
                controller.closeSidebarTabs(controller.sidebarRelativeTodayTabs(above: above))
            }
        }
        window(.sidebarMuteTab, validate: { $0.sidebarMuteSurface != nil }) { $0.toggleSidebarMute() }
        window(.renameCurrentItem, validate: { $0.sidebarRenameTarget != nil }) { $0.renameSidebarTarget() }
        window(.pinUnpinTab, validate: { $0.canTogglePinFromSidebar }) { $0.togglePinSidebarTargets() }
        window(.newFolder, validate: { $0.session.organization != nil }) { $0.createSidebarFolder() }
        window(.collapseAllFolders, validate: { $0.sidebarHasFolders(collapsed: false) }) { $0.session.setAllFoldersCollapsed(true) }
        window(.expandAllFolders, validate: { $0.sidebarHasFolders(collapsed: true) }) { $0.session.setAllFoldersCollapsed(false) }
        window(.collapsePinnedSection, validate: { $0.session.organization?.isPinnedSectionCollapsed == false }) {
            $0.session.setPinnedSectionCollapsed(true)
        }
        window(.expandPinnedSection, validate: { $0.session.organization?.isPinnedSectionCollapsed == true }) {
            $0.session.setPinnedSectionCollapsed(false)
        }
        window(.resetTabToOriginalURL, validate: { !$0.sidebarAwayPinnedTargets.isEmpty }) { controller in
            for id in controller.sidebarAwayPinnedTargets { controller.resetSidebarTab(id) }
        }
        window(.resetAllTabsInThisSpace, validate: { $0.session.organization?.pinned.isEmpty == false }) { controller in
            controller.hideLibrary()
            controller.session.resetPinnedTabs { surface, url in surface.navigate(to: url) }
        }
        for command in [BrowserCommandID.revealTabInSidebar, .revealCurrentTab] {
            window(command, validate: { $0.session.organization?.selectedTab != nil }) { $0.revealSelectedTabInSidebar() }
        }
        window(.sidebarAddToFavorites, validate: { !$0.sidebarListTabTargets.isEmpty && !$0.sidebar.commandTargets().contains(where: { $0.splitID != nil }) }) { controller in
            controller.session.addToFavorites(controller.sidebarListTabTargets)
        }
        window(.sidebarCloseItems, validate: { !$0.sidebarTabTargets.isEmpty }) { controller in
            controller.closeSidebarTabs(controller.sidebarTabTargets)
        }
        window(.sidebarConvertFolderToSpace, validate: { $0.sidebarFolderTarget != nil }) { controller in
            if let id = controller.sidebarFolderTarget { controller.session.convertFolderToSpace(id) }
        }
        window(.sidebarDeleteFolder, validate: { $0.sidebarFolderTarget != nil }) { controller in
            if let id = controller.sidebarFolderTarget { controller.session.deleteFolder(id, contents: .keepContents) }
        }
        window(.sidebarDeleteFolderAndTabs, validate: { $0.sidebarFolderTarget != nil }) { controller in
            if let id = controller.sidebarFolderTarget { controller.session.deleteFolder(id, contents: .archiveContents) }
        }
        SidebarCommandHub.add(registry)
    }

    // MARK: Context menus

    /// Entries of a row context menu, in groups separated by separators.
    static func contextCommands(for nodes: [BrowserOrganizationNode],
                                in organization: BrowserOrganizationSnapshot?, option: Bool = false) -> [[BrowserCommandID]] {
        guard let organization, !nodes.isEmpty else { return [] }
        let tabs = nodes.flatMap { node -> [TabID] in
            if let id = node.tabID { return [id] }
            if case let .split(split)? = organization.item(for: node) { return split.group.tabIDs }
            return []
        }
        if nodes.count == 1, nodes[0].folderID != nil {
            return [[.newFolder, .sidebarConvertFolderToSpace], [.renameCurrentItem, .sidebarDuplicate], [option ? .sidebarCopyMarkdownLinks : .sidebarCopyLinks],
                    [.sidebarDeleteFolder, .sidebarDeleteFolderAndTabs]]
        }
        if nodes.count == 1, let id = nodes[0].tabID, let tab = organization.tab(id) {
            var editing: [BrowserCommandID] = [.sidebarChangeTabIcon, .renameCurrentItem, .sidebarMuteTab]
            if tab.pinnedURL != nil { editing.append(.sidebarEditPinnedURL) }
            // The observed order leads; commands that already existed stay available after it.
            var groups: [[BrowserCommandID]] = [[.sidebarCopyLinks, .sidebarCopyMarkdownLinks], editing,
                                                [.addSplitView, .sidebarDuplicate, .newFolder]]
            if tab.isAwayFromPinnedURL { groups.append([.resetTabToOriginalURL]) }
            groups.append([.pinUnpinTab])
            if case .today = tab.section {
                groups.append([.sidebarCloseItems, .sidebarArchiveOtherTabs, .sidebarArchiveTabsAbove, .sidebarArchiveTabsBelow])
            } else {
                groups.append([.sidebarCloseItems])
            }
            return groups
        }
        var groups: [[BrowserCommandID]] = []
        groups.append([.sidebarCopyLinks, .sidebarCopyMarkdownLinks])
        if nodes.count == 1, nodes[0].splitID == nil { groups.append([.renameCurrentItem, .sidebarDuplicate]) }
        groups.append([.pinUnpinTab, .newFolder])
        if tabs.count == 1 { groups.append([.sidebarMuteTab]) }
        if nodes.count == 1, nodes[0].splitID != nil {
            groups.append([.sidebarDuplicate])
            groups.append([.separatePageFromSplitView, .unsplitAllPanes, .convertToVerticalSplitView, .convertToHorizontalSplitView, .swapSplitPanes])
        }
        if tabs.contains(where: { organization.tab($0)?.isAwayFromPinnedURL == true }) { groups.append([.resetTabToOriginalURL]) }
        if !tabs.isEmpty {
            groups.append([.sidebarCloseItems])
            if tabs.allSatisfy({ if case .today = organization.tab($0)?.section { return true }; return false }) {
                groups.append([.sidebarArchiveOtherTabs, .sidebarArchiveTabsAbove, .sidebarArchiveTabsBelow])
            }
        }
        return groups
    }

    static func title(for id: BrowserCommandID, nodes: [BrowserOrganizationNode],
                      in organization: BrowserOrganizationSnapshot?) -> String? {
        let tabs = nodes.flatMap { node -> [BrowserOrganizationTabItem] in
            if let id = node.tabID, let tab = organization?.tab(id) { return [tab] }
            if case let .split(split)? = organization?.item(for: node) { return split.tabs }
            return []
        }
        let plural = tabs.count > 1
        func text(_ key: String, _ english: String) -> String { SidebarListStrings.string("menu.\(key)", english) }
        switch id {
        case .renameCurrentItem: return nodes.count == 1 && nodes[0].tabID != nil ? uiText("Rename…") : text("rename", "Rename")
        case .addSplitView: return tabs.first?.pinnedURL == nil ? uiText("Open in Split View") : uiText("Add Split View")
        case .sidebarMuteTab: return uiText("Mute")
        case .sidebarCopyLinks: return nodes.contains(where: { $0.folderID != nil }) ? uiText("Copy All Links") : uiText(plural ? "Copy URLs" : "Copy Link")
        case .sidebarCopyMarkdownLinks: return nodes.contains(where: { $0.folderID != nil }) ? uiText("Copy All Links as Markdown") : uiText(plural ? "Copy Links as Markdown" : "Copy Link as Markdown")
        case .pinUnpinTab:
            let allPinned = !tabs.isEmpty && tabs.allSatisfy { if case .pinned = $0.section { return true }; return false }
            return allPinned ? (plural ? text("unpinTabs", "Unpin Tabs") : uiText("Remove Pin"))
                : (plural ? text("pinTabs", "Pin Tabs") : text("pinTab", "Pin Tab"))
        case .sidebarAddToFavorites: return text("addToFavorites", "Add to Favorites")
        case .newFolder:
            return nodes.count == 1 && nodes[0].folderID != nil ? text("newFolder", "New Nested Folder…")
                : text("newFolderWithSelection", "New Folder with Selection")
        case .resetTabToOriginalURL: return text("resetTab", "Reset Tab to Original URL")
        case .sidebarCloseItems:
            let allToday = !tabs.isEmpty && tabs.allSatisfy { if case .today = $0.section { return true }; return false }
            if allToday { return plural ? text("archiveTabs", "Archive Tabs") : text("archiveTab", "Archive Tab") }
            return plural ? text("closeTabs", "Close Tabs") : text("closeTab", "Close Tab")
        case .collapseAllFolders: return text("collapseAllFolders", "Collapse All Folders")
        case .expandAllFolders: return text("expandAllFolders", "Expand All Folders")
        case .sidebarConvertFolderToSpace:
            guard let id = nodes.first?.folderID, case let .folder(folder)? = organization?.item(for: .folder(id)) else { return nil }
            return uiFormat("Turn “%@” into Space", folder.title)
        case .sidebarDeleteFolder: return text("deleteFolder", "Delete")
        case .sidebarDeleteFolderAndTabs: return text("deleteFolderAndTabs", "Archive Folder")
        default: return nil
        }
    }
}

/// Registries installed in this process. A window finds the one whose router owns it, then builds
/// its context menus with `BrowserCommandMenus` and a target captured before display, so items
/// validate and dispatch through the registry exactly like the menu bar.
@MainActor
enum SidebarCommandHub {
    private struct Entry {
        weak var registry: AnyObject?
        let makeMenu: (AnyObject, [[BrowserCommandID]]) -> (menu: NSMenu, owner: AnyObject)?
    }

    private static var entries: [Entry] = []

    static func add<Engine: BrowserEngine>(_ registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        entries.removeAll { $0.registry == nil || $0.registry === registry }
        entries.append(Entry(registry: registry) { [weak registry] window, groups in
            guard let registry, let controller = window as? BrowserWindowController<Engine>,
                  registry.router.windows[controller.id] === controller,
                  let target = registry.captureTarget(windowID: controller.id) else { return nil }
            let menus = BrowserCommandMenus(registry: registry, target: target)
            let menu = NSMenu()
            for group in groups {
                let items = menus.makeContextMenu(commands: group).items
                if !items.isEmpty && !menu.items.isEmpty { menu.addItem(.separator()) }
                for item in items {
                    item.menu?.removeItem(item)
                    menu.addItem(item)
                }
            }
            return (menu, menus)
        })
    }

    /// Nil when no registry owns `window` or its session cannot supply a stable target yet.
    static func contextMenu(for window: AnyObject, commands: [[BrowserCommandID]]) -> (menu: NSMenu, owner: AnyObject)? {
        entries.removeAll { $0.registry == nil }
        for entry in entries {
            if let built = entry.makeMenu(window, commands) { return built }
        }
        return nil
    }
}

/// Windows by `BrowserWindowController.id`, to move live documents dropped from another window.
@MainActor
enum SidebarWindowDirectory {
    private struct Entry {
        weak var window: AnyObject?
        let activeSpace: @MainActor () -> SpaceID?
        let organization: @MainActor () -> BrowserOrganizationSnapshot?
    }
    private static var windows: [UUID: Entry] = [:]

    static func register(_ window: AnyObject, id: UUID, activeSpace: @escaping @MainActor () -> SpaceID?,
                         organization: @escaping @MainActor () -> BrowserOrganizationSnapshot? = { nil }) {
        windows = windows.filter { $0.value.window != nil }
        windows[id] = Entry(window: window, activeSpace: activeSpace, organization: organization)
    }

    static func window(_ id: UUID) -> AnyObject? { windows[id]?.window }

    /// Hovering and accepting a row in a sibling window preserves the source's key window.
    static func keepSourceKey(_ id: UUID) {
        guard NSApp.isActive, let source = window(id) as? NSWindowController,
              let window = source.window, window.isVisible, !window.isKeyWindow else { return }
        window.makeKey()
    }

    static func organization(of id: UUID) -> BrowserOrganizationSnapshot? {
        guard let entry = windows[id], entry.window != nil else { return nil }
        return entry.organization()
    }

    /// The active Space of a registered, still open window.
    static func activeSpace(of id: UUID) -> SpaceID? {
        guard let entry = windows[id], entry.window != nil else { return nil }
        return entry.activeSpace()
    }

    /// The controller id of the window hosting `window`.
    static func id(of window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return windows.first { ($0.value.window as? NSWindowController)?.window === window }?.key
    }
}
