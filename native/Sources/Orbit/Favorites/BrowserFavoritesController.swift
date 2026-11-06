import AppKit
import BrowserCore
import BrowserEngine

/// Window-owned projection; the store remains authoritative for profile and tab identity.
@MainActor
final class BrowserFavoritesController<Engine: BrowserEngine> {
    typealias Surface = Engine.Surface
    weak var owner: BrowserWindowController<Engine>?
    let grid = FavoritesGridView()
    let icons: FavoriteIconPipeline<Surface>
    let gmail = BrowserGmailRuntime()
    let gmailPreview = GmailPreviewController()
    private let gmailSession: (any BrowserGmailWebSession)?
    private var gmailRefreshTimer: Timer?
    private weak var registry: BrowserCommandRegistry<BrowserWindowController<Engine>>?
    private(set) var menuController: FavoritesContextMenu?
    private struct MenuSelection {
        let token = UUID()
        let tab: BrowserOrganizationTabItem
        let spaceID: SpaceID
        let profileID: ProfileID
        let context: BrowserCommandContext
    }
    private var menuSelection: MenuSelection?
    private var acceptedMenuCommands: [(id: BrowserCommandID, selection: MenuSelection)] = []
    private var observer: BrowserHookRegistration?
    private var profileID: ProfileID?
    private var spaceID: SpaceID?
    private final class WeakSurface {
        weak var value: Surface?
        init(_ value: Surface) { self.value = value }
    }
    private var surfacesByTab: [TabID: WeakSurface] = [:]

    init(owner: BrowserWindowController<Engine>, gmailSession: (any BrowserGmailWebSession)? = nil) {
        self.owner = owner
        self.gmailSession = gmailSession ?? owner.engine as? any BrowserGmailWebSession
        icons = FavoriteIconPipeline<Surface>()
    }

    func install() {
        guard let owner, grid.superview == nil else { return }
        grid.frame = owner.sidebar.favoritesContainer.bounds
        grid.autoresizingMask = [.width, .height]
        owner.sidebar.favoritesContainer.addSubview(grid)
        grid.onDragWillBegin = { [weak self] in self?.owner?.sidebar.spaceSwipe.cancel() }
        grid.onSelect = { [weak self] id in
            self?.gmailPreview.dismiss()
            self?.owner?.submitInput { controller in
                controller.hideLibrary()
                controller.session.selectTab(id)
                controller.session.performOnSelectedSurface { [weak controller] _ in
                    guard let controller, controller.session.organization?.selectedTab?.id == id,
                          controller.window?.isKeyWindow == true else { return }
                    controller.focusSelectedDocument()
                }
            }
        }
        grid.makeContextMenu = { [weak self] id in self?.contextMenu(for: id) }
        grid.onHover = { [weak self] tile, inside in self?.gmailPreview.hover(tile, inside: inside) }
        gmail.onChange = { [weak self] in self?.render() }
        gmailPreview.onPresentationChange = { [weak owner] in owner?.windowShell.hoverHoldDidChange() }
        gmailPreview.inbox = { [weak self] in self?.gmail.states[$0]?.inbox }
        gmailPreview.refresh = { [weak self] in self?.gmail.refresh($0) }
        gmailPreview.permitted = { [weak self] _, captured, account in
            guard let self, let owner = self.owner, owner.acceptsCommands, !owner.isPrivateWindow,
                  !owner.sidebar.isPresentationHidden, !owner.sidebar.isSwitchingSpace,
                  !owner.palette.isPresented, !owner.library.isPresented, owner.themeEditor == nil,
                  !owner.session.isClosed, let current = owner.session.organization,
                  current.profileID == self.profileID,
                  let tab = current.tab(captured.id), tab.section.keepsPinnedURL else { return false }
            return captured.section == tab.section && BrowserGmailAccount(url: tab.pinnedURL ?? tab.url) == account
        }
        gmailPreview.open = { [weak self] tab, account, message in self?.openGmail(tab, account: account, message: message) }
        owner.sidebar.onTabHover = { [weak self] row, inside in
            guard let self, let owner = self.owner else { return false }
            if let tab = owner.session.organization?.tab(row.item.id), tab.section.keepsPinnedURL,
               BrowserGmailAccount(url: tab.pinnedURL ?? tab.url) != nil {
                if inside { owner.richTabPreview.dismiss() }
                self.gmailPreview.hover(row, tab: tab, inside: inside)
                return true
            }
            if inside { self.gmailPreview.dismiss() }
            return owner.richTabPreview.hover(row, inside: inside)
        }
        gmailRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.owner?.window?.occlusionState.contains(.visible) == true else { return }
                self.render()
            }
        }
        grid.dropTarget.onPreviewCountChange = { [weak self] count in self?.owner?.sidebar.favoritePreviewCount = count }
        grid.dropTarget.onEmptyZoneVisibilityChange = { [weak self] visible in
            guard let sidebar = self?.owner?.sidebar else { return }
            sidebar.showsEmptyFavoritesDropZone = visible && sidebar.favoriteCount == 0
        }
        grid.dropTarget.validate = { [weak self] payload, destination in
            guard let self, let owner = self.owner, owner.acceptsCommands,
                  let snapshot = owner.session.organization, let catalog = owner.session.catalog,
                  snapshot.profileID == payload.profileID else { return false }
            return snapshot.validateMove(payload.nodes, to: destination, catalog: catalog) == nil
        }
        grid.dropTarget.commit = { [weak self] payload, destination in
            guard let self, let owner = self.owner, let snapshot = owner.session.organization else { return }
            owner.submitInput { controller in
                guard let current = controller.session.organization,
                      current.spaceID == snapshot.spaceID, current.profileID == snapshot.profileID,
                      let catalog = controller.session.catalog,
                      current.validateMove(payload.nodes, to: destination, catalog: catalog) == nil else { return }
                controller.session.moveItems(payload.nodes, to: destination)
            }
        }
        icons.onChange = { [weak self] in self?.render() }
        let priorMediaHook = owner.siteControls.onMediaStateChange
        owner.siteControls.onMediaStateChange = { [weak self] surface, state in
            priorMediaHook?(surface, state)
            guard let self, grid.items.contains(where: {
                surfacesByTab[$0.tab.id]?.value === surface
                    && ($0.isAudible != (state.isAudible ?? state.isAudioPlaying) || $0.isAudioMuted != state.isAudioMuted)
            }) else { return }
            render()
        }
        observer = owner.engineEventHooks.observe { [weak self] surface, event in
            guard let self, let owner = self.owner, owner.owns(surface) else { return }
            let occurrence = owner.session.occurrenceID(for: surface)
            if event == .navigationFinished,
               let id = owner.session.snapshot?.tabs.first(where: { $0.occurrenceID == occurrence })?.id,
               let tab = owner.session.organization?.tab(id), tab.section.keepsPinnedURL,
               let account = BrowserGmailAccount(url: tab.pinnedURL ?? tab.url) {
                gmail.refresh(account, force: true)
            }
            guard grid.items.contains(where: { surfacesByTab[$0.tab.id]?.value === surface })
                || owner.session.organization?.favorites.contains(where: {
                    if case let .tab(tab) = $0 { return occurrence != nil && tab.occurrenceID == occurrence }
                    return false
                }) == true else { return }
            render()
            if grid.items.contains(where: { surfacesByTab[$0.tab.id]?.value === surface }),
               event == .navigationFinished || (surface !== owner.session.selectedSurface && event != .navigationStarted) {
                owner.siteControls.refreshMedia(surface)
            }
        }
    }

    func shutdown() {
        gmailRefreshTimer?.invalidate(); gmailRefreshTimer = nil
        gmailPreview.dismiss(); gmail.clear()
        observer?.cancel()
        observer = nil
        icons.clear()
        surfacesByTab.removeAll()
        menuSelection = nil
        acceptedMenuCommands.removeAll()
        menuController = nil
        grid.commandsEnabled = false
        grid.dropTarget.end()
    }

    func bind(to registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) { self.registry = registry }

    func render() {
        guard let owner, let session = owner.session else { return }
        owner.sidebar.spaceSwipe.validate(catalog: session.catalog, active: session.snapshot?.activeSpaceID)
        owner.sidebar.prepareSpaceContentPublication(to: session.snapshot?.activeSpaceID)
        let snapshot = session.organization
        if spaceID != snapshot?.spaceID { gmailPreview.dismiss(); spaceID = snapshot?.spaceID }
        if profileID != snapshot?.profileID {
            gmailPreview.dismiss(); gmail.clear()
            icons.clear()
            surfacesByTab.removeAll()
            menuSelection = nil
            acceptedMenuCommands.removeAll()
            profileID = snapshot?.profileID
        }
        let tabs = snapshot?.favorites.compactMap { item -> BrowserOrganizationTabItem? in
            if case let .tab(tab) = item { return tab }
            return nil
        } ?? []
        let ids = Set(tabs.map(\.id))
        let pinnedTabs = snapshot.map { FolderPreviewResult.ordered($0.pinned).map(\.tab) } ?? []
        let accounts = Set((tabs + pinnedTabs).compactMap { BrowserGmailAccount(url: $0.pinnedURL ?? $0.url) })
        gmail.reconcile(profile: owner.isPrivateWindow ? nil : snapshot?.profileID,
                        accounts: owner.isPrivateWindow ? [] : accounts,
                        session: owner.isPrivateWindow ? nil : gmailSession)
        icons.retain(ids)
        surfacesByTab = surfacesByTab.filter { ids.contains($0.key) && $0.value.value.map(owner.owns) == true }
        let items = tabs.map { tab in
            if let id = tab.occurrenceID, let surface = session.surface(for: id) { surfacesByTab[tab.id] = WeakSurface(surface) }
            let surface = surfacesByTab[tab.id]?.value
            let media = surface.flatMap { owner.siteControls.mediaStates[ObjectIdentifier($0)] }
            let icon = icons.image(for: tab, surface: surface, isOwned: { [weak owner] in owner?.owns($0) == true })
            let account = BrowserGmailAccount(url: tab.pinnedURL ?? tab.url)
            let count = account.flatMap { gmail.states[$0]?.inbox?.unreadCount }
            let badges = snapshot.flatMap { owner.settingsPreferences?.runtime.document.profile($0.profileID).hiddenGmailBadges } ?? []
            return FavoriteTileItem(tab: tab, favicon: icon, isLoading: surface?.navigationState.isLoading == true,
                                    isAudible: media?.isAudible ?? media?.isAudioPlaying, isAudioMuted: media?.isAudioMuted,
                                    gmailUnreadCount: count, showsGmailBadge: !badges.contains(tab.id))
        }
        grid.commandsEnabled = !owner.isPreparingForTermination && !session.isClosed
        grid.minimumTileWidth = owner.sidebar.favoriteMinimumTileWidth
        owner.sidebar.favoriteCount = items.count
        grid.accent = owner.sidebar.currentThemeAccent
        grid.render(items, profileID: snapshot?.profileID)
        let hidden = snapshot.flatMap { owner.settingsPreferences?.runtime.document.profile($0.profileID).hiddenGmailBadges } ?? []
        for row in owner.sidebar.page.list.tabRows {
            let account = snapshot?.tab(row.item.id).flatMap { $0.section.keepsPinnedURL ? BrowserGmailAccount(url: $0.pinnedURL ?? $0.url) : nil }
            row.setGmailUnread(count: account.flatMap { gmail.states[$0]?.inbox?.unreadCount }, showsBadge: !hidden.contains(row.item.id))
        }
        gmailPreview.reconcile()
    }

    func applySelection(_ ids: Set<TabID>) {
        guard let owner, let snapshot = owner.session.organization, profileID == snapshot.profileID else { render(); return }
        let items = grid.items.compactMap { item -> FavoriteTileItem? in
            guard ids.contains(item.tab.id), let tab = owner.session.organizationTab(item.tab.id) else { return nil }
            return FavoriteTileItem(tab: tab, favicon: item.favicon, isLoading: item.isLoading,
                isAudible: item.isAudible, isAudioMuted: item.isAudioMuted,
                gmailUnreadCount: item.gmailUnreadCount, showsGmailBadge: item.showsGmailBadge)
        }
        grid.applySelection(items)
    }

    func hasFavorite(at index: Int) -> Bool {
        let count = owner?.session.organization?.favorites.compactMap { $0.node.tabID }.count ?? 0
        return index >= 0 && index < count
    }
    func activate(at index: Int) {
        guard hasFavorite(at: index) else { return }
        owner?.hideLibrary()
        owner?.session.selectFavorite(at: index) { [weak owner] _ in
            guard let owner, owner.window?.isKeyWindow == true else { return }
            owner.focusSelectedDocument()
        }
    }

    var currentMenuTab: BrowserOrganizationTabItem? {
        guard let owner, owner.acceptsCommands, let captured = menuSelection,
              let current = owner.session.organization, current.spaceID == captured.spaceID,
              current.profileID == captured.profileID, owner.commandState.context == captured.context,
              current.tab(captured.tab.id) == captured.tab else { return nil }
        return captured.tab
    }
    func contextMenu(for id: TabID) -> NSMenu? {
        gmailPreview.dismiss()
        guard let owner, let registry, let snapshot = owner.session.organization,
              let tab = snapshot.tab(id), snapshot.favorites.contains(where: { $0.node == .tab(id) }),
              let target = registry.captureTarget(windowID: owner.id) else { return nil }
        let captured = MenuSelection(tab: tab, spaceID: snapshot.spaceID, profileID: snapshot.profileID, context: target.context)
        menuSelection = captured
        let ids: [BrowserCommandID] = [.copyFavoriteLink, .renameFavorite] + (tab.isAwayFromPinnedURL ? [.resetFavorite] : []) + [.removeFavorite]
        let controller = FavoritesContextMenu(definitions: ids.compactMap { registry.definition($0) })
        controller.isEnabled = { [weak self, weak registry] id in
            self?.menuSelection?.token == captured.token && registry?.isEnabled(id, target: target) == true
        }
        controller.onClose = { [weak self] in
            if self?.menuSelection?.token == captured.token { self?.menuSelection = nil }
        }
        controller.onInvoke = { [weak self, weak registry] id in
            guard let self, let registry, let owner = self.owner,
                  owner.commandState.context == captured.context, matches(captured),
                  owner.session.organization?.tab(captured.tab.id) == captured.tab else { return }
            // AppKit can close the menu before dispatching its action. Restore the captured
            // object for synchronous validation, and retain an accepted action independently.
            menuSelection = captured
            acceptedMenuCommands.append((id, captured))
            if !registry.dispatch(id, origin: .contextMenu, target: target, onDropped: { [weak self] in
                self?.acceptedMenuCommands.removeAll { $0.selection.token == captured.token }
                if self?.menuSelection?.token == captured.token { self?.menuSelection = nil }
            }) {
                acceptedMenuCommands.removeAll { $0.selection.token == captured.token }
                menuSelection = nil
            }
        }
        if let move = SidebarMoveMenu(owner: owner, nodes: [.tab(id)]) {
            controller.menu.insertItem(move.item, at: 1)
            controller.retainedOwners.append(move)
        }
        menuController = controller
        for item in controller.menu.items where !item.isSeparatorItem && item.submenu == nil { item.isEnabled = controller.validateMenuItem(item) }
        if let badge = gmailBadgeMenu(for: id) {
            controller.retainedOwners.append(badge)
            controller.menu.insertItem(.separator(), at: 0)
            controller.menu.insertItem(badge.item, at: 0)
        }
        return controller.menu
    }

    func gmailBadgeMenu(for id: TabID) -> GmailBadgeMenu? {
        guard let owner, !owner.isPrivateWindow, let snapshot = owner.session.organization,
              let tab = snapshot.tab(id), tab.section.keepsPinnedURL,
              let account = BrowserGmailAccount(url: tab.pinnedURL ?? tab.url),
              let runtime = owner.settingsPreferences?.runtime else { return nil }
        return GmailBadgeMenu(tab: id, profile: snapshot.profileID, runtime: runtime,
            permitted: { [weak owner] in
                guard let owner, owner.acceptsCommands, !owner.session.isClosed,
                      let current = owner.session.organization, current.profileID == snapshot.profileID,
                      current.spaceID == snapshot.spaceID, let tab = current.tab(id), tab.section.keepsPinnedURL else { return false }
                return BrowserGmailAccount(url: tab.pinnedURL ?? tab.url) == account
            }, changed: { [weak self] in self?.render() },
            failed: { [weak owner] in owner?.session.onError?($0) })
    }

    private func openGmail(_ tab: BrowserOrganizationTabItem, account: BrowserGmailAccount, message: String?) {
        guard let owner, let current = owner.session.organization,
              tab.section.keepsPinnedURL,
              let url = message.flatMap({ account.messageURL(id: $0) }) ?? (message == nil ? account.composeURL : nil) else { return }
        let id = tab.id, profile = current.profileID, space = current.spaceID
        owner.submitInput { controller in
            guard !controller.isPrivateWindow, let current = controller.session.organization,
                  current.profileID == profile, current.spaceID == space,
                  let tab = current.tab(id), tab.section.keepsPinnedURL,
                  BrowserGmailAccount(url: tab.pinnedURL ?? tab.url) == account else { return }
            controller.session.selectTab(id)
            controller.session.performOnSelectedSurface { [weak controller] surface in
                guard let controller, controller.session.organization?.selectedTab?.id == id,
                      controller.session.activeProfileID == profile,
                      controller.session.organization?.spaceID == space else { return }
                surface.navigate(to: url)
                controller.focusSelectedDocument()
            }
        }
    }

    func performMenuCommand(_ id: BrowserCommandID, origin: BrowserCommandOrigin) {
        guard origin == .contextMenu, let owner else { return }
        let context = owner.commandState.context
        // Context changes purge stale requests; `onDropped` also removes the exact request when
        // a busy session rejects delivery without changing its revision or input epoch.
        acceptedMenuCommands.removeAll { $0.selection.context != context }
        guard let index = acceptedMenuCommands.firstIndex(where: { $0.id == id && $0.selection.context == context }) else { return }
        let captured = acceptedMenuCommands.remove(at: index).selection
        defer { if menuSelection?.token == captured.token { menuSelection = nil } }
        guard matches(captured) else { return }
        let tab = captured.tab
        switch id {
        case .removeFavorite: owner.session.removeFromFavorites([tab.id])
        case .resetFavorite:
            owner.hideLibrary()
            owner.session.selectTab(tab.id)
            owner.session.resetTabToPinnedURL(tab.id) { surface, url in surface.navigate(to: url) }
        case .copyFavoriteLink:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url.absoluteString, forType: .string)
        case .renameFavorite: presentRename(captured)
        default: break
        }
    }

    private func matches(_ captured: MenuSelection) -> Bool {
        guard let owner, !owner.session.isClosed, let current = owner.session.organization else { return false }
        return current.profileID == captured.profileID && current.spaceID == captured.spaceID
            && current.favorites.contains { $0.node == .tab(captured.tab.id) }
    }
    private func presentRename(_ captured: MenuSelection) {
        guard let owner, let window = owner.window, window.isVisible else { return }
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = uiText("Rename Favorite")
        alert.addButton(withTitle: uiText("Save"))
        alert.addButton(withTitle: uiText("Cancel"))
        let name = NSTextField(string: captured.tab.customTitle ?? "")
        name.placeholderString = captured.tab.pageTitle ?? uiText("Page Title")
        name.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        name.setAccessibilityLabel(uiText("Favorite Name"))
        alert.accessoryView = name
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self, weak owner] response in
            guard response == .alertFirstButtonReturn, let self, let owner, owner.acceptsCommands else { return }
            let title = name.stringValue
            owner.submitInput { [weak self] controller in
                guard let self, matches(captured) else { return }
                controller.session.renameFavorite(captured.tab.id, to: title,
                    inProfile: captured.profileID, fromSpace: captured.spaceID)
            }
        }
    }
}
