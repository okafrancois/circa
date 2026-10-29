import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// One browser window, independent of the web engine: it places `Surface.hostView` views and
/// reacts to engine events through `BrowserEngineSurfaceDelegate`.
/// This file keeps stored state, lifetime, the session projection and every `@objc` entry
/// point (Swift forbids `@objc` members in extensions of generic classes). Feature behaviour
/// lives in `BrowserWindowController+<Feature>.swift` extensions in the feature folders; see
/// `docs/native-port/module-map.md`.
@MainActor
final class BrowserWindowController<Engine: BrowserEngine>: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    typealias Surface = Engine.Surface

    let id: UUID
    let engine: Engine
    let historyObserver: BrowserHistoryEngineObserver<Surface>
    private let onClose: () -> Void
    private let onActivate: () -> Void
    private(set) var session: BrowserWindowSession<Surface>!
    var tabSuspension: BrowserTabSuspensionController<Engine>!

    // MARK: Address and navigation controls
    let addressField = OrbitLocationField()
    let backButton = OrbitGlyphButton(glyph: nil, label: OrbitShellText.back)
    let forwardButton = OrbitGlyphButton(glyph: nil, label: OrbitShellText.forward)
    let reloadButton = OrbitGlyphButton(glyph: nil, label: OrbitShellText.reload)
    var addressResolver = AddressResolver()
    let translationPages: BrowserTranslationPages
    lazy var translation = BrowserTranslationController(owner: self)
    lazy var capture = BrowserCaptureController(owner: self)
    lazy var pageSaver = BrowserPageSaveController(owner: self)
    var settingsPreferences: BrowserWindowSettings?
    /// The open theme editor of this window, previewing its draft on the window.
    var themeEditor: OrbitThemeEditorController?
    let themeUndoManager = OrbitThemeUndoManager()
    var themeEditors: OrbitThemeEditorRegistry? {
        didSet { themeUndoManager.registry = themeEditors }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { themeUndoManager }

    // MARK: Window shell (theme, frame, sidebar presentation)
    let windowShell = OrbitWindowShell()

    // MARK: Sidebar
    let sidebar = BrowserSidebarView()
    lazy var extensionControls = BrowserExtensionsController(owner: self)
    lazy var passwordPrompt = BrowserPasswordPromptPresenter(owner: self)
    let sidebarIcons = FavoriteIconPipeline<Surface>()
    var sidebarActivityObserver: BrowserHookRegistration?
    let folderPreview = FolderPreviewController<Surface>()
    var favorites: BrowserFavoritesController<Engine>!
    var sidebarWidth: NSLayoutConstraint!
    var sidebarLeading: NSLayoutConstraint!
    var isSidebarVisible = true

    // MARK: Content card
    let contentCard = BrowserContentCardView()
    let split = BrowserSplitPresentation()
    var displayedOccurrenceID: TabOccurrenceID?
    var displayedSpaceID: SpaceID?

    // MARK: Find
    let findSession: BrowserFindSession<Surface>
    var findBarStorage: BrowserFindBarView?
    var findBar: BrowserFindBarView {
        if let findBarStorage { return findBarStorage }
        let view = BrowserFindBarView()
        findBarStorage = view
        if let root = window?.contentView { installFindBar(in: root) }
        return view
    }
    weak var findOwner: Surface?
    var displayedFindDocumentGeneration: UInt64 = 0
    weak var focusBeforeFind: NSResponder?
    var shouldReturnFindFocus = false

    // MARK: Page zoom
    let zoomButton = NSButton()
    weak var zoomOwner: Surface?
    var zoomDocumentGeneration: UInt64 = 0

    var siteControls: BrowserSiteControls<Engine>!
    let developerToolbar = BrowserDeveloperToolbar()
    var developerToolbarProfile: ProfileID?
    weak var developerTintSurface: Surface?
    lazy var sharing = BrowserSharingController(owner: self)

    let archive = BrowserArchivePresentation()
    let library = BrowserLibraryPresentation()
    var boostsRuntime: BrowserBoostsRuntime?
    var boostEditor: BrowserBoostEditorController?
    var boostTask: Task<Void, Never>?
    var boostsIntroduced = false
    var bookmarkTransfer: BrowserBookmarkTransferController<Engine>?

    // MARK: Downloads
    let downloads: BrowserDownloadsController
    lazy var downloadsPane = BrowserDownloadsPane()
    var downloadsProfileID: ProfileID?

    // MARK: Tab switcher
    var tabSwitcher: BrowserTabSwitcher<Engine>!
    var palette: BrowserPaletteController<Engine>!

    // MARK: Peek
    let peek = BrowserPeekController<Surface>()

    // MARK: Page surfaces (CH-ESSENTIALS)
    /// Open page context menu and element fullscreen; see `…+PageInteraction.swift`.
    let pageInteraction = BrowserPageInteractionState()
    /// Native window fullscreen for element fullscreen. The hidden smoke replaces it (a window it
    /// never shows must not enter fullscreen).
    var toggleNativeFullScreen: (NSWindow) -> Void = { $0.toggleFullScreen(nil) }

    // MARK: Engine events
    /// Feature observers and new-target routes; see `BrowserSurfaceEventHooks`.
    let engineEventHooks = BrowserSurfaceEventHooks<Surface>()

    // MARK: New targets created by the engine
    struct NativeCreation {
        let surface: Surface
        let adoption: Task<TabOccurrenceID?, Never>
        let previousContext: Task<BrowserContext?, Never>
        let sourceOccurrenceID: TabOccurrenceID
        let foreground: Bool
        let inputToken: UUID
        /// Set by the first main-frame commit, the contract's "displayable" signal: later downloads
        /// belong to the target itself, and the target is promoted then (never on a response).
        var hasCommitted = false
    }
    var onMoveSpaceToProfile: ((SpaceID, ProfileID, ProfileID) async throws -> Void)?
    var onCreateSpaceProfile: ((String) async throws -> ProfileID)?
    var onDeleteSpace: ((SpaceID, ProfileID) async throws -> Void)?
    var nativeCreations: [ObjectIdentifier: NativeCreation] = [:]
    var pendingNativeClosures: Set<ObjectIdentifier> = []
    var explicitInputToken = UUID()
    struct NativePromotion {
        let id = UUID()
        let surface: Surface
        let intent: BrowserSelectionIntent
    }
    var nativePromotion: NativePromotion?
    var promotionsAwaitingAdoption = 0

    var provisionalCloses: Set<ObjectIdentifier> = []
    var provisionalDownloads: [ObjectIdentifier: [BrowserDownloadKey]] = [:]

    // MARK: Engine windows
    /// Model windows announced to the engine with this NSWindow (`shellWindowDidOpen`).
    var engineWindowIDs: Set<WindowID> = []
    /// The latest sidebar order published to the engine (`publishTabOrder`).
    var publishedTabOrder: (windowID: WindowID?, surfaces: [ObjectIdentifier]) = (nil, [])

    // MARK: Window coordination
    private let onStateChange: () -> Void
    private let onCatalogChange: (BrowserCatalogSnapshot) -> Void
    private let onInput: ((@escaping @MainActor (BrowserWindowController) -> Void) -> Void)?
    private var publishedCatalog: BrowserCatalogSnapshot?
    private let onRetire: (BrowserWindowSession<Surface>) -> Void
    var windowedFrame: NSRect?
    let savesSessionLocally: Bool
    let isPrivateWindow: Bool
    private(set) var isPreparingForTermination = false
    private var isDispatchingAcceptedCommand = false
    var acceptsCommands: Bool { !isPreparingForTermination || isDispatchingAcceptedCommand }

    init(
        id: UUID,
        store: BrowserStore,
        spaceID: SpaceID,
        engine: Engine,
        restoringWindowID: WindowID? = nil,
        opensInitialTab: Bool = true,
        savesSessionLocally: Bool = false,
        isPrivateWindow: Bool = false,
        downloads: BrowserDownloadsController = BrowserDownloadsController(),
        history: BrowserHistoryRecorder = BrowserHistoryRecorder(),
        translationPages: BrowserTranslationPages = BrowserTranslationPages(),
        rescue: BrowserSurfaceContainer<Engine.Surface>? = nil,
        onInput: ((@escaping @MainActor (BrowserWindowController) -> Void) -> Void)? = nil,
        onCatalogChange: @escaping (BrowserCatalogSnapshot) -> Void = { _ in },
        onStateChange: @escaping () -> Void = {},
        onRetire: @escaping (BrowserWindowSession<Surface>) -> Void = { _ in },
        onClose: @escaping () -> Void,
        onActivate: @escaping () -> Void
    ) {
        BrowserPerformance.mark(.windowPropertiesReady)
        self.translationPages = translationPages
        self.id = id
        self.engine = engine
        self.onClose = onClose
        self.onActivate = onActivate
        self.onStateChange = onStateChange
        self.onCatalogChange = onCatalogChange
        self.onInput = onInput
        self.onRetire = onRetire
        self.savesSessionLocally = savesSessionLocally
        self.isPrivateWindow = isPrivateWindow
        self.downloads = downloads
        self.library.history.recorder = history
        self.historyObserver = BrowserHistoryEngineObserver(recorder: history, resolveProfile: engine.profile(for:))
        findSession = BrowserFindSession<Surface>()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = isPrivateWindow ? uiText("Private") : uiText("Orbit")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 600, height: 400)
        window.center()
        BrowserPerformance.mark(.nativeWindowReady)
        super.init(window: window)
        siteControls = BrowserSiteControls<Engine>(owner: self)
        favorites = BrowserFavoritesController<Engine>(owner: self)
        palette = BrowserPaletteController(owner: self)
        window.delegate = self
        configureContent()
        sidebar.isPrivate = isPrivateWindow
        if isPrivateWindow {
            contentCard.emptyStateTitle = uiText("Private")
            contentCard.emptyStateDetail = uiText("Your browsing history is not saved.")
        }
        historyObserver.install(in: engineEventHooks)
        // The session can outlive this controller (retirement tracking, queued commands). A call
        // after the controller is gone fails explicitly (`surfaceUnavailable`) instead of relying
        // on a lifetime convention.
        let makeSurface: (ProfileID, URL) -> Surface? = { [weak self] profileID, _ in
            guard let self else { return nil }
            let surface = engine.makeSurface(profileID: profileID, delegate: self)
            bindSurface(surface)
            return surface
        }
        // Ownership and placement are recorded before the first load starts.
        let startSurface: (Surface, URL) -> Void = { surface, url in
            if url.absoluteString != "about:blank" {
                BrowserNavigationPolicy.authorizeLocalDocument(url, for: surface)
                if engine.kind == .chromium, BrowserNavigationPolicy.isChromiumSettingsURL(url) {
                    BrowserNavigationPolicy.authorizeChromiumSettings(for: surface)
                }
                surface.navigate(to: url)
            }
        }
        if let restoringWindowID {
            session = BrowserWindowSession(store: store, restoringWindowID: restoringWindowID,
                                           makeSurface: makeSurface, startSurface: startSurface)
        } else {
            session = BrowserWindowSession(store: store, spaceID: spaceID,
                                           makeSurface: makeSurface, startSurface: startSurface)
        }
        session.surfaceLoadingPolicy = .visibleOnly
        tabSuspension = BrowserTabSuspensionController(owner: self, store: store)
        session.rescueContainer = rescue
        tabSwitcher = BrowserTabSwitcher(owner: self)
        session.onSurfaceMembershipChange = { [weak self] surface, membership in
            self?.surfaceMembershipDidChange(surface, membership)
        }
        session.onChange = { [weak self] in
            self?.bookmarkTransfer?.contextDidChange()
            self?.renderSession()
            self?.onStateChange()
        }
        session.onError = { _ in NSSound.beep() }
        session.observeOrganizationChanges()
        findSession.onChange = { [weak self] in self?.renderFind() }
        findSession.onFocusReturn = { [weak self] surface in self?.returnFocusAfterFind(on: surface) }
        downloads.observeChanges(id) { [weak self] delta in
            self?.renderDownloads(delta: delta)
            if delta.historyChanged || delta.changed.contains(where: { $0.state == .complete }) {
                self?.renderLibraryMedia()
            }
        }
        if restoringWindowID == nil && opensInitialTab { openTab() }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    // MARK: Window lifetime

    func windowDidMove(_ notification: Notification) { windowPlacementDidChange() }
    func windowDidResize(_ notification: Notification) { windowPlacementDidChange() }
    func windowWillEnterFullScreen(_ notification: Notification) { windowedFrame = window?.frame }

    func windowPlacementDidChange() {
        guard session != nil, let window, !window.styleMask.contains(.fullScreen), !windowShell.isFullScreen else { return }
        windowedFrame = window.frame
        onStateChange()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onActivate()
        passwordPrompt.render()
        // Detached swipe pages need not compete with the first window transaction.
        Task { [weak self] in
            guard let self, !session.isClosed else { return }
            sidebar.spaceSwipe.validate(catalog: session.catalog, active: session.snapshot?.activeSpaceID)
        }
    }

    func windowDidResignKey(_ notification: Notification) { passwordPrompt.close() }

    func windowWillClose(_ notification: Notification) {
        translation.close()
        passwordPrompt.close()
        developerTintSurface?.setPageTintObservationEnabled(false)
        developerTintSurface = nil
        boostTask?.cancel()
        boostEditor?.close()
        library.boostsTask?.cancel()
        capture.cancel()
        tabSuspension.close()
        extensionControls.close()
        bookmarkTransfer?.cancel()
        library.isPresented = false
        library.drawer.finishClosing()
        folderPreview.shutdown()
        sidebar.spaceSwipe.detach()
        library.swipe.detach()
        themeEditor?.close(animated: false)
        library.history.stop()
        archive.task?.cancel()
        tabSwitcher.shutdown()
        favorites.shutdown()
        sidebarActivityObserver?.cancel()
        sidebarActivityObserver = nil
        sidebarIcons.clear()
        downloads.sourceWindowClosed(session.snapshot?.id)
        siteControls.cancelPermission()
        downloads.stopObserving(id)
        findSession.shutdown()
        session.close()
        releaseEngineWindows()
        onRetire(session)
        onClose()
    }

    /// Termination after the session was saved: releases every live document of this window
    /// without touching the model, so the saved session stays exactly as written.
    func retireForTermination() {
        translation.close()
        boostTask?.cancel(); boostEditor?.close(); library.boostsTask?.cancel()
        library.isPresented = false
        library.drawer.finishClosing()
        sidebar.spaceSwipe.detach()
        library.swipe.detach()
        freezeCommandsForTermination()
        downloads.stopObserving(id)
        findSession.shutdown()
        session.retireForApplicationTermination()
    }

    func freezeCommandsForTermination() {
        passwordPrompt.close()
        extensionControls.close()
        bookmarkTransfer?.cancel()
        library.revokeSelections()
        siteControls.cancelPermission()
        isPreparingForTermination = true
        window?.ignoresMouseEvents = true
        sidebar.setCommandsEnabled(false)
    }

    /// Only the application router uses this for commands accepted before termination began.
    func performAcceptedCommand(_ action: () -> Void) {
        let previous = isDispatchingAcceptedCommand
        isDispatchingAcceptedCommand = true
        defer { isDispatchingAcceptedCommand = previous }
        action()
    }

    func prepareForTermination() {
        freezeCommandsForTermination()
        for surface in session.ownedSurfaces {
            surface.stopLoading()
            if let url = surface.currentURL {
                session.updateDestination(for: surface, to: url)
            }
        }
    }

    func cancelTerminationPreparation() {
        isPreparingForTermination = false
        window?.ignoresMouseEvents = false
        sidebar.setCommandsEnabled(true)
        for surface in session.ownedSurfaces {
            surface.cancelStoppedNavigationTracking()
            surfaceDidChange(surface)
        }
    }

    // MARK: Input routing

    func recordExplicitInput() {
        explicitInputToken = UUID()
        nativePromotion?.intent.revoke()
    }

    func submitInput(_ action: @escaping @MainActor (BrowserWindowController) -> Void) {
        guard acceptsCommands else { return }
        recordExplicitInput()
        if let onInput { onInput(action) }
        else { action(self) }
    }

    // MARK: Surface ownership

    func owns(_ surface: Surface) -> Bool {
        !session.isClosed && session.ownedSurfaces.contains { $0 === surface }
    }

    /// Makes this window the receiver of a surface's engine events and observations, in the same
    /// turn as the surface's creation for, or acceptance into, this window.
    func bindSurface(_ surface: Surface) {
        let key = ObjectIdentifier(surface)
        surface.delegate = self
        surface.onChange = { [weak self, weak surface] in
            if let surface { self?.surfaceDidChange(surface) }
        }
        surface.onDispose = { [weak self, weak surface] in
            self?.nativeCreations.removeValue(forKey: key)
            self?.pendingNativeClosures.remove(key)
            if let surface {
                self?.findSession.retire(surface)
                self?.pageSurfaceDidLeave(surface)
            }
        }
    }

    func surfaceDidChange(_ surface: Surface) {
        guard !isPreparingForTermination, owns(surface) else { return }
        if let url = surface.currentURL {
            session.updateDestination(for: surface, to: url)
        }
        session.updatePageTitle(for: surface, to: surface.navigationState.title)
        refreshNavigation(for: surface)
        engineEventHooks.emit(.stateChanged, for: surface)
        palette.renderContext()
        passwordPrompt.render()
        translation.render()
    }

    // MARK: Session projection

    /// The single projection of session state onto the window. Each feature contributes one
    /// render call; feature logic stays in its extension.
    func renderSession() {
        SpaceSwipeTrace.interval("RenderSession") { renderSessionProjection() }
    }

    private func renderSessionProjection() {
        BrowserPerformance.count(.windowProjections, window: id)
        tabSuspension?.selectionDidChange()
        if let catalog = session.catalog, catalog != publishedCatalog {
            publishedCatalog = catalog
            onCatalogChange(catalog)
        }
        publishTabOrder()
        SpaceSwipeTrace.interval("RenderChrome") { renderChrome() }
        let selected = session.selectedSurface
        findSession.select(pageCommandSurface())
        renderFind()
        refreshPageZoom()
        renderDownloads()
        renderArchive()
        if let boostEditor, boostEditor.session.store.profileID != session.activeProfileID
            || (boostEditor.pageHost !== selected?.hostView && boostEditor.pageHost !== peek.presentedSurface?.hostView) {
            boostEditor.close(); self.boostEditor = nil
        }
        renderLibrary()
        let pillSelectionChanged = displayedSpaceID != nil && displayedSpaceID != session.snapshot?.activeSpaceID
        if pillSelectionChanged { sidebar.addressContainer.beginSelectionUpdate() }
        siteControls.render()
        renderDeveloperToolbar()
        extensionControls.render()
        SpaceSwipeTrace.interval("RenderFavorites") { favorites.render() }
        let selectionChanged = displayedOccurrenceID != session.snapshot?.selectedOccurrenceID
            || displayedSpaceID != session.snapshot?.activeSpaceID
        let preserveAddressDraft = nativePromotion?.surface === selected
            && nativePromotion?.intent.isRevoked == true && addressField.currentEditor() != nil
            && window?.firstResponder === addressField.currentEditor()
        if selectionChanged {
            capture.cancel()
            let previousSpaceID = displayedSpaceID
            displayedOccurrenceID = session.snapshot?.selectedOccurrenceID
            displayedSpaceID = session.snapshot?.activeSpaceID
            if !preserveAddressDraft {
                let url = selected?.navigationState.url ?? session.organization?.selectedTab?.url
                addressField.setAddress(url?.absoluteString ?? "", from: previousSpaceID,
                                        to: displayedSpaceID, spaces: session.catalog?.spaces ?? [])
            }
        }
        if selected == nil {
            contentCard.emptyStateTitle = isPrivateWindow ? uiText("Private") : session.catalog?.spaces.first {
                $0.id == session.snapshot?.activeSpaceID
            }?.name ?? OrbitShellText.emptySpaceTitle
        }
        let outgoingCapture = SpaceSwipeTrace.interval("RenderOutgoingCaptureRequest") { tabSwitcher.prepareForPresentation(selected) }
        if let selected { contentCard.prepareToReparent(selected.hostView) }
        SpaceSwipeTrace.interval("RenderSplitReparent") { renderSplit(retainingPreviousUntil: outgoingCapture) }
        peek.revealPromotionIfPlaced(in: contentCard)
        if let selected {
            refreshNavigation(for: selected)
        } else {
            if window?.firstResponder !== addressField.currentEditor() {
                addressField.refreshAddress(session.organization?.selectedTab?.url.absoluteString ?? "", in: session.snapshot?.activeSpaceID)
            }
            backButton.isEnabled = false
            forwardButton.isEnabled = false
            reloadButton.isEnabled = false
            rebuildTabStrip()
        }
        if pillSelectionChanged { sidebar.addressContainer.endSelectionUpdate() }
        if selectionChanged, !library.isPresented, !palette.isPresented, !preserveAddressDraft, window?.isKeyWindow == true { focusSelectedDocument() }
        renderPeek()
        tabSwitcher.renderSession()
        palette.renderContext()
        settingsPreferences?.renderSession(in: self)
        passwordPrompt.render()
        translation.render()
    }

    // MARK: Objective-C entry points (forwarders only)

    func controlTextDidBeginEditing(_ notification: Notification) { recordAddressFieldInput(notification) }
    func controlTextDidChange(_ notification: Notification) { recordAddressFieldInput(notification) }
    func controlTextDidEndEditing(_ notification: Notification) { addressEditingDidEnd(notification) }

    @objc func goBack(_ sender: Any?) { submitInput { $0.navigateBack() } }
    @objc func goForward(_ sender: Any?) { submitInput { $0.navigateForward() } }
    @objc func reloadPage(_ sender: Any?) { submitInput { $0.reload() } }
    @objc func toggleSidebarAction(_ sender: Any?) { submitInput { $0.toggleSidebar() } }
    @objc func navigateToEnteredAddress(_ sender: Any?) { submitEnteredAddress() }
    @objc func resetPageZoom(_ sender: Any?) { resetPageZoomFromControl() }
    @objc func copyAddressFromPill(_ sender: Any?) {
        guard acceptsCommands, let url = session.selectedSurface?.currentURL else { return }
        guard BrowserLinkPasteboard.write(url) else { return }
        (sender as? PillCopyLinkButton)?.confirmCopied()
    }

    // MARK: Test and diagnostics accessors

    var displayedAddress: String { addressField.currentEditor()?.string ?? addressField.stringValue }
    var displayedTabTitles: [String] { sidebar.tabTitles }
    var displayedSpaceTitles: [String] { sidebar.spaceTitles }
    var addressControl: NSTextField { addressField }
    var hasPendingNativePromotion: Bool { nativePromotion != nil || promotionsAwaitingAdoption > 0 }
    var isSidebarShown: Bool { isSidebarVisible }
    var displayedEmptyTitle: String? { contentCard.displayedEmptyTitle }
    var displayedZoom: Double? { session.selectedSurface?.pageZoom }
    var zoomControl: NSButton { zoomButton }
}
