import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import WebKit

@MainActor
public final class WebKitSurface: BrowserEngineSurface {
    public let profileID: ProfileID
    public let webView: WKWebView
    public var hostView: NSView { webView }
    public var currentURL: URL? { requestedDestination ?? webView.url }
    public var onChange: (() -> Void)?
    public var onDispose: (() -> Void)?
    public weak var delegate: (any BrowserEngineSurfaceDelegate<WebKitSurface>)?
    public var placement = BrowserSurfacePlacement.detached
    public private(set) var committedURL: URL?
    public private(set) var findDocumentGeneration: UInt64 = 0
    public private(set) var isDisposed = false
    /// WebKit closes the document synchronously in `dispose()`.
    public private(set) var isTeardownComplete = false
    /// See `WebKitActionMetadata`; set only while the delegate answers a policy question or a new
    /// target request of this surface.
    public internal(set) var pendingActionMetadata: WebKitActionMetadata?
    var isProvisionalNavigationInFlight = false
    weak var engine: WebKitBrowserEngine?
    let zoomStore: WebKitPageZoomStore
    private let bridge = WebKitNavigationBridge()
    private var findToken: UUID?
    private var observations: [NSKeyValueObservation] = []
    private var requestedDestination: URL?
    private var requestedNavigation: WKNavigation?
    /// The address of the current document, updated by commits and same-document navigations.
    private var documentURL: URL?
    /// Policy questions suspended by a delegate; answered with their fallback on disposal.
    private var openDecisions: [UUID: () -> Void] = [:]

    public var navigationState: BrowserNavigationState {
        BrowserNavigationState(url: webView.url, committedURL: committedURL, title: webView.title,
                               isLoading: webView.isLoading, canGoBack: webView.canGoBack,
                               canGoForward: webView.canGoForward)
    }

    public var pageZoom: Double { Double(webView.pageZoom) }

    /// A standalone surface outside any engine, with its own zoom scope. Used by tests.
    public convenience init(profileID: ProfileID, dataStore: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        self.init(profileID: profileID, configuration: configuration)
    }

    public convenience init(profileID: ProfileID, configuration: WKWebViewConfiguration) {
        self.init(profileID: profileID, configuration: configuration, engine: nil, zoomStore: WebKitPageZoomStore())
    }

    init(profileID: ProfileID, configuration: WKWebViewConfiguration,
         engine: WebKitBrowserEngine?, zoomStore: WebKitPageZoomStore) {
        self.profileID = profileID
        self.engine = engine
        self.zoomStore = zoomStore
        webView = WebKitDocumentView(frame: .zero, configuration: configuration)
        bridge.surface = self
        webView.navigationDelegate = bridge
        webView.uiDelegate = bridge
        observations = [
            webView.observe(\.title) { [weak self] _, _ in self?.scheduleRefresh() },
            webView.observe(\.url) { [weak self] _, _ in
                self?.scheduleRefresh()
                self?.scheduleSameDocumentCheck()
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.scheduleRefresh() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.scheduleRefresh() },
            webView.observe(\.cameraCaptureState) { [weak self] _, _ in self?.scheduleRefresh() },
            webView.observe(\.microphoneCaptureState) { [weak self] _, _ in self?.scheduleRefresh() }
        ]
        zoomStore.register(self)
        engine?.registerPermissionSurface(self)
    }

    nonisolated private func scheduleSameDocumentCheck() {
        Task { @MainActor [weak self] in self?.reportSameDocumentNavigation() }
    }

    /// Public WebKit has no same-document callback: an address change outside a provisional
    /// navigation, without a commit, is a fragment or History API navigation. WebKit shows the
    /// address of a shell request (`load`, `goBack`) before its provisional navigation starts, so
    /// that address is never taken for a same-document change.
    private func reportSameDocumentNavigation() {
        guard !isDisposed, !isProvisionalNavigationInFlight, let documentURL, let url = webView.url, url != documentURL,
              requestedNavigation == nil || url != requestedDestination else { return }
        self.documentURL = url
        delegate?.surface(self, didNavigateWithinDocument: BrowserSameDocumentNavigation(url: url, previous: documentURL))
    }

    nonisolated private func scheduleRefresh() {
        Task { @MainActor [weak self] in
            guard let self, !isDisposed else { return }
            onChange?()
        }
    }

    // MARK: Navigation

    public func navigate(to url: URL) {
        let navigation = url.isFileURL
            ? webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            : webView.load(URLRequest(url: url))
        recordNavigation(navigation, to: url)
    }

    @discardableResult
    public func goBack() -> URL? {
        guard let url = webView.backForwardList.backItem?.url else { return nil }
        recordNavigation(webView.goBack(), to: url)
        return url
    }

    @discardableResult
    public func goForward() -> URL? {
        guard let url = webView.backForwardList.forwardItem?.url else { return nil }
        recordNavigation(webView.goForward(), to: url)
        return url
    }

    public func reload() { webView.reload() }
    public func reloadIgnoringCache() throws { webView.reloadFromOrigin() }
    public func stopLoading() { webView.stopLoading() }

    func recordNavigation(_ navigation: WKNavigation?, to url: URL) {
        guard navigation != nil else { return }
        requestedNavigation = navigation
        requestedDestination = url
    }

    func navigationCommitted(_ navigation: WKNavigation?) {
        findToken = nil
        findDocumentGeneration &+= 1
        committedURL = webView.url
        documentURL = webView.url
        guard let navigation, navigation === requestedNavigation else { return }
        requestedNavigation = nil
        requestedDestination = nil
    }

    func navigationFailed(_ navigation: WKNavigation?) {
        guard let navigation, navigation === requestedNavigation else { return }
        requestedNavigation = nil
        requestedDestination = nil
    }

    /// A refused shell request never starts: it no longer owns the displayed address.
    func shellRequestRefused(_ url: URL?) {
        guard url != nil, url == requestedDestination else { return }
        requestedNavigation = nil
        requestedDestination = nil
    }

    public func cancelStoppedNavigationTracking() {
        requestedNavigation = nil
        requestedDestination = nil
    }

    /// WebKit's policy hooks are asynchronous, so a delegate may suspend: the original request
    /// stays inside WebKit until the answer and is never replayed.
    func askPolicy<Policy: Sendable & Equatable>(
        fallback: Policy, _ ask: (BrowserPolicyDecision<Policy>) -> Void
    ) async -> Policy {
        await withCheckedContinuation { continuation in
            let id = UUID()
            let decision = BrowserPolicyDecision<Policy>(canSuspend: true, fallback: fallback) { [weak self] policy in
                self?.openDecisions.removeValue(forKey: id)
                continuation.resume(returning: policy)
            }
            openDecisions[id] = { decision.abandon() }
            ask(decision)
            decision.endSynchronousTurn()
        }
    }

    /// Contract metadata of a WebKit navigation action. WebKit does not expose user gestures,
    /// and may strip request bodies from the UI process (`hasBody` nil for a body-less POST).
    func describe(_ action: WKNavigationAction) -> BrowserNavigationAction {
        let isMainFrame = action.targetFrame?.isMainFrame
        let kind: BrowserNavigationKind = switch action.navigationType {
        case .linkActivated: .linkActivation
        case .formSubmitted, .formResubmitted: .formSubmission
        case .backForward: .backForward
        case .reload: .reload
        default:
            if let url = action.request.url, url == requestedDestination { .typed }
            else if isMainFrame != false, isProvisionalNavigationInFlight { .redirect }
            else { .other }
        }
        return BrowserNavigationAction(
            url: action.request.url, shouldPerformDownload: action.shouldPerformDownload, isMainFrame: isMainFrame,
            modifiers: BrowserModifierKeys(action.modifierFlags),
            buttonNumber: WebKitNavigationBridge.contractButtonNumber(action.buttonNumber), kind: kind,
            httpMethod: action.request.httpMethod?.uppercased(), hasBody: Self.hasBody(action.request),
            isUserGesture: nil, disposition: action.targetFrame == nil ? .newWindow : .currentTab)
    }

    static func hasBody(_ request: URLRequest) -> Bool? {
        if request.httpBody != nil || request.httpBodyStream != nil { return true }
        let method = request.httpMethod?.uppercased() ?? "GET"
        return method == "GET" || method == "HEAD" ? false : nil
    }

    public func focusDocument() -> Bool {
        guard !isDisposed, let window = webView.window else { return false }
        return window.makeFirstResponder(webView)
    }

    // MARK: Page tools

    public func performZoom(_ command: BrowserPageZoomCommand) {
        zoomStore.perform(command, on: self)
    }

    public func performFind(
        _ request: BrowserFindRequest,
        update: @escaping @MainActor (BrowserFindUpdate) -> Void
    ) {
        guard !isDisposed, request.documentGeneration == findDocumentGeneration else { return }
        // Public WebKit always selects a match. It cannot implement a count-only request.
        guard request.selectMatch else {
            update(BrowserFindUpdate(token: request.token, documentGeneration: request.documentGeneration,
                                     matchFound: false, final: true, error: .unsupportedOperation))
            return
        }
        findToken = request.token
        let configuration = WKFindConfiguration()
        configuration.backwards = !request.forward
        configuration.caseSensitive = request.matchCase
        configuration.wraps = true
        webView.find(request.query, configuration: configuration) { [weak self] result in
            guard let self, !isDisposed, findToken == request.token,
                  findDocumentGeneration == request.documentGeneration else { return }
            update(BrowserFindUpdate(token: request.token, documentGeneration: request.documentGeneration,
                                     matchFound: result.matchFound, final: true))
        }
    }

    public func stopFinding(clearSelection: Bool) {
        findToken = nil
        guard !isDisposed, clearSelection else { return }
        webView.find("", configuration: WKFindConfiguration()) { _ in }
    }

    public func captureSnapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserSurfaceSnapshot {
        guard !request.fullPage else { throw BrowserEngineError.unsupportedOperation }
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        let generation = findDocumentGeneration
        if let expected = request.documentGeneration, expected != generation { throw BrowserEngineError.documentChanged }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = request.afterScreenUpdates
        if let width = request.width { configuration.snapshotWidth = NSNumber(value: Double(width)) }
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        // A commit during capture makes the image ambiguous; never label it with either document.
        guard findDocumentGeneration == generation else { throw BrowserEngineError.documentChanged }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw BrowserEngineError.snapshotUnavailable
        }
        return BrowserSurfaceSnapshot(image: cgImage, documentGeneration: generation)
    }

    public func requestMediaState() async -> BrowserMediaState {
        guard !isDisposed else { return BrowserMediaState() }
        let playback: BrowserMediaPlaybackState = switch await webView.requestMediaPlaybackState() {
        case .none: .none
        case .playing: .playing
        case .paused: .paused
        case .suspended: .suspended
        @unknown default: .unknown
        }
        // Public WebKit does not report audibility or page muting.
        return BrowserMediaState(playback: playback, camera: Self.captureState(webView.cameraCaptureState),
                                 microphone: Self.captureState(webView.microphoneCaptureState))
    }

    /// CH-ESSENTIALS: WebKit's print operation as a sheet of the surface's window.
    public func perform(_ command: BrowserPageCommand) throws {
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        guard command == .print, let window = webView.window else { throw BrowserEngineError.unsupportedOperation }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    public func setAudioMuted(_ muted: Bool) throws {
        throw BrowserEngineError.unsupportedOperation
    }

    private static func captureState(_ state: WKMediaCaptureState) -> BrowserMediaCaptureState {
        switch state {
        case .none: .none
        case .active: .active
        case .muted: .muted
        @unknown default: .unknown
        }
    }

    // MARK: Lifetime

    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        findToken = nil
        onDispose?()
        onDispose = nil
        for observation in observations { observation.invalidate() }
        observations.removeAll()
        onChange = nil
        delegate = nil
        requestedNavigation = nil
        requestedDestination = nil
        let decisions = openDecisions.values
        openDecisions.removeAll()
        for abandon in decisions { abandon() }
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        isTeardownComplete = true
    }
}

/// How WebKit started the navigation or new target that the delegate is being asked about.
/// Interim adapter seam (PEEK-R2) until CONTRACT-R2 carries navigation kind, method and gesture
/// in `BrowserNavigationAction`/`BrowserNewSurfaceRequest`. Public WebKit cannot tell a user
/// click from a script-dispatched click event on a link: both are `.linkActivated`.
public struct WebKitActionMetadata: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case linkActivated, formSubmitted, backForward, reload, formResubmitted
        /// A main-frame question while a provisional navigation is in flight: a server redirect
        /// or an interrupted load. Never treated as a user link activation.
        case redirect
        case other
    }

    public let kind: Kind
    public let httpMethod: String?
    public let hasBody: Bool

    public init(kind: Kind, httpMethod: String?, hasBody: Bool) {
        self.kind = kind
        self.httpMethod = httpMethod
        self.hasBody = hasBody
    }

    @MainActor init(_ action: WKNavigationAction, isRedirect: Bool) {
        let kind: Kind = switch action.navigationType {
        case .linkActivated: .linkActivated
        case .formSubmitted: .formSubmitted
        case .backForward: .backForward
        case .reload: .reload
        case .formResubmitted: .formResubmitted
        case .other: .other
        @unknown default: .other
        }
        self.init(kind: isRedirect ? .redirect : kind, httpMethod: action.request.httpMethod,
                  hasBody: action.request.httpBody != nil || action.request.httpBodyStream != nil)
    }
}

extension WebKitSurface {
    /// Runs `body` with `pendingActionMetadata` describing the question being asked.
    func withActionMetadata<Result>(_ metadata: WebKitActionMetadata, _ body: () -> Result) -> Result {
        let previous = pendingActionMetadata
        pendingActionMetadata = metadata
        defer { pendingActionMetadata = previous }
        return body()
    }
}

/// Translates WebKit delegate callbacks into engine-independent surface events. It is the only
/// `WKNavigationDelegate`/`WKUIDelegate` of an engine surface; the shell never sees WebKit types.
@MainActor
final class WebKitNavigationBridge: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var surface: WebKitSurface?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let surface, !surface.isDisposed, let delegate = surface.delegate else { return .cancel }
        let action = surface.describe(navigationAction)
        // Interim PEEK-R2 seam kept for source compatibility; the contract fields now carry it.
        let metadata = WebKitActionMetadata(navigationAction, isRedirect: action.kind == .redirect)
        let policy = await surface.askPolicy(fallback: BrowserNavigationActionPolicy.cancel) { decision in
            surface.withActionMetadata(metadata) { delegate.surface(surface, decidePolicyFor: action, decision: decision) }
        }
        if policy == .cancel, action.isMainFrame == true { surface.shellRequestRefused(action.url) }
        switch policy {
        case .allow: return .allow
        case .cancel: return .cancel
        case .download: return .download
        }
    }

    /// WebKit leaves download-versus-render to its client; the adapter applies Chromium's native
    /// rule itself (non-renderable MIME type or `Content-Disposition: attachment` downloads), so
    /// the shell never has to answer `.download` for a response to be downloaded.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard let surface, !surface.isDisposed, let delegate = surface.delegate else { return .cancel }
        let response = BrowserNavigationResponse(response: navigationResponse.response,
                                                 canShowMIMEType: navigationResponse.canShowMIMEType,
                                                 isForMainFrame: navigationResponse.isForMainFrame)
        let policy = await surface.askPolicy(fallback: BrowserNavigationResponsePolicy.cancel) {
            delegate.surface(surface, decidePolicyFor: response, decision: $0)
        }
        switch policy {
        case .allow: return Self.downloadsNatively(navigationResponse) ? .download : .allow
        case .cancel: return .cancel
        case .download: return .download
        }
    }

    static func downloadsNatively(_ response: WKNavigationResponse) -> Bool {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        return !response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment")
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A new target must stay in the source profile's store; WebKit supplies the configuration
        // that carries the original request and opener.
        guard let surface, !surface.isDisposed, let delegate = surface.delegate,
              configuration.websiteDataStore === webView.configuration.websiteDataStore else { return nil }
        let action = surface.describe(navigationAction)
        let request = BrowserNewSurfaceRequest(
            url: navigationAction.request.url, modifiers: action.modifiers, buttonNumber: action.buttonNumber,
            kind: action.kind == .typed || action.kind == .redirect ? .other : action.kind,
            httpMethod: action.httpMethod, hasBody: action.hasBody, isUserGesture: nil,
            disposition: Self.newTargetDisposition(action.modifiers, buttonNumber: action.buttonNumber,
                                                   features: windowFeatures))
        var created: WebKitSurface?
        let accepted = surface.withActionMetadata(WebKitActionMetadata(navigationAction, isRedirect: false)) {
            delegate.surface(surface, createSurfaceFor: request) {
                precondition(created == nil, "A new target surface can be created only once")
                let child = WebKitSurface(profileID: surface.profileID, configuration: configuration,
                                          engine: surface.engine, zoomStore: surface.zoomStore)
                // WebKit opens the target in its opener's content process.
                (child.webView as? WebKitDocumentView)?.contentProcessDidStart()
                child.delegate = delegate
                created = child
                return child
            }
        }
        guard let accepted, accepted === created else {
            created?.dispose()
            return nil
        }
        return accepted.webView
    }

    /// Chrome's dispositions for modified clicks; sized `window.open` requests are popups.
    static func newTargetDisposition(_ modifiers: BrowserModifierKeys, buttonNumber: Int,
                                     features: WKWindowFeatures) -> BrowserNavigationDisposition {
        if buttonNumber == 2 || (modifiers.contains(.command) && !modifiers.contains(.shift)) { return .newBackgroundTab }
        if modifiers.contains(.command) { return .newForegroundTab }
        if modifiers.contains(.shift) { return .newWindow }
        if features.width != nil || features.height != nil || features.x != nil || features.y != nil { return .popup }
        return .newForegroundTab
    }

    static func contractButtonNumber(_ webKitButton: Int) -> Int {
        switch webKitButton {
        case 2: 1
        case 4: 2
        default: 0
        }
    }

    /// The page is gone until the next load relaunches a process; key equivalents must reach
    /// the menu meanwhile (see `WebKitDocumentView`).
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        (webView as? WebKitDocumentView)?.contentProcessDidTerminate()
        // CH-ESSENTIALS: the shell shows its crashed page; reload starts a new process.
        guard let surface, !surface.isDisposed else { return }
        surface.delegate?.surface(surface, rendererDidTerminate: .unknown)
        surface.delegate?.surfaceDidFailNavigation(surface)
    }

    // MARK: Page surfaces (CH-ESSENTIALS)

    private static func origin(of frame: WKFrameInfo) -> String? {
        let origin = frame.securityOrigin
        guard !origin.host.isEmpty else { return nil }
        let port = origin.port == 0 ? "" : ":\(origin.port)"
        return "\(origin.protocol)://\(origin.host)\(port)"
    }

    private func dialog(_ kind: BrowserJavaScriptDialog.Kind, _ message: String,
                        _ frame: WKFrameInfo) async -> BrowserJavaScriptDialogResponse {
        guard let surface, !surface.isDisposed, let delegate = surface.delegate else { return .suppressed }
        return await delegate.surface(surface, runJavaScriptDialog: BrowserJavaScriptDialog(
            kind: kind, message: message, origin: Self.origin(of: frame)))
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await dialog(.alert, message, frame)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        if case .accept = await dialog(.confirm, message, frame) { return true }
        return false
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        if case .accept(let text) = await dialog(.prompt(defaultText: defaultText ?? ""), prompt, frame) { return text ?? "" }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        guard let surface, !surface.isDisposed, let delegate = surface.delegate else { return nil }
        let mode: BrowserFileChooserRequest.Mode = parameters.allowsDirectories ? .openFolder
            : parameters.allowsMultipleSelection ? .openMultiple : .open
        // WebKit does not pass the accept filters through its public API.
        return await delegate.surface(surface, runFileChooser: BrowserFileChooserRequest(mode: mode))
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let methods = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                       NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodDefault]
        guard methods.contains(space.authenticationMethod), let surface, !surface.isDisposed,
              let delegate = surface.delegate else { return (.performDefaultHandling, nil) }
        let scheme = space.protocol ?? "https"
        let challengeValue = BrowserAuthenticationChallenge(
            origin: "\(scheme)://\(space.host)\(space.port == 0 ? "" : ":\(space.port)")", host: space.host, port: space.port,
            realm: space.realm?.isEmpty == false ? space.realm : nil,
            scheme: space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest ? "digest" : "basic",
            isProxy: space.isProxy())
        guard let credential = await delegate.surface(surface, requestsCredentialsFor: challengeValue) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(user: credential.user, password: credential.password, persistence: .forSession))
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let surface else { return }
        surface.delegate?.surfaceDidRequestClose(surface)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        deliver(download, from: webView, suggestedFilename: navigationAction.request.url?.lastPathComponent ?? "Download")
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        deliver(download, from: webView, suggestedFilename: navigationResponse.response.suggestedFilename ?? "Download")
    }

    private func deliver(_ download: WKDownload, from webView: WKWebView, suggestedFilename: String) {
        guard let surface, let delegate = surface.delegate else {
            download.cancel(nil)
            return
        }
        let engineDownload = WebKitEngineDownload(
            download: download, dataStore: webView.configuration.websiteDataStore,
            suggestedFilename: suggestedFilename,
            resumeDownload: surface.engine?.resumeDownload ?? WebKitDownloadTransfer.defaultResumeDownload)
        delegate.surface(surface, didStartDownload: engineDownload)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Covers loads WebKit starts itself (restoration, new targets) without a public entry point.
        (webView as? WebKitDocumentView)?.contentProcessDidStart()
        guard let surface else { return }
        surface.isProvisionalNavigationInFlight = true
        surface.delegate?.surfaceDidStartNavigation(surface)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        (webView as? WebKitDocumentView)?.contentProcessDidStart()
        surface?.isProvisionalNavigationInFlight = false
        guard let surface, !surface.isDisposed else { return }
        surface.navigationCommitted(navigation)
        surface.zoomStore.documentDidCommit(surface)
        surface.delegate?.surfaceDidCommitNavigation(surface)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let surface else { return }
        surface.delegate?.surfaceDidFinishNavigation(surface)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(navigation)
    }

    private func failed(_ navigation: WKNavigation?) {
        surface?.isProvisionalNavigationInFlight = false
        guard let surface, !surface.isDisposed else { return }
        surface.navigationFailed(navigation)
        surface.delegate?.surfaceDidFailNavigation(surface)
    }

    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo) async -> WKPermissionDecision {
        await decidePermission(origin: origin, frame: frame, kind: .geolocation)
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let kind: BrowserPermissionKind = switch type {
        case .camera: .camera
        case .microphone: .microphone
        case .cameraAndMicrophone: .cameraAndMicrophone
        @unknown default: .other("media-capture")
        }
        return await decidePermission(origin: origin, frame: frame, kind: kind)
    }

    private func decidePermission(origin: WKSecurityOrigin, frame: WKFrameInfo,
                                  kind: BrowserPermissionKind) async -> WKPermissionDecision {
        guard let surface, !surface.isDisposed, let delegate = surface.delegate else { return .deny }
        let generation = surface.findDocumentGeneration
        let port = origin.port == 0 ? "" : ":\(origin.port)"
        let host = origin.host.contains(":") && !origin.host.hasPrefix("[") ? "[\(origin.host)]" : origin.host
        let request = BrowserPermissionRequest(kind: kind, origin: "\(origin.protocol)://\(host)\(port)",
                                               isMainFrame: frame.isMainFrame)
        let decision = await delegate.surface(surface, requestsPermission: request)
        guard !surface.isDisposed, surface.findDocumentGeneration == generation else { return .deny }
        switch decision {
        case .grant, .grantOnce: return .grant
        case .deny: return .deny
        case .engineDefault: return .prompt
        }
    }
}

extension BrowserModifierKeys {
    init(_ flags: NSEvent.ModifierFlags) {
        var keys: BrowserModifierKeys = []
        if flags.contains(.command) { keys.insert(.command) }
        if flags.contains(.shift) { keys.insert(.shift) }
        if flags.contains(.option) { keys.insert(.option) }
        if flags.contains(.control) { keys.insert(.control) }
        self = keys
    }
}
