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
        SidebarWindowDirectory.register(self, id: id, activeSpace: { [weak self] in self?.session.snapshot?.activeSpaceID },
                                        organization: { [weak self] in self?.session.organization })
        // Rows dropped on the Favorites zone go through the FAVORITES lot's adapter.
        sidebar.addDropTarget(SidebarFavoritesDropTarget(grid: favorites.grid, sidebar: sidebar))
        sidebar.liveTitle = { [weak self] item in
            guard let self, let occurrenceID = item.occurrenceID else { return nil }
            return session.surface(for: occurrenceID)?.navigationState.title
        }
        sidebar.liveActivity = { [weak self] item in
            guard let self else { return .init() }
            let customIcon = SpaceIconImages.tabImage(item.customIcon)
            guard let occurrenceID = item.occurrenceID else {
                return SidebarTabActivity(favicon: customIcon ?? session.organization.flatMap {
                    sidebarIcons.memoryCache.image(profile: $0.profileID, home: item.pinnedURL ?? item.url)
                })
            }
            guard let surface = session.surface(for: occurrenceID), owns(surface) else {
                return SidebarTabActivity(favicon: customIcon ?? tabSuspension.icon(for: occurrenceID)
                    ?? session.organization.flatMap { sidebarIcons.memoryCache.image(profile: $0.profileID, home: item.pinnedURL ?? item.url) }
                    ?? sidebarIcons.image(for: item, surface: nil, isOwned: { _ in false }))
            }
            let media = siteControls.mediaStates[ObjectIdentifier(surface)]
            let preservingSleep = tabSuspension.preservesSleepingPresentation(for: occurrenceID)
            let sleepingIcon = preservingSleep ? tabSuspension.icon(for: occurrenceID) : nil
            let icon = customIcon ?? sleepingIcon ?? sidebarIcons.image(for: item, surface: surface, isOwned: { [weak self] in self?.owns($0) == true })
            return SidebarTabActivity(favicon: icon, isLoading: surface.navigationState.isLoading && !preservingSleep,
                                      isAudible: media?.isAudible ?? media?.isAudioPlaying, isAudioMuted: media?.isAudioMuted)
        }
        sidebarIcons.onTabChange = { [weak self] id in
            self?.sidebarMetadataIDs.insert(id)
            self?.scheduleSidebarMetadata()
            self?.folderPreview.view.refreshImages()
        }
        let previousMediaHook = siteControls.onMediaStateChange
        siteControls.onMediaStateChange = { [weak self] surface, state in
            previousMediaHook?(surface, state)
            guard let self, owns(surface) else { return }
            queueSidebarMetadata(for: surface)
        }
        sidebarActivityObserver = engineEventHooks.observe { [weak self] surface, event in
            guard let self, owns(surface) else { return }
            queueSidebarMetadata(for: surface)
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
        sidebar.onSetPinnedSectionCollapsed = { [weak self] id, collapsed in
            self?.submitInput { controller in
                guard controller.session.snapshot?.activeSpaceID == id else { return }
                controller.session.setPinnedSectionCollapsed(collapsed)
            }
        }
        sidebar.onSetFolderCollapsed = { [weak self] id, collapsed in
            self?.submitInput { $0.session.setFolderCollapsed(id, collapsed) }
        }
        sidebar.onResetTab = { [weak self] id in self?.submitInput { $0.resetSidebarTab(id) } }
        sidebar.onRename = { [weak self] node, title in self?.submitInput { $0.renameSidebarNode(node, to: title) } }
        sidebar.onRenameDidEnd = { [weak self] in self?.windowShell.hoverHoldDidChange() }
        // ARCHIVE-UI's hook keeps visible and media tabs (archive-r2).
        sidebar.onClearToday = { [weak self] in self?.submitInput { $0.clearTodayFromArchiveCommand() } }
        sidebar.page.list.prepareDesktopPreview = { [weak self] payload in
            guard let self, let tab = payload.nodes.first?.tabID, let surface = liveSidebarSurface(of: tab) else { return }
            let generation = surface.documentGeneration
            let viewport = surface.hostView.bounds.size
            Task { [weak self, weak surface] in
                guard let surface, let snapshot = try? await surface.captureSnapshot(.init(width: 1024, documentGeneration: generation)),
                      surface.documentGeneration == generation else { return }
                self?.sidebar.page.list.desktopPreview = NSImage(cgImage: snapshot.image, size: viewport)
                self?.sidebar.page.list.desktopPreviewBackground = NSBitmapImageRep(cgImage: snapshot.image).colorAt(x: 0, y: 0) ?? .windowBackgroundColor
            }
        }
        sidebar.onTearOff = { [weak self] payload, point in self?.onTearOffTab?(payload, point) }
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


    func performSidebarDrop(_ payload: SidebarDragPayload, to destination: BrowserOrganizationDestination,
                            changesOrganization: Bool) {
        guard acceptsCommands, let snapshot = session.organization, let catalog = session.catalog,
              snapshot.profileID == payload.profileID,
              SidebarDropCoordinator.validate(payload, to: destination, snapshot: snapshot, catalog: catalog) == nil else { return }
        let source = SidebarWindowDirectory.window(payload.sourceWindow) as? BrowserWindowController
        if payload.sourceWindow != id {
            guard let source, source.acceptsCommands, let sourceSnapshot = source.session.organization,
                  sourceSnapshot.spaceID == payload.spaceID, sourceSnapshot.profileID == payload.profileID,
                  payload.nodes.allSatisfy({ sourceSnapshot.item(for: $0) != nil }) else { return }
        }
        let crossesSpace = payload.sourceWindow != id && (snapshot.spaceID != payload.spaceID
            || source?.session.snapshot?.isStandalone == true || session.snapshot?.isStandalone == true)
        let destination = session.snapshot?.isStandalone == true ? BrowserOrganizationDestination(.standalone(snapshot.windowID), position: destination.position) : destination
        if crossesSpace {
            // Release before changing shared placement: reconciliation must never dispose the
            // document being moved. The receiver records placement and undo with adoption.
            guard let source, payload.nodes.count == 1, let tab = payload.nodes.first?.tabID else { return }
            if let surface = source.liveSidebarSurface(of: tab) {
                guard source.canTransferSurface(surface, to: self) else { return }
                if let move = source.moveSurface(surface, to: self, activate: true, replacingExisting: true, movingTo: destination) {
                    Task { [weak source] in
                        guard await move.value != nil else { return }
                        SidebarWindowDirectory.keepSourceKey(payload.sourceWindow)
                        if source?.window?.isKeyWindow == true { source?.focusSelectedDocument() }
                    }
                }
            } else {
                let move = source.session.moveItems(payload.nodes, to: destination)
                Task { [weak self] in
                    guard await move.value == true, let self, acceptsCommands,
                          session.activeProfileID == payload.profileID else { return }
                    session.synchronizeOrganization()
                    await session.waitForPendingCommands()
                    guard session.organization?.tab(tab) != nil else { return }
                    session.selectTab(tab)
                }
            }
            return
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
            // A live drag is a move. Refusal keeps the original document and its history;
            // loading the URL in the receiver would silently turn this into a copy.
            guard source.canTransferSurface(dragged, to: self) else { continue }
            source.moveSurface(dragged, to: self, activate: activate, replacingExisting: true)
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
        if let mute = built.menu.items.first(where: { $0.identifier?.rawValue == BrowserCommandID.sidebarMuteTab.rawValue }) {
            if let surface = sidebarMuteSurface {
                let muted = siteControls.mediaStates[ObjectIdentifier(surface)]?.isAudioMuted == true
                mute.title = uiText(muted ? "Unmute" : "Mute")
            } else { mute.isEnabled = false }
        }
        for item in built.menu.items where [BrowserCommandID.sidebarArchiveTabsAbove.rawValue, BrowserCommandID.sidebarArchiveOtherTabs.rawValue].contains(item.identifier?.rawValue ?? "") {
            if let validator = item.target as? NSMenuItemValidation, !validator.validateMenuItem(item) { built.menu.removeItem(item) }
        }
        for item in built.menu.items.reversed() where item.isSeparatorItem {
            guard let index = built.menu.items.firstIndex(of: item) else { continue }
            if index == 0 || index == built.menu.items.count - 1 || built.menu.items[index - 1].isSeparatorItem { built.menu.removeItem(item) }
        }
        let move = SidebarMoveMenu(owner: self, nodes: nodes)
        if let move {
            let index = nodes.count == 1 && nodes[0].tabID != nil
                ? (built.menu.items.firstIndex { $0.identifier?.rawValue == BrowserCommandID.sidebarDuplicate.rawValue }.map { $0 + 1 } ?? 0)
                : (built.menu.items.firstIndex { $0.identifier?.rawValue == BrowserCommandID.renameCurrentItem.rawValue } ?? 0)
            built.menu.insertItem(move.item, at: index)
        }
        var editOwner: AnyObject?
        if let parent = built.menu.items.first(where: { $0.identifier?.rawValue == BrowserCommandID.sidebarEditPinnedURL.rawValue }),
           let submenu = SidebarCommandHub.contextMenu(for: self, commands: [[.sidebarEditPinnedURL]]) {
            submenu.menu.items.last?.title = uiText("Edit…")
            parent.action = nil
            parent.submenu = submenu.menu
            editOwner = submenu.owner
        }
        return (built.menu, SidebarObjectMenuOwner(commands: built.owner, move: move, editing: editOwner))
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
            markdown ? BrowserMarkdownLink.format(title: tab.title, url: tab.url) : tab.url.absoluteString
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
    func acceptsFolders(in snapshot: BrowserOrganizationSnapshot) -> Bool {
        switch self {
        case .pinned: return true
        case .folder: return true
        case .favorites, .today, .split, .standalone: return false
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

/// Retains the captured registry targets through AppKit's deferred action delivery.
private final class SidebarObjectMenuOwner {
    let commands: AnyObject
    let move: AnyObject?
    let editing: AnyObject?
    init(commands: AnyObject, move: AnyObject?, editing: AnyObject?) {
        self.commands = commands; self.move = move; self.editing = editing
    }
}
