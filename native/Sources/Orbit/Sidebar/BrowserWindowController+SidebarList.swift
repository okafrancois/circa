import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// The Pinned/Today list (SB-LIST): rows from `session.organization`, keyed by `TabID`, and the
/// organization commands they issue. Every command joins the session's queue through
/// `submitInput`, so list gestures keep their order with keyboard and engine commands.
extension BrowserWindowController {
    func installSidebarList() {
        sidebar.windowIdentifier = id
        installFolderPreview()
        SidebarWindowDirectory.register(self, id: id) { [weak self] in self?.session.snapshot?.activeSpaceID }
        // Rows dropped on the Favorites zone go through the FAVORITES lot's adapter.
        sidebar.addDropTarget(SidebarFavoritesDropTarget(grid: favorites.grid, sidebar: sidebar))
        sidebar.liveTitle = { [weak self] item in
            guard let self, let occurrenceID = item.occurrenceID else { return nil }
            return session.surface(for: occurrenceID)?.navigationState.title
        }
        sidebar.liveActivity = { [weak self] item in
            guard let self else { return .init() }
            guard let occurrenceID = item.occurrenceID else {
                return SidebarTabActivity(favicon: session.organization.flatMap {
                    sidebarIcons.memoryCache.image(profile: $0.profileID, home: item.pinnedURL ?? item.url)
                })
            }
            guard let surface = session.surface(for: occurrenceID), owns(surface) else {
                return SidebarTabActivity(favicon: tabSuspension.icon(for: occurrenceID)
                    ?? session.organization.flatMap { sidebarIcons.memoryCache.image(profile: $0.profileID, home: item.pinnedURL ?? item.url) }
                    ?? sidebarIcons.image(for: item, surface: nil, isOwned: { _ in false }))
            }
            let media = siteControls.mediaStates[ObjectIdentifier(surface)]
            let icon = sidebarIcons.image(for: item, surface: surface, isOwned: { [weak self] in self?.owns($0) == true })
            return SidebarTabActivity(favicon: icon, isLoading: surface.navigationState.isLoading,
                                      isAudible: media?.isAudible ?? media?.isAudioPlaying, isAudioMuted: media?.isAudioMuted)
        }
        sidebarIcons.onChange = { [weak self] in
            self?.rebuildTabStrip()
            self?.folderPreview.view.refreshImages()
        }
        let previousMediaHook = siteControls.onMediaStateChange
        siteControls.onMediaStateChange = { [weak self] surface, state in
            previousMediaHook?(surface, state)
            guard let self, owns(surface) else { return }
            rebuildTabStrip()
        }
        sidebarActivityObserver = engineEventHooks.observe { [weak self] surface, event in
            guard let self, owns(surface) else { return }
            rebuildTabStrip()
            if event == .stateChanged || event == .navigationFinished { siteControls.refreshMedia(surface) }
        }
        sidebar.onToggleTabAudio = { [weak self] id in
            self?.submitInput { controller in
                guard let occurrence = controller.session.organization?.tab(id)?.occurrenceID,
                      let surface = controller.session.surface(for: occurrence), controller.owns(surface),
                      let muted = controller.siteControls.mediaStates[ObjectIdentifier(surface)]?.isAudioMuted else { return }
                do { try surface.setAudioMuted(!muted) } catch { NSSound.beep() }
                controller.siteControls.refreshMedia(surface)
            }
        }
        sidebar.onSelectSplit = { [weak self] id in self?.submitInput { $0.session.selectSplit(id) } }
        sidebar.onSelectTab = { [weak self] id in self?.submitInput { $0.activateSidebarTab(id) } }
        sidebar.onCloseTabs = { [weak self] ids in self?.submitInput { $0.closeSidebarTabs(ids) } }
        sidebar.onSetFolderCollapsed = { [weak self] id, collapsed in
            self?.submitInput { $0.session.setFolderCollapsed(id, collapsed) }
        }
        sidebar.onResetTab = { [weak self] id in self?.submitInput { $0.resetSidebarTab(id) } }
        sidebar.onRename = { [weak self] node, title in self?.submitInput { $0.renameSidebarNode(node, to: title) } }
        sidebar.onRenameDidEnd = { [weak self] in self?.windowShell.hoverHoldDidChange() }
        // ARCHIVE-UI's hook keeps visible and media tabs (archive-r2).
        sidebar.onClearToday = { [weak self] in self?.submitInput { $0.clearTodayFromArchiveCommand() } }
        sidebar.onDrop = { [weak self] payload, destination, changes in
            self?.submitInput { $0.performSidebarDrop(payload, to: destination, changesOrganization: changes) }
        }
        sidebar.onContextMenu = { [weak self] nodes, event, view in self?.showSidebarContextMenu(for: nodes, event: event, in: view) }
        let router = sidebar.undoRouter
        router.canUndoOrganization = { [weak self] in self?.acceptsCommands == true && self?.session.organization?.undoAction != nil }
        router.canRedoOrganization = { [weak self] in self?.acceptsCommands == true && self?.session.organization?.redoAction != nil }
        router.replayOrganization = { [weak self] redo, choose, completion in
            guard let self, acceptsCommands, !session.isClosed else { completion(nil); return }
            submitInput { controller in
                controller.session.routeOrganizationReplay(undoing: !redo, choosingOrganization: {
                    var organization = false
                    controller.performAcceptedCommand { organization = choose() }
                    return organization
                }, completion: completion)
            }
        }
        router.undoOrganizationName = { [weak self] in self?.session.organization?.undoAction.map(SidebarUndoStrings.name) }
        router.redoOrganizationName = { [weak self] in self?.session.organization?.redoAction.map(SidebarUndoStrings.name) }
    }

    // MARK: Row actions

    /// Clicking a row: selects (or loads here) the tab; clicking the visible tab focuses its page.
    func activateSidebarTab(_ id: TabID, expecting expected: BrowserOrganizationSnapshot? = nil,
                            admission: BrowserSidebarSelectionAdmission? = nil,
                            isCurrent: @escaping @MainActor () -> Bool = { true }) {
        guard acceptsCommands, admission?.isValid != false, isCurrent(), expected == nil || expected == session.organization else { return }
        hideLibrary()
        if let item = session.organization?.tab(id), item.isSelected, session.selectedSurface != nil {
            focusSelectedDocument()
            return
        }
        session.selectTab(id, expecting: expected, admission: admission, isCurrent: isCurrent)
    }

    /// × and "Close/Archive": one Today tab goes to the archive (`archiveTabs`, ARCHIVE-UI's API);
    /// several tabs close as one command (`closeTabs`: Today tabs archived in one undoable step,
    /// Pinned and Favorite tabs unloaded here and returned to their pinned URL, ORG-MODEL rule).
    func closeSidebarTabs(_ ids: [TabID]) {
        guard acceptsCommands, !ids.isEmpty else { return }
        if ids.count == 1, case .today? = session.organization?.tab(ids[0])?.section {
            session.archiveTabs(ids)
        } else {
            session.closeTabs(ids)
        }
    }

    /// ⌘W "Archive Tab" (M-968). A sidebar multi-selection closes as one command (Orbit 2022 notes:
    /// ⌘W closes a multi-selected group); otherwise the visible tab closes as before.
    func archiveSelectedTabs() {
        guard acceptsCommands else { return }
        if library.isPresented { hideLibrary(); return }
        if let organization = session.organization, sidebar.selection.nodes.count >= 2 {
            let tabs = sidebar.selection.orderedNodes(in: organization).flatMap { node -> [TabID] in
                if let id = node.tabID { return [id] }
                if case let .split(group)? = organization.item(for: node) { return group.group.tabIDs }
                return []
            }
            if !tabs.isEmpty {
                closeSidebarTabs(tabs)
                sidebar.collapseSelectionToActiveTab()
                return
            }
        }
        closeSelectedTab()
    }

    /// Keeps the ⌘Z router in the window's responder chain and tells it about new organization
    /// commands of this window (called with every sidebar projection).
    func updateSidebarUndoRouter() {
        guard let window else { return }
        sidebar.undoRouter.install(in: window)
        if let snapshot = session.organization {
            sidebar.undoRouter.organizationDidChange(count: snapshot.undoRecordCount,
                undoRecordID: snapshot.undoRecordID, redoRecordID: snapshot.redoRecordID)
        }
    }

    func resetSidebarTab(_ id: TabID) {
        guard acceptsCommands else { return }
        hideLibrary()
        session.resetTabToPinnedURL(id) { surface, url in surface.navigate(to: url) }
    }

    /// A blank tab title restores the web title; a blank folder title is refused (kept).
    func renameSidebarNode(_ node: BrowserOrganizationNode, to title: String) {
        guard acceptsCommands else { return }
        switch node {
        case .split: refuseSplitRename() // Group labels are composed from pane titles.
        case let .tab(id): session.renameTab(id, to: title.isEmpty ? nil : title)
        case let .folder(id): if !title.isEmpty { session.renameFolder(id, to: title) }
        }
    }

    // MARK: Drag and drop (ORBIT-DRAG)

    /// Commits a drop validated by the sidebar.
    /// Rule between windows of one Space (SB-LIST-R2, reconstruction: ORG-MODEL allows one
    /// occurrence per window, Orbit's exact rule is BL-ORG-ORBIT-CHECKS): a drop from window A into
    /// window B *moves* its tabs. Afterwards each dropped tab that A had loaded is loaded in B
    /// with A's live document (process, history, forms — `BrowserSurfaceTransfer`) and no longer
    /// loaded in A. If B already had its own occurrence, that one is unloaded (not archived) in
    /// favour of the dragged document. When a live transfer is impossible, B shows the tab (loading
    /// it if needed) and A unloads it: a tab is never left loaded in both windows by a drag. Tabs
    /// A had not loaded are simply shown here. The first dropped tab becomes visible in B; tabs
    /// inside a dragged folder stay where they are loaded.
    func performSidebarDrop(_ payload: SidebarDragPayload, to destination: BrowserOrganizationDestination,
                            changesOrganization: Bool) {
        guard acceptsCommands, let snapshot = session.organization, let catalog = session.catalog,
              snapshot.spaceID == payload.spaceID, snapshot.profileID == payload.profileID,
              SidebarDropCoordinator.validate(payload, to: destination, snapshot: snapshot, catalog: catalog) == nil else { return }
        let source = SidebarWindowDirectory.window(payload.sourceWindow) as? BrowserWindowController
        if payload.sourceWindow != id {
            guard let source, source.acceptsCommands, let sourceSnapshot = source.session.organization,
                  sourceSnapshot.spaceID == payload.spaceID, sourceSnapshot.profileID == payload.profileID,
                  payload.nodes.allSatisfy({ sourceSnapshot.item(for: $0) != nil }) else { return }
        }
        if changesOrganization { session.moveItems(payload.nodes, to: destination) }
        guard payload.sourceWindow != id else { return }
        for (index, node) in payload.nodes.enumerated() {
            let activate = index == 0
            if case let .split(group)? = snapshot.item(for: node) {
                if let source, source.moveSplitGroup(group.group, to: self, activate: activate) != nil { continue }
                // A partly live or nontransferable group is refused as a unit. Dormant groups
                // may be selected normally; never replay a missing sibling during a live move.
                let hasLiveMember = group.group.tabIDs.contains { source?.liveSidebarSurface(of: $0) != nil }
                if activate && !hasLiveMember { session.selectSplit(group.group.id) }
                continue
            }
            guard let tabID = node.tabID else { continue }
            guard let source, let dragged = source.liveSidebarSurface(of: tabID) else {
                if activate { session.selectTab(tabID) }
                continue
            }
            if source.canTransferSurface(dragged, to: self) {
                if source.moveSurface(dragged, to: self, activate: activate, replacingExisting: true) != nil { continue }
            }
            // Without a transfer the first tab is shown here; the others load when clicked.
            if activate { session.selectTab(tabID) }
            source.unloadSidebarOccurrence(dragged)
        }
    }

    /// This window's live document of `tabID` in its active Space.
    func liveSidebarSurface(of tabID: TabID) -> Surface? {
        session.organization?.tab(tabID)?.occurrenceID.flatMap { session.surface(for: $0) }
    }

    /// The conditions of `moveSurface`, checked without releasing anything.
    func canTransferSurface(_ surface: Surface, to destination: BrowserWindowController) -> Bool {
        destination !== self && destination.engine === engine && engine.capabilities.contains(.liveSurfaceTransfer)
            && acceptsCommands && destination.acceptsCommands && owns(surface)
            && destination.session.activeProfileID == surface.profileID
    }

    /// Unloads this window's occurrence of a tab without archiving it or resetting it: the
    /// logical tab stays in the sidebar (it moved to another window).
    func unloadSidebarOccurrence(_ surface: Surface) {
        guard let transfer = session.releaseSurface(surface) else { return }
        surfaceDidLeave(surface)
        transfer.cancel()
    }

    // MARK: Context menus (UX-CONTEXT through the Commands registry)

    /// Builds the row menu with the registry and a captured target; nil when no registry owns the
    /// window or its session is busy (callers retry after publication).
    func makeSidebarContextMenu(for nodes: [BrowserOrganizationNode]) -> (menu: NSMenu, owner: AnyObject)? {
        let organization = session.organization
        let groups = SidebarListCommands.contextCommands(for: nodes, in: organization)
        guard !groups.isEmpty, let built = SidebarCommandHub.contextMenu(for: self, commands: groups) else { return nil }
        for item in built.menu.items {
            guard let value = item.identifier?.rawValue, let id = BrowserCommandID(rawValue: value),
                  let title = SidebarListCommands.title(for: id, nodes: nodes, in: organization) else { continue }
            item.title = title
            item.keyEquivalent = ""
        }
        let move = SidebarMoveMenu(owner: self, nodes: nodes)
        if let move {
            let index = built.menu.items.firstIndex { $0.identifier?.rawValue == BrowserCommandID.renameCurrentItem.rawValue } ?? 0
            built.menu.insertItem(move.item, at: index)
        }
        return (built.menu, SidebarContextMenuOwner(commands: built.owner, move: move))
    }

    func showSidebarContextMenu(for nodes: [BrowserOrganizationNode], event: NSEvent, in view: NSView) {
        if let built = makeSidebarContextMenu(for: nodes) {
            NSMenu.popUpContextMenu(built.menu, with: event, for: view)
            endSidebarContextMenu(retaining: built.owner)
            return
        }
        guard session.hasPendingCommands else {
            sidebar.endContextMenu()
            return
        }
        // A busy session cannot supply a stable target: show the menu once it has published.
        let location = view.convert(event.locationInWindow, from: nil)
        Task { [weak self, weak view] in
            guard let self else { return }
            await session.waitForQueuedCommands()
            guard let view, view.window != nil, let built = makeSidebarContextMenu(for: nodes) else {
                sidebar.endContextMenu()
                return
            }
            built.menu.popUp(positioning: nil, at: location, in: view)
            endSidebarContextMenu(retaining: built.owner)
        }
    }

    /// AppKit may send the chosen item's action after the menu closed: targets stay until the
    /// next main-actor turn, and the menu factory lives as long.
    private func endSidebarContextMenu(retaining owner: AnyObject) {
        Task { @MainActor [weak self] in
            withExtendedLifetime(owner) {}
            self?.sidebar.endContextMenu()
        }
    }

    // MARK: Command targets

    /// Tabs targeted by a list command (context rows, multi-selection or the selected tab).
    var sidebarTabTargets: [TabID] {
        sidebar.commandTargets().flatMap { node in
            if let id = node.tabID { return [id] }
            if case let .split(split)? = session.organization?.item(for: node) { return split.group.tabIDs }
            return []
        }
    }

    /// Targeted tabs shown in Pinned or Today (Favorites have their own grid).
    var sidebarListTabTargets: [TabID] {
        sidebarTabTargets.filter { id in
            guard let item = session.organization?.tab(id) else { return false }
            if case .favorites = item.section { return false }
            return true
        }
    }

    var sidebarAwayPinnedTargets: [TabID] {
        sidebarTabTargets.filter { session.organization?.tab($0)?.isAwayFromPinnedURL == true }
    }

    var sidebarLinkTargets: [BrowserOrganizationTabItem] {
        guard let organization = session.organization else { return [] }
        func tabs(_ item: BrowserOrganizationItem) -> [BrowserOrganizationTabItem] {
            switch item {
            case .tab(let tab): return [tab]
            case .folder(let folder): return folder.children.flatMap(tabs)
            case .split(let split): return split.tabs
            }
        }
        return organization.topLevelNodes(sidebar.commandTargets()).compactMap { organization.item(for: $0) }.flatMap(tabs)
    }

    var sidebarOtherTodayTabs: [TabID] {
        let selected = Set(sidebarTabTargets)
        return session.organization?.today.flatMap { item -> [TabID] in
            if case .tab(let tab) = item { return selected.contains(tab.id) ? [] : [tab.id] }
            if case .split(let split) = item { return split.group.tabIDs.filter { !selected.contains($0) } }
            return []
        } ?? []
    }

    func copySidebarLinks(markdown: Bool) {
        let links = sidebarLinkTargets.map { tab in
            markdown ? "[\(tab.title ?? tab.url.absoluteString)](\(tab.url.absoluteString))" : tab.url.absoluteString
        }
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }

    var sidebarFolderTarget: FolderID? {
        let targets = sidebar.commandTargets()
        guard targets.count == 1 else { return nil }
        return targets[0].folderID
    }

    /// The row Rename Current Item edits: the context row, else the selection anchor or the
    /// selected tab when the list shows it (or can reveal it).
    var sidebarRenameTarget: BrowserOrganizationNode? {
        let context = sidebar.contextMenuNodes
        if !context.isEmpty { return context.count == 1 && context[0].splitID == nil ? context[0] : nil }
        guard let organization = session.organization else { return nil }
        if let anchor = sidebar.selection.anchor, sidebar.listContent.entry(for: anchor) != nil,
           sidebar.selection.nodes.count <= 1 { return anchor.splitID == nil ? anchor : nil }
        guard let selected = organization.selectedTab else { return nil }
        if case .favorites = selected.section { return nil }
        return .tab(selected.id)
    }

    func renameSidebarTarget() {
        guard acceptsCommands, let node = sidebarRenameTarget else { return }
        revealInSidebar(node)
        sidebar.beginRename(node)
    }

    var canTogglePinFromSidebar: Bool {
        if sidebar.contextMenuNodes.isEmpty, sidebar.selection.nodes.count < 2 {
            return session.organization?.selectedTab != nil
        }
        return !sidebarListTabTargets.isEmpty
    }

    /// ⌘D on the visible tab (exact ORG-MODEL semantics), or on the targeted rows: Today rows are
    /// pinned; when all are pinned they are unpinned.
    func togglePinSidebarTargets() {
        guard acceptsCommands else { return }
        if sidebar.contextMenuNodes.isEmpty, sidebar.selection.nodes.count < 2 {
            session.togglePinSelectedTab()
            return
        }
        let targets = sidebarListTabTargets
        let today = targets.filter { id in
            if case .today = session.organization?.tab(id)?.section { return true }
            return false
        }
        if !today.isEmpty { session.pinTabs(today) } else if !targets.isEmpty { session.unpinTabs(targets) }
    }

    func sidebarHasFolders(collapsed: Bool) -> Bool {
        guard let organization = session.organization else { return false }
        var stack = organization.pinned
        while let item = stack.popLast() {
            if case let .folder(folder) = item {
                if folder.isCollapsed == collapsed { return true }
                stack.append(contentsOf: folder.children)
            }
        }
        return false
    }

    /// New Folder (⇧⌘N): an empty folder at the end of Pinned, or a folder grouping the targeted
    /// rows at the first one's place (a folder's context menu creates it inside). The title is
    /// then edited in place.
    func createSidebarFolder() {
        guard acceptsCommands, let organization = session.organization else { return }
        let context = sidebar.contextMenuNodes
        let selection = sidebar.selection.orderedNodes(in: organization)
        let targets = !context.isEmpty ? context : selection.count >= 2 ? selection : []
        if organization.isPinnedSectionCollapsed { session.setPinnedSectionCollapsed(false) }
        let destination: BrowserOrganizationDestination
        var contents: [BrowserOrganizationNode] = []
        if targets.count == 1, let folder = targets[0].folderID {
            destination = .init(.folder(folder), position: .end)
            if case let .folder(item)? = organization.item(for: targets[0]), item.isCollapsed {
                session.setFolderCollapsed(folder, false)
            }
        } else {
            contents = organization.topLevelNodes(targets)
            if let first = contents.first, let (container, _) = organization.sidebarContainer(of: first),
               container.acceptsFolders(in: organization) {
                destination = .init(container, position: .before(first))
            } else {
                destination = .init(.pinned(organization.spaceID), position: .end)
            }
        }
        let creation = session.createFolder(title: SidebarListStrings.newFolder, at: destination, containing: contents)
        Task { [weak self] in
            guard let id = await creation.value, let self else { return }
            sidebar.beginRename(.folder(id))
        }
    }

    /// Reveal Tab in Sidebar (M-752): shows the sidebar, opens the folders and the Pinned section
    /// holding the selected tab, and scrolls it into view.
    func revealSelectedTabInSidebar() {
        guard acceptsCommands, let selected = session.organization?.selectedTab else { return }
        revealInSidebar(session.organization!.rowNode(for: selected.id))
    }

    func revealInSidebar(_ node: BrowserOrganizationNode) {
        guard let organization = session.organization else { return }
        if !isSidebarVisible { setSidebarVisible(true) }
        if let (section, ancestors) = organization.location(of: node) {
            if case .pinned = section, organization.isPinnedSectionCollapsed { session.setPinnedSectionCollapsed(false) }
            for folder in ancestors where organization.isCollapsed(folder) { session.setFolderCollapsed(folder, false) }
        }
        sidebar.reveal(node)
    }
}

extension BrowserOrganizationContainer {
    /// Pinned and the folders inside it hold folders (ORG-MODEL reconstruction choice).
    func acceptsFolders(in snapshot: BrowserOrganizationSnapshot) -> Bool {
        switch self {
        case .pinned: return true
        case .folder: return true
        case .favorites, .today, .split: return false
        }
    }
}

extension BrowserOrganizationSnapshot {
    /// Section and enclosing folders (outermost first) of a node of the active Space or Favorites.
    func location(of node: BrowserOrganizationNode) -> (BrowserOrganizationSection, [FolderID])? {
        func search(_ items: [BrowserOrganizationItem], chain: [FolderID]) -> [FolderID]? {
            for item in items {
                if item.node == node { return chain }
                if case let .folder(folder) = item, let found = search(folder.children, chain: chain + [folder.id]) {
                    return found
                }
            }
            return nil
        }
        if let chain = search(favorites, chain: []) { return (.favorites(profileID), chain) }
        if let chain = search(pinned, chain: []) { return (.pinned(spaceID), chain) }
        if let chain = search(today, chain: []) { return (.today(spaceID), chain) }
        return nil
    }

    func isCollapsed(_ folder: FolderID) -> Bool {
        if case let .folder(item)? = item(for: .folder(folder)) { return item.isCollapsed }
        return false
    }
}
