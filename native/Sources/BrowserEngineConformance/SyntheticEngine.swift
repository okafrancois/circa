import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation

/// A windowless reference engine that implements the contract with plain AppKit views, proving
/// that the contract needs no web engine framework and giving shell features (BrowserShell and
/// Orbit tests) a deterministic test double. Never linked into the application.
/// It models stock CEF where the contract is strict: policy questions must be answered
/// synchronously (no `suspendablePolicyDecisions`), there is no response policy question
/// (`navigationResponsePolicy`) and no download conversion, the document responder is a child of a
/// plain host view, teardown completes asynchronously after `dispose()` (`teardown`), and with
/// `.deferred` readiness the native host appears one turn after creation, as with `OnAfterCreated`.
@MainActor
public final class SyntheticEngine: BrowserEngine, BrowserPagePrinting {
    public private(set) var printedSurfaces: [ObjectIdentifier] = []
    public func printPage(_ surface: SyntheticSurface) throws {
        guard !surface.isDisposed else { throw BrowserEngineError.surfaceDisposed }
        try surface.perform(.print)
        printedSurfaces.append(ObjectIdentifier(surface))
    }
    public enum Readiness: Sendable {
        /// The host exists on creation; events of a navigation arrive synchronously inside it.
        case immediate
        /// The host appears on a later main-actor turn; earlier commands are queued in order.
        case deferred
    }

    /// When the native close of a disposed surface completes, as CEF's `OnBeforeClose` would.
    public enum Teardown: Equatable, Sendable {
        case nextTurn
        case delayed(Duration)
        /// Never completes: `shutdown()` does not return (a hung engine).
        case never
    }

    public let kind = BrowserEngineKind.synthetic
    public var capabilities: BrowserEngineCapabilities {
        BrowserEngineCapabilities([.liveSurfaceTransfer, .profileRemoval, .printing]).union(extraCapabilities)
    }
    /// Capabilities a test turns on (CH-ESSENTIALS: page context menus, beforeunload, DevTools, print).
    public var extraCapabilities: BrowserEngineCapabilities = []
    public let readiness: Readiness
    public var teardown: Teardown
    public var extensions: (any BrowserExtensionHost)? { nil }
    public var conformanceProbe: (any BrowserEngineConformanceProbe<SyntheticSurface>)? { SyntheticConformanceProbe() }
    public private(set) var profiles: [ProfileID: BrowserEngineProfile] = [:]
    public private(set) var surfaces: [SyntheticSurface] = []
    public private(set) var isShutDown = false
    /// Disposed surfaces whose native close has not completed yet.
    public internal(set) var pendingTeardowns = 0
    private var siteData: [ProfileID: SyntheticSiteData] = [:]

    /// Shell windows the shell announced (CHROMIUM-APP), each with its NSWindow; and the closed ones.
    public private(set) var shellWindows: [WindowID: ObjectIdentifier] = [:]
    public private(set) var closedShellWindows: [WindowID] = []

    public func shellWindowDidOpen(_ windowID: WindowID, window: NSWindow) {
        shellWindows[windowID] = ObjectIdentifier(window)
    }

    public func shellWindowWillClose(_ windowID: WindowID) {
        shellWindows[windowID] = nil
        closedShellWindows.append(windowID)
    }

    /// Native moves announced by the shell (surface tokens, destination), and whether to refuse.
    public private(set) var announcedMoves: [(surfaces: [ObjectIdentifier], windowID: WindowID)] = []
    public var refusesMoves = false
    /// The latest tab order the shell published for each window.
    public private(set) var tabOrders: [WindowID: [ObjectIdentifier]] = [:]

    public func shellWillMoveSurfaces(_ surfaces: [SyntheticSurface], toWindow windowID: WindowID) -> Bool {
        announcedMoves.append((surfaces.map(ObjectIdentifier.init), windowID))
        return !refusesMoves
    }

    /// Settlements of announced moves (surface tokens, destination, committed).
    public private(set) var finishedMoves: [(surfaces: [ObjectIdentifier], windowID: WindowID, committed: Bool)] = []

    public func shellDidFinishMovingSurfaces(_ surfaces: [SyntheticSurface], toWindow windowID: WindowID, committed: Bool) {
        finishedMoves.append((surfaces.map(ObjectIdentifier.init), windowID, committed))
    }

    public func shellWindowTabOrderDidChange(_ windowID: WindowID, surfaces: [SyntheticSurface]) {
        tabOrders[windowID] = surfaces.map(ObjectIdentifier.init)
    }

    public init(readiness: Readiness = .immediate, teardown: Teardown = .nextTurn) {
        self.readiness = readiness
        self.teardown = teardown
    }

    public func profile(for profileID: ProfileID) -> BrowserEngineProfile {
        if let existing = profiles[profileID] { return existing }
        let profile = BrowserEngineProfile(profileID: profileID, persistence: .ephemeral)
        profiles[profileID] = profile
        siteData[profileID] = SyntheticSiteData()
        return profile
    }

    public func makeSurface(profileID: ProfileID,
                            delegate: any BrowserEngineSurfaceDelegate<SyntheticSurface>) -> SyntheticSurface {
        let surface = makeSurface(profileID: profileID)
        surface.delegate = delegate
        return surface
    }

    public func makeSurface(profileID: ProfileID) -> SyntheticSurface {
        _ = profile(for: profileID)
        let surface = SyntheticSurface(profileID: profileID, engine: self, siteData: siteData[profileID]!,
                                       isReady: readiness == .immediate)
        if readiness == .deferred {
            Task { @MainActor [weak surface] in surface?.becomeReady() }
        }
        surfaces.append(surface)
        return surface
    }

    public func removeProfile(_ profileID: ProfileID) async throws {
        guard !surfaces.contains(where: { $0.profileID == profileID && !$0.isDisposed }) else { throw BrowserEngineError.profileInUse }
        while surfaces.contains(where: { $0.profileID == profileID && !$0.isTeardownComplete }) {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
            guard !surfaces.contains(where: { $0.profileID == profileID && !$0.isDisposed }) else { throw BrowserEngineError.profileInUse }
        }
        siteData[profileID]?.cookies.removeAll()
        siteData[profileID] = nil
        profiles[profileID] = nil
    }

    /// Returns once every disposed surface reported its teardown, or early, without shutting
    /// down, when its task is cancelled (a caller's deadline elapsed).
    public func shutdown() async {
        while pendingTeardowns > 0 {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        isShutDown = true
    }
}

/// Per-profile site data, shared by every surface of the profile.
@MainActor
final class SyntheticSiteData {
    var cookies: [String: String] = [:]
}

@MainActor
final class SyntheticConformanceProbe: BrowserEngineConformanceProbe {
    func writeSiteDataMarker(_ value: String, for origin: URL, through surface: SyntheticSurface) async throws {
        surface.siteData.cookies[origin.host ?? ""] = value
    }

    func readSiteDataMarker(for origin: URL, through surface: SyntheticSurface) async throws -> String? {
        surface.siteData.cookies[origin.host ?? ""]
    }

    /// The synthetic document has no script engine. It answers only the conformance key probe,
    /// with the keys its document responder received.
    func evaluateScript(_ script: String, in surface: SyntheticSurface) async throws -> String? {
        guard script == BrowserEngineConformance.typedKeysScript else { throw BrowserEngineError.unsupportedOperation }
        return surface.typedKeys
    }
}

/// The responder a real engine places inside its host view. Key presses reach the "page".
public final class SyntheticDocumentView: NSView {
    weak var surface: SyntheticSurface?
    override public var acceptsFirstResponder: Bool { true }

    override public func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            surface?.typedKeys += event.charactersIgnoringModifiers ?? ""
        }
    }
}

@MainActor
public final class SyntheticSurface: BrowserEngineSurface {
    public let profileID: ProfileID
    /// A plain parent view, like the `NSView` handed to CEF; it is not itself focusable.
    public let hostView = NSView()
    public let documentView = SyntheticDocumentView()
    public weak var delegate: (any BrowserEngineSurfaceDelegate<SyntheticSurface>)?
    public weak var engine: SyntheticEngine?
    let siteData: SyntheticSiteData
    public var placement = BrowserSurfacePlacement.detached
    public var onChange: (() -> Void)?
    public var onDispose: (() -> Void)?
    public private(set) var isDisposed = false
    public private(set) var isTeardownComplete = false
    public internal(set) var isReady: Bool
    public private(set) var findDocumentGeneration: UInt64 = 0
    public private(set) var pageZoom: Double = 1
    /// Every new load the engine started, including refused ones; a replay would appear twice.
    public private(set) var requestedURLs: [URL] = []
    /// Every action policy question asked, with its metadata.
    public private(set) var askedActions: [BrowserNavigationAction] = []
    /// Key presses delivered to the document responder.
    public internal(set) var typedKeys = ""
    /// Downloads this document started, in order.
    public private(set) var downloads: [SyntheticDownload] = []
    // CH-ESSENTIALS page surfaces, recorded for shell tests.
    public private(set) var performedContextMenuCommands: [BrowserContextMenuCommand] = []
    public private(set) var closedContextMenus: [BrowserContextMenuRequest] = []
    public private(set) var performedPageCommands: [BrowserPageCommand] = []
    public private(set) var fullscreenExits = 0
    public private(set) var reloads = 0
    /// The page's answer to `confirmClose()` (beforeunload), and how often it was asked.
    public var closeConfirmation = true
    public private(set) var closeConfirmationRequests = 0
    private var pendingCommands: [() -> Void] = []
    private var history: [URL] = []
    private var index = -1
    private let zoomPolicy = try! BrowserPageZoom()

    init(profileID: ProfileID, engine: SyntheticEngine?, siteData: SyntheticSiteData, isReady: Bool = true) {
        self.profileID = profileID
        self.engine = engine
        self.siteData = siteData
        self.isReady = isReady
        documentView.surface = self
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

    public var currentURL: URL? { history.indices.contains(index) ? history[index] : nil }

    public var navigationState: BrowserNavigationState {
        BrowserNavigationState(url: currentURL, committedURL: currentURL, title: currentURL?.host,
                               canGoBack: index > 0, canGoForward: index + 1 < history.count)
    }

    /// Asks for policy synchronously, then commits synchronously: the synthetic engine has no network.
    public func navigate(to url: URL) {
        let action = BrowserNavigationAction(url: url, isMainFrame: true, kind: .typed, httpMethod: "GET",
                                             hasBody: false, isUserGesture: false)
        perform { [weak self] in self?.load(action) }
    }

    /// Simulates a navigation the page starts (link, form, script), with its metadata.
    public func simulateNavigation(
        to url: URL, kind: BrowserNavigationKind, httpMethod: String = "GET", hasBody: Bool = false,
        isUserGesture: Bool = true, modifiers: BrowserModifierKeys = [], buttonNumber: Int = 0
    ) {
        let action = BrowserNavigationAction(url: url, isMainFrame: true, modifiers: modifiers, buttonNumber: buttonNumber,
                                             kind: kind, httpMethod: httpMethod, hasBody: hasBody,
                                             isUserGesture: isUserGesture)
        perform { [weak self] in self?.load(action) }
    }

    /// Simulates a fragment or History API navigation: a new history entry, no new document.
    public func navigateWithinDocument(to url: URL) {
        perform { [weak self] in
            guard let self, let previous = currentURL else { return }
            history = Array(history.prefix(index + 1)) + [url]
            index = history.count - 1
            delegate?.surface(self, didNavigateWithinDocument: BrowserSameDocumentNavigation(url: url, previous: previous))
            onChange?()
        }
    }

    /// Asks the action policy; a refusal is reported as a load error, as stock CEF does.
    private func allows(_ action: BrowserNavigationAction) -> Bool {
        askedActions.append(action)
        var policy = BrowserNavigationActionPolicy.cancel
        let decision = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: false, fallback: .cancel) {
            policy = $0
        }
        delegate?.surface(self, decidePolicyFor: action, decision: decision)
        decision.endSynchronousTurn()
        guard !isDisposed else { return false }
        // Without download conversion, `.download` is `.allow`: the engine's own handler decides.
        guard policy != .cancel else {
            // Stock CEF reports a refused navigation as a load error (ERR_ABORTED).
            delegate?.surfaceDidFailNavigation(self)
            return false
        }
        return true
    }

    private func load(_ action: BrowserNavigationAction) {
        guard let url = action.url else { return }
        requestedURLs.append(url)
        guard allows(action) else { return }
        history = Array(history.prefix(index + 1)) + [url]
        index = history.count - 1
        commit()
    }

    public func goBack() -> URL? { move(by: -1) }
    public func goForward() -> URL? { move(by: 1) }

    private func move(by offset: Int) -> URL? {
        guard history.indices.contains(index + offset) else { return nil }
        let destination = history[index + offset]
        perform { [weak self] in
            guard let self, history.indices.contains(index + offset),
                  allows(BrowserNavigationAction(url: history[index + offset], isMainFrame: true, kind: .backForward,
                                                 httpMethod: "GET", hasBody: false, isUserGesture: false)) else { return }
            index += offset
            commit()
        }
        return destination
    }

    private func commit() {
        findDocumentGeneration &+= 1
        delegate?.surfaceDidStartNavigation(self)
        delegate?.surfaceDidCommitNavigation(self)
        onChange?()
        delegate?.surfaceDidFinishNavigation(self)
    }

    public func reload() {
        reloads += 1
        perform { [weak self] in
            guard let self, let url = currentURL,
                  allows(BrowserNavigationAction(url: url, isMainFrame: true, kind: .reload, httpMethod: "GET",
                                                 hasBody: false, isUserGesture: false)) else { return }
            commit()
        }
    }
    public func stopLoading() {}
    public func cancelStoppedNavigationTracking() {}

    public func focusDocument() -> Bool {
        guard !isDisposed, let window = hostView.window else { return false }
        return window.makeFirstResponder(documentView)
    }

    public func performZoom(_ command: BrowserPageZoomCommand) {
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

    public func performFind(_ request: BrowserFindRequest, update: @escaping @MainActor (BrowserFindUpdate) -> Void) {
        update(BrowserFindUpdate(token: request.token, documentGeneration: request.documentGeneration,
                                 matchFound: false, final: true, error: .unsupportedOperation))
    }

    public func stopFinding(clearSelection: Bool) {}

    public func captureSnapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserSurfaceSnapshot {
        throw BrowserEngineError.unsupportedOperation
    }

    public func requestMediaState() async -> BrowserMediaState { BrowserMediaState() }

    public func setAudioMuted(_ muted: Bool) throws { throw BrowserEngineError.unsupportedOperation }

    // MARK: Page surfaces (CH-ESSENTIALS)

    public func confirmClose() async -> Bool {
        closeConfirmationRequests += 1
        return closeConfirmation
    }

    public func exitElementFullscreen() { fullscreenExits += 1 }

    public func performContextMenuCommand(_ command: BrowserContextMenuCommand, for request: BrowserContextMenuRequest) throws {
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        guard request.documentGeneration == findDocumentGeneration else { throw BrowserEngineError.documentChanged }
        guard request.availableCommands.contains(command.kind) else { throw BrowserEngineError.unsupportedOperation }
        performedContextMenuCommands.append(command)
    }

    public func contextMenuDidClose(_ request: BrowserContextMenuRequest) { closedContextMenus.append(request) }

    public func perform(_ command: BrowserPageCommand) throws {
        guard !isDisposed else { throw BrowserEngineError.surfaceDisposed }
        guard let engine, engine.capabilities.contains(command == .print ? .printing : .devTools) else {
            throw BrowserEngineError.unsupportedOperation
        }
        performedPageCommands.append(command)
    }

    /// Simulates a new target from this document (`window.open`, `target=_blank`, modified click,
    /// form posted to a named target). The engine loads the original request in the accepted
    /// surface, through the delegate that surface has when `createSurfaceFor` returns.
    public func openNewTarget(
        _ url: URL, modifiers: BrowserModifierKeys = [], buttonNumber: Int = 0,
        kind: BrowserNavigationKind = .linkActivation, httpMethod: String = "GET", hasBody: Bool = false,
        disposition: BrowserNavigationDisposition? = nil
    ) -> SyntheticSurface? {
        guard let delegate, let engine else { return nil }
        let background = buttonNumber == 2 || (modifiers.contains(.command) && !modifiers.contains(.shift))
        let request = BrowserNewSurfaceRequest(
            url: url, modifiers: modifiers, buttonNumber: buttonNumber, kind: kind, httpMethod: httpMethod,
            hasBody: hasBody, isUserGesture: true,
            disposition: disposition ?? (background ? .newBackgroundTab
                : modifiers == [.shift] ? .newWindow : .newForegroundTab))
        var created: SyntheticSurface?
        let accepted = delegate.surface(self, createSurfaceFor: request) {
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
        accepted.simulateNavigation(to: url, kind: kind, httpMethod: httpMethod, hasBody: hasBody,
                                    modifiers: modifiers, buttonNumber: buttonNumber)
        return accepted
    }

    /// Simulates `window.close()` from this document.
    public func requestClose() {
        delegate?.surfaceDidRequestClose(self)
    }

    /// Simulates a download the engine decided natively (attachment response, CEF
    /// `OnBeforeDownload`). The current document stays.
    @discardableResult
    public func startDownload(suggestedFilename: String = "synthetic.bin", from url: URL? = nil) -> SyntheticDownload {
        let download = SyntheticDownload(suggestedFilename: suggestedFilename, sourceURL: url ?? currentURL)
        downloads.append(download)
        if !isDisposed, let delegate { delegate.surface(self, didStartDownload: download) } else { download.cancel() }
        return download
    }

    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        onDispose?()
        onDispose = nil
        onChange = nil
        delegate = nil
        pendingCommands.removeAll()
        hostView.removeFromSuperview()
        guard let engine else {
            isTeardownComplete = true
            return
        }
        // Native teardown completes later, as CEF's OnBeforeClose does.
        engine.pendingTeardowns += 1
        let finish: @MainActor () -> Void = { [weak self, weak engine] in
            self?.isTeardownComplete = true
            engine?.pendingTeardowns -= 1
        }
        switch engine.teardown {
        case .nextTurn:
            Task { @MainActor in finish() }
        case .delayed(let delay):
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                finish()
            }
        case .never:
            break
        }
    }
}

/// A download the synthetic engine started. Its transfer accepts commands and never progresses.
@MainActor
public final class SyntheticDownload: BrowserEngineDownload {
    public let suggestedFilename: String
    public let sourceURL: URL?
    public private(set) var isCancelled = false
    public private(set) var transfer: SyntheticDownloadTransfer?

    init(suggestedFilename: String, sourceURL: URL?) {
        self.suggestedFilename = suggestedFilename
        self.sourceURL = sourceURL
    }

    public func cancel() { isCancelled = true }

    public func makeTransfer(
        chooseDestination: @escaping @MainActor (String) async -> URL?
    ) -> any BrowserEngineDownloadTransfer {
        if let transfer { return transfer }
        let created = SyntheticDownloadTransfer()
        transfer = created
        return created
    }
}

@MainActor
public final class SyntheticDownloadTransfer: BrowserEngineDownloadTransfer {
    public var onInvalidate: (() -> Void)?
    public private(set) var registration: BrowserDownloadRegistration?
    public private(set) var isInvalidated = false

    public func attach(_ registration: BrowserDownloadRegistration) { self.registration = registration }

    public func perform(_ action: BrowserDownloadAction,
                        completion: @escaping @MainActor (Result<Void, BrowserDownloadError>) -> Void) {
        completion(.success(()))
    }

    public func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        let callback = onInvalidate
        onInvalidate = nil
        callback?()
    }
}
