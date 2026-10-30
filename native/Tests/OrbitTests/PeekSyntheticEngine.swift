import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
@testable import Orbit

/// A windowless, deterministic engine for Peek integration tests in OrbitTests (the shared
/// `SyntheticEngine` lives in BrowserEngineTests, which cannot see Orbit). Like stock CEF it
/// answers policy synchronously, keeps the document responder inside a plain host view, and
/// never reloads a document on its own: `requestedURLs` grows only when a load starts.
@MainActor
final class PeekSyntheticEngine: BrowserEngine, BrowserNavigationMetadataSource {
    let kind = BrowserEngineKind.synthetic
    var capabilities: BrowserEngineCapabilities = [.liveSurfaceTransfer]
    var extensions: (any BrowserExtensionHost)? { nil }
    private(set) var surfaces: [PeekSyntheticSurface] = []
    /// Profiles whose site data (and therefore history) persists; every other profile is private.
    var persistentProfiles: Set<ProfileID> = []

    func profile(for profileID: ProfileID) -> BrowserEngineProfile {
        BrowserEngineProfile(profileID: profileID,
                             persistence: persistentProfiles.contains(profileID) ? .persistent : .ephemeral)
    }

    func makeSurface(profileID: ProfileID,
                     delegate: any BrowserEngineSurfaceDelegate<PeekSyntheticSurface>) -> PeekSyntheticSurface {
        let surface = PeekSyntheticSurface(profileID: profileID, engine: self)
        surface.delegate = delegate
        surfaces.append(surface)
        return surface
    }

    func shutdown() async {}

    /// EXT-OUTCOME-R1: the shell's handler for tabs the engine creates by itself, by window.
    private(set) var tabAdoption: [WindowID: @MainActor (BrowserEngineTabRequest, () -> PeekSyntheticSurface) -> PeekSyntheticSurface?] = [:]
    func setEngineTabAdoption(for windowID: WindowID,
                              _ adopt: (@MainActor (BrowserEngineTabRequest, () -> PeekSyntheticSurface) -> PeekSyntheticSurface?)?) {
        tabAdoption[windowID] = adopt
    }

    /// What a native extension system does for `chrome.tabs.create`: the tab is offered to its
    /// window before it exists, then loads. Nil when no handler takes it.
    func createEngineTab(in windowID: WindowID, url: URL, profileID: ProfileID, foreground: Bool) -> PeekSyntheticSurface? {
        guard let adopt = tabAdoption[windowID] else { return nil }
        var created: PeekSyntheticSurface?
        let accepted = adopt(BrowserEngineTabRequest(url: url, profileID: profileID, isForeground: foreground)) {
            precondition(created == nil, "An engine tab can be made only once")
            let surface = PeekSyntheticSurface(profileID: profileID, engine: self)
            surfaces.append(surface)
            created = surface
            return surface
        }
        guard let accepted, accepted === created else {
            created?.dispose()
            return nil
        }
        accepted.navigate(to: url)
        return accepted
    }

    /// Like the WebKit seam: what started the question being asked, during the delegate call.
    func pendingNavigationMetadata(for surface: AnyObject) -> BrowserNavigationMetadata? {
        (surface as? PeekSyntheticSurface)?.pendingMetadata
    }
}

final class PeekSyntheticDocumentView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class PeekSyntheticSurface: BrowserEngineSurface, BrowserLinkGeometrySource {
    var supportsPageTranslation = false
    var translationRestoreCount = 0
    func translationSample() async throws -> BrowserTranslationSample { .init(text: "", language: "") }
    func restoreTranslation() async throws { translationRestoreCount += 1 }
    var linkActivationPoint: NSPoint?
    var linkGeometryResult: BrowserLinkGeometry?
    var linkGeometryPoints: [NSPoint] = []
    func linkGeometry(at point: NSPoint) async -> BrowserLinkGeometry? {
        linkGeometryPoints.append(point)
        return linkGeometryResult
    }
    let profileID: ProfileID
    let hostView = NSView()
    let documentView = PeekSyntheticDocumentView()
    weak var delegate: (any BrowserEngineSurfaceDelegate<PeekSyntheticSurface>)? {
        didSet { onDelegateChange?() }
    }
    /// Tests can interleave a reentrant receiver retirement at the real engine binding boundary.
    var onDelegateChange: (() -> Void)?
    weak var engine: PeekSyntheticEngine?
    var placement = BrowserSurfacePlacement.detached
    var onChange: (() -> Void)?
    var onDispose: (() -> Void)?
    private(set) var isDisposed = false
    private(set) var findDocumentGeneration: UInt64 = 0
    private(set) var pageZoom: Double = 1
    /// Every load the engine started; a reload or replay would appear here.
    private(set) var requestedURLs: [URL] = []
    /// Document state that only survives while the same document lives (a stand-in for form/JS state).
    var documentState: String?
    /// Set while the delegate answers a policy question or a new-target request.
    private(set) var pendingMetadata: BrowserNavigationMetadata?
    /// Every request that left the engine, with its method, as a server would count them.
    private(set) var sentRequests: [(method: String, url: URL)] = []
    private var history: [URL] = []
    private var index = -1

    init(profileID: ProfileID, engine: PeekSyntheticEngine?) {
        self.profileID = profileID
        self.engine = engine
        documentView.autoresizingMask = [.width, .height]
        hostView.addSubview(documentView)
    }

    var currentURL: URL? { history.indices.contains(index) ? history[index] : nil }

    var simulatedLoading = false
    var stopCount = 0

    var navigationState: BrowserNavigationState {
        BrowserNavigationState(url: currentURL, committedURL: currentURL, title: currentURL?.path,
                               isLoading: simulatedLoading, canGoBack: index > 0, canGoForward: index + 1 < history.count)
    }

    /// A programmatic load (address bar, `navigate(to:)`).
    func navigate(to url: URL) { load(url, modifiers: [], metadata: .init(kind: .other, httpMethod: "GET", hasBody: false)) }

    /// A link the user clicked in the document, with the gesture's modifiers.
    func clickLink(to url: URL, modifiers: BrowserModifierKeys = []) {
        load(url, modifiers: modifiers, metadata: .init(kind: .linkActivation, httpMethod: "GET", hasBody: false))
    }

    /// A form submitted with POST, for example with ⇧ held on its submit button.
    func submitForm(to url: URL, modifiers: BrowserModifierKeys = []) {
        load(url, modifiers: modifiers, metadata: .init(kind: .formSubmission, httpMethod: "POST", hasBody: true))
    }

    /// `location.href = …` from a script, whatever modifiers its triggering event carried.
    func scriptNavigate(to url: URL, modifiers: BrowserModifierKeys = []) {
        load(url, modifiers: modifiers, metadata: .init(kind: .other, httpMethod: "GET", hasBody: false))
    }

    private func load(_ url: URL, modifiers: BrowserModifierKeys, metadata: BrowserNavigationMetadata) {
        guard !isDisposed else { return }
        var policy = BrowserNavigationActionPolicy.cancel
        let decision = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: false, fallback: .cancel) { policy = $0 }
        pendingMetadata = metadata
        delegate?.surface(self, decidePolicyFor: BrowserNavigationAction(url: url, isMainFrame: true, modifiers: modifiers),
                          decision: decision)
        pendingMetadata = nil
        decision.endSynchronousTurn()
        guard !isDisposed, policy == .allow else {
            if !isDisposed { delegate?.surfaceDidFailNavigation(self) }
            return
        }
        requestedURLs.append(url)
        sentRequests.append((metadata.httpMethod ?? "GET", url))
        var responsePolicy = BrowserNavigationResponsePolicy.cancel
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html"])!
        let responseDecision = BrowserPolicyDecision<BrowserNavigationResponsePolicy>(canSuspend: false, fallback: .cancel) {
            responsePolicy = $0
        }
        delegate?.surface(self, decidePolicyFor: BrowserNavigationResponse(response: response, canShowMIMEType: true,
                                                                            isForMainFrame: true), decision: responseDecision)
        responseDecision.endSynchronousTurn()
        guard !isDisposed, responsePolicy == .allow else { return }
        history = Array(history.prefix(index + 1)) + [url]
        index = history.count - 1
        commit()
    }

    func goBack() -> URL? { move(by: -1) }
    func goForward() -> URL? { move(by: 1) }

    private func move(by offset: Int) -> URL? {
        guard !isDisposed, history.indices.contains(index + offset) else { return nil }
        index += offset
        commit()
        return history[index]
    }

    private func commit() {
        findDocumentGeneration &+= 1
        documentState = nil
        delegate?.surfaceDidStartNavigation(self)
        delegate?.surfaceDidCommitNavigation(self)
        onChange?()
        delegate?.surfaceDidFinishNavigation(self)
    }

    var cacheBypassingReloadCount = 0
    var developerPanels: [BrowserDeveloperPanel] = []
    func reloadIgnoringCache() throws { cacheBypassingReloadCount += 1; reload() }
    func showDeveloperPanel(_ panel: BrowserDeveloperPanel) throws { developerPanels.append(panel) }

    func reload() {
        guard let currentURL else { return }
        requestedURLs.append(currentURL)
        sentRequests.append(("GET", currentURL))
        commit()
    }

    var supportsNativeDuplication = false
    func duplicateWithHistory() -> Bool {
        guard supportsNativeDuplication, let url = currentURL, let clone = openNewTarget(url, userGesture: false) else { return false }
        clone.history = history
        clone.index = index
        clone.commit()
        return true
    }

    func stopLoading() { stopCount += 1; simulatedLoading = false }
    func cancelStoppedNavigationTracking() {}

    func focusDocument() -> Bool {
        guard !isDisposed, let window = hostView.window else { return false }
        return window.makeFirstResponder(documentView)
    }

    func performZoom(_ command: BrowserPageZoomCommand) {
        switch command {
        case .increase: pageZoom += 0.1
        case .decrease: pageZoom -= 0.1
        case .reset: pageZoom = 1
        }
        onChange?()
    }

    func performFind(_ request: BrowserFindRequest, update: @escaping @MainActor (BrowserFindUpdate) -> Void) {
        update(BrowserFindUpdate(token: request.token, documentGeneration: request.documentGeneration,
                                 matchFound: false, final: true, error: .unsupportedOperation))
    }

    func stopFinding(clearSelection: Bool) {}

    func captureSnapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserSurfaceSnapshot {
        throw BrowserEngineError.unsupportedOperation
    }

    func requestMediaState() async -> BrowserMediaState { BrowserMediaState() }
    func setAudioMuted(_ muted: Bool) throws { throw BrowserEngineError.unsupportedOperation }

    /// `target=_blank`, `window.open` or a Chromium modified click: the engine creates the target
    /// and loads the original request in the surface the delegate returned.
    /// `userGesture: false` models a scripted `window.open`.
    @discardableResult
    func openNewTarget(_ url: URL, modifiers: BrowserModifierKeys = [], buttonNumber: Int = 0,
                       userGesture: Bool = true) -> PeekSyntheticSurface? {
        guard let delegate, let engine else { return nil }
        var created: PeekSyntheticSurface?
        pendingMetadata = .init(kind: userGesture ? .linkActivation : .other, httpMethod: "GET", hasBody: false)
        let accepted = delegate.surface(self, createSurfaceFor: BrowserNewSurfaceRequest(
            url: url, modifiers: modifiers, buttonNumber: buttonNumber)) {
            let child = engine.makeSurface(profileID: profileID, delegate: delegate)
            created = child
            return child
        }
        pendingMetadata = nil
        guard let accepted, accepted === created else {
            created?.dispose()
            return nil
        }
        accepted.navigate(to: url)
        return accepted
    }

    func requestClose() { delegate?.surfaceDidRequestClose(self) }

    func requestPermission(_ request: BrowserPermissionRequest) async -> BrowserPermissionDecision {
        guard let delegate else { return .deny }
        return await delegate.surface(self, requestsPermission: request)
    }

    @discardableResult
    func startDownload(named name: String) -> PeekSyntheticDownload {
        let download = PeekSyntheticDownload(name: name, sourceURL: currentURL)
        if let delegate { delegate.surface(self, didStartDownload: download) } else { download.cancel() }
        return download
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        onDispose?()
        onDispose = nil
        onChange = nil
        delegate = nil
        hostView.removeFromSuperview()
    }
}

@MainActor
final class PeekSyntheticDownload: BrowserEngineDownload {
    let suggestedFilename: String
    let sourceURL: URL?
    private(set) var isCancelled = false
    private(set) var transfer: PeekSyntheticDownloadTransfer?

    init(name: String, sourceURL: URL?) {
        suggestedFilename = name
        self.sourceURL = sourceURL
    }

    func cancel() { isCancelled = true }

    func makeTransfer(chooseDestination: @escaping @MainActor (String) async -> URL?) -> any BrowserEngineDownloadTransfer {
        let transfer = PeekSyntheticDownloadTransfer()
        self.transfer = transfer
        return transfer
    }
}

@MainActor
final class PeekSyntheticDownloadTransfer: BrowserEngineDownloadTransfer {
    var onInvalidate: (() -> Void)?
    private(set) var registration: BrowserDownloadRegistration?

    func attach(_ registration: BrowserDownloadRegistration) { self.registration = registration }

    func perform(_ action: BrowserDownloadAction, completion: @escaping @MainActor (Result<Void, BrowserDownloadError>) -> Void) {
        completion(.success(()))
    }

    func invalidate() {
        onInvalidate?()
        onInvalidate = nil
    }
}
