import AppKit
import OrbitChromiumBridge
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import ImageIO
import OSLog

@MainActor
final class ChromiumHostView: NSView {
    weak var surface: ChromiumSurface?
    var linkActivationModifiers: BrowserModifierKeys = []
    var linkActivation: (point: NSPoint, timestamp: TimeInterval, generation: UInt64)?
    private(set) var paintGeometryGeneration: UInt64 = 0
    private static let signposter = OSSignposter(subsystem: "local.orbit", category: "chromium-layout")

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        paintGeometryGeneration &+= 1
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        paintGeometryGeneration &+= 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paintGeometryGeneration &+= 1
        if window != nil, !isHiddenOrHasHiddenAncestor { surface?.hostViewDidBecomeVisible() }
        else { surface?.hostDidChange(hidden: true) }
    }

    override func viewDidHide() {
        super.viewDidHide()
        paintGeometryGeneration &+= 1
        surface?.hostDidChange(hidden: true)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        paintGeometryGeneration &+= 1
        if window != nil { surface?.hostViewDidBecomeVisible() }
    }

    // Geometry authority. The engine content view must always fill this view exactly: the shell
    // sizes the card, Chromium renders into it. AppKit autoresizing only adds size deltas, so a
    // content frame that Chromium set itself (WebContentsViewMac::Resize, e.g. a tab added in the
    // background sized like the previously active tab) would keep its offset across every later
    // card resize, and the page would lay out wider than the visible card until a re-placement.
    private var contentFrameObservers: [ObjectIdentifier: ContentFrameObservation] = [:]

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        fitContent()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        if newOrigin != frame.origin { paintGeometryGeneration &+= 1 }
        super.setFrameOrigin(newOrigin)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { paintGeometryGeneration &+= 1 }
        super.setFrameSize(newSize)
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        if newOrigin != bounds.origin { paintGeometryGeneration &+= 1 }
        super.setBoundsOrigin(newOrigin)
    }

    override func setBoundsSize(_ newSize: NSSize) {
        if newSize != bounds.size { paintGeometryGeneration &+= 1 }
        super.setBoundsSize(newSize)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        subview.postsFrameChangedNotifications = true
        contentFrameObservers[ObjectIdentifier(subview)] = ContentFrameObservation(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: subview, queue: nil
        ) { [weak self, weak subview] _ in
            MainActor.assumeIsolated {
                guard let self, let subview, subview.superview === self else { return }
                self.fit(subview)
            }
        })
        fit(subview)
        ChromiumFileDrop.install(in: subview)
    }

    override func willRemoveSubview(_ subview: NSView) {
        contentFrameObservers[ObjectIdentifier(subview)] = nil
        super.willRemoveSubview(subview)
    }

    private func fitContent() {
        for subview in subviews { fit(subview); ChromiumFileDrop.install(in: subview) }
    }

    private func fit(_ subview: NSView) {
        guard subview.frame != bounds else { return }
        let interval = Self.signposter.beginInterval("ChromiumContentResize", id: Self.signposter.makeSignpostID())
        subview.frame = bounds
        Self.signposter.endInterval("ChromiumContentResize", interval)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, let type = NSApp?.currentEvent?.type,
           [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
            surface?.hostViewDidBecomeVisible()
            if type == .leftMouseDown, let event = NSApp.currentEvent, let surface {
                let local = convert(event.locationInWindow, from: nil)
                var modifiers: BrowserModifierKeys = []
                if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
                if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
                if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
                if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
                linkActivationModifiers = modifiers
                linkActivation = (NSPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y),
                                  event.timestamp, surface.documentGeneration)
            }
        }
        return hit
    }
}

/// Unregisters a content-frame observer when its subview leaves or its host view goes away.
private final class ContentFrameObservation {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// One browser hosted in a shell-owned container view: an Alloy browser (stock SDK, or an engine
/// in `.alloy` mode), or a Chrome-style tab of a logical Browser (patched CEF, `.hosted` mode).
/// The shell places and moves `hostView`; the adapter never creates windows the shell sees. A
/// hosted surface's native tab is created on its first placement in a shell window (see
/// `ChromiumBrowserEngine.SurfaceMode`).
@MainActor
public final class ChromiumSurface: BrowserEngineSurface {
    public let profileID: ProfileID
    public let hostView: NSView
    public private(set) var pageThemeColor: UInt32?
    public private(set) var pageBackgroundColor: UInt32?
    private var nativeAudible: Bool?
    public var onChange: (() -> Void)?
    public var onDispose: (() -> Void)?
    public weak var delegate: (any BrowserEngineSurfaceDelegate<ChromiumSurface>)?
    public var placement: BrowserSurfacePlacement = .detached {
        didSet { if placement != oldValue { cancelExtensionAction(); engine?.surfacePlacementDidChange(self) } }
    }
    /// Hosted mode: the native tab waits for a shell window (`placement.windowID`).
    public internal(set) var awaitsHostedCreation = false
    /// Hosted mode: the shell window token of the logical Browser holding the native tab.
    public internal(set) var hostedWindowToken: UInt64 = 0
    /// Laboratory observation hook for raw engine events.
    public var onEngineEvent: ((String, [String: String]) -> Void)?

    var secureInputReconciliation = BrowserSecureInputFocusReconciliation()
    var secureInputHostHidden = false
    public private(set) var isDisposed = false
    private var paintActivationID: UInt64 = 0
    private lazy var nativeServices = ChromiumNativePageServices(token: token)
    public var nativePageServices: (any BrowserNativePageServices)? {
        guard !isDisposed, ACRNativePageServicesVersion() >= 14 else { return nil }
        return nativeServices
    }
    private lazy var nativePerformance = ChromiumPagePerformance(token: token)
    public var pagePerformance: (any BrowserPagePerformance)? {
        guard !isDisposed, ACRPagePerformanceAvailable() == 1 else { return nil }
        return nativePerformance
    }
    /// True after `OnBeforeClose` (or when no browser was ever created).
    public private(set) var isTeardownComplete = false
    public private(set) var findDocumentGeneration: UInt64 = 0
    public private(set) var pageZoom: Double = 1
    public private(set) var isBrowserCreated = false
    /// False between `CreateBrowser` and `OnAfterCreated`; commands are queued meanwhile.
    public var isReady: Bool { isBrowserCreated }
    public private(set) var runtimeStyle: Int32 = 0
    public private(set) var browserID: Int32 = 0

    let token: UInt64
    var passwordPromptObserver: (@MainActor (BrowserPasswordPromptEvent, BrowserPasswordPrompt) -> Void)?
    let profileToken: UInt64
    weak var engine: ChromiumBrowserEngine?
    private var state = BrowserNavigationState()
    var translationWorld: (generation: UInt64, context: Int)?
    var pageTintObservationEnabled = false
    var pageTintTask: Task<Void, Never>?
    var pageTintFailed = false

    func updatePageTint(_ tint: BrowserPageTint?) {
        guard state.pageTint != tint else { return }
        state.pageTint = tint
        onChange?()
    }
    private var faviconRevision: UInt64 = 0
    private var requestedDestination: URL?
    /// Kind of the next main-frame navigation the shell started (history traversal, reload).
    private var pendingKind: BrowserNavigationKind?
    /// Commands issued before `OnAfterCreated`, replayed in call order once the browser exists.
    private enum PendingCommand {
        case navigate(URL), reload, reloadIgnoringCache, stop, zoom(BrowserPageZoomCommand), focus, hostChanged(hidden: Bool), mute(Bool)
    }
    private var pendingCommands: [PendingCommand] = []
    private var zoomsAwaitingCommit: [BrowserPageZoomCommand] = []
    private var pendingMute: Bool?
    /// Permission requests handed to the delegate and not answered yet.
    private var pendingPermissions: Set<UInt64> = []
    private var wasLoading = false
    private var capture: (video: Bool, audio: Bool) = (false, false)
    private var find: (token: UUID, generation: UInt64, update: @MainActor (BrowserFindUpdate) -> Void)?
    private struct DevToolsRequest {
        var continuation: CheckedContinuation<(Bool, Data), Never>?
    }
    private var devTools: [Int32: DevToolsRequest] = [:]
    private var snapshotRequestID: Int32?
    var snapshotCaptureInFlight = false
    private var nativeSnapshotToken: UUID?
    private var nativeSnapshotContinuation: CheckedContinuation<BrowserNativeCapture, any Error>?
    private var devToolsTimeouts: [Int32: Task<Void, Never>] = [:]
    var lifecycleObservation: Task<Void, Never>?
    var audioContexts = ChromiumAudioContextActivity()
    weak var automaticPiPSourceWindow: NSWindow?
    var automaticPiPPresentation: ChromiumPictureInPicturePresentation?
    var automaticPiPTask: Task<Void, Never>?
    var automaticPiPShouldEnter = false
    var automaticPiPIsSelected = true
    var automaticPiPSession: (context: Int, generation: UInt64)?
    var automaticPiPRevision: UInt64 = 0
    public internal(set) var isSuspended = false
    var suspensionPaintEnabled = false
    var suspensionMainFrame: String?
    var suspensionLoader: String?
    var suspensionPaintTask: Task<Void, Never>?
    public internal(set) var suspensionPaintGeneration: UInt64?
    var isProtectedFromSuspension: Bool {
        BrowserPageSuspensionPolicy.refusal(pagePerformance?.lifecycle()) != nil || !audioContexts.isSafe || isElementFullscreen
            || !pendingPermissions.isEmpty || !pendingDialogRequests.isEmpty || !pendingPageRequests.isEmpty
            || capture.video || capture.audio || !downloads.isEmpty
    }
    private var downloads: [UInt32: ChromiumDownloadTransfer] = [:]
    var hasActiveDownloads: Bool { !downloads.isEmpty }
    private var downloadSourceCommitted = false
    private var didRequestShellClose = false
    private var downloadSourceTimeouts: [UUID: Task<Void, Never>] = [:]
    private var downloadSourceWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// Page-first keys sent to the page with a shell receipt, by bridge key id (ABI 7).
    private var keyReceipts: [(id: UInt64, receipt: BrowserKeyReceipt)] = []

    // ABI 9 page surfaces (CH-ESSENTIALS, `ChromiumSurface+PageInteraction.swift`).
    /// JavaScript dialogs, credentials and choosers handed to the delegate, by bridge request id.
    var pendingDialogRequests: Set<UInt64> = []
    var pendingPageRequests: Set<UInt64> = []
    /// The open native context menu: its request id, the Chrome commands offered for it, and the
    /// contract request the delegate received.
    var openContextMenu: (id: UInt64, commands: [String: Int32], request: BrowserContextMenuRequest)?
    /// `confirmClose()` waiting for the page; and whether its beforeunload dialog reached the delegate.
    var closeConfirmationTimeout: Task<Void, Never>?
    var closeCleanupTimeout: Task<Void, Never>?
    var closeConfirmation: CheckedContinuation<Bool, Never>?
    var closeConfirmationAskedUser = false
    var isConfirmingDownloadClose = false
    /// The page agreed to close (natively closed by Chrome): the shell disposes the surface.
    var closedByConfirmation = false
    public internal(set) var isElementFullscreen = false
    public internal(set) var isRendererUnresponsive = false
    /// Why the renderer ended, until the next committed document.
    public internal(set) var rendererTermination: BrowserRendererTermination?

    init(engine: ChromiumBrowserEngine, profileID: ProfileID, token: UInt64, profileToken: UInt64) {
        self.engine = engine
        self.profileID = profileID
        self.token = token
        self.profileToken = profileToken
        let view = ChromiumHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.wantsLayer = true
        view.autoresizesSubviews = true
        hostView = view
        view.surface = self

    }

    public var currentURL: URL? { requestedDestination ?? state.url }
    public var navigationState: BrowserNavigationState {
        state
    }

    /// True while CEF creates the browser of a surface that was not disposed before creation.
    public private(set) var isCreationPending = false

    func createBrowser() {
        isCreationPending = true
        // Tracked before the call: CreateBrowserSync delivers OnAfterCreated inside it.
        engine?.nativeCreationStarted(token)
        let result = ACRCreateSurface(token, profileToken, Unmanaged.passUnretained(hostView).toOpaque(), "")
        if result == 0 {
            isCreationPending = false
            engine?.nativeEnded(token)
            creationDidFail()
            onEngineEvent?("create-failed", [:])
        }
    }

    /// The bridge refused the browser (refused profile, shutdown): no browser will ever exist.
    /// Queued and later navigations are reported as failed instead of waiting forever.
    public private(set) var creationFailed = false

    private func creationDidFail() {
        creationFailed = true
        let navigates = pendingCommands.contains { if case .navigate = $0 { true } else { false } }
        pendingCommands.removeAll()
        if navigates { reportFailedNavigationLater() }
    }

    private func reportFailedNavigationLater() {
        Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            self.delegate?.surfaceDidFailNavigation(self)
        }
    }

    /// ABI 6 (patched CEF): a Chrome-style tab of the logical Browser of `window`, its content
    /// view a child of `hostView`. See `ChromiumBrowserEngine.makeTabSurface`.
    func createTabBrowser(window: UInt64, index: Int32) {
        awaitsHostedCreation = false
        hostedWindowToken = window
        isCreationPending = true
        engine?.nativeCreationStarted(token)
        let perfStart = BrowserPerformance.begin()
        defer { BrowserPerformance.end(.nativeBrowser, since: perfStart) }
        BrowserPerformance.mark(.nativeBrowserBegin)
        defer { BrowserPerformance.mark(.nativeBrowserReady) }
        let result = ACRCreateTabSurface(token, profileToken, window, index,
                                         Unmanaged.passUnretained(hostView).toOpaque(), "")
        if result == 0 {
            isCreationPending = false
            engine?.nativeEnded(token)
            creationDidFail()
            onEngineEvent?("create-failed", ["hosted": "true"])
        }
    }

    // MARK: Navigation

    /// Hosted mode: a command needs the native tab (created in the placement's window, or in the
    /// engine's holding window while the surface is not shown by any window).
    private func needBrowser() {
        if awaitsHostedCreation { engine?.createHostedBrowserIfPossible(self, commanded: true) }
    }

    public func navigate(to url: URL) {
        guard !isDisposed else { return }
        requestedDestination = url
        pendingKind = nil
        if creationFailed { reportFailedNavigationLater(); return }
        guard isBrowserCreated else { pendingCommands.append(.navigate(url)); needBrowser(); return }
        _ = ACRNavigate(token, url.absoluteString)
    }

    @discardableResult
    public func goBack() -> URL? { history(-1) }
    @discardableResult
    public func goForward() -> URL? { history(1) }

    private func history(_ offset: Int32) -> URL? {
        guard !isDisposed, isBrowserCreated else { return nil }
        var buffer = [CChar](repeating: 0, count: 8192)
        guard ACRHistoryURL(token, offset, &buffer, buffer.count) >= 0,
              let url = URL(string: String(nulTerminated: buffer)) else { return nil }
        let previousDestination = requestedDestination
        let previousKind = pendingKind
        requestedDestination = url
        pendingKind = .backForward
        guard (offset < 0 ? ACRGoBack(token) : ACRGoForward(token)) == 1 else {
            requestedDestination = previousDestination
            pendingKind = previousKind
            return nil
        }
        return url
    }

    public func reload() {
        guard !isDisposed else { return }
        guard isBrowserCreated else { pendingCommands.append(.reload); needBrowser(); return }
        pendingKind = .reload
        _ = ACRReload(token)
    }

    public func reloadIgnoringCache() throws {
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        guard isBrowserCreated else { pendingCommands.append(.reloadIgnoringCache); needBrowser(); return }
        pendingKind = .reload
        guard ACRReloadIgnoringCache(token) == 1 else { throw BrowserEngineError.unsupportedOperation }
    }

    public func duplicateWithHistory() -> Bool {
        !isDisposed && isReady && ACRDuplicateTab(token) == 1
    }

    public func stopLoading() {
        guard !isDisposed else { return }
        guard isBrowserCreated else { pendingCommands.append(.stop); return }
        _ = ACRStopLoad(token)
    }
    public func cancelStoppedNavigationTracking() { requestedDestination = nil }

    /// First responder on CEF's child browser view, then `SetFocus(true)` on the host. A hosted
    /// tab also becomes the active tab of its logical Browser (the focused Split pane is the
    /// active tab for extensions).
    @discardableResult
    public func focusDocument() -> Bool {
        guard !isDisposed, let window = hostView.window else { return false }
        guard isBrowserCreated, let view = ACRBrowserNSView(token) else {
            pendingCommands.append(.focus)
            needBrowser()
            return true
        }
        if hostedWindowToken != 0 { engine?.activateHostedTab(self) }
        let browserView = Unmanaged<NSView>.fromOpaque(view).takeUnretainedValue()
        window.makeFirstResponder(browserView)
        _ = ACRSetFocus(token, 1)
        return true
    }

    /// A submitted main-frame barrier for live-tab paint holding; never a scanout signal.
    public func activationPaintBarrier() -> Task<Bool, Never>? {
        guard isBrowserCreated, !isDisposed, !isSuspended, !state.isLoading,
              let performance = pagePerformance else { return nil }
        paintActivationID &+= 1
        if paintActivationID == 0 { paintActivationID = 1 }
        let activationID = paintActivationID
        let generation = documentGeneration
        return Task { [weak self] in
            // This task runs after the synchronous card placement and native visibility /
            // logical-tab activation. Finish layout before registering against that geometry.
            guard let self, let host = self.hostView as? ChromiumHostView else { return false }
            host.window?.contentView?.layoutSubtreeIfNeeded()
            let geometry = host.paintGeometryGeneration
            return await BrowserActivationPaintBarrier.wait(performance: performance, host: host,
                browserID: self.browserID, activationID: activationID) { [weak self] in
                    guard let self else { return false }
                    return !self.isDisposed && !self.isSuspended && !self.state.isLoading
                        && self.documentGeneration == generation && self.paintActivationID == activationID
                        && host.paintGeometryGeneration == geometry
                }
        }
    }

    /// The shell showed `hostView` in a window, or the user clicked into it.
    func hostViewDidBecomeVisible() {
        guard !isDisposed, isBrowserCreated, hostedWindowToken != 0 else { return }
        secureInputHostHidden = false
        resumeDiscardedTab()
        engine?.activateHostedTab(self)
    }

    /// Call after the shell moved `hostView` to another window or changed its visibility.
    public func hostDidChange(hidden: Bool) {
        secureInputHostHidden = hidden
        if hidden {
            cancelExtensionAction()
            if engine?.activeHostedTabs[hostedWindowToken]?.surface === self {
                engine?.activeHostedTabs[hostedWindowToken] = nil
            }
        }
        guard !isDisposed else { return }
        guard isBrowserCreated else { pendingCommands.append(.hostChanged(hidden: hidden)); return }
        if !hidden { resumeDiscardedTab() }
        if hidden { releaseSecureInputFocus() }
        _ = ACRNotifyHostChanged(token, hidden ? 1 : 0)
    }

    // MARK: Page tools

    public func performZoom(_ command: BrowserPageZoomCommand) {
        guard !isDisposed else { return }
        guard isBrowserCreated else { pendingCommands.append(.zoom(command)); return }
        let code: Int32 = switch command {
        case .increase: 1
        case .decrease: 2
        case .reset: 3
        }
        var level = 0.0
        var before = 0.0
        _ = ACRZoom(token, 0, &before)
        var result = ACRZoom(token, code, &level)
        if result == 1, command != .reset, abs(level - before) < 0.000_001 {
            _ = ACRSetZoomLevel(token, Self.presetLevel(after: before, command))
            result = ACRZoom(token, 0, &level) == 1 ? -3 : -1
        } else if result == -1 {
            // CanZoom is false before the first committed document (no host to key the site
            // zoom on). Measure whether an explicit level still applies.
            let target = Self.presetLevel(after: level, command)
            _ = ACRSetZoomLevel(token, target)
            result = ACRZoom(token, 0, &level) == 1 ? -2 : -1
        }
        onEngineEvent?("zoom", ["command": "\(command)", "result": String(result), "level": String(level)])
        pageZoom = pow(1.2, level)
        onChange?()
        // Zoom may apply asynchronously (renderer/host zoom map); confirm with a later readback.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !self.isDisposed, self.isBrowserCreated else { return }
            let previous = self.pageZoom
            self.refreshZoom()
            self.onEngineEvent?("zoom-readback", ["level": String(log(self.pageZoom) / log(1.2))])
            if self.pageZoom != previous { self.onChange?() }
        }
    }

    static let presetFactors: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

    static func presetLevel(after level: Double, _ command: BrowserPageZoomCommand) -> Double {
        let factor = pow(1.2, level)
        let next: Double = switch command {
        case .reset: 1
        case .increase: presetFactors.first { $0 > factor + 0.001 } ?? factor
        case .decrease: presetFactors.last { $0 < factor - 0.001 } ?? factor
        }
        return log(next) / log(1.2)
    }

    private func refreshZoom() {
        var level = 0.0
        if ACRZoom(token, 0, &level) == 1 { pageZoom = pow(1.2, level) }
    }

    public func performFind(_ request: BrowserFindRequest,
                            update: @escaping @MainActor (BrowserFindUpdate) -> Void) {
        guard !isDisposed, request.documentGeneration == findDocumentGeneration else { return }
        guard isBrowserCreated else {
            // No document to search before OnAfterCreated: end the query instead of leaving it open.
            update(BrowserFindUpdate(token: request.token, documentGeneration: request.documentGeneration,
                                     matchFound: false, final: true, error: .unsupportedOperation))
            return
        }
        find = (request.token, request.documentGeneration, update)
        // CEF 156 forwards findNext as find_match: false counts and highlights without selecting.
        if ACRFind(token, request.query, request.forward ? 1 : 0, request.matchCase ? 1 : 0,
                   request.selectMatch ? 1 : 0) != 1 {
            find = nil
            update(BrowserFindUpdate(token: request.token, documentGeneration: request.documentGeneration,
                                     matchFound: false, final: true, error: .unsupportedOperation))
        }
    }

    public func stopFinding(clearSelection: Bool) {
        find = nil
        if !isDisposed, isBrowserCreated { _ = ACRStopFinding(token, clearSelection ? 1 : 0) }
    }

    public static var snapshotProbe: ((String, Int) -> Void)?

    public func captureSnapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserSurfaceSnapshot {
        try Task.checkCancellation()
        // ImageIO cannot interrupt a decode already in progress. Keep the admission slot through
        // its completion, including cancellation, so another capture cannot overlap that worker.
        try await beginSnapshotCapture()
        defer { snapshotCaptureInFlight = false }
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        Self.snapshotProbe?("started", 0)
        var captureSucceeded = false
        defer { Self.snapshotProbe?(captureSucceeded ? "completed" : Task.isCancelled ? "cancelled" : "failed", 0) }
        let generation = request.documentGeneration ?? documentGeneration
        guard generation == documentGeneration else { throw BrowserEngineError.documentChanged }
        guard isBrowserCreated else { throw BrowserEngineError.snapshotUnavailable }
        let size = hostView.bounds.size
        let scale = hostView.window?.backingScaleFactor ?? hostView.layer?.contentsScale ?? 1
        if !request.fullPage, let api = pagePerformance,
           let target = ChromiumSnapshotDecoder.nativeRequest(size: size, scale: scale, width: request.width) {
            let captured = try await captureNativeSnapshot(api, request: target)
            Self.snapshotProbe?("native-\(captured.status.rawValue)", 0)
            try Task.checkCancellation()
            guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
            guard generation == documentGeneration, captured.status != .documentChanged else { throw BrowserEngineError.documentChanged }
            guard size == hostView.bounds.size,
                  scale == (hostView.window?.backingScaleFactor ?? hostView.layer?.contentsScale ?? 1) else {
                throw BrowserEngineError.snapshotUnavailable
            }
            if captured.status == .closed { throw BrowserEngineError.surfaceDisposed }
            if let image = ChromiumSnapshotDecoder.nativeImage(captured) {
                Self.snapshotProbe?("transportBytes", captured.pixels.count)
                Self.snapshotProbe?("decodedBytes", captured.pixels.count)
                captureSucceeded = true
                return BrowserSurfaceSnapshot(image: image, documentGeneration: generation)
            }
            // Older engines, hidden/unavailable surfaces and failed readbacks retain the PNG path.
        }
        var parameters: [String: Any] = ["format": "png"]
        if request.fullPage {
            let (ok, metrics) = await devToolsCall("Page.getLayoutMetrics")
            try Task.checkCancellation()
            guard !isDisposed, generation == documentGeneration else { throw BrowserEngineError.documentChanged }
            guard ok, let object = try? JSONSerialization.jsonObject(with: metrics) as? [String: Any],
                  let size = object["cssContentSize"] as? [String: Any],
                  let width = size["width"] as? Double, let height = size["height"] as? Double,
                  width.isFinite, height.isFinite, width > 0, height > 0,
                  width <= 32768, height <= 32768, width * height <= 100_000_000 else {
                throw BrowserEngineError.snapshotUnavailable
            }
            parameters["captureBeyondViewport"] = true
            parameters["clip"] = ["x": 0, "y": 0, "width": width, "height": height, "scale": 1]
        }
        try Task.checkCancellation()
        let json = try JSONSerialization.data(withJSONObject: parameters)
        let (success, data) = await devToolsCall("Page.captureScreenshot", params: String(decoding: json, as: UTF8.self))
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        guard generation == documentGeneration else { throw BrowserEngineError.documentChanged }
        try Task.checkCancellation()
        guard success else { throw BrowserEngineError.snapshotUnavailable }
        Self.snapshotProbe?("transportBytes", data.count)
        let width = request.width
        let worker = Task.detached(priority: .utility) {
            ChromiumSnapshotDecoder.decode(data, width: width, generation: generation)
        }
        let decoded = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        // Decoding yields the main actor: a close, navigation or cancellation may win meanwhile.
        try Task.checkCancellation()
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        guard generation == documentGeneration else { throw BrowserEngineError.documentChanged }
        guard let decoded else { throw BrowserEngineError.snapshotUnavailable }
        Self.snapshotProbe?("decodedBytes", decoded.decodedBytes)
        captureSucceeded = true
        return decoded.snapshot
    }

    /// A cancelled CDP response still owns its slot until callback/timeout. Native captures
    /// likewise retain admission until their exactly-once completion, including cancelled tint.
    func beginSnapshotCapture() async throws {
        while snapshotCaptureInFlight || snapshotRequestID != nil || nativeSnapshotToken != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        snapshotCaptureInFlight = true
    }

    /// Cancellation releases the consumer promptly. The readback keeps its slot until its
    /// callback, so a cancelled tint/thumbnail cannot overlap the next capture.
    func captureNativeSnapshot(_ api: any BrowserPagePerformance, request: BrowserNativeCaptureRequest) async throws -> BrowserNativeCapture {
        try Task.checkCancellation()
        let token = UUID()
        nativeSnapshotToken = token
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                nativeSnapshotContinuation = continuation
                Task { @MainActor [weak self] in
                    let result = await api.capture(request)
                    guard let self, self.nativeSnapshotToken == token else { return }
                    self.nativeSnapshotToken = nil
                    let consumer = self.nativeSnapshotContinuation
                    self.nativeSnapshotContinuation = nil
                    consumer?.resume(returning: result)
                }
                if Task.isCancelled { cancelNativeSnapshot(token) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelNativeSnapshot(token) }
        }
    }

    private func cancelNativeSnapshot(_ token: UUID) {
        guard nativeSnapshotToken == token else { return }
        let consumer = nativeSnapshotContinuation
        nativeSnapshotContinuation = nil
        consumer?.resume(throwing: CancellationError())
    }

    /// Runs Chromium's native save pipeline. The shell may continue using archivePage for MHTML.
    public func savePageWithNativeDialog() throws {
        guard !isDisposed, isReady, ACRExecuteChromeCommand(token, "IDC_SAVE_PAGE") == 1 else {
            throw BrowserEngineError.unsupportedOperation
        }
    }

    public func archivePage(documentGeneration generation: UInt64) async throws -> Data {
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        guard generation == documentGeneration else { throw BrowserEngineError.documentChanged }
        let (ok, data) = await devToolsCall("Page.captureSnapshot", params: #"{"format":"mhtml"}"#)
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        guard generation == documentGeneration else { throw BrowserEngineError.documentChanged }
        guard ok, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let archive = object["data"] as? String, !archive.isEmpty else { throw BrowserEngineError.unsupportedOperation }
        return Data(archive.utf8)
    }

    /// Executes a DevTools protocol method on this browser. Native-side only; pages never see it.
    public func devToolsCall(_ method: String, params: String = "", timeout: Duration = .seconds(8)) async -> (Bool, Data) {
        // A submitted screenshot cannot be cancelled in Chromium. Keep its native slot until
        // response/timeout even when its consumer is cancelled, and never overlap another one.
        if method == "Page.captureScreenshot" {
            while snapshotRequestID != nil {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return (false, Data()) }
                guard !isDisposed else { return (false, Data()) }
            }
        }
        guard !Task.isCancelled, !isDisposed, isBrowserCreated else { return (false, Data()) }
        let identifier = ACRExecuteDevToolsMethod(token, method, params)
        guard identifier != 0 else { return (false, Data()) }
        if method == "Page.captureScreenshot" { snapshotRequestID = identifier }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                devTools[identifier] = DevToolsRequest(continuation: continuation)
                devToolsTimeouts[identifier] = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finishDevTools(identifier, result: (false, Data()))
                }
                if Task.isCancelled { cancelDevTools(identifier) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelDevTools(identifier) }
        }
    }

    private func cancelDevTools(_ identifier: Int32) {
        let continuation = devTools[identifier]?.continuation
        devTools[identifier]?.continuation = nil
        continuation?.resume(returning: (false, Data()))
    }

    private func finishDevTools(_ identifier: Int32, result: (Bool, Data)) {
        if snapshotRequestID == identifier { snapshotRequestID = nil }
        devToolsTimeouts.removeValue(forKey: identifier)?.cancel()
        devTools.removeValue(forKey: identifier)?.continuation?.resume(returning: result)
    }

    public func requestMediaState() async -> BrowserMediaState {
        guard !isDisposed else { return BrowserMediaState() }
        let muted = isBrowserCreated ? ACRIsAudioMuted(token) : pendingMute.map { $0 ? 1 : 0 } ?? -1
        let lifecycle = pagePerformance?.lifecycle()
        let playing: Bool? = audioContexts.isRunning ? true : lifecycle.flatMap {
            if $0.playingMedia || $0.playingVideo || $0.audioContextRunning { return true }
            return audioContexts.isKnown ? false : nil
        }
        // The native lifecycle does not expose audio-track presence. A playing silent or
        // muted player stays unknown rather than being declared safe for auto-archive.
        let audio: Bool? = audioContexts.isRunning ? true : lifecycle.flatMap {
            if $0.audible || $0.audioContextRunning || ($0.playingMedia && !$0.playingVideo) { return true }
            return $0.playingMedia || !audioContexts.isKnown ? nil : false
        }
        return BrowserMediaState(playback: playing == true ? .playing : playing == false ? .paused : .unknown,
                                 camera: capture.video ? .active : .none, microphone: capture.audio ? .active : .none,
                                 isAudible: lifecycle?.audible ?? nativeAudible,
                                 isAudioMuted: muted < 0 ? nil : muted == 1, isAudioPlaying: audio)
    }

    public func setAudioMuted(_ muted: Bool) throws {
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        guard isBrowserCreated else {
            pendingMute = muted
            pendingCommands.append(.mute(muted))
            return
        }
        guard ACRSetAudioMuted(token, muted ? 1 : 0) == 1 else { throw BrowserEngineError.unsupportedOperation }
        onChange?()
    }

    // MARK: Lifetime

    func cancelExtensionAction() {
        _ = ACRCancelExtensionAction(token)
    }

    private func requestShellClose() {
        guard !isDisposed, !didRequestShellClose, let delegate else { return }
        didRequestShellClose = true
        delegate.surfaceDidRequestClose(self)
    }

    public func dispose() {
        lifecycleObservation?.cancel()
        lifecycleObservation = nil
        nativePerformance.close()
        suspensionPaintTask?.cancel()
        suspensionPaintTask = nil
        closeCleanupTimeout?.cancel()
        closeCleanupTimeout = nil
        observePasswordPrompt(nil)
        pageTintTask?.cancel()
        pageTintTask = nil
        automaticPiPPresentation?.finish()
        automaticPiPPresentation = nil
        automaticPiPTask?.cancel()
        automaticPiPTask = nil
        cancelExtensionAction()
        guard !isDisposed else { return }
        if isBrowserCreated { releaseSecureInputFocus() }
        isDisposed = true
        state.faviconURL = nil
        state.faviconImage = nil
        onDispose?()
        onDispose = nil
        onChange = nil
        delegate = nil
        find = nil
        requestedDestination = nil
        pendingCommands.removeAll()
        zoomsAwaitingCommit.removeAll()
        pendingMute = nil
        keyReceipts.removeAll()
        nativeServices.close()
        releasePageRequests()
        let neverCreated = awaitsHostedCreation
        awaitsHostedCreation = false
        if neverCreated { engine?.hostedSurfaceDisposedBeforeCreation(self) }
        // Requests still with the delegate are answered now; its late answer is ignored.
        for request in pendingPermissions { _ = ACRResolvePermission(request, ACR_PERMISSION_DEFAULT) }
        pendingPermissions.removeAll()
        for request in devTools.values { request.continuation?.resume(returning: (false, Data())) }
        snapshotRequestID = nil
        devTools.removeAll()
        for task in devToolsTimeouts.values { task.cancel() }
        devToolsTimeouts.removeAll()
        hostView.removeFromSuperview()
        // A download belongs to the application, not to this tab. Retain its detached native
        // browser until the last terminal callback, otherwise CEF silently drops those updates.
        if downloads.isEmpty { _ = ACRCloseSurface(token) }
        if !isBrowserCreated && !isCreationPending { isTeardownComplete = true }
    }

    /// The bridge reported that this pending surface will never get a browser.
    func creationAborted(reason: String) {
        isCreationPending = false
        isTeardownComplete = true
        pendingCommands.removeAll()
        onEngineEvent?("create-aborted", ["reason": reason])
        engine?.runtime.unregister(token)
        if !isDisposed { dispose() }
    }

    private func replayPendingCommands() {
        let commands = pendingCommands
        pendingCommands.removeAll()
        pendingMute = nil
        var navigationIssued = false
        for command in commands {
            guard !isDisposed, isBrowserCreated else { return }
            switch command {
            case .navigate(let url):
                _ = ACRNavigate(token, url.absoluteString)
                navigationIssued = true
            case .reload:
                pendingKind = .reload
                _ = ACRReload(token)
                navigationIssued = true
            case .reloadIgnoringCache:
                pendingKind = .reload
                _ = ACRReloadIgnoringCache(token)
                navigationIssued = true
            case .stop:
                _ = ACRStopLoad(token)
                navigationIssued = false
                flushZoomsAwaitingCommit()
            case .zoom(let zoom):
                if navigationIssued { zoomsAwaitingCommit.append(zoom) } else { performZoom(zoom) }
            case .focus:
                focusDocument()
            case .hostChanged(let hidden):
                if !hidden { resumeDiscardedTab() }
                _ = ACRNotifyHostChanged(token, hidden ? 1 : 0)
            case .mute(let muted):
                _ = ACRSetAudioMuted(token, muted ? 1 : 0)
            }
        }
        onEngineEvent?("replayed", ["commands": String(commands.count), "zoomsAwaitingCommit": String(zoomsAwaitingCommit.count)])
    }

    private func flushZoomsAwaitingCommit() {
        let zooms = zoomsAwaitingCommit
        zoomsAwaitingCommit.removeAll()
        for zoom in zooms { performZoom(zoom) }
    }

    // MARK: Engine events

    func decideNewSurface(url: String?, disposition: Int32, userGesture: Bool, keepsOpener: Bool) -> ChromiumSurface? {
        guard !isDisposed, let delegate, let engine else { return nil }
        var metadata = orbit_navigation_metadata_t()
        metadata.struct_size = UInt32(MemoryLayout<orbit_navigation_metadata_t>.size)
        let known = keepsOpener && ACRPopupNavigationMetadata(token, &metadata) == 1
        let method = known ? metadata.method.map { String(cString: $0) } : nil
        let kind = known ? Self.navigationKind(.init(url: url, isMainFrame: true, userGesture: userGesture,
            isRedirect: false, transitionType: metadata.transition_type), shellStarted: false, pendingKind: nil)
            : (userGesture ? .linkActivation : .other)
        // The new browser is created by CEF after OnBeforePopup returns; it is not ready yet.
        let request = BrowserNewSurfaceRequest(url: url.flatMap(URL.init(string:)),
                                               modifiers: userGesture ? recentLinkModifiers ?? Self.modifiers(disposition) : Self.modifiers(disposition),
                                               kind: kind, httpMethod: method,
                                               hasBody: known ? metadata.has_body != 0 : nil,
                                               isUserGesture: userGesture,
                                               disposition: Self.disposition(disposition))
        var created: ChromiumSurface?
        let accepted = delegate.surface(self, createSurfaceFor: request) {
            precondition(created == nil, "A new target surface can be created only once")
            let child = engine.makePendingSurface(profileID: profileID)
            child.markCreationPending()
            child.delegate = delegate
            created = child
            return child
        }
        guard let accepted, accepted === created else {
            created?.abandon()
            return nil
        }
        // CEF owns the creation from here: OnAfterCreated or ACR_EVENT_CREATE_ABORTED follows.
        engine.nativeCreationStarted(accepted.token)
        if accepted.onEngineEvent == nil { accepted.onEngineEvent = onEngineEvent }
        onEngineEvent?("new-surface", ["disposition": String(disposition), "path": keepsOpener ? "OnBeforePopup" : "OnOpenURLFromTab",
                                       "gesture": String(userGesture)])
        return accepted
    }

    func markCreationPending() { isCreationPending = true }

    /// A pending surface the shell did not record: CEF will never be asked for its browser.
    func abandonUnstartedCreation() { abandon() }

    // MARK: Page-first keyboard (ABI 7, BL-CONTRACT-KEY-RECEIPT)

    /// Shortcut candidates: Command, Control or Option, Escape, Tab and function keys. Plain typing
    /// never reaches the delegate.
    static func isShortcutCandidate(_ event: NSEvent) -> Bool {
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return true }
        if [53, 48].contains(event.keyCode) { return true }  // Escape, Tab
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        return (0xF704...0xF726).contains(scalar.value)  // NSF1FunctionKey ... NSF35FunctionKey
    }

    func decideKey(_ key: ChromiumKeyEvent) -> (consume: Bool, track: Bool) {
        guard !isDisposed, let event = key.event, event.type == .keyDown else { return (false, false) }
        // Enter/Space can activate a focused link. Never reuse a preceding mouse click for it.
        (hostView as? ChromiumHostView)?.linkActivation = nil
        guard Self.isShortcutCandidate(event), let delegate else { return (false, false) }
        switch delegate.surface(self, willSendKeyToPage: event) {
        case .browser:
            return (true, false)
        case .page(let receipt):
            guard let receipt else { return (false, false) }
            keyReceipts.append((key.keyID, receipt))
            if keyReceipts.count > 32 { keyReceipts.removeFirst(keyReceipts.count - 32) }
            return (false, true)
        }
    }

    func pageDidNotHandleKey(_ key: ChromiumKeyEvent) -> Bool {
        guard let index = keyReceipts.firstIndex(where: { $0.id == key.keyID }) else { return false }
        let receipt = keyReceipts.remove(at: index).receipt
        guard !isDisposed, let event = key.event, let delegate else { return false }
        let handled = delegate.surface(self, pageDidNotHandleKey: event, receipt: receipt)
        onEngineEvent?("unhandled-key", ["handled": String(handled)])
        return handled
    }

    /// A pending surface whose browser CEF never created.
    private func abandon() {
        isCreationPending = false
        isDisposed = true
        isTeardownComplete = true
        engine?.runtime.unregister(token)
    }

    /// CEF transition sources and qualifiers (`cef_transition_type_t`).
    enum Transition {
        static let sourceMask: UInt32 = 0xFF
        static let link: UInt32 = 0
        static let explicit: UInt32 = 1
        static let formSubmit: UInt32 = 7
        static let reload: UInt32 = 8
        static let forwardBack: UInt32 = 0x0100_0000
        static let clientRedirect: UInt32 = 0x4000_0000
        static let serverRedirect: UInt32 = 0x8000_0000
    }

    /// CONTRACT-R2 kind of a main-frame or subframe navigation question (ABI 7 metadata), with
    /// the kinds of navigations the shell started itself taking precedence.
    static func navigationKind(_ request: ChromiumNavigationRequest, shellStarted: Bool,
                               pendingKind: BrowserNavigationKind?) -> BrowserNavigationKind {
        let transition = request.transitionType
        if request.isRedirect || transition & (Transition.clientRedirect | Transition.serverRedirect) != 0 {
            return .redirect
        }
        if transition & Transition.forwardBack != 0 || (request.isMainFrame && pendingKind == .backForward && shellStarted) {
            return .backForward
        }
        if request.isMainFrame, shellStarted { return .typed }
        switch transition & Transition.sourceMask {
        case Transition.explicit where request.isMainFrame: return .typed
        case Transition.formSubmit: return .formSubmission
        case Transition.reload: return .reload
        case Transition.link: return request.userGesture ? .linkActivation : .other
        default: return request.isMainFrame && pendingKind == .reload ? .reload : .other
        }
    }

    func decideNavigation(_ request: ChromiumNavigationRequest) -> ACRNavigationPolicy {
        if !downloadSourceWaiters.isEmpty, request.isMainFrame, request.url == "about:blank" {
            return ACR_POLICY_ALLOW
        }
        guard !isDisposed else { return ACR_POLICY_CANCEL }
        let destination = request.url.flatMap(URL.init(string:))
        let shellStarted = destination != nil && destination == requestedDestination
        let kind = Self.navigationKind(request, shellStarted: shellStarted, pendingKind: pendingKind)
        if request.isMainFrame, kind == .backForward || kind == .reload { pendingKind = nil }
        let action = BrowserNavigationAction(url: destination, isMainFrame: request.isMainFrame,
                                             modifiers: kind == .linkActivation ? recentLinkModifiers ?? [] : [], kind: kind,
                                             httpMethod: request.method, hasBody: request.hasBody,
                                             isUserGesture: request.userGesture, parentFrameURL: request.parentURL.flatMap(URL.init(string:)))
        onEngineEvent?("before-browse", ["url": request.url ?? "", "main": String(request.isMainFrame),
                                         "gesture": String(request.userGesture), "redirect": String(request.isRedirect),
                                         "kind": kind.rawValue, "method": request.method ?? "", "parent": request.parentURL ?? ""])
        // OnBeforeBrowse returns synchronously on the UI thread: no suspension on the stock SDK.
        let decision = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: false, fallback: .cancel) { _ in }
        delegate?.surface(self, decidePolicyFor: action, decision: decision)
        decision.endSynchronousTurn()
        // CONTRACT-R2: no `navigationDownloadConversion` on stock CEF. `.download` behaves as
        // `.allow` and CefDownloadHandler decides; `StartDownload` on the URL would be a replay.
        switch decision.policy ?? .cancel {
        case .allow, .download: return ACR_POLICY_ALLOW
        case .cancel: return ACR_POLICY_CANCEL
        }
    }

    static func disposition(_ disposition: Int32) -> BrowserNavigationDisposition {
        switch disposition {
        case 4: .newBackgroundTab    // CEF_WOD_NEW_BACKGROUND_TAB
        case 5: .popup               // CEF_WOD_NEW_POPUP
        case 6: .newWindow           // CEF_WOD_NEW_WINDOW
        default: .newForegroundTab   // CEF_WOD_NEW_FOREGROUND_TAB and others
        }
    }

    private var recentLinkModifiers: BrowserModifierKeys? {
        guard let host = hostView as? ChromiumHostView, let activation = host.linkActivation,
              activation.generation == documentGeneration,
              ProcessInfo.processInfo.systemUptime - activation.timestamp < 1,
              NSApp.currentEvent?.type != .keyDown else { return nil }
        return host.linkActivationModifiers
    }

    static func modifiers(_ disposition: Int32) -> BrowserModifierKeys {
        switch disposition {
        case 3: [.command, .shift]   // CEF_WOD_NEW_FOREGROUND_TAB
        case 4: [.command]           // CEF_WOD_NEW_BACKGROUND_TAB
        case 6: [.shift]             // CEF_WOD_NEW_WINDOW
        case 7: [.option]            // CEF_WOD_SAVE_TO_DISK
        default: []
        }
    }

    func receive(_ event: ChromiumEvent) {
        if event.kind == ACR_EVENT_DOCUMENT {
            downloadSourceCommitted = true
            finishDownloadSourcePreparation(true)
        }
        // CEF can ask for the target again during an automatic or manual resume. The
        // original transfer owns it even after its shell tab has retired.
        if event.kind == ACR_EVENT_DOWNLOAD, let transfer = downloads[event.downloadID] {
            transfer.receive(event)
            return
        }
        if event.kind == ACR_EVENT_DOWNLOAD, event.requestID == 0 { return }
        if event.kind == ACR_EVENT_DEVTOOLS_RESULT {
            let identifier = Int32(truncatingIfNeeded: event.requestID)
            finishDevTools(identifier, result: (event.value == 1, event.payload ?? Data()))
            return
        }
        if event.kind == ACR_EVENT_CREATE_ABORTED {
            creationAborted(reason: event.detail ?? "")
            return
        }
        if event.kind == ACR_EVENT_CLOSED {
            nativeServices.close()
            finishDownloadSourcePreparation(false)
            isBrowserCreated = false
            isCreationPending = false
            isTeardownComplete = true
            pendingPermissions.removeAll()  // The bridge cancelled them with the browser.
            pageRequestsDidEnd()
            // An unexpected native destruction still loses CEF's download observation. Normal
            // shell disposal is deferred above until the transfers have actually ended.
            for transfer in Array(downloads.values) { transfer.sourceClosed() }
            downloads.removeAll()
            onEngineEvent?("closed", [:])
            engine?.runtime.unregister(token)
            // A close the page agreed to (`confirmClose`): the shell closes its tab and disposes.
            if finishCloseConfirmation(closed: true) || closedByConfirmation { return }
            // Chrome-style tabs can be destroyed directly (including window.close and extension
            // APIs), without DoClose. Let the owner retire the model occurrence before disposal,
            // just as for CLOSE_REQUEST; provisional adoptions may still be resolving ownership.
            if !isDisposed {
                if delegate != nil { requestShellClose() }
                else { dispose() }
            }
            return
        }
        guard !isDisposed else {
            if event.kind == ACR_EVENT_PERMISSION { _ = ACRResolvePermission(event.requestID, ACR_PERMISSION_DENY) }
            if event.kind == ACR_EVENT_DOWNLOAD, event.requestID != 0 { _ = ACRResolveDownloadDestination(event.requestID, nil) }
            Self.refuseUnanswered(event)
            return
        }
        switch event.kind {
        case ACR_EVENT_MEDIA_ACTIVITY:
            if let method = event.detail, let payload = event.payload {
                if method == "Runtime.bindingCalled" { receiveOptionLink(payload) }
                audioContexts.receive(method: method, payload: payload)
                receiveSuspensionPaint(method: method, payload: payload)
                onChange?()
            }
        case ACR_EVENT_CREATED:
            isBrowserCreated = true
            isCreationPending = false
            runtimeStyle = event.value
            browserID = event.browserID
            onEngineEvent?("created", ["style": event.value == 1 ? "alloy" : "chrome", "browser": String(event.browserID)])
            if let view = ACRBrowserNSView(token) {
                let browserView = Unmanaged<NSView>.fromOpaque(view).takeUnretainedValue()
                browserView.frame = hostView.bounds
                browserView.autoresizingMask = [.width, .height]
            }
            // Popups and new-tab targets of a hosted tab are hosted tabs of the same window.
            if let identity = tabIdentity, identity.isHosted { hostedWindowToken = identity.windowToken }
            if hostedWindowToken != 0 { engine?.hostedTabDidCreate(self) }
            // Submit before the first navigation. CEF may not answer until it has a document;
            // waiting for the reply here would delay that document by the command timeout.
            _ = ACRExecuteDevToolsMethod(token, "Page.enable", "")
            observePageLifecycle()
            installOptionLinks()
            Task { [weak self] in
                guard let self else { return }
                let (ok, _) = await self.devToolsCall("WebAudio.enable")
                self.audioContexts.ready = ok && !self.isDisposed
                self.onChange?()
            }
            replayPendingCommands()
        case ACR_EVENT_ADDRESS:
            let previous = state.url
            state.url = event.url.flatMap(URL.init(string:))
            if event.value == 1 {
                state.committedURL = state.url
                requestedDestination = nil
            }
            onChange?()
            // ABI 7: an address change without a new document (fragment, History API).
            if event.value == 1, let url = state.url {
                let navigation = BrowserSameDocumentNavigation(url: url, previous: previous)
                onEngineEvent?("same-document", ["kind": navigation.kind.rawValue])
                delegate?.surface(self, didNavigateWithinDocument: navigation)
            }
        case ACR_EVENT_TITLE:
            state.title = event.title
            onChange?()
        case ACR_EVENT_LOADING:
            state.isLoading = event.value == 1
            state.canGoBack = event.flags & 1 != 0
            state.canGoForward = event.flags & 2 != 0
            let started = state.isLoading && !wasLoading
            wasLoading = state.isLoading
            onChange?()
            if started { delegate?.surfaceDidStartNavigation(self) }
        case ACR_EVENT_DOCUMENT:
            if isConfirmingDownloadClose, event.url == "about:blank" {
                _ = finishCloseConfirmation(closed: true)
                return
            }
            // A native activation or extension may navigate a discarded background tab.
            isSuspended = false
            findDocumentGeneration &+= 1
            find = nil
            state.faviconURL = nil
            state.faviconImage = nil
            faviconRevision = 0
            state.faviconRevision = 0
            state.faviconMetadataIsSettled = false
            state.committedURL = event.url.flatMap(URL.init(string:))
            pageTintFailed = false
            if !["http", "https", "file"].contains(state.committedURL?.scheme?.lowercased() ?? "") {
                updatePageTint(nil)
            }
            restartPageTintObservation()
            requestedDestination = nil
            refreshZoom()
            onEngineEvent?("commit", ["url": event.url ?? "", "generation": String(findDocumentGeneration),
                                      "transition": String(UInt32(bitPattern: event.value), radix: 16)])
            documentDidCommitForPageSurfaces()
            onChange?()
            delegate?.surfaceDidCommitNavigation(self)
            flushZoomsAwaitingCommit()
        case ACR_EVENT_LOAD_END:
            onEngineEvent?("load-end", ["status": String(event.value)])
            delegate?.surfaceDidFinishNavigation(self)
        case ACR_EVENT_LOAD_ERROR:
            if event.value != -3 {
                pageTintFailed = true
                updatePageTint(nil)
            }
            if isConfirmingDownloadClose {
                _ = finishCloseConfirmation(closed: false)
            }
            requestedDestination = nil
            // CEF does not send OnAddressChange for every failed main-frame navigation.
            // Show its failed destination; an aborted navigation keeps the previous address.
            if event.value != -3, let url = event.url.flatMap(URL.init(string:)) {
                state.url = url
                onChange?()
            }
            onEngineEvent?("load-error", ["code": String(event.value), "url": event.url ?? ""])
            delegate?.surfaceDidFailNavigation(self)
            flushZoomsAwaitingCommit()
        case ACR_EVENT_FAVICON:
            guard event.surfaceToken == token, event.profileToken == profileToken,
                  event.browserID == browserID, event.documentGeneration == findDocumentGeneration,
                  event.requestID >= faviconRevision else { return }
            let url = event.url.flatMap(URL.init(string:))
            // A newer receipt announces its candidate (and may coalesce bytes for ABI
            // callers). Equal-revision bytes can only fill that exact announced source.
            if event.requestID == faviconRevision, event.url != state.faviconURL?.absoluteString { return }
            faviconRevision = event.requestID
            state.faviconRevision = event.requestID
            state.faviconMetadataIsSettled = event.payload != nil || event.faviconPayloadWasRejected || url == nil || url?.scheme == "data"
            guard url == nil || BrowserFaviconImage.allowsSourceURL(url!) else {
                state.faviconURL = nil
                state.faviconImage = nil
                state.faviconMetadataIsSettled = true
                onChange?()
                return
            }
            state.faviconURL = url
            state.faviconImage = nil
            if let url, let data = event.payload {
                state.faviconImage = BrowserFaviconImage(sourceURL: url, png: data)
            }
            onChange?()
        case ACR_EVENT_BROWSER_STATE:
            guard let payload = event.payload, payload.count == MemoryLayout<orbit_browser_state_t>.size else { return }
            let value = payload.withUnsafeBytes { $0.loadUnaligned(as: orbit_browser_state_t.self) }
            nativeAudible = value.audible != 0
            onEngineEvent?("browser-state", ["audible": String(value.audible), "muted": String(value.muted)])
            pageThemeColor = value.colors & 1 != 0 ? value.theme_color : nil
            pageBackgroundColor = value.colors & 2 != 0 ? value.background_color : nil
            // A declared theme colour updates the developer toolbar at once, without a probe.
            if pageTintObservationEnabled, let tint = nativeThemeTint { updatePageTint(tint) }
            onChange?()
        case ACR_EVENT_AUDIO:
            capture = (event.flags & 1 != 0, event.flags & 2 != 0)
            onChange?()
        case ACR_EVENT_CLOSE_REQUEST:
            onEngineEvent?("close-request", [:])
            requestShellClose()
        case ACR_EVENT_FIND_RESULT:
            guard let find, find.generation == findDocumentGeneration else { return }
            let count = Int(event.value)
            let ordinal = Int(event.flags)
            let final = event.detailCode == 1
            if final { self.find = nil }
            find.update(BrowserFindUpdate(token: find.token, documentGeneration: find.generation,
                                          matchFound: count > 0, count: count, activeOrdinal: ordinal, final: final))
        case ACR_EVENT_PERMISSION:
            handlePermission(event)
        case ACR_EVENT_ACTIVATION_REQUEST:
            delegate?.surfaceDidRequestActivation(self)
        case ACR_EVENT_DOWNLOAD:
            handleDownload(event)
        case ACR_EVENT_RENDER_TERMINATED:
            guard !isSuspended, pagePerformance?.lifecycle()?.state != .discarded else { return }
            pageTintFailed = true
            updatePageTint(nil)
            onEngineEvent?("render-terminated", ["status": String(event.value)])
            rendererDidTerminate(status: event.value)
            delegate?.surfaceDidFailNavigation(self)
        case ACR_EVENT_JS_DIALOG, ACR_EVENT_JS_DIALOG_RESET, ACR_EVENT_AUTH, ACR_EVENT_FILE_DIALOG,
             ACR_EVENT_CONTEXT_MENU, ACR_EVENT_FULLSCREEN, ACR_EVENT_UNRESPONSIVE, ACR_EVENT_CLOSE_CANCELED:
            receivePageEvent(event)
        default:
            break
        }
    }

    private func handlePermission(_ event: ChromiumEvent) {
        let request = event.requestID
        guard let delegate else { _ = ACRResolvePermission(request, ACR_PERMISSION_DEFAULT); return }
        let kind = Self.permissionKind(mask: event.permissionMask, media: event.detailCode == 1)
        let origin = event.url.flatMap(URL.init(string:)).map { url -> String in
            let port = url.port.map { ":\($0)" } ?? ""
            return "\(url.scheme ?? "")://\(url.host ?? "")\(port)"
        } ?? ""
        let permission = BrowserPermissionRequest(kind: kind, origin: origin, isMainFrame: event.isMainFrame)
        pendingPermissions.insert(request)
        onEngineEvent?("permission-request", ["kind": "\(kind)", "request": String(request)])
        // The surface stays alive for the delegate's answer; dispose() answers first if it comes earlier.
        Task { @MainActor [self] in
            // Disposed meanwhile: dispose() already answered and the delegate gets no event.
            guard pendingPermissions.contains(request), !isDisposed else { return }
            let decision = await delegate.surface(self, requestsPermission: permission)
            guard pendingPermissions.remove(request) != nil else {
                onEngineEvent?("permission-late-answer-ignored", ["request": String(request)])
                return
            }
            _ = ACRResolvePermission(request, decision == .grantOnce ? ACR_PERMISSION_GRANT_ONCE : decision == .grant ? ACR_PERMISSION_GRANT
                                     : decision == .deny ? ACR_PERMISSION_DENY : ACR_PERMISSION_DEFAULT)
            onEngineEvent?("permission-resolved", ["request": String(request), "decision": "\(decision)"])
        }
    }

    /// Match the entire mask: an unrecognized capability must never receive a partial grant.
    public static func permissionKind(mask: UInt32, media: Bool) -> BrowserPermissionKind {
        if media {
            switch mask {
            case 1: return .microphone
            case 2: return .camera
            case 3: return .cameraAndMicrophone
            default: return .other("cef-media-\(mask)")
            }
        }
        switch mask {
        case 1 << 2: return .camera
        case 1 << 12: return .microphone
        case (1 << 2) | (1 << 12): return .cameraAndMicrophone
        case 1 << 8: return .geolocation
        case 1 << 15: return .notifications
        case 1 << 4: return .other(BrowserSitePermission.clipboardRead.rawValue)
        default: return .other("cef-permission-\(mask)")
        }
    }

    private func handleDownload(_ event: ChromiumEvent) {
        if event.requestID != 0 {
            guard let delegate else { _ = ACRResolveDownloadDestination(event.requestID, nil); return }
            let download = ChromiumEngineDownload(surface: self, event: event)
            onEngineEvent?("download-offered", ["id": String(event.downloadID)])
            delegate.surface(self, didStartDownload: download)
            if !download.adopted { download.cancel() }
            else if !downloadSourceCommitted { requestShellClose() }
            return
        }
        downloads[event.downloadID]?.receive(event)
    }

    func track(_ transfer: ChromiumDownloadTransfer, id: UInt32) {
        downloads[id] = transfer
        engine?.runtime.retainDownloadSource(self)
    }

    /// Chrome closes an initial-navigation download tab before CEF can report completion.
    /// A real about:blank commit prevents that automatic close; the shell tab can disappear,
    /// while its detached browser remains solely to service downloads. No download URL replay.
    func prepareDownloadSource() async -> Bool {
        guard isBrowserCreated, !isTeardownComplete else { return false }
        if downloadSourceCommitted { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let startsNavigation = downloadSourceWaiters.isEmpty
            downloadSourceWaiters[id] = continuation
            if startsNavigation, ACRNavigate(token, "about:blank") != 1 {
                finishDownloadSourcePreparation(false)
                return
            }
            downloadSourceTimeouts[id] = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                self?.downloadSourceTimeouts[id] = nil
                self?.downloadSourceWaiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    private func finishDownloadSourcePreparation(_ ready: Bool) {
        for timeout in downloadSourceTimeouts.values { timeout.cancel() }
        downloadSourceTimeouts.removeAll()
        let waiters = downloadSourceWaiters.values
        downloadSourceWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ready) }
    }
    func untrack(id: UInt32) {
        downloads[id] = nil
        guard downloads.isEmpty else { return }
        // Defer closing out of OnDownloadUpdated: CEF is still borrowing the item on its stack.
        if isDisposed {
            Task { @MainActor [self] in _ = ACRCloseSurface(token) }
            // Keep the surface pinned through CLOSED, which unregisters it and confirms teardown.
        } else {
            engine?.runtime.releaseDownloadSource(token)
        }
    }
}
