import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation

/// A windowless engine that implements the contract with plain AppKit views, proving that the
/// contract needs no web engine framework and giving shell features a deterministic test double.
/// It models stock CEF where the contract is strict: policy questions must be answered
/// synchronously (no `suspendablePolicyDecisions`), the document responder is a child of a plain
/// host view, teardown completes asynchronously after `dispose()`, and with `.deferred`
/// readiness the native host appears one turn after creation, as with `OnAfterCreated`.
@MainActor
final class SiteSyntheticEngine: BrowserEngine, BrowserSitePermissionAvailability {
    enum Readiness {
        /// The host exists on creation; events of a navigation arrive synchronously inside it.
        case immediate
        /// The host appears on a later main-actor turn; earlier commands are queued in order.
        case deferred
    }

    let kind = BrowserEngineKind.synthetic
    let capabilities: BrowserEngineCapabilities = [.liveSurfaceTransfer, .audioMuting, .audibleState, .mediaPlaybackState, .mediaCapturePermissions]
    let readiness: Readiness
    var extensionManagement: (any BrowserExtensionManagement)? { extensions }
    var diagnosticRoot: URL?
    func diagnosticDataRoot(for profileID: ProfileID) -> URL? { diagnosticRoot }
    var extensions: (any BrowserExtensionHost)?
    var conformanceProbe: (any BrowserEngineConformanceProbe<SiteSyntheticSurface>)? { SiteSyntheticConformanceProbe() }
    private(set) var profiles: [ProfileID: BrowserEngineProfile] = [:]
    private(set) var surfaces: [SiteSyntheticSurface] = []
    private(set) var isShutDown = false
    private var siteData: [ProfileID: SiteSyntheticSiteData] = [:]
    var pendingTeardowns = 0

    init(readiness: Readiness = .immediate) {
        self.readiness = readiness
    }

    func profile(for profileID: ProfileID) -> BrowserEngineProfile {
        if let existing = profiles[profileID] { return existing }
        let profile = BrowserEngineProfile(profileID: profileID, persistence: .ephemeral)
        profiles[profileID] = profile
        siteData[profileID] = SiteSyntheticSiteData()
        return profile
    }

    func makeSurface(profileID: ProfileID,
                     delegate: any BrowserEngineSurfaceDelegate<SiteSyntheticSurface>) -> SiteSyntheticSurface {
        let surface = makeSurface(profileID: profileID)
        surface.delegate = delegate
        return surface
    }

    func makeSurface(profileID: ProfileID) -> SiteSyntheticSurface {
        _ = profile(for: profileID)
        let surface = SiteSyntheticSurface(profileID: profileID, engine: self, siteData: siteData[profileID]!,
                                       isReady: readiness == .immediate)
        if readiness == .deferred {
            Task { @MainActor [weak surface] in surface?.becomeReady() }
        }
        surfaces.append(surface)
        return surface
    }

    let supportedSitePermissions: Set<BrowserSitePermission> = [.camera, .microphone]
    private(set) var revocations = 0
    func revokeSitePermission(_ permission: BrowserSitePermission?, origin: BrowserSiteOrigin, profileID: ProfileID) async {
        revocations += 1
        for surface in surfaces where surface.profileID == profileID && surface.currentURL.flatMap(BrowserSiteOrigin.init(url:)) == origin {
            if permission == nil || permission == .camera { surface.media.camera = .none }
            if permission == nil || permission == .microphone { surface.media.microphone = .none }
        }
    }

    func shutdown() async {
        while pendingTeardowns > 0 { await Task.yield() }
        isShutDown = true
    }
}

/// Per-profile site data, shared by every surface of the profile.
@MainActor
final class SiteSyntheticSiteData {
    var cookies: [String: String] = [:]
}

@MainActor
final class SiteSyntheticConformanceProbe: BrowserEngineConformanceProbe {
    func writeSiteDataMarker(_ value: String, for origin: URL, through surface: SiteSyntheticSurface) async throws {
        surface.siteData.cookies[origin.host ?? ""] = value
    }

    func readSiteDataMarker(for origin: URL, through surface: SiteSyntheticSurface) async throws -> String? {
        surface.siteData.cookies[origin.host ?? ""]
    }
}

/// The responder a real engine places inside its host view.
final class SiteSyntheticDocumentView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class SiteSyntheticSurface: BrowserEngineSurface {
    var automaticPiPUpdates: [(selected: Bool, allowed: Bool)] = []
    func updateAutomaticPictureInPicture(isSelected: Bool, allowed: Bool) {
        automaticPiPUpdates.append((isSelected, allowed))
    }
    var nativePageServices: (any BrowserNativePageServices)?
    let profileID: ProfileID
    /// A plain parent view, like the `NSView` handed to CEF; it is not itself focusable.
    let hostView = NSView()
    let documentView = SiteSyntheticDocumentView()
    weak var delegate: (any BrowserEngineSurfaceDelegate<SiteSyntheticSurface>)?
    weak var engine: SiteSyntheticEngine?
    let siteData: SiteSyntheticSiteData
    var placement = BrowserSurfacePlacement.detached
    var onChange: (() -> Void)?
    var onDispose: (() -> Void)?
    private(set) var isDisposed = false
    private(set) var isReady: Bool
    private(set) var findDocumentGeneration: UInt64 = 0
    private(set) var pageZoom: Double = 1
    /// Every request the engine started, including refused ones; a replay would appear twice.
    private(set) var requestedURLs: [URL] = []
    private var pendingCommands: [() -> Void] = []
    private var history: [URL] = []
    private var index = -1
    private let zoomPolicy = try! BrowserPageZoom()

    init(profileID: ProfileID, engine: SiteSyntheticEngine?, siteData: SiteSyntheticSiteData, isReady: Bool = true) {
        self.profileID = profileID
        self.engine = engine
        self.siteData = siteData
        self.isReady = isReady
        documentView.autoresizingMask = [.width, .height]
        hostView.addSubview(documentView)
    }

    func becomeReady() {
        guard !isDisposed, !isReady else { return }
        isReady = true
        let commands = pendingCommands
        pendingCommands.removeAll()
        for command in commands { command() }
    }

    private func perform(_ command: @escaping () -> Void) {
        guard !isDisposed else { return }
        if isReady { command() } else { pendingCommands.append(command) }
    }

    var currentURL: URL? { history.indices.contains(index) ? history[index] : nil }

    var pagePerformance: (any BrowserPagePerformance)?

    // Opt-in native-discard fixture; other suites retain the unsupported default.
    var isSuspended = false
    var allowsSuspension = false
    var supportsSuspensionPaint = false
    var suspensionPaintGeneration: UInt64?
    func prepareSuspensionPaint() async -> Bool { supportsSuspensionPaint }
    var snapshotHandler: ((BrowserSnapshotRequest) async throws -> BrowserSurfaceSnapshot)?
    var suspensionCapture: (() async -> BrowserSuspensionState?)?
    var suspensionCount = 0
    func captureStateForSuspension() async -> BrowserSuspensionState? {
        if let suspensionCapture { return await suspensionCapture() }
        guard allowsSuspension, let currentURL else { return nil }
        return BrowserSuspensionState(url: currentURL, documentGeneration: documentGeneration,
            scrollX: 0, scrollY: 0, history: history, historyIndex: index)
    }
    func suspendInPlace() -> BrowserSurfaceSuspensionResult {
        guard allowsSuspension else { return .refused }
        suspensionCount += 1
        return .suspended
    }

    var isLoading = false
    var faviconURL: URL?
    var faviconImage: BrowserFaviconImage?
    var pageTint: BrowserPageTint?
    private(set) var observesPageTint = false
    func setPageTintObservationEnabled(_ enabled: Bool) { observesPageTint = enabled }

    var navigationState: BrowserNavigationState {
        var state = BrowserNavigationState(url: currentURL, committedURL: currentURL, title: currentURL?.host,
                               canGoBack: index > 0, canGoForward: index + 1 < history.count, faviconURL: faviconURL)
        state.isLoading = isLoading
        state.faviconImage = faviconImage
        state.pageTint = pageTint
        return state
    }

    /// Asks for policy synchronously, then commits synchronously: the synthetic engine has no network.
    func navigate(to url: URL) {
        perform { [weak self] in self?.load(url) }
    }

    private func load(_ url: URL) {
        requestedURLs.append(url)
        var policy = BrowserNavigationActionPolicy.cancel
        let decision = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: false, fallback: .cancel) {
            policy = $0
        }
        delegate?.surface(self, decidePolicyFor: BrowserNavigationAction(url: url, isMainFrame: true), decision: decision)
        decision.endSynchronousTurn()
        guard !isDisposed else { return }
        guard policy == .allow else {
            // Stock CEF reports a refused navigation as a load error (ERR_ABORTED).
            delegate?.surfaceDidFailNavigation(self)
            return
        }
        history = Array(history.prefix(index + 1)) + [url]
        index = history.count - 1
        commit()
    }

    func goBack() -> URL? { move(by: -1) }
    func goForward() -> URL? { move(by: 1) }

    private func move(by offset: Int) -> URL? {
        guard history.indices.contains(index + offset) else { return nil }
        index += offset
        commit()
        return history[index]
    }

    private func commit() {
        findDocumentGeneration &+= 1
        delegate?.surfaceDidStartNavigation(self)
        delegate?.surfaceDidCommitNavigation(self)
        onChange?()
        delegate?.surfaceDidFinishNavigation(self)
    }

    func reload() { perform { [weak self] in if self?.currentURL != nil { self?.commit() } } }
    func stopLoading() {}
    func cancelStoppedNavigationTracking() {}

    func focusDocument() -> Bool {
        guard !isDisposed, let window = hostView.window else { return false }
        return window.makeFirstResponder(documentView)
    }

    func performZoom(_ command: BrowserPageZoomCommand) {
        perform { [weak self] in
            guard let self else { return }
            switch command {
            case .increase: pageZoom = (try? zoomPolicy.nextFactor(after: pageZoom)) ?? pageZoom
            case .decrease: pageZoom = (try? zoomPolicy.previousFactor(before: pageZoom)) ?? pageZoom
            case .reset: pageZoom = zoomPolicy.resetFactor
            }
            onChange?()
        }
    }

    func performFind(_ request: BrowserFindRequest, update: @escaping @MainActor (BrowserFindUpdate) -> Void) {
        update(BrowserFindUpdate(token: request.token, documentGeneration: request.documentGeneration,
                                 matchFound: false, final: true, error: .unsupportedOperation))
    }

    func stopFinding(clearSelection: Bool) {}

    func captureSnapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserSurfaceSnapshot {
        if let snapshotHandler { return try await snapshotHandler(request) }
        throw BrowserEngineError.unsupportedOperation
    }

    var media = BrowserMediaState(playback: .playing, isAudible: true, isAudioMuted: false)
    var mediaRequest: (() async -> BrowserMediaState)?
    func requestMediaState() async -> BrowserMediaState {
        if let mediaRequest { return await mediaRequest() }
        return media
    }
    func requestPermission(_ request: BrowserPermissionRequest) async -> BrowserPermissionDecision {
        await delegate?.surface(self, requestsPermission: request) ?? .deny
    }

    func setAudioMuted(_ muted: Bool) throws { media.isAudioMuted = muted; onChange?() }

    /// Simulates `window.open` from this document. The engine loads the original request in the
    /// accepted surface, through the delegate that surface has when `createSurfaceFor` returns.
    func openNewTarget(_ url: URL, modifiers: BrowserModifierKeys = []) -> SiteSyntheticSurface? {
        guard let delegate, let engine else { return nil }
        var created: SiteSyntheticSurface?
        let accepted = delegate.surface(self, createSurfaceFor: BrowserNewSurfaceRequest(url: url, modifiers: modifiers)) {
            let child = engine.makeSurface(profileID: profileID)
            child.isReady = true
            child.delegate = delegate
            created = child
            return child
        }
        guard let accepted, accepted === created else {
            created?.dispose()
            return nil
        }
        accepted.navigate(to: url)
        return accepted
    }

    /// Simulates `window.close()` from this document.
    func requestClose() {
        delegate?.surfaceDidRequestClose(self)
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        onDispose?()
        onDispose = nil
        onChange = nil
        delegate = nil
        pendingCommands.removeAll()
        hostView.removeFromSuperview()
        // Native teardown completes later, as CEF's OnBeforeClose does.
        if let engine {
            engine.pendingTeardowns += 1
            Task { @MainActor [weak engine] in engine?.pendingTeardowns -= 1 }
        }
    }
}
