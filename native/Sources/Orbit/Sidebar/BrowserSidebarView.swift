import AppKit
import BrowserCore

private typealias Metrics = OrbitTokens.Metrics.Sidebar

/// Projects the engine-independent window selection without owning browser state.
/// Anatomy of design §2, from the top: toolbar row (window buttons, sidebar toggle, back,
/// forward, reload), address field, Favorites, then the scrollable Space page (Space title, pinned
/// rows and folders, separator, New Tab, Today rows) and the footer. The visual layer belongs to
/// the Themes & motion lot; the Pinned/Today list (SB-LIST) lives in the page's
/// `SidebarListView`, fed by `render(catalog:activeSpaceID:organization:)`; the Favorites grid
/// (FAVORITES lot) fills `favoritesContainer` and joins drag and drop through `addDropTarget(_:)`.
/// The view keeps the window's list selection (ORBIT-MULTISELECT, `BrowserOrganizationSelection`)
/// and is the single AppKit dragging destination of the sidebar (ORBIT-DRAG).
@MainActor
final class BrowserSidebarView: NSView, SidebarListHost {
    var isLibraryInputSuppressed = false
    /// An offscreen sidebar retains its backing layers but accepts no input or presentations.
    var isShellHidden = false
    var isPresentationHidden: Bool { isShellHidden || isHiddenOrHasHiddenAncestor }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isLibraryInputSuppressed || isShellHidden ? nil : super.hitTest(point)
    }

    var isPrivate = false {
        didSet {
            privateIndicator.isHidden = !isPrivate
            footer.isHidden = isPrivate
            page.isPrivate = isPrivate
            needsLayout = true
        }
    }
    private let privateIndicator: NSTextField = {
        let label = NSTextField(labelWithString: uiText("Private"))
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.setAccessibilityIdentifier("private-window-indicator")
        label.isHidden = true
        return label
    }()
    let navigationContainer = SidebarToolbarRow()
    let addressContainer = SidebarAddressField()
    var extensionsContainer: SidebarExtensionStrip { addressContainer.extensions }
    /// Seam for the Favorites grid (`BrowserOrganizationSnapshot.favorites`): set `favoriteCount`
    /// so the page starts below the tiles, and place tiles with `geometry.favoriteTileFrame(index:)`.
    let favoritesContainer = SidebarFlippedView()
    var favoriteCount = 0 { didSet { if favoriteCount != oldValue { needsLayout = true } } }
    var favoriteMinimumTileWidth = Metrics.favoriteMinimumTileWidth { didSet { if favoriteMinimumTileWidth != oldValue { needsLayout = true } } }
    var favoritePreviewCount: Int? { didSet { if favoritePreviewCount != oldValue { needsLayout = true } } }
    var showsEmptyFavoritesDropZone = false { didSet { if showsEmptyFavoritesDropZone != oldValue { needsLayout = true } } }
    /// Pinned rows laid out above the separator, gap pitches included (0 when collapsed).
    var pinnedRowCount: Int { page.list.displayedLayout.pinnedSlotCount }
    let footer = SidebarFooterView()

    // Window identity for drag payloads (`BrowserWindowController.id`).
    var windowIdentifier: UUID?
    var onFolderHover: ((SidebarListRow, Bool) -> Void)?
    var onPreviewInvalidated: ((SidebarListRow) -> Void)?
    var onSelectTab: ((TabID) -> Void)?
    var onCloseTabs: (([TabID]) -> Void)?
    var onSetFolderCollapsed: ((FolderID, Bool) -> Void)?
    var onResetTab: ((TabID) -> Void)?
    var onToggleTabAudio: ((TabID) -> Void)?
    var onRename: ((BrowserOrganizationNode, String) -> Void)?
    var onRenameDidEnd: (() -> Void)?
    var onClearToday: (() -> Void)?
    /// A validated drop: payload, destination, and whether the organization changes (false for
    /// rows dropped back in place, which still move live documents between windows).
    var onDrop: ((SidebarDragPayload, BrowserOrganizationDestination, Bool) -> Void)?
    /// Context menu for these nodes (the clicked row, or the multi-selection containing it).
    var onContextMenu: (([BrowserOrganizationNode], NSEvent, NSView) -> Void)?
    /// ⌘Z routing between organization commands and window edits (UX-UNDO).
    let undoRouter = SidebarUndoRouter()
    /// The engine's title of a tab loaded in this window (fresher than the stored copy).
    var liveTitle: (BrowserOrganizationTabItem) -> String? = { _ in nil }
    var liveActivity: (BrowserOrganizationTabItem) -> SidebarTabActivity = { _ in .init() }
    var onSelectSpace: ((SpaceID) -> Void)?
    var onNewTab: (() -> Void)?
    var onNewSpace: (() -> Void)?
    var configureNewSpacePage: ((SidebarNewSpacePageView) -> Void)?
    var creationActions: (() -> [SidebarCreationAction])?
    private var creationMenu: SidebarCreationMenu?
    var hasFooterPresentation: Bool { creationMenu != nil || footer.contextMenu != nil || footer.iconPicker != nil }
    var onFooterPresentationChange: (() -> Void)?
    func cancelFooterPresentations() {
        creationMenu?.popover.performClose(nil)
        footer.cancelContextMenu()
        footer.cancelIconPicker()
        spaceHoverDidChange(nil)
    }
    var onDeleteSpace: ((SpaceID) -> Void)?
    var onRenameSpace: ((SpaceID) -> Void)?
    var onEditSpaceTheme: ((SpaceID) -> Void)?
    var onEditSpaceIcon: ((SpaceID) -> Void)?
    var onMoveSpace: ((SpaceID, SpaceID?) -> Void)?
    var onShowLibrary: (() -> Void)?
    /// Shortcut label of the Space at an index ("⌃2"), supplied by the Commands lot.
    var spaceShortcutLabel: (Int) -> String? = { BrowserSpaceCommands.shortcutLabel(at: $0) }
    var resolveSpaceIcon: (SpaceID) -> BrowserSpaceIcon = { _ in .none }

    private let pageContainer = SidebarSpaceContentViewport()
    private(set) var page = SidebarSpacePageView()
    private var leavingPage: SidebarSpacePageView?
    let spaceSwipe = SidebarSpaceSwipeController()
    var previewIcon: (ProfileID, URL) -> NSImage? = { _, _ in nil }
    private var swipeSharesFavorites = false
    private var ordinarySharesFavorites = false
    private var swipeOutgoing: SidebarSpacePageView?
    private var swipePreview: SidebarSpacePageView?
    private var swipePreviewContent: SidebarListContent?
    private var swipeOffset: CGFloat?
    private(set) var newSpaceSwipePage: SidebarNewSpacePageView?
    private var swipeSourceGeometry: OrbitSidebarGeometry?
    private var swipeDestinationGeometry: OrbitSidebarGeometry?
    private var swipePreviewFavorites: FavoritesGridView?
    private var swipeOutgoingFavorites: FavoritesGridView?
    private struct PreparedSwipePage {
        let page: SidebarSpacePageView
        let content: SidebarListContent
        let favorites: FavoritesGridView
        let pageRaster: SpaceSwipeRaster?
        let favoritesRaster: SpaceSwipeRaster?
    }
    private var preparedSwipePages: [SpaceID: PreparedSwipePage] = [:]
    private var swipePreviewRaster: SpaceSwipeRaster?
    private var swipeFavoritesRaster: SpaceSwipeRaster?
    private let ordinarySpaceMotion = OrbitSpringAnimator(value: 0, usesCoreVideoClock: true)
    private var ordinaryOffset: CGFloat?
    private var ordinaryDirection: CGFloat = 1
    private var ordinarySourceGeometry: OrbitSidebarGeometry?
    private var ordinaryOutgoingFavorites: FavoritesGridView?
    private let tooltip = SidebarSpaceTooltip()
    private var tooltipTimer: (any OrbitCancellable)?
    private var tooltipIsWarm = false
    private var renderedCatalog: BrowserCatalogSnapshot?
    private var activeSpaceID: SpaceID?
    private var commandsEnabled = true
    private var accent = OrbitTokens.ThemeAccent.defaultSpace
    private(set) var geometry = OrbitSidebarGeometry.resolve(.init(height: 640))

    // Organization projection (SB-LIST).
    private(set) var organization: BrowserOrganizationSnapshot?
    var onSelectSplit: ((SplitGroupID) -> Void)?
    private(set) var selection = BrowserOrganizationSelection()
    private var lastSelectedTabID: TabID?
    /// Targets of the context menu being shown; commands use them instead of the selection.
    private(set) var contextMenuNodes: [BrowserOrganizationNode] = []
    private let dropCoordinator = SidebarDropCoordinator()
    var onReorderSnap: (() -> Void)? {
        get { dropCoordinator.onReorderSnap }
        set { dropCoordinator.onReorderSnap = newValue }
    }
    /// Retained here; targets hold their views weakly.
    private var externalDropTargets: [any SidebarDropTarget] = []

    var tabTitles: [String] { page.list.content.tabs.map(\.title) }
    var spaceTitles: [String] { renderedCatalog?.spaces.map(\.name) ?? [] }
    var isSwitchingSpace: Bool { leavingPage != nil }
    var listContent: SidebarListContent { page.list.content }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.group)
        setAccessibilityLabel(OrbitShellText.sidebar)
        pageContainer.wantsLayer = true
        pageContainer.layer?.masksToBounds = true
        tooltip.isHidden = true
        for view in [navigationContainer, addressContainer, pageContainer, footer, tooltip, privateIndicator] {
            addSubview(view)
        }
        privateIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            privateIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            privateIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            privateIndicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            privateIndicator.heightAnchor.constraint(equalToConstant: 20)
        ])
        configure(page)
        pageContainer.addSubview(favoritesContainer)
        pageContainer.addSubview(page)
        footer.libraryButton.target = self
        footer.libraryButton.action = #selector(showLibrary(_:))
        footer.plusButton.target = self
        footer.plusButton.action = #selector(showCreationMenu(_:))
        footer.onSelectSpace = { [weak self] id in self?.onSelectSpace?(id) }
        footer.onDeleteSpace = { [weak self] id in self?.onDeleteSpace?(id) }
        footer.onRenameSpace = { [weak self] id in self?.onRenameSpace?(id) }
        footer.onEditSpaceTheme = { [weak self] id in self?.onEditSpaceTheme?(id) }
        footer.onMoveSpace = { [weak self] id, before in self?.onMoveSpace?(id, before) }
        footer.onMenuWillOpen = { [weak self] in
            self?.creationMenu?.popover.performClose(nil)
            self?.spaceSwipe.cancel()
            self?.spaceHoverDidChange(nil)
        }
        footer.onMenuPresentationChange = { [weak self] in self?.onFooterPresentationChange?() }
        footer.onHoverSpace = { [weak self] button in self?.spaceHoverDidChange(button, allowsHandoff: true) }
        registerForDraggedTypes([SidebarDragPayload.pasteboardType, FavoritesDragPayload.pasteboardType])
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cancelFooterPresentations()
        spaceSwipe.attach(to: self)
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelFooterPresentations()
        spaceSwipe.cancel()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        spaceSwipe.layoutChanged()
        let layout = page.list.displayedLayout
        geometry = OrbitSidebarGeometry.resolve(.init(
            width: bounds.width, height: bounds.height,
            favoriteCount: max(favoriteCount, favoritePreviewCount ?? 0, showsEmptyFavoritesDropZone ? 1 : 0),
            favoriteMinimumTileWidth: favoriteMinimumTileWidth,
            pinnedRowCount: layout.pinnedSlotCount, todayRowCount: layout.todaySlotCount,
            spaceCount: renderedCatalog?.spaces.count ?? 1))
        navigationContainer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: geometry.addressFrame.minY)
        navigationContainer.apply(geometry)
        addressContainer.frame = geometry.addressFrame
        pageContainer.frame = contentViewportFrame
        favoritesContainer.frame = contentFrame(geometry.favoritesFrame)
        for page in [page, leavingPage, swipePreview, swipeOutgoing].compactMap({ $0 }) {
            page.frame = contentFrame(geometry.pageFrame)
            page.geometry = geometry
        }
        pageContainer.scrollReceiver = page.pageScrollView
        layoutSpaceSwipePages()
        layoutOrdinarySpacePages()
        footer.frame = geometry.footerFrame
        footer.apply(geometry)
        if isPrivate {
            footer.isHidden = true
            favoritesContainer.isHidden = true
            page.isPrivate = true
            privateIndicator.isHidden = false
        }
    }

    // MARK: Projection

    func setCommandsEnabled(_ enabled: Bool) {
        commandsEnabled = enabled
        if !enabled { cancelFooterPresentations(); spaceSwipe.cancel() }
        for grid in favoritesContainer.subviews.compactMap({ $0 as? FavoritesGridView }) { grid.commandsEnabled = enabled }
        page.setCommandsEnabled(enabled)
        footer.setCommandsEnabled(enabled)
        navigationContainer.setCommandsEnabled(enabled)
    }

    /// Projects the catalog and the active Space's organization. A snapshot of another Space (a
    /// switch in flight) renders as empty until the matching one arrives.
    func render(catalog: BrowserCatalogSnapshot?, activeSpaceID: SpaceID?, organization: BrowserOrganizationSnapshot?) {
        if catalog != renderedCatalog || activeSpaceID != self.activeSpaceID { cancelFooterPresentations() }
        let wasCreating = spaceSwipe.isCreationPageVisible
        spaceSwipe.validate(catalog: catalog, active: activeSpaceID)
        let consumedSwipe = spaceSwipe.willRender(active: activeSpaceID) || wasCreating
        let previousSpaceID = self.activeSpaceID
        let previousCatalog = renderedCatalog
        if catalog != renderedCatalog || activeSpaceID != self.activeSpaceID {
            renderedCatalog = catalog
            self.activeSpaceID = activeSpaceID
            footer.render(spaces: catalog?.spaces ?? [], activeSpaceID: activeSpaceID)
            needsLayout = true
        }
        let current = organization?.spaceID == activeSpaceID ? organization : nil
        self.organization = current
        if let current {
            let selectedID = current.selectedTab?.id
            if selectedID != lastSelectedTabID {
                lastSelectedTabID = selectedID
                // The selection follows the active tab unless several rows are selected.
                if selection.nodes.count <= 1, let selectedID { selection.select(current.rowNode(for: selectedID), in: current) }
            }
            selection.reconcile(with: current)
        }
        page.canDeleteSpace = (catalog?.spaces.count ?? 0) > 1
        let content = makeContent()
        let space = catalog?.spaces.first { $0.id == activeSpaceID }
        let title = space?.name ?? OrbitShellText.untitledSpace
        if !consumedSwipe, let previousSpaceID, let activeSpaceID, previousSpaceID != activeSpaceID, page.spaceID == previousSpaceID {
            let spaces = catalog?.spaces ?? previousCatalog?.spaces ?? []
            let from = spaces.firstIndex { $0.id == previousSpaceID } ?? previousCatalog?.spaces.firstIndex { $0.id == previousSpaceID } ?? 0
            let to = spaces.firstIndex { $0.id == activeSpaceID } ?? 0
            switchPage(to: activeSpaceID, title: title, content: content, forward: to >= from)
        } else {
            page.spaceID = activeSpaceID
            page.render(title: title, content: content, animated: true)
        }
    }

    private struct ContentInputs: Equatable {
        let organization: BrowserOrganizationSnapshot?
        let selection: BrowserOrganizationSelection
        let liveTitles: [TabID: String]
        let liveActivities: [TabID: SidebarTabActivity]
    }
    private var contentInputs: ContentInputs?
    private var cachedContent = SidebarListContent.empty

    /// Surface updates (loading progress, titles) re-render often: the content is rebuilt only
    /// when the snapshot, the selection or a live title changed.
    private func makeContent() -> SidebarListContent {
        var titles: [TabID: String] = [:]
        var activities: [TabID: SidebarTabActivity] = [:]
        if let organization {
            for tab in organization.allTabs where tab.occurrenceID != nil {
                if let title = liveTitle(tab) { titles[tab.id] = title }
                activities[tab.id] = liveActivity(tab)
            }
        }
        let inputs = ContentInputs(organization: organization, selection: selection, liveTitles: titles, liveActivities: activities)
        guard inputs != contentInputs else { return cachedContent }
        contentInputs = inputs
        cachedContent = SidebarListContent(snapshot: organization, selection: selection, liveTitle: { titles[$0.id] },
                                          liveActivity: { activities[$0.id] ?? .init() })
        return cachedContent
    }

    /// Re-renders after a local selection change, without waiting for the session.
    private func refreshContent() {
        page.render(title: nil, content: makeContent(), animated: true)
    }

    // MARK: Commands support

    /// Nodes a list command acts on: the context menu's rows, else a multi-selection, else the
    /// selected tab.
    func commandTargets() -> [BrowserOrganizationNode] {
        if !contextMenuNodes.isEmpty { return contextMenuNodes }
        guard let organization else { return [] }
        let ordered = selection.orderedNodes(in: organization)
        if ordered.count >= 2 { return ordered }
        if let selected = organization.selectedTab { return [organization.rowNode(for: selected.id)] }
        return ordered
    }

    /// Starts renaming `node` (deferred until its row exists).
    func beginRename(_ node: BrowserOrganizationNode) { page.list.beginRename(node) }

    func reveal(_ node: BrowserOrganizationNode) { page.list.reveal(node) }

    /// Called by the owner once a context menu it showed has closed.
    func endContextMenu() {
        contextMenuNodes = []
        page.list.setContextTargets([])
    }

    /// Regions other than the list (the Favorites grid) that accept dragged rows. Frontmost first.
    func addDropTarget(_ target: any SidebarDropTarget) {
        externalDropTargets.removeAll { $0 === target }
        externalDropTargets.append(target)
    }

    private var dropTargets: [any SidebarDropTarget] { externalDropTargets + [page.list] }

    // MARK: SidebarListHost

    func list(_ list: SidebarListView, activate node: BrowserOrganizationNode, modifiers: NSEvent.ModifierFlags) {
        guard commandsEnabled, let organization, list === page.list else { return }
        if modifiers.contains(.command) {
            if selection.isEmpty, let selected = organization.selectedTab, organization.rowNode(for: selected.id) != node {
                selection.select(organization.rowNode(for: selected.id), in: organization)
            }
            selection.toggle(node, in: organization)
            refreshContent()
            return
        }
        if modifiers.contains(.shift) {
            if selection.anchor == nil, let selected = organization.selectedTab {
                selection.select(organization.rowNode(for: selected.id), in: organization)
            }
            selection.extend(to: node, in: organization)
            refreshContent()
            return
        }
        let hadMulti = selection.nodes.count >= 2
        selection.select(node, in: organization)
        if hadMulti { refreshContent() }
        switch node {
        case let .tab(id):
            onSelectTab?(id)
        case let .split(id): onSelectSplit?(id)
        case let .folder(id):
            if let folder = list.content.entry(for: node)?.folder { onSetFolderCollapsed?(id, !folder.isCollapsed) }
        }
    }

    func list(_ list: SidebarListView, close tab: TabID) {
        if commandsEnabled { onCloseTabs?(organization?.split(containing: tab)?.group.tabIDs ?? [tab]) }
    }
    func list(_ list: SidebarListView, resetToPinnedURL tab: TabID) { if commandsEnabled { onResetTab?(tab) } }
    func list(_ list: SidebarListView, toggleAudio tab: TabID) { if commandsEnabled { onToggleTabAudio?(tab) } }
    func list(_ list: SidebarListView, rename node: BrowserOrganizationNode, to title: String) {
        if commandsEnabled { onRename?(node, title) }
    }
    func listRenameDidEnd(_ list: SidebarListView) { onRenameDidEnd?() }

    func list(_ list: SidebarListView, contextMenuFor node: BrowserOrganizationNode, event: NSEvent, in view: NSView) {
        guard commandsEnabled, organization != nil else { return }
        spaceSwipe.cancel()
        let nodes = prepareContextMenu(for: node)
        if let onContextMenu { onContextMenu(nodes, event, view) } else { endContextMenu() }
    }

    /// Targets of a context menu on `node`: the multi-selection containing it, else the row. They
    /// stay highlighted and drive the commands until `endContextMenu()`.
    @discardableResult
    func prepareContextMenu(for node: BrowserOrganizationNode) -> [BrowserOrganizationNode] {
        let ordered = organization.map { selection.orderedNodes(in: $0) } ?? []
        let nodes = ordered.count >= 2 && ordered.contains(node) ? ordered : [node]
        contextMenuNodes = nodes
        page.list.setContextTargets(Set(nodes))
        return nodes
    }

    func list(_ list: SidebarListView, dragPayloadFor node: BrowserOrganizationNode, grabOffsetX: CGFloat) -> SidebarDragPayload? {
        guard let organization, let windowIdentifier else { return nil }
        let ordered = selection.orderedNodes(in: organization)
        let nodes = ordered.count >= 2 && ordered.contains(node) ? organization.topLevelNodes(ordered) : [node]
        return SidebarDragPayload(sourceWindow: windowIdentifier, spaceID: organization.spaceID,
                                  profileID: organization.profileID, nodes: nodes,
                                  rowCount: max(1, list.liftedRows(for: nodes).count), grabOffsetX: grabOffsetX)
    }

    func list(_ list: SidebarListView, dragDidChange payload: SidebarDragPayload?) {
        spaceSwipe.cancel()
        for target in externalDropTargets { target.sidebarDragDidChange(payload) }
    }

    func listCurrentNode(_ list: SidebarListView) -> BrowserOrganizationNode? {
        let content = list.content
        if let anchor = selection.anchor, content.entry(for: anchor) != nil { return anchor }
        return organization?.selectedTab.map { .tab($0.id) }.flatMap { content.entry(for: $0) != nil ? $0 : nil }
    }

    /// After a command consumed the multi-selection (⌘W): back to the visible tab.
    func collapseSelectionToActiveTab() {
        guard let organization else { return }
        if let selected = organization.selectedTab { selection.select(.tab(selected.id), in: organization) }
        else { selection.clear() }
        refreshContent()
    }

    func listCancelSelection(_ list: SidebarListView) {
        guard let organization, selection.nodes.count >= 2 else { return }
        if let selected = organization.selectedTab { selection.select(organization.rowNode(for: selected.id), in: organization) }
        else { selection.clear() }
        refreshContent()
    }

    func listNewTab(_ list: SidebarListView) { newTab(nil) }
    func listClearToday(_ list: SidebarListView) { if commandsEnabled { onClearToday?() } }
    func list(_ list: SidebarListView, undo redo: Bool, sender: Any?) {
        guard commandsEnabled else { return }
        undoRouter.perform(redo: redo, sender: sender, preferringOrganization: true)
    }

    func list(_ list: SidebarListView, validateUndo item: any NSValidatedUserInterfaceItem) -> Bool {
        undoRouter.validate(item, preferringOrganization: true)
    }

    // MARK: Drag destination (ORBIT-DRAG)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard commandsEnabled, let payload = dragPayload(from: sender) else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        page.autoscrollDuringDrag(at: convert(point, to: page))
        let verdict = dropCoordinator.update(payload: payload, at: point, in: self, targets: dropTargets,
                                             snapshot: organization, catalog: renderedCatalog)
        return verdict?.isValid == true ? .move : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropCoordinator.clear() }

    /// Any end of the session (cancelled over the sidebar included) drops leftover feedback; a
    /// committed drop already handed its feedback to the target.
    override func draggingEnded(_ sender: any NSDraggingInfo) { dropCoordinator.clear() }

    /// Rows dragged inside this process only: the list's payload, or a Favorites tile whose source
    /// still vouches for its pasteboard payload (FAVORITES' local check). Other applications'
    /// drags carry neither type, and a forged pasteboard without an in-process source is refused.
    private func dragPayload(from sender: any NSDraggingInfo) -> SidebarDragPayload? {
        guard sender.draggingSource != nil else { return nil }
        if let payload = SidebarDragPayload(pasteboard: sender.draggingPasteboard) { return payload }
        guard let source = sender.draggingSource as? any FavoritesLocalDragSource, let local = source.favoritesDragPayload,
              let data = sender.draggingPasteboard.data(forType: FavoritesDragPayload.pasteboardType), data.count < 64_000,
              let decoded = try? JSONDecoder().decode(FavoritesDragPayload.self, from: data), decoded == local else { return nil }
        return SidebarDragPayload(favorites: decoded, sourceWindow: SidebarWindowDirectory.id(of: (source as? NSView)?.window))
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        commandsEnabled && dropCoordinator.acceptedDrop() != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard commandsEnabled, let accepted = dropCoordinator.acceptedDrop() else {
            dropCoordinator.clear()
            return false
        }
        if let frame = accepted.target.dropFrame(for: accepted.proposal) {
            let settled = convert(frame, from: accepted.target.dropTargetView)
            sender.animatesToDestination = true
            let stacks = accepted.proposal.gap != nil
            sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, index, _ in
                // Rows settle one pitch apart in the placeholder; into a folder they settle on it.
                item.draggingFrame = stacks
                    ? NSRect(x: settled.minX, y: settled.minY + CGFloat(index) * Metrics.rowPitch, width: settled.width, height: Metrics.rowHeight)
                    : settled
            }
        }
        commitDrop(accepted.payload, proposal: accepted.proposal, target: accepted.target)
        return true
    }

    /// Commits a validated drop (also the entry point of the hidden-window tests).
    func commitDrop(_ payload: SidebarDragPayload, proposal: SidebarDropProposal, target: any SidebarDropTarget) {
        let isLocalNoOp = payload.sourceWindow == windowIdentifier
            && organization.map { SidebarDropResolver.isNoOp(payload.nodes, destination: proposal.destination, in: $0) } == true
        let committed = target.didAcceptDrop(proposal, payload: payload, changesOrganization: !isLocalNoOp)
        dropCoordinator.finish()
        if !committed { onDrop?(payload, proposal.destination, !isLocalNoOp) }
    }

    /// Validates and commits a drag at `point` (sidebar coordinates) without an AppKit dragging
    /// session; the hidden-window tests exercise the same path as `performDragOperation`.
    @discardableResult
    func simulateDrop(_ payload: SidebarDragPayload, at point: NSPoint) -> SidebarDropCoordinator.Verdict? {
        let verdict = dropCoordinator.update(payload: payload, at: point, in: self, targets: dropTargets,
                                             snapshot: organization, catalog: renderedCatalog)
        guard let accepted = dropCoordinator.acceptedDrop() else {
            dropCoordinator.clear()
            return verdict
        }
        commitDrop(accepted.payload, proposal: accepted.proposal, target: accepted.target)
        return verdict
    }

    /// Shows the verdict of a drag hovering `point` without dropping (tests).
    @discardableResult
    func simulateDragHover(_ payload: SidebarDragPayload, at point: NSPoint) -> SidebarDropCoordinator.Verdict? {
        dropCoordinator.update(payload: payload, at: point, in: self, targets: dropTargets,
                               snapshot: organization, catalog: renderedCatalog)
    }

    func simulateDragExit() { dropCoordinator.clear() }

    // MARK: Space switch (Orbit PageSwipeController spring and CoreVideo timeline).

    private func switchPage(to spaceID: SpaceID, title: String, content: SidebarListContent, forward: Bool) {
        ordinarySpaceMotion.onChange = nil
        ordinarySpaceMotion.onSettle = nil
        ordinarySpaceMotion.set(0)
        leavingPage?.removeFromSuperview()
        let outgoing = page
        outgoing.list.cancelRename()
        let incoming = SidebarSpacePageView()
        configure(incoming)
        incoming.spaceID = spaceID
        incoming.render(title: title, content: content, animated: false)
        incoming.setCommandsEnabled(commandsEnabled)
        pageContainer.addSubview(incoming)
        page = incoming
        outgoing.setCommandsEnabled(false)
        outgoing.setAccessibilityHidden(true)
        dropCoordinator.clear()
        let visible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true && bounds.width > 0
        let style = OrbitMotionStyle.resolve(animated: true, canAnimate: visible,
                                           reducedMotion: OrbitMotionPreferences.prefersReducedMotion)
        guard style == .spring else {
            if style == .crossfade { OrbitTransitions.crossfade(pageContainer.layer) }
            outgoing.removeFromSuperview()
            ordinaryOutgoingFavorites?.removeFromSuperview(); ordinaryOutgoingFavorites = nil
            ordinarySourceGeometry = nil; ordinaryOffset = nil
            needsLayout = true
            return
        }
        leavingPage = outgoing
        ordinarySourceGeometry = ordinarySourceGeometry ?? geometry
        ordinaryDirection = forward ? 1 : -1
        ordinaryOffset = 0
        ordinarySpaceMotion.onChange = { [weak self] value in
            guard let self else { return }
            ordinaryOffset = CGFloat(value)
            layoutOrdinarySpacePages()
        }
        ordinarySpaceMotion.onSettle = { [weak self, weak outgoing] in
            guard let self, self.leavingPage === outgoing else { return }
            outgoing?.removeFromSuperview(); self.leavingPage = nil
            self.ordinaryOutgoingFavorites?.removeFromSuperview(); self.ordinaryOutgoingFavorites = nil
            self.ordinaryOffset = nil; self.ordinarySourceGeometry = nil
            self.needsLayout = true
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        ordinarySpaceMotion.animate(to: Double(-ordinaryDirection * bounds.width), spring: OrbitTokens.Motion.spaceSwitchSidebar, in: self)
    }

    private func configure(_ page: SidebarSpacePageView) {
        page.list.host = self
        page.list.onFolderHover = { [weak self] row, inside in self?.onFolderHover?(row, inside) }
        page.list.onPreviewInvalidated = { [weak self] row in self?.onPreviewInvalidated?(row) }
        page.accent = accent
        page.onRenameSpace = { [weak self, weak page] in
            if let id = page?.spaceID { self?.onRenameSpace?(id) }
        }
        page.canDeleteSpace = (renderedCatalog?.spaces.count ?? 0) > 1
        page.onDeleteSpace = { [weak self, weak page] in
            if let id = page?.spaceID { self?.onDeleteSpace?(id) }
        }
        page.onEditTheme = { [weak self, weak page] in
            if let id = page?.spaceID { self?.onEditSpaceTheme?(id) }
        }
        page.onEditIcon = { [weak self, weak page] in
            if let id = page?.spaceID { self?.onEditSpaceIcon?(id) }
        }
        page.onLayoutChange = { [weak self] in self?.needsLayout = true }
    }

    // MARK: Accent

    func applyAccent(_ accent: OrbitTokens.ThemeAccent) {
        self.accent = accent
        addressContainer.accent = accent
        navigationContainer.accent = accent
        footer.accent = accent
        page.accent = accent
        leavingPage?.accent = accent
    }

    // MARK: Footer actions

    @objc private func newTab(_ sender: Any?) { if commandsEnabled { onNewTab?() } }
    @objc private func newSpace(_ sender: Any?) { if commandsEnabled { onNewSpace?() } }
    @objc private func showLibrary(_ sender: Any?) { if commandsEnabled { onShowLibrary?() } }

    @objc private func showCreationMenu(_ sender: NSButton) {
        guard commandsEnabled else { return }
        guard let actions = creationActions?(), !actions.isEmpty else { return }
        if let creationMenu { creationMenu.popover.performClose(nil); return }
        footer.cancelContextMenu()
        spaceSwipe.cancel()
        spaceHoverDidChange(nil)
        let menu = SidebarCreationMenu(actions: actions, accent: accent)
        creationMenu = menu
        menu.onClose = { [weak self] in
            self?.footer.setCreationMenuOpen(false)
            self?.creationMenu = nil
            self?.onFooterPresentationChange?()
        }
        footer.setCreationMenuOpen(true)
        onFooterPresentationChange?()
        menu.show(relativeTo: sender)
    }

    private func spaceHoverDidChange(_ button: SidebarSpaceButton?, allowsHandoff: Bool = false) {
        // Orbit keeps the capsule visible when moving directly to an adjacent Space.
        // Only pointer exits within the icon strip qualify; hide/menu/model invalidation
        // still dismiss synchronously, even when the pointer has not moved.
        if allowsHandoff, button == nil, tooltipIsWarm, let window,
           let first = footer.spaceButtons.first, let last = footer.spaceButtons.last {
            let strip = first.frame.union(last.frame)
            let pointer = footer.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if strip.contains(pointer) { return }
        }
        tooltipTimer?.cancel()
        tooltipTimer = nil
        let immediate = tooltipIsWarm
        tooltip.isHidden = true
        guard !hasFooterPresentation, let button else { tooltipIsWarm = false; return }
        let present: @MainActor @Sendable () -> Void = { [weak self, weak button] in
            guard let self, let button, button.window != nil else { return }
            let size = self.tooltip.configure(name: button.space.name, shortcut: self.spaceShortcutLabel(button.index), maximumWidth: max(40, self.bounds.width - 2 * Metrics.paddingX))
            let anchor = button.convert(button.bounds, to: self)
            var x = (anchor.midX - size.width / 2).rounded()
            x = min(max(Metrics.paddingX, x), self.bounds.width - Metrics.paddingX - size.width)
            self.tooltip.frame = NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height)
            self.tooltip.isHidden = false
            self.tooltipIsWarm = true
        }
        if immediate { present() }
        else { tooltipTimer = OrbitRunLoopTimer(after: SidebarSpaceTooltip.appearanceDelay, present) }
    }
}

/// The Space page: title, then the Pinned/Today list (separator, New Tab, Today rows), scrolled
/// together.
@MainActor
final class SidebarSpacePageView: NSView, NSTextFieldDelegate {
    var isPrivate = false { didSet { if oldValue != isPrivate { needsLayout = true } } }
    var spaceID: SpaceID? { didSet { if spaceID != oldValue { cancelSpaceRename() }; list.spaceID = spaceID } }
    private let scrollView = NSScrollView()
    let list = SidebarListView()
    private let titleLabel = SidebarSpaceTitleLabel(labelWithString: "")
    private let iconButton = OrbitGlyphButton(glyph: nil, label: uiText("Change Icon or Emoji…"))
    var iconSelection: BrowserSpaceIcon = .none {
        didSet {
            guard iconSelection != oldValue else { return }
            iconButton.subviews.forEach { $0.removeFromSuperview() }
            iconButton.isHidden = iconSelection == .none
            if iconSelection != .none {
                let image = SpaceIconImages.view(iconSelection, pointSize: Metrics.spaceIconSize)
                image.frame = iconButton.bounds.insetBy(dx: 4, dy: 4)
                image.autoresizingMask = [.width, .height]
                iconButton.addSubview(image)
            }
            needsLayout = true
        }
    }
    /// In-place Space name editor ( symbols `isEditingSpaceHeader`, `didBeginEditingSpaceName`
    /// shell; presentation is a reconstruction). Return, Tab or leaving the field commit; Escape cancels.
    private var titleEditor: NSTextField?
    private var titleCommit: ((String) -> Void)?
    var isRenamingSpace: Bool { titleEditor != nil }
    var onDeleteSpace: (() -> Void)?
    var canDeleteSpace = false { didSet { titleLabel.menu = titleMenu() } }
    var accent = OrbitTokens.ThemeAccent.defaultSpace {
        didSet {
            titleLabel.textColor = OrbitTokens.Color.Text.sidebarLabel
            list.accent = accent
        }
    }
    var onRenameSpace: (() -> Void)?
    var onEditTheme: (() -> Void)?
    var onEditIcon: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var geometry: OrbitSidebarGeometry? { didSet { if geometry != oldValue { needsLayout = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // Keep system overlay/legacy and hover behavior; use the smaller native control.
        scrollView.verticalScroller?.controlSize = .small
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = list
        addSubview(scrollView)
        titleLabel.font = OrbitTokens.Typography.sidebarSpaceTitle
        titleLabel.textColor = OrbitTokens.Color.Text.sidebarLabel
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.menu = titleMenu()
        titleLabel.onDoubleClick = { [weak self] in self?.renameSpace(nil) }
        list.addSubview(titleLabel)
        iconButton.isHidden = true
        iconButton.target = self
        iconButton.action = #selector(editIcon(_:))
        list.addSubview(iconButton)
        list.onLayoutChange = { [weak self] in
            self?.needsLayout = true
            self?.onLayoutChange?()
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Updates the page; a nil title keeps the current one.
    func render(title: String?, content: SidebarListContent, animated: Bool) {
        if let title, titleLabel.stringValue != title {
            titleLabel.stringValue = title
            needsLayout = true
        }
        list.apply(content, animated: animated)
    }

    func setCommandsEnabled(_ enabled: Bool) {
        if !enabled { cancelSpaceRename() }
        list.setCommandsEnabled(enabled)
    }

    /// Replaces the title by an editor over the same frame and typography, text selected.
    @discardableResult
    func beginSpaceRename(commit: @escaping (String) -> Void) -> Bool {
        guard list.commandsEnabled, titleEditor == nil, window != nil else { return false }
        list.cancelRename()
        let editor = NSTextField(string: titleLabel.stringValue)
        editor.font = titleLabel.font
        editor.textColor = OrbitTokens.Color.Text.primary
        editor.isBordered = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.wantsLayer = true
        editor.layer?.cornerRadius = OrbitTokens.Radius.toolbarButtonHover
        editor.layer?.backgroundColor = accent.soft.withAlphaComponent(0.6).resolvedCGColor(for: effectiveAppearance)
        editor.lineBreakMode = .byClipping
        editor.cell?.isScrollable = true
        editor.delegate = self
        editor.setAccessibilityLabel(uiText("Space Name"))
        editor.setAccessibilityIdentifier("space-title-editor")
        titleEditor = editor
        titleCommit = commit
        titleLabel.isHidden = true
        list.addSubview(editor)
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard window?.makeFirstResponder(editor) == true else {
            finishSpaceRename(commit: false)
            return false
        }
        editor.currentEditor()?.selectAll(nil)
        return true
    }

    /// Ends editing without writing.
    func cancelSpaceRename() { finishSpaceRename(commit: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === titleEditor else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): finishSpaceRename(commit: false)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): finishSpaceRename(commit: true)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === titleEditor else { return }
        finishSpaceRename(commit: true)
    }

    /// Commits a trimmed, non-empty, changed name once; marked (IME) text is never committed.
    func finishSpaceRename(commit: Bool) {
        guard let editor = titleEditor else { return }
        if commit, (editor.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        let name = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = titleCommit
        titleEditor = nil
        titleCommit = nil
        editor.delegate = nil
        // End the field editor before removal so no detached editor keeps the keyboard.
        if editor.currentEditor() != nil { window?.makeFirstResponder(nil) }
        editor.removeFromSuperview()
        titleLabel.isHidden = false
        needsLayout = true
        if commit, !name.isEmpty, name != titleLabel.stringValue { action?(name) }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        guard let geometry else { return }
        let width = bounds.width
        list.spaceTitleCenterY = geometry.spaceTitleCenterY
        let documentHeight = max(list.documentHeight, scrollView.contentSize.height)
        if list.frame.size != NSSize(width: width, height: documentHeight) {
            list.frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        }
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        // THEME-R2 D37: x 16 without a Space icon, 44 with one.
        let titleX = iconSelection == .none ? geometry.spaceTitleOriginX : Metrics.titleOriginX
        iconButton.frame = NSRect(x: Metrics.faviconCenterX - 12, y: geometry.spaceTitleCenterY - 12,
                                  width: 24, height: 24)
        titleLabel.frame = NSRect(x: titleX, y: (geometry.spaceTitleCenterY - titleHeight / 2).rounded(),
                                  width: max(0, width - titleX - Metrics.paddingX - Metrics.rowInsetX), height: titleHeight)
        titleEditor?.frame = titleLabel.frame.insetBy(dx: -4, dy: -3)
        if isPrivate { titleLabel.isHidden = true; iconButton.isHidden = true }
    }

    /// Auto-scroll while a drag hovers near the page's top or bottom edge ( C27).
    func autoscrollDuringDrag(at point: NSPoint) {
        let clip = scrollView.contentView
        let visible = clip.documentVisibleRect
        let pointer = list.convert(point, from: self)
        let step = SidebarAutoScroll.step(pointerY: pointer.y, visible: visible, documentHeight: list.frame.height)
        guard step != 0 else { return }
        clip.scroll(to: NSPoint(x: visible.minX, y: visible.minY + step))
        scrollView.reflectScrolledClipView(clip)
    }

    private func titleMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: OrbitShellText.renameSpace, action: #selector(renameSpace(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: uiText("Change Space Icon…"), action: #selector(editIcon(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: uiText("Edit Theme Color…"), action: #selector(editTheme(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let delete = menu.addItem(withTitle: uiText("Delete Space…"), action: #selector(deleteSpace(_:)), keyEquivalent: "")
        delete.target = self
        delete.isEnabled = canDeleteSpace
        return menu
    }

    @objc private func deleteSpace(_ sender: Any?) { if list.commandsEnabled && canDeleteSpace { onDeleteSpace?() } }
    var spaceContextMenu: NSMenu? { titleLabel.menu }

    @objc private func renameSpace(_ sender: Any?) { if list.commandsEnabled { onRenameSpace?() } }
    @objc private func editTheme(_ sender: Any?) { if list.commandsEnabled { onEditTheme?() } }
    @objc private func editIcon(_ sender: Any?) { if list.commandsEnabled { onEditIcon?() } }

    // Test accessors.
    var tabRows: [SidebarTabRow] { list.tabRows }
    var folderRows: [SidebarFolderRow] { list.folderRows }
    var titleFrame: NSRect { titleLabel.frame }
    var separatorFrame: NSRect { list.separator.frame }
    var scrollDocument: NSView { list }
    var newTabRow: SidebarNewTabRow { list.newTabRow }
    var pageScrollView: NSScrollView { scrollView }
}

/// Toolbar row of the sidebar (design §3.1, `OrbitSidebarGeometry.Toolbar`): the window buttons sit
/// at x 20 + n × the system spacing (placed by the shell), the sidebar toggle 27.25 after the third,
/// back/forward/reload anchored right at W − 90.25 / 56.25 / 22, all centred on y 24. Below 224 pt
/// the row turns compact: toggle and reload hide, smaller arrows at W − 76 / 48 and a "•••" overflow
/// at W − 20 (measured + ). In full screen the toggle moves to x 28.6 (C09).
@MainActor
final class SidebarToolbarRow: SidebarFlippedView {
    private(set) var buttons: [NSButton] = []
    private(set) var overflowButton: NSButton?
    var accent = OrbitTokens.ThemeAccent.defaultSpace {
        didSet {
            for button in buttons { applyAccent(to: button) }
            if let overflowButton { applyAccent(to: overflowButton) }
        }
    }

    private func applyAccent(to button: NSButton) {
        let effective = OrbitSpaceThemes.accent(accent, over: [], iconHover: OrbitTokens.Color.State.standaloneButton)
        if let glyph = button as? OrbitGlyphButton { glyph.tint = effective.icon }
        else { button.contentTintColor = effective.icon }
    }
    private var overflowTarget: OrbitMenuButtonTarget?
    private var lastGeometry: OrbitSidebarGeometry?
    private(set) var layoutState: OrbitSidebarGeometry.Toolbar?
    /// Set by the window: the system spacing of its buttons and the full-screen state.
    var trafficLightPitch: CGFloat = OrbitTrafficLights.pitch { didSet { if trafficLightPitch != oldValue { reapply() } } }
    var isFullScreen = false { didSet { if isFullScreen != oldValue { reapply() } } }

    /// Order: sidebar toggle, back, forward, reload.
    func install(_ buttons: [NSButton]) {
        self.buttons = buttons
        for button in buttons { applyAccent(to: button); addSubview(button) }
    }

    /// The compact row's "•••" button; it pops up `menu` below itself.
    func installOverflow(_ button: NSButton, menu: @escaping @MainActor () -> NSMenu?) {
        let target = OrbitMenuButtonTarget(menu: menu)
        button.target = target
        button.action = #selector(OrbitMenuButtonTarget.show(_:))
        overflowTarget = target
        overflowButton = button
        applyAccent(to: button)
        button.isHidden = true
        addSubview(button)
    }

    func apply(_ geometry: OrbitSidebarGeometry) {
        lastGeometry = geometry
        let toolbar = OrbitSidebarGeometry.Toolbar.resolve(width: geometry.width, trafficLightPitch: trafficLightPitch,
                                                         isFullScreen: isFullScreen)
        let compactChanged = layoutState?.isCompact != toolbar.isCompact
        layoutState = toolbar
        let size = OrbitTokens.Metrics.Toolbar.buttonHitSize
        let centers = [toolbar.sidebarToggleCenterX, toolbar.backCenterX, toolbar.forwardCenterX, toolbar.reloadCenterX]
        for (index, (button, center)) in zip(buttons, centers).enumerated() {
            if button.isHidden != (center == nil) { button.isHidden = center == nil }
            guard let center else { continue }
            let width = index == 0 ? size : toolbar.hitWidth
            button.frame = NSRect(x: center - width / 2, y: toolbar.centerY - size / 2, width: width, height: size)
        }
        if let overflowButton {
            overflowButton.isHidden = toolbar.overflowCenterX == nil
            if let center = toolbar.overflowCenterX {
                overflowButton.frame = NSRect(x: center - toolbar.hitWidth / 2, y: toolbar.centerY - size / 2,
                                              width: toolbar.hitWidth, height: size)
            }
        }
        if compactChanged, buttons.count >= 3 {
            (buttons[1] as? OrbitGlyphButton)?.glyph = toolbar.isCompact ? OrbitGlyph.backCompact : OrbitGlyph.back
            (buttons[2] as? OrbitGlyphButton)?.glyph = toolbar.isCompact ? OrbitGlyph.forwardCompact : OrbitGlyph.forward
        }
    }

    private func reapply() {
        if let lastGeometry { apply(lastGeometry) }
    }

    func setCommandsEnabled(_ enabled: Bool) {}
}

/// Address field of the sidebar (design §3.2): y 46, h 36, radius 12, `sidebarItem` at rest and
/// `sidebarItemHovered` on hover (assets [H/M]); 13 pt text inset 12. While the field is edited in
/// place it lifts to `tabCurrent` with the selected-row shadow (: in Orbit the click
/// opens the command bar, which belongs to the Palette lot).
@MainActor
final class SidebarAddressField: SidebarFlippedView {
    private let background = OrbitSurfaceBackgroundView(cornerRadius: OrbitTokens.Radius.addressField)
    /// URL text followed by extension actions, copy link and the site control center.
    let extensions = SidebarExtensionStrip()
    let controls = NSStackView()
    private var accessories: [NSView] = []
    private var accessoryOrder: [ObjectIdentifier: Int] = [:]
    private var hoverAccessories: [NSView] = []
    var holdsAccessoriesVisible = false { didSet { refresh() } }
    private weak var field: NSTextField?
    var accent = OrbitTokens.ThemeAccent.defaultSpace { didSet { if accent != oldValue { refreshAccent() } } }
    var effectiveAccent: OrbitTokens.ThemeAccent {
        OrbitSpaceThemes.accent(accent, over: background.fillColor.map { [$0] } ?? [])
    }
    var isEditing = false { didSet { if isEditing != oldValue { refresh() } } }
    private var isHovering = false { didSet { if isHovering != oldValue { refresh() } } }
    private var hasPage = true
    private var selectionWidth: CGFloat?
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(background, positioned: .below, relativeTo: nil)
        controls.orientation = .horizontal
        controls.distribution = .fill
        controls.alignment = .centerY
        controls.spacing = 0
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OrbitTokens.Metrics.Sidebar.addressTextInsetX),
            // Align the 18 pt site glyph with the center measured in Orbit’s trailing 30 pt cell.
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        refresh()
    }

    /// Places the address text field; it takes the remaining width.
    func installField(_ field: NSView) {
        self.field = field as? NSTextField
        if let address = field as? OrbitLocationField {
            hasPage = !address.stringValue.isEmpty
            address.onAddressChange = { [weak self] hasPage in
                guard let self, self.hasPage != hasPage else { return }
                self.hasPage = hasPage
                self.refresh()
            }
        }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controls.insertArrangedSubview(field, at: 0)
        refreshAccent()
    }

    /// Capture the whole accessory container, including native popup anchors. In the
    /// 28 Oct F119–125 / F185–191, contraction keeps the new contents at the old leading
    /// edge, then moves them right. Expansion installs its complete layout immediately.
    func beginSelectionUpdate() {
        guard selectionWidth == nil else { return }
        layoutSubtreeIfNeeded()
        selectionWidth = accessoryWidth
    }

    func endSelectionUpdate(animated: Bool = true) {
        guard let previous = selectionWidth else { return }
        selectionWidth = nil
        refresh()
        layoutSubtreeIfNeeded()
        let contraction = previous - accessoryWidth
        for accessory in accessories where !accessory.isHidden {
            if animated { AddressStatusMotion.translate(accessory, from: -max(0, contraction)) }
            else { accessory.layer?.removeAnimation(forKey: "address-reflow") }
        }
    }

    private var accessoryWidth: CGFloat {
        accessories.filter { !$0.isHidden }.reduce(0) { $0 + $1.fittingSize.width }
    }

    /// Trailing icons use neutral secondary grey; AppKit retains disabled-state rendering.
    func installAccessory(_ view: NSView, onHover: Bool = false, order: Int = 0) {
        if let button = view as? NSButton, button.image != nil {
            if view.accessibilityIdentifier() != "site-controls" {
                button.image = button.image?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            }
            (button as? SiteControlButton)?.usesURLPillStyle = true
            button.isBordered = false
            // Orbit exposes a 30 pt accessibility target around the 28 pt control.
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: SidebarExtensionStrip.hitSize).isActive = true
        }
        applyAccessoryAccent(view)
        accessoryOrder[ObjectIdentifier(view)] = order
        let index = accessories.firstIndex { (accessoryOrder[ObjectIdentifier($0)] ?? 0) > order } ?? accessories.count
        accessories.insert(view, at: index)
        controls.insertArrangedSubview(view, at: index + (field == nil ? 0 : 1))
        if onHover { hoverAccessories.append(view); refresh() }
    }

    private func applyAccessoryAccent(_ view: NSView) {
        if let button = view as? OrbitGlyphButton {
            button.tint = OrbitTokens.Color.Text.secondary
        } else if let button = view as? NSButton {
            button.contentTintColor = button.image == nil ? effectiveAccent.sidebarSecondaryText : OrbitTokens.Color.Text.secondary
        }
    }

    private func refreshAccent() {
        for accessory in accessories { applyAccessoryAccent(accessory) }
        // Explicit manually supplied accents preserve an installed editor's independent styling.
        guard accent.contrastTheme != nil, let field else { return }
        let effective = effectiveAccent
        if field.textColor != effective.sidebarText { field.textColor = effective.sidebarText }
        if let editor = field.currentEditor() as? NSTextView {
            if editor.textColor != effective.sidebarText { editor.textColor = effective.sidebarText }
            if editor.insertionPointColor != effective.sidebarText { editor.insertionPointColor = effective.sidebarText }
        }
        if let placeholder = field.placeholderAttributedString?.string ?? field.placeholderString,
           field.placeholderAttributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            != effective.sidebarSecondaryText {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: field.font ?? OrbitTokens.Typography.addressField, .foregroundColor: effective.sidebarSecondaryText
            ])
        }
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        background.frame = bounds
        let others = accessories.filter { $0 !== extensions && !$0.isHidden }
        let occupied = others.reduce(CGFloat(0)) { $0 + $1.fittingSize.width }
        let gaps = CGFloat(others.count + 1) * controls.spacing
        extensions.availableWidth = max(0, bounds.width - 20 - 60 - occupied - gaps)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    private func refresh() {
        for view in hoverAccessories {
            let revealed = (isHovering || holdsAccessoriesVisible) && !isEditing
            // Keep native popup anchors in the visible hierarchy after the pointer enters
            // a menu or an extension popup. Editing alone reclaims their layout width.
            view.alphaValue = revealed ? 1 : 0
            view.setAccessibilityHidden(!revealed)
            view.isHidden = isEditing || (view === extensions ? !extensions.isAvailable : !hasPage)
        }
        if isEditing {
            background.fillColor = OrbitTokens.Color.State.tabCurrent
            background.outerShadow = OrbitTokens.Shadow.tabSelected
        } else {
            background.outerShadow = nil
            background.fillColor = isHovering ? OrbitTokens.Color.State.sidebarItemHovered : OrbitTokens.Color.State.sidebarItem
        }
        refreshAccent()
        needsLayout = true
    }
}

@MainActor
class SidebarFlippedView: NSView {
    override var isFlipped: Bool { true }
}


// MARK: Interactive Space motion

extension BrowserSidebarView {
    var swipePreviewCount: Int { (swipePreview == nil ? 0 : 1) + (swipeOutgoing == nil ? 0 : 1) }
    var swipeWidth: CGFloat { pageContainer.bounds.width }
    var swipeContext: (BrowserCatalogSnapshot, SpaceID)? {
        guard let renderedCatalog, let activeSpaceID else { return nil }
        return (renderedCatalog, activeSpaceID)
    }
    var swipeCanInteract: Bool {
        commandsEnabled && !hasFooterPresentation && page.list.renamingNode == nil && !page.isRenamingSpace
            && contextMenuNodes.isEmpty && leavingPage == nil
    }
    func swipeContains(_ windowPoint: NSPoint) -> Bool {
        !isPresentationHidden && contentViewportFrame.contains(convert(windowPoint, from: nil))
    }

    var contentViewportFrame: CGRect {
        CGRect(x: 0, y: geometry.addressFrame.maxY, width: bounds.width,
               height: max(0, geometry.footerFrame.minY - geometry.addressFrame.maxY))
    }
    private func contentFrame(_ frame: CGRect, x: CGFloat = 0) -> CGRect {
        frame.offsetBy(dx: x, dy: -contentViewportFrame.minY)
    }
    private func geometry(favorites: Int, page: SidebarSpacePageView) -> OrbitSidebarGeometry {
        OrbitSidebarGeometry.resolve(.init(width: bounds.width, height: bounds.height,
            favoriteCount: favorites, favoriteMinimumTileWidth: favoriteMinimumTileWidth,
            pinnedRowCount: page.list.displayedLayout.pinnedSlotCount, todayRowCount: page.list.displayedLayout.todaySlotCount,
            spaceCount: renderedCatalog?.spaces.count ?? 1))
    }
    private func frozenFavorites(_ items: [FavoriteTileItem], profile: ProfileID?, attach: Bool = true) -> FavoritesGridView {
        let grid = FavoritesGridView()
        grid.commandsEnabled = false
        grid.animatesChanges = false
        grid.minimumTileWidth = favoriteMinimumTileWidth
        grid.setAccessibilityHidden(true)
        grid.render(items, profileID: profile)
        if attach { pageContainer.addSubview(grid) }
        return grid
    }

    /// Detached views are built and laid out before a horizontal gesture needs them. No
    /// surfaces, favicon requests, native scrolling or selection changes occur here.
    func prepareSpaceSwipeNeighbors(document: BrowserSessionDocument, active: SpaceID,
                                   resolveTheme: (SpaceID) -> OrbitTokens.SpaceTheme) {
        guard let index = document.spaces.firstIndex(where: { $0.id == active }) else { return }
        var prepared: [SpaceID: PreparedSwipePage] = [:]
        for neighbor in [index - 1, index + 1] where document.spaces.indices.contains(neighbor) {
            let space = document.spaces[neighbor]
            let content = SpaceSwipePreview.content(document: document, spaceID: space.id, windowID: organization?.windowID, icon: previewIcon)
            let favorites = SpaceSwipePreview.favorites(document: document, spaceID: space.id, windowID: organization?.windowID, icon: previewIcon)
            let incoming = SidebarSpacePageView()
            incoming.appearance = effectiveAppearance
            incoming.spaceID = space.id
            incoming.iconSelection = resolveSpaceIcon(space.id)
            incoming.accent = OrbitSpaceThemes.accent(for: resolveTheme(space.id))
            incoming.setCommandsEnabled(false)
            incoming.setAccessibilityHidden(true)
            incoming.render(title: space.name, content: content, animated: false)
            let layout = geometry(favorites: favorites?.items.count ?? 0, page: incoming)
            incoming.geometry = layout
            incoming.frame = contentFrame(layout.pageFrame)
            incoming.layoutSubtreeIfNeeded()
            let grid = frozenFavorites(favorites?.items ?? [], profile: favorites?.profileID, attach: false)
            grid.appearance = effectiveAppearance
            grid.frame = contentFrame(layout.favoritesFrame)
            grid.layoutSubtreeIfNeeded()
            let scale = window?.backingScaleFactor ?? 2
            prepared[space.id] = PreparedSwipePage(page: incoming, content: content, favorites: grid,
                pageRaster: SpaceSwipeRaster(view: incoming, scale: scale),
                favoritesRaster: SpaceSwipeRaster(view: grid, scale: scale))
        }
        preparedSwipePages = prepared
    }
    private var liveFavoritesGrid: FavoritesGridView? {
        favoritesContainer.subviews.compactMap { $0 as? FavoritesGridView }.first
    }

    /// Capture outgoing profile paint before the live Favorites owner publishes another Space.
    func prepareSpaceContentPublication(to requested: SpaceID?) {
        guard let requested, let activeSpaceID, requested != activeSpaceID else { return }
        if swipeOffset != nil { _ = spaceSwipe.willRender(active: requested); return }
        // Chrome and Favorites render before the sidebar's model projection. A swipe that
        // arrived before publication already adopted this page; do not leave an ordinary
        // outgoing Favorites grid behind during the rest of that publication.
        guard page.spaceID != requested else { return }
        if leavingPage != nil {
            ordinarySpaceMotion.onChange = nil; ordinarySpaceMotion.onSettle = nil
            ordinarySpaceMotion.set(0)
            leavingPage?.removeFromSuperview(); leavingPage = nil
            ordinaryOutgoingFavorites?.removeFromSuperview(); ordinaryOutgoingFavorites = nil
            ordinaryOffset = nil; ordinarySourceGeometry = nil
        }
        guard ordinaryOutgoingFavorites == nil else { return }
        ordinarySourceGeometry = geometry
        ordinarySharesFavorites = renderedCatalog?.spaces.first { $0.id == requested }?.profileID == organization?.profileID
        guard !ordinarySharesFavorites else { return }
        if let grid = liveFavoritesGrid {
            ordinaryOutgoingFavorites = frozenFavorites(grid.items, profile: grid.dropTarget.profileID)
        }
    }

    /// Both native Favorites and list geometry move inside one clipped viewport.
    private func layoutSpaceSwipePages() {
        guard let offset = swipeOffset else { return }
        if let creation = newSpaceSwipePage {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let sourceGeometry = swipeSourceGeometry ?? geometry
            positionSpaceSwipeView(page, frame: contentFrame(sourceGeometry.pageFrame), x: offset)
            positionSpaceSwipeView(favoritesContainer, frame: contentFrame(sourceGeometry.favoritesFrame), x: offset)
            creation.frame = pageContainer.bounds.offsetBy(dx: offset + swipeWidth, dy: 0)
            CATransaction.commit()
            return
        }
        let source = swipeOutgoing ?? page
        let destination = swipeOutgoing == nil ? swipePreview : page
        let sourceGeometry = swipeSourceGeometry ?? geometry
        let destinationGeometry = swipeDestinationGeometry ?? geometry
        let destinationX = offset + (offset > 0 ? -1 : 1) * swipeWidth
        swipeOutgoingFavorites?.isHidden = swipeSharesFavorites
        swipePreviewFavorites?.isHidden = swipeSharesFavorites
        CATransaction.begin(); CATransaction.setDisableActions(true)
        positionSpaceSwipeView(source, frame: contentFrame(sourceGeometry.pageFrame), x: offset)
        source.geometry = sourceGeometry
        if let destination {
            positionSpaceSwipeView(destination, frame: contentFrame(destinationGeometry.pageFrame), x: destinationX)
        }
        destination?.geometry = destinationGeometry
        if swipeSharesFavorites {
            positionSpaceSwipeView(favoritesContainer, frame: contentFrame(sourceGeometry.favoritesFrame), x: 0)
            swipeOutgoingFavorites?.isHidden = true
            swipePreviewFavorites?.isHidden = true
        } else if swipeOutgoing != nil {
            if let outgoing = swipeOutgoingFavorites {
                positionSpaceSwipeView(outgoing, frame: contentFrame(sourceGeometry.favoritesFrame), x: offset)
            }
            positionSpaceSwipeView(favoritesContainer, frame: contentFrame(destinationGeometry.favoritesFrame), x: destinationX)
        } else {
            positionSpaceSwipeView(favoritesContainer, frame: contentFrame(sourceGeometry.favoritesFrame), x: offset)
            if let preview = swipePreviewFavorites {
                positionSpaceSwipeView(preview, frame: contentFrame(destinationGeometry.favoritesFrame), x: destinationX)
            }
        }
        CATransaction.commit()
    }

    /// Preserve AppKit's native scroll, paint and descendant image-layer coordinates.
    private func positionSpaceSwipeView(_ view: NSView, frame: CGRect, x: CGFloat) {
        let positioned = frame.offsetBy(dx: x, dy: 0)
        if view.frame != positioned { view.frame = positioned }
    }

    private func retainSpaceSwipePreview() {
        guard let page = swipePreview, let id = page.spaceID, id != activeSpaceID,
              let content = swipePreviewContent, let favorites = swipePreviewFavorites else { return }
        preparedSwipePages[id] = PreparedSwipePage(page: page, content: content, favorites: favorites,
            pageRaster: swipePreviewRaster, favoritesRaster: swipeFavoritesRaster)
    }

    private func layoutOrdinarySpacePages() {
        guard let offset = ordinaryOffset, let leavingPage else { return }
        let sourceGeometry = ordinarySourceGeometry ?? geometry
        let targetGeometry = geometry(favorites: favoriteCount, page: page)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        leavingPage.frame = contentFrame(sourceGeometry.pageFrame, x: offset)
        leavingPage.geometry = sourceGeometry
        ordinaryOutgoingFavorites?.frame = contentFrame(sourceGeometry.favoritesFrame, x: offset)
        let incomingX = offset + ordinaryDirection * bounds.width
        page.frame = contentFrame(targetGeometry.pageFrame, x: incomingX)
        page.geometry = targetGeometry
        favoritesContainer.frame = contentFrame(targetGeometry.favoritesFrame, x: ordinarySharesFavorites ? 0 : incomingX)
        CATransaction.commit()
    }

    func showSpaceSwipe(offset: CGFloat, space: BrowserSpace?, content: SidebarListContent?,
                        destinationAccent: OrbitTokens.ThemeAccent? = nil, favorites: SpaceSwipeFavoritesPreview? = nil) {
        newSpaceSwipePage?.closePickers()
        newSpaceSwipePage?.removeFromSuperview(); newSpaceSwipePage = nil
        if swipeSourceGeometry == nil { swipeSourceGeometry = geometry }
        if swipeOutgoing == nil {
            swipeSharesFavorites = space != nil && space?.profileID == organization?.profileID
        }
        swipeOffset = offset
        if swipeOutgoing != nil {
            layoutSpaceSwipePages()
            return
        }
        page.list.cancelRename()
        if let space {
            if swipePreview?.spaceID != space.id {
                retainSpaceSwipePreview()
                swipePreview?.removeFromSuperview()
                let prepared = preparedSwipePages.removeValue(forKey: space.id)
                let incoming = prepared?.page ?? SidebarSpacePageView()
                incoming.spaceID = space.id
                let icon = resolveSpaceIcon(space.id)
                let iconChanged = incoming.iconSelection != icon
                if iconChanged { prepared?.pageRaster?.restore() }
                incoming.iconSelection = icon
                let nextAccent = destinationAccent ?? accent
                if incoming.accent != nextAccent { incoming.accent = nextAccent }
                if prepared == nil {
                    incoming.geometry = geometry
                    incoming.frame = pageContainer.bounds
                }
                incoming.setCommandsEnabled(false)
                incoming.setAccessibilityHidden(true)
                pageContainer.addSubview(incoming)
                swipePreview = incoming
                swipePreviewContent = prepared?.content
                swipePreviewRaster = iconChanged ? nil : prepared?.pageRaster
                swipeFavoritesRaster = prepared?.favoritesRaster
                swipePreviewFavorites?.removeFromSuperview()
                swipePreviewFavorites = prepared?.favorites
                if let grid = prepared?.favorites { pageContainer.addSubview(grid) }
            }
            if swipePreviewFavorites?.items != favorites?.items || swipePreviewFavorites == nil
                || swipePreviewFavorites?.dropTarget.profileID != favorites?.profileID {
                swipeFavoritesRaster?.restore(); swipeFavoritesRaster = nil
                swipePreviewFavorites?.removeFromSuperview()
                swipePreviewFavorites = frozenFavorites(favorites?.items ?? [], profile: favorites?.profileID)
            }
            if swipePreviewContent != content || swipePreviewContent == nil {
                swipePreviewRaster?.restore(); swipePreviewRaster = nil
                swipePreview?.render(title: space.name, content: content ?? .empty, animated: false)
                swipePreviewContent = content
            }
            if let preview = swipePreview {
                let layout = geometry(favorites: favorites?.items.count ?? 0, page: preview)
                if let raster = swipePreviewRaster, raster.size != layout.pageFrame.size {
                    swipePreviewRaster?.restore(); swipePreviewRaster = nil
                }
                if let raster = swipeFavoritesRaster, raster.size != layout.favoritesFrame.size {
                    swipeFavoritesRaster?.restore(); swipeFavoritesRaster = nil
                }
                swipeDestinationGeometry = layout
            }
        } else {
            retainSpaceSwipePreview()
            swipePreview?.removeFromSuperview()
            swipePreview = nil
            swipePreviewFavorites?.removeFromSuperview(); swipePreviewFavorites = nil
            swipePreviewRaster = nil; swipeFavoritesRaster = nil
        }
        layoutSpaceSwipePages()
    }

    func showNewSpaceSwipe(offset: CGFloat) {
        if swipeSourceGeometry == nil { swipeSourceGeometry = geometry }
        swipeOffset = offset
        swipePreview?.removeFromSuperview(); swipePreview = nil; swipePreviewContent = nil
        swipePreviewFavorites?.removeFromSuperview(); swipePreviewFavorites = nil
        if newSpaceSwipePage == nil {
            let creation = SidebarNewSpacePageView()
            configureNewSpacePage?(creation)
            pageContainer.addSubview(creation)
            newSpaceSwipePage = creation
        }
        layoutSpaceSwipePages()
    }

    /// Source and destination keep their presented frames when session selection publishes mid-spring.
    func adoptSpaceSwipeDestination(_ id: SpaceID) {
        guard swipeOutgoing == nil, let incoming = swipePreview, incoming.spaceID == id else { return }
        if !swipeSharesFavorites, abs(swipeOffset ?? 0) < swipeWidth, let grid = liveFavoritesGrid {
            swipeOutgoingFavorites = frozenFavorites(grid.items, profile: grid.dropTarget.profileID)
        }
        swipePreviewFavorites?.removeFromSuperview(); swipePreviewFavorites = nil
        swipeFavoritesRaster = nil
        swipeOutgoing = page
        swipeOutgoing?.setCommandsEnabled(false)
        swipeOutgoing?.setAccessibilityHidden(true)
        page = incoming
        swipePreviewRaster?.restore(); swipePreviewRaster = nil
        incoming.appearance = nil
        swipePreview = nil
        swipePreviewContent = nil
        configure(incoming)
        incoming.setCommandsEnabled(commandsEnabled)
        incoming.setAccessibilityHidden(false)
        pageContainer.scrollReceiver = incoming.pageScrollView
        layoutSpaceSwipePages()
    }

    /// Rebase coordinates to the newly selected Space without removing either presented list.
    func rebaseSpaceSwipeForRetake() -> CGFloat? {
        guard let outgoing = swipeOutgoing else { return nil }
        let position = page.frame.minX
        swipePreview = outgoing
        swipePreviewContent = outgoing.list.content
        swipeOutgoing = nil
        swipePreviewFavorites = swipeOutgoingFavorites
        swipeOutgoingFavorites = nil
        swap(&swipeSourceGeometry, &swipeDestinationGeometry)
        swipeOffset = position
        return position
    }

    func finishSpaceSwipe(committed: SpaceID?) {
        newSpaceSwipePage?.closePickers()
        newSpaceSwipePage?.removeFromSuperview(); newSpaceSwipePage = nil
        if let committed { adoptSpaceSwipeDestination(committed) }
        retainSpaceSwipePreview()
        swipeOutgoing?.removeFromSuperview()
        swipeOutgoing = nil
        swipePreview?.removeFromSuperview()
        swipePreview = nil
        swipePreviewContent = nil
        swipePreviewFavorites?.removeFromSuperview(); swipePreviewFavorites = nil
        swipePreviewRaster = nil; swipeFavoritesRaster = nil
        swipeOutgoingFavorites?.removeFromSuperview(); swipeOutgoingFavorites = nil
        swipeSourceGeometry = nil; swipeDestinationGeometry = nil
        swipeOffset = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        page.frame = contentFrame(geometry.pageFrame)
        favoritesContainer.frame = contentFrame(geometry.favoritesFrame)
        pageContainer.scrollReceiver = page.pageScrollView
        page.layer?.setAffineTransform(.identity)
        favoritesContainer.layer?.setAffineTransform(.identity)
        CATransaction.commit()
    }
}

/// The Space title; a double click starts the in-place rename (hypothesis: Orbit header editing).
@MainActor
final class SidebarSpaceTitleLabel: NSTextField {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}
