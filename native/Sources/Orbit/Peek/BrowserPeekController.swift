import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// One window's Peek: the owner (`BrowserSurfaceContainer`) and engine delegate of the previewed
/// surface, and its overlay. Window-specific decisions (routing, attribution, promotion) are made
/// by `BrowserWindowController+Peek.swift` through the hooks below; this object never reaches
/// into the window session.
/// At most one Peek is presented per window (): presenting a new
/// one disposes the previous one. A dismissed surface stays alive, inert, until the overlay's
/// exit animation ends, then it is disposed exactly once by the container.
@MainActor
final class BrowserPeekController<Surface: BrowserEngineSurface>: BrowserEngineSurfaceDelegate {
    struct Presentation {
        let id = UUID()
        let surface: Surface
        /// The tab whose link opened the Peek; downloads and popups are attributed to it.
        weak var source: Surface?
        let sourceOccurrenceID: TabOccurrenceID?
        let trigger: BrowserPeekTrigger
        /// A main-frame document committed (the contract's displayable signal, CONTRACT-R2).
        var hasRendered = false
    }

    /// Which page last held keyboard focus while a Peek is presented; page commands follow it.
    enum PageFocus: Equatable {
        case peek
        case tab
    }

    struct DismissedPeek: Equatable {
        let url: URL
        let sourceOccurrenceID: TabOccurrenceID?
        var closedAt = Date()
    }

    private var containerStorage: BrowserSurfaceContainer<Surface>?
    /// The owner of every Peek surface of this window, created on first use on the main actor.
    var container: BrowserSurfaceContainer<Surface> {
        if let containerStorage { return containerStorage }
        let container = BrowserSurfaceContainer<Surface>()
        containerStorage = container
        return container
    }
    private(set) lazy var overlay = BrowserPeekOverlayView()
    var clock: () -> Date = Date.init
    var settings = BrowserPeekSettings()
    private(set) var presentation: Presentation?
    /// The last Peek the user closed, reopened by ⇧⌘T while its source tab stays selected
    /// (official notes O23: ⇧⌘T reopens a closed Peek).
    private(set) var lastDismissed: DismissedPeek?
    /// Set while the window forwards a Peek document's new target to its own tab adoption.
    var isForwardingNewTarget = false
    /// Sticky across focus moves to the find bar or toolbar; reset with each presentation.
    var pageFocus = PageFocus.peek
    private var observers: [NSObjectProtocol] = []

    // MARK: Hooks installed by the window

    /// Where the Peek is shown, for `BrowserSurfacePlacement.peek`.
    var windowID: () -> WindowID? = { nil }
    /// Classifies a source tab: Favorite, Pinned (with its home address) or Today, from the
    /// organization model. Nil (no model, unknown occurrence): automatic Peek never applies.
    var sourceClassifier: ((TabOccurrenceID) -> (role: BrowserPeekSourceRole, homeURL: URL?)?)?
    /// SPLIT installs this: accept the transfer in the same turn and return true, or return
    /// false and leave it pending; Peek then takes the document back.
    var splitHandoff: ((BrowserSurfaceTransfer<Surface>) -> Task<TabOccurrenceID?, Never>?)? {
        didSet { overlay.isSplitAvailable = splitHandoff != nil }
    }
    var onStateChange: (@MainActor () -> Void)?
    var onNewTarget: (@MainActor (Surface, BrowserNewSurfaceRequest, () -> Surface) -> Surface?)?
    var onDownload: (@MainActor (Surface, any BrowserEngineDownload, Presentation) -> Void)?
    var onPermission: (@MainActor (Surface, BrowserPermissionRequest) async -> BrowserPermissionDecision)?
    /// CH-ESSENTIALS: page-initiated surfaces of the Peek document (dialogs, sign-in, file choosers,
    /// context menu, fullscreen, renderer state) go to the window, which shows them over the Peek.
    weak var pageDelegate: (any BrowserEngineSurfaceDelegate<Surface>)?
    /// Application links (mailto:, tel:...) of the Peek document: confirmed by the window.
    var onExternalLink: (@MainActor (Surface, BrowserNavigationAction) -> Void)?
    /// The window's engine renders Chrome extension documents (`extensionDocuments`).
    var allowsExtensionDocuments = false
    var onCloseRequest: (@MainActor () -> Void)?
    /// Engine events of the presented Peek document, for find, zoom and feature observers (history).
    var onEngineEvent: (@MainActor (Surface, BrowserSurfaceEvent) -> Void)?
    /// A Peek surface is being disposed (closed, replaced or with its window).
    var onSurfaceDispose: (@MainActor (Surface) -> Void)?

    /// Nonisolated so that a window can hold it as a stored property; views are created lazily.
    nonisolated init() {}

    var presentedSurface: Surface? { presentation?.surface }
    var isPresented: Bool { presentation != nil }

    func retain(_ observer: NSObjectProtocol) { observers.append(observer) }

    // MARK: Ownership

    /// Takes ownership of an unowned surface (engine `make()` or `makeSurface`) and binds it.
    func claim(_ surface: Surface) -> Bool {
        guard container.claim(surface) else { return false }
        bind(surface)
        return true
    }

    /// Makes Peek the receiver of the surface's events, in the turn it became the owner.
    func bind(_ surface: Surface) {
        surface.delegate = self
        surface.placement = BrowserSurfacePlacement(container: .peek, windowID: windowID())
        surface.onChange = { [weak self, weak surface] in
            guard let self, let surface, presentation?.surface === surface else { return }
            onStateChange?()
            onEngineEvent?(surface, .stateChanged)
        }
        surface.onDispose = { [weak self, weak surface] in
            guard let self, let surface else { return }
            onSurfaceDispose?(surface)
        }
    }

    func owns(_ surface: Surface) -> Bool { container.owns(surface) }

    var handoffTask: Task<TabOccurrenceID?, Never>?

    private func isPresented(_ surface: Surface) -> Bool {
        presentation?.surface === surface && container.owns(surface)
    }

    // MARK: Presentation lifecycle

    /// Shows a surface Peek already owns. A previous Peek is disposed without animation.
    func present(_ surface: Surface, source: Surface?, sourceOccurrenceID: TabOccurrenceID?,
                 trigger: BrowserPeekTrigger, animated: Bool) {
        handoffTask?.cancel()
        handoffTask = nil
        // The previous Peek, presented or still fading out, is disposed now.
        presentation = nil
        for other in container.surfaces where other !== surface { container.dispose(other) }
        presentation = Presentation(surface: surface, source: source, sourceOccurrenceID: sourceOccurrenceID, trigger: trigger)
        lastDismissed = nil
        pageFocus = .peek
        overlay.isSplitAvailable = splitHandoff != nil
        overlay.show(surface.hostView, animated: animated)
        refreshToolbar()
    }

    /// Ends the presentation and disposes the surface once the overlay is gone. Returns the
    /// dismissed presentation. `remember` records it for ⇧⌘T.
    @discardableResult
    func dismiss(animated: Bool, remember: Bool) -> Presentation? {
        handoffTask?.cancel()
        handoffTask = nil
        guard let dismissed = presentation else { return nil }
        presentation = nil
        if remember, let url = dismissed.surface.currentURL ?? dismissed.surface.navigationState.url {
            lastDismissed = DismissedPeek(url: url, sourceOccurrenceID: dismissed.sourceOccurrenceID, closedAt: clock())
        }
        let surface = dismissed.surface
        // Inert from now on: no navigation, popup or download can start while it fades out.
        surface.stopLoading()
        overlay.hide(animated: animated) { [weak self, weak surface] in
            guard let self, let surface, presentation?.surface !== surface else { return }
            container.dispose(surface)
        }
        onStateChange?()
        return dismissed
    }

    /// Ends the presentation of a surface that left Peek alive (tab, Split). The overlay leaves
    /// with `expand` or `hide`; the surface is no longer Peek's.
    func endPresentationAfterHandOff() {
        presentation = nil
        lastDismissed = nil
        onStateChange?()
    }

    func forgetDismissed() { lastDismissed = nil }

    /// Closes the Peek of a closing window: every owned surface is disposed.
    func close() {
        handoffTask?.cancel()
        handoffTask = nil
        presentation = nil
        lastDismissed = nil
        overlay.hide(animated: false)
        container.close()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    func refreshToolbar() {
        guard let surface = presentation?.surface else { return }
        let state = surface.navigationState
        overlay.toolbar.update(url: state.url ?? surface.currentURL, title: state.title)
    }

    // MARK: BrowserEngineSurfaceDelegate (the Peek surface only)

    func surfaceDidStartNavigation(_ surface: Surface) { notifyIfPresented(surface, .navigationStarted) }
    func surfaceDidCommitNavigation(_ surface: Surface) {
        if isPresented(surface) { presentation?.hasRendered = true }
        notifyIfPresented(surface, .navigationCommitted)
    }
    func surfaceDidFinishNavigation(_ surface: Surface) { notifyIfPresented(surface, .navigationFinished) }
    func surfaceDidFailNavigation(_ surface: Surface) { notifyIfPresented(surface, .navigationFailed) }

    private func notifyIfPresented(_ surface: Surface, _ event: BrowserSurfaceEvent) {
        guard isPresented(surface) else { return }
        refreshToolbar()
        onStateChange?()
        onEngineEvent?(surface, event)
    }

    /// Links inside a Peek navigate the Peek; they never open another Peek
    /// ().
    func surface(_ surface: Surface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        guard isPresented(surface), let url = action.url, let scheme = url.scheme?.lowercased() else {
            decision.decide(.cancel)
            return
        }
        if action.shouldPerformDownload {
            decision.decide(["http", "https", "blob", "data"].contains(scheme) ? .download : .cancel)
        } else if ["http", "https", "about", "blob", "data"].contains(scheme)
                    || BrowserNavigationPolicy.allowsViewSource(url)
                    || allowsExtensionDocuments && BrowserNavigationPolicy.isExtensionDocument(url) {
            decision.decide(.allow)
        } else {
            onExternalLink?(surface, action)
            decision.decide(.cancel)
        }
    }

    func surface(_ surface: Surface, decidePolicyFor response: BrowserNavigationResponse,
                 decision: BrowserPolicyDecision<BrowserNavigationResponsePolicy>) {
        guard isPresented(surface), let url = response.response.url, let scheme = url.scheme?.lowercased(),
              ["http", "https", "blob", "data", "about"].contains(scheme)
                || BrowserNavigationPolicy.allowsViewSource(url)
                || allowsExtensionDocuments && BrowserNavigationPolicy.isExtensionDocument(url) else {
            decision.decide(.cancel)
            return
        }
        // Download versus render is the engine's native decision (CONTRACT-R2); engines without
        // navigationResponsePolicy never ask this question.
        decision.decide(.allow)
    }

    func surface(_ surface: Surface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> Surface) -> Surface? {
        guard isPresented(surface) else { return nil }
        return onNewTarget?(surface, request, make)
    }

    func surfaceDidRequestClose(_ surface: Surface) {
        guard isPresented(surface) else { return }
        onCloseRequest?()
    }

    func surface(_ surface: Surface, didStartDownload download: any BrowserEngineDownload) {
        guard isPresented(surface), let presentation, let onDownload else {
            download.cancel()
            return
        }
        onDownload(surface, download, presentation)
    }

    func surface(_ surface: Surface, requestsPermission request: BrowserPermissionRequest) async -> BrowserPermissionDecision {
        guard isPresented(surface), let onPermission else { return .deny }
        return await onPermission(surface, request)
    }

    // MARK: Page surfaces (CH-ESSENTIALS), forwarded to the window

    func surface(_ surface: Surface, runJavaScriptDialog dialog: BrowserJavaScriptDialog) async -> BrowserJavaScriptDialogResponse {
        guard isPresented(surface), let pageDelegate else { return .suppressed }
        return await pageDelegate.surface(surface, runJavaScriptDialog: dialog)
    }

    func surfaceDidResetJavaScriptDialogs(_ surface: Surface) { pageDelegate?.surfaceDidResetJavaScriptDialogs(surface) }

    func surface(_ surface: Surface, requestsCredentialsFor challenge: BrowserAuthenticationChallenge) async -> BrowserCredential? {
        guard isPresented(surface), let pageDelegate else { return nil }
        return await pageDelegate.surface(surface, requestsCredentialsFor: challenge)
    }

    func surface(_ surface: Surface, runFileChooser request: BrowserFileChooserRequest) async -> [URL]? {
        guard isPresented(surface), let pageDelegate else { return nil }
        return await pageDelegate.surface(surface, runFileChooser: request)
    }

    func surface(_ surface: Surface, showContextMenu request: BrowserContextMenuRequest) {
        guard isPresented(surface), let pageDelegate else {
            surface.contextMenuDidClose(request)
            return
        }
        pageDelegate.surface(surface, showContextMenu: request)
    }

    func surface(_ surface: Surface, didChangeElementFullscreen isFullscreen: Bool) {
        guard isPresented(surface) || !isFullscreen else { return }
        pageDelegate?.surface(surface, didChangeElementFullscreen: isFullscreen)
    }

    func surface(_ surface: Surface, rendererDidTerminate termination: BrowserRendererTermination) {
        guard isPresented(surface) else { return }
        pageDelegate?.surface(surface, rendererDidTerminate: termination)
    }

    func surface(_ surface: Surface, rendererDidBecomeUnresponsive isUnresponsive: Bool) {
        guard isPresented(surface) || !isUnresponsive else { return }
        pageDelegate?.surface(surface, rendererDidBecomeUnresponsive: isUnresponsive)
    }
}
