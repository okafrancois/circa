import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import ImageIO
import OrbitChromiumBridge
import WebKit
import WebKitEngine

// Protected streaming (DRM-WEBKIT-FALLBACK). Services that refuse an unsigned Widevine host play
// FairPlay in the system WebKit. A tab keeps its ChromiumSurface; for those sites the surface
// shows a WebKitSurface above its (hidden) Chromium document and reports the WebKit document's
// state and events as its own. Each engine keeps its own per-profile site data: cookies set in
// a WebKit document are not visible to Chromium documents, and the reverse.
//
// Routing (`ChromiumBrowserEngine.siteEngine(for:profileID:)`): the per-host choice saved by
// "Reload with WebKit/Chromium", then `BrowserProtectedStreamingSites`.
// - Into WebKit: `navigate(to:)` (address field, bookmarks, restored tabs, Little Circa) and any
//   Chromium main-frame navigation (links, redirects, popups' first load).
// - Out of WebKit: `navigate(to:)` to a Chromium site, and links activated in the page. Redirects,
//   form posts and script navigations stay in WebKit so that sign-in flows keep their cookies.
// - Back from the first WebKit entry shows the Chromium document that was left, unchanged.

extension ChromiumSurface: BrowserSiteEngineSwitching {
    public var siteEngineSwitching: (any BrowserSiteEngineSwitching)? { self }
    public var siteEngine: BrowserSiteEngine { webContent == nil ? .chromium : .webKit }

    @discardableResult
    public func reload(with target: BrowserSiteEngine) -> Bool {
        guard !isDisposed, target != siteEngine, let url = navigationState.committedURL ?? navigationState.url,
              let host = BrowserSitePreferenceStore.host(url) else { return false }
        // Also covers stores that cannot save (private windows): this tab keeps the choice.
        siteEngineOverride = (host, target)
        switch target {
        case .webKit: enterWebContent(url, kind: .reload)
        case .chromium: navigate(to: url)
        }
        return true
    }

    /// The engine this tab uses for a navigation to `url`.
    func siteEngine(for url: URL) -> BrowserSiteEngine {
        if let override = siteEngineOverride, override.host == BrowserSitePreferenceStore.host(url) {
            return override.engine
        }
        return engine?.siteEngine(for: url, profileID: profileID) ?? .chromium
    }

    /// `navigate(to:)`: true when WebKit took the navigation; leaves WebKit for a Chromium site.
    func routeNavigationToWebKit(_ url: URL) -> Bool {
        if siteEngine(for: url) == .webKit, engine?.canHostWebContent == true {
            enterWebContent(url, kind: .typed)
            return true
        }
        if webContent != nil { leaveWebContent() }
        return false
    }

    func shouldMoveChromiumNavigationToWebKit(_ url: URL) -> Bool {
        webContent == nil && siteEngine(for: url) == .webKit && engine?.canHostWebContent == true
    }

    /// Shows `url` in WebKit content, creating it when the tab shows its Chromium document.
    func enterWebContent(_ url: URL, kind: BrowserNavigationKind) {
        guard !isDisposed else { return }
        if let webContent { webContent.surface.navigate(to: url); return }
        guard let engine, let content = engine.makeWebContent(for: self) else { return }
        endPictureInPicture()
        pauseHiddenChromiumMedia()
        install(content)
        onEngineEvent?("webkit-enter", ["kind": kind.rawValue])
        content.surface.navigate(to: url)
    }

    /// A WebKit target created by a WebKit page (`window.open`), in a new tab of the same profile.
    func adoptWebContent(_ content: ChromiumWebContent) {
        install(content)
        onEngineEvent?("webkit-enter", ["kind": "new-target"])
    }

    private func install(_ content: ChromiumWebContent) {
        content.owner = self
        webContent = content
        webContentGeneration &+= 1
        let view = content.surface.hostView
        view.frame = hostView.bounds
        view.autoresizingMask = [.width, .height]
        hostView.addSubview(view, positioned: .above, relativeTo: nil)
        documentView.isHidden = true
        if documentView.window?.firstResponder.map({ ($0 as? NSView)?.isDescendant(of: documentView) == true }) == true {
            documentView.window?.makeFirstResponder(view)
        }
        onChange?()
    }

    /// Removes the WebKit content; the Chromium document shows again as it was left.
    func leaveWebContent() {
        guard let content = webContent else { return }
        webContent = nil
        content.dispose()
        documentView.isHidden = false
        webContentGeneration &+= 1
        onEngineEvent?("webkit-leave", [:])
        onChange?()
    }

    /// Back from WebKit content: WebKit history first, then the Chromium document behind it.
    func webContentGoBack() -> URL? {
        guard let webContent else { return nil }
        if webContent.surface.navigationState.canGoBack { return webContent.surface.goBack() }
        guard let url = chromiumNavigationState.committedURL else { return nil }
        leaveWebContent()
        delegate?.surfaceDidCommitNavigation(self)
        delegate?.surfaceDidFinishNavigation(self)
        return url
    }

    /// A link in the WebKit page leads to a Chromium site: this tab continues there in Chromium.
    func continueInChromium(_ url: URL) {
        guard !isDisposed, webContent != nil else { return }
        navigate(to: url)
    }

    /// The Chromium document stays alive under the WebKit content; it must not keep playing.
    private func pauseHiddenChromiumMedia() {
        guard isBrowserCreated, chromiumNavigationState.committedURL != nil else { return }
        let expression = "document.querySelectorAll('video,audio').forEach(m => { try { m.pause() } catch (e) {} })"
        guard let params = try? JSONSerialization.data(withJSONObject: ["expression": expression]) else { return }
        _ = ACRExecuteDevToolsMethod(token, "Runtime.evaluate", String(decoding: params, as: UTF8.self))
    }

    /// Chromium document events that would overwrite the WebKit document's state.
    static func webContentMasksEvent(_ kind: ACREventKind) -> Bool {
        [ACR_EVENT_ADDRESS, ACR_EVENT_TITLE, ACR_EVENT_LOADING, ACR_EVENT_DOCUMENT, ACR_EVENT_LOAD_END,
         ACR_EVENT_LOAD_ERROR, ACR_EVENT_FAVICON].contains(kind)
    }
}

/// The WebKit document of a ChromiumSurface, its delegate relay and the small services WebKit
/// lacks publicly (tab muting, favicon discovery, audible playback observation).
@MainActor
final class ChromiumWebContent {
    let surface: WebKitSurface
    let relay = ChromiumWebContentRelay()
    weak var owner: ChromiumSurface? {
        didSet { relay.owner = owner }
    }
    private(set) var isAudioMuted = false
    private var favicon: URL?
    private var faviconImage: BrowserFaviconImage?
    private var faviconRevision: UInt64 = 0
    private var faviconSettled = true

    init(surface: WebKitSurface) {
        self.surface = surface
        relay.content = self
        surface.delegate = relay
        ChromiumWebContentMessages.shared.attach(self)
    }

    func navigationState(behind chromium: BrowserNavigationState) -> BrowserNavigationState {
        var state = surface.navigationState
        state.canGoBack = state.canGoBack || chromium.committedURL != nil
        state.faviconURL = favicon
        state.faviconImage = faviconImage
        state.faviconRevision = faviconRevision
        state.faviconMetadataIsSettled = faviconSettled
        return state
    }

    func dispose() {
        ChromiumWebContentMessages.shared.detach(self)
        relay.owner = nil
        surface.dispose()
    }

    // MARK: Find and snapshots (the owner's generation labels the WebKit document)

    func performFind(_ request: BrowserFindRequest, update: @escaping @MainActor (BrowserFindUpdate) -> Void) {
        let outer = request.documentGeneration
        let inner = BrowserFindRequest(token: request.token, documentGeneration: surface.findDocumentGeneration,
                                       query: request.query, forward: request.forward,
                                       matchCase: request.matchCase, selectMatch: request.selectMatch)
        surface.performFind(inner) { [weak self] result in
            guard let owner = self?.owner, owner.findDocumentGeneration == outer else { return }
            update(BrowserFindUpdate(token: result.token, documentGeneration: outer, matchFound: result.matchFound,
                                     count: result.count, activeOrdinal: result.activeOrdinal,
                                     final: result.final, error: result.error))
        }
    }

    func captureSnapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserSurfaceSnapshot {
        guard let owner else { throw BrowserEngineError.surfaceDisposed }
        let outer = owner.findDocumentGeneration
        if let expected = request.documentGeneration, expected != outer { throw BrowserEngineError.documentChanged }
        var inner = request
        inner.documentGeneration = nil
        let snapshot = try await surface.captureSnapshot(inner)
        guard self.owner?.findDocumentGeneration == outer else { throw BrowserEngineError.documentChanged }
        return BrowserSurfaceSnapshot(image: snapshot.image, documentGeneration: outer)
    }

    // MARK: Media

    /// WebKit reports playback but neither audibility nor muting. Audio playing means a main-frame
    /// media element that plays unmuted with volume; muting is applied to media elements from an
    /// isolated script world and observed for elements that start later.
    func requestMediaState() async -> BrowserMediaState {
        var state = await surface.requestMediaState()
        state.isAudioMuted = isAudioMuted
        let playing = try? await surface.webView.evaluateJavaScript(
            "[...document.querySelectorAll('video,audio')].some(m => !m.paused && !m.muted && m.volume > 0)",
            in: nil, contentWorld: .defaultClient) as? Bool
        state.isAudioPlaying = isAudioMuted ? false : playing
        return state
    }

    func setAudioMuted(_ muted: Bool) {
        isAudioMuted = muted
        applyMuting()
    }

    func applyMuting() {
        let script = """
        (() => {
          const muted = \(isAudioMuted ? "true" : "false");
          window.__circaMuted = muted;
          window.__circaMutedByTab = window.__circaMutedByTab || new WeakSet();
          const apply = m => {
            if (window.__circaMuted) { if (!m.muted) { m.muted = true; window.__circaMutedByTab.add(m); } }
            else if (window.__circaMutedByTab.has(m)) { m.muted = false; window.__circaMutedByTab.delete(m); }
          };
          if (!window.__circaMuteHook) {
            window.__circaMuteHook = true;
            document.addEventListener('play', e => { if (e.target instanceof HTMLMediaElement) apply(e.target); }, true);
          }
          document.querySelectorAll('video,audio').forEach(apply);
          return true;
        })()
        """
        surface.webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }

    // MARK: Document events (from the relay)

    func documentDidCommit() {
        favicon = nil
        faviconImage = nil
        faviconSettled = false
        faviconRevision &+= 1
        if isAudioMuted { applyMuting() }
    }

    func documentDidFinish() {
        if isAudioMuted { applyMuting() }
        let script = """
        (() => {
          const pick = s => { const e = document.querySelector(s); return e && e.href ? e.href : null; };
          return pick('link[rel~="icon" i]') || pick('link[rel="apple-touch-icon" i]')
            || new URL('/favicon.ico', location.href).href;
        })()
        """
        let revision = faviconRevision
        surface.webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, let owner = self.owner, !owner.isDisposed, self.faviconRevision == revision else { return }
                let url = (try? result.get() as? String).flatMap(URL.init(string:))
                self.favicon = url.flatMap { BrowserFaviconImage.allowsSourceURL($0) ? $0 : nil }
                guard let icon = self.favicon, ["http", "https"].contains(icon.scheme?.lowercased() ?? "") else {
                    self.faviconSettled = true
                    self.faviconRevision &+= 1
                    owner.onChange?()
                    return
                }
                Task { @MainActor [weak self] in
                    let image = await ChromiumWebContentFavicon.load(icon)
                    guard let self, let owner = self.owner, !owner.isDisposed, self.faviconRevision == revision,
                          self.favicon == icon else { return }
                    self.faviconImage = image
                    self.faviconSettled = true
                    self.faviconRevision &+= 1
                    owner.onChange?()
                }
            }
        }
    }

    func mediaActivityDidChange() { owner?.onChange?() }
}

/// Forwards the WebKit surface's delegate events to the owner's delegate, as events of the owner.
@MainActor
final class ChromiumWebContentRelay: BrowserEngineSurfaceDelegate {
    weak var owner: ChromiumSurface?
    weak var content: ChromiumWebContent?

    private var target: (ChromiumSurface, any BrowserEngineSurfaceDelegate<ChromiumSurface>)? {
        guard let owner, !owner.isDisposed, owner.webContent === content, let delegate = owner.delegate else { return nil }
        return (owner, delegate)
    }

    func surface(_ surface: WebKitSurface, openDroppedFiles urls: [URL]) -> Bool {
        guard case let (owner, delegate)? = target else { return false }
        return delegate.surface(owner, openDroppedFiles: urls)
    }

    func surfaceDidStartNavigation(_ surface: WebKitSurface) {
        guard case let (owner, delegate)? = target else { return }
        owner.onChange?()
        delegate.surfaceDidStartNavigation(owner)
    }

    func surfaceDidCommitNavigation(_ surface: WebKitSurface) {
        guard case let (owner, delegate)? = target else { return }
        owner.webContentGeneration &+= 1
        content?.documentDidCommit()
        owner.onChange?()
        delegate.surfaceDidCommitNavigation(owner)
    }

    func surfaceDidFinishNavigation(_ surface: WebKitSurface) {
        guard case let (owner, delegate)? = target else { return }
        content?.documentDidFinish()
        owner.onChange?()
        delegate.surfaceDidFinishNavigation(owner)
    }

    func surfaceDidFailNavigation(_ surface: WebKitSurface) {
        guard case let (owner, delegate)? = target else { return }
        owner.onChange?()
        delegate.surfaceDidFailNavigation(owner)
    }

    func surface(_ surface: WebKitSurface, didNavigateWithinDocument navigation: BrowserSameDocumentNavigation) {
        guard case let (owner, delegate)? = target else { return }
        delegate.surface(owner, didNavigateWithinDocument: navigation)
    }

    /// The shell answers first (new-tab modifiers, pinned-tab rules, Peek). An allowed link to a
    /// Chromium site is then cancelled in WebKit and continued by Chromium in the same tab.
    func surface(_ surface: WebKitSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        guard case let (owner, delegate)? = target else { decision.decide(.cancel); return }
        let leaves = action.isMainFrame == true && action.kind == .linkActivation
            && action.url.map { BrowserSitePreferenceStore.host($0) != nil && owner.siteEngine(for: $0) == .chromium } == true
        let relayed = BrowserPolicyDecision<BrowserNavigationActionPolicy>(
            canSuspend: decision.canSuspend, fallback: decision.fallback
        ) { [weak owner] policy in
            guard leaves, policy == .allow, let url = action.url else { decision.decide(policy); return }
            decision.decide(.cancel)
            Task { @MainActor in owner?.continueInChromium(url) }
        }
        delegate.surface(owner, decidePolicyFor: action, decision: relayed)
        if relayed.isSuspended { _ = decision.suspend() }
        relayed.endSynchronousTurn()
    }

    func surface(_ surface: WebKitSurface, decidePolicyFor response: BrowserNavigationResponse,
                 decision: BrowserPolicyDecision<BrowserNavigationResponsePolicy>) {
        guard case let (owner, delegate)? = target else { decision.decide(.cancel); return }
        delegate.surface(owner, decidePolicyFor: response, decision: decision)
    }

    /// `window.open` and modified clicks in a WebKit page: a new ChromiumSurface that shows the
    /// WebKit target WebKit created (it keeps its opener and original request).
    func surface(_ surface: WebKitSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> WebKitSurface) -> WebKitSurface? {
        guard let (owner, delegate) = target, let engine = owner.engine else { return nil }
        var created: (outer: ChromiumSurface, inner: WebKitSurface)?
        let accepted = delegate.surface(owner, createSurfaceFor: request) {
            let inner = make()
            let outer = engine.makeSurface(profileID: owner.profileID, delegate: delegate)
            outer.adoptWebContent(ChromiumWebContent(surface: inner))
            created = (outer, inner)
            return outer
        }
        guard let created, let accepted, accepted === created.outer else {
            created?.outer.dispose()
            return nil
        }
        return created.inner
    }

    func surfaceDidRequestClose(_ surface: WebKitSurface) {
        guard case let (owner, delegate)? = target else { return }
        delegate.surfaceDidRequestClose(owner)
    }

    func surfaceDidRequestActivation(_ surface: WebKitSurface) {
        guard case let (owner, delegate)? = target else { return }
        delegate.surfaceDidRequestActivation(owner)
    }

    func surface(_ surface: WebKitSurface, didStartDownload download: any BrowserEngineDownload) {
        guard case let (owner, delegate)? = target else { download.cancel(); return }
        delegate.surface(owner, didStartDownload: download)
    }

    func surface(_ surface: WebKitSurface, requestsPermission request: BrowserPermissionRequest) async -> BrowserPermissionDecision {
        guard case let (owner, delegate)? = target else { return .deny }
        return await delegate.surface(owner, requestsPermission: request)
    }

    func surface(_ surface: WebKitSurface, performNonEditingUndo event: NSEvent, receipt: BrowserKeyReceipt) -> Bool {
        guard case let (owner, delegate)? = target else { return false }
        return delegate.surface(owner, performNonEditingUndo: event, receipt: receipt)
    }

    func surface(_ surface: WebKitSurface, willSendKeyToPage event: NSEvent) -> BrowserKeyRouting {
        guard case let (owner, delegate)? = target else { return .page(receipt: nil) }
        return delegate.surface(owner, willSendKeyToPage: event)
    }

    func surface(_ surface: WebKitSurface, pageDidNotHandleKey event: NSEvent, receipt: BrowserKeyReceipt) -> Bool {
        guard case let (owner, delegate)? = target else { return false }
        return delegate.surface(owner, pageDidNotHandleKey: event, receipt: receipt)
    }

    func surface(_ surface: WebKitSurface, runJavaScriptDialog dialog: BrowserJavaScriptDialog) async -> BrowserJavaScriptDialogResponse {
        guard case let (owner, delegate)? = target else { return .suppressed }
        return await delegate.surface(owner, runJavaScriptDialog: dialog)
    }

    func surfaceDidResetJavaScriptDialogs(_ surface: WebKitSurface) {
        guard case let (owner, delegate)? = target else { return }
        delegate.surfaceDidResetJavaScriptDialogs(owner)
    }

    func surface(_ surface: WebKitSurface, requestsCredentialsFor challenge: BrowserAuthenticationChallenge) async -> BrowserCredential? {
        guard case let (owner, delegate)? = target else { return nil }
        return await delegate.surface(owner, requestsCredentialsFor: challenge)
    }

    func surface(_ surface: WebKitSurface, runFileChooser request: BrowserFileChooserRequest) async -> [URL]? {
        guard case let (owner, delegate)? = target else { return nil }
        return await delegate.surface(owner, runFileChooser: request)
    }

    func surface(_ surface: WebKitSurface, didChangeElementFullscreen isFullscreen: Bool) {
        guard case let (owner, delegate)? = target else { return }
        delegate.surface(owner, didChangeElementFullscreen: isFullscreen)
    }

    func surface(_ surface: WebKitSurface, rendererDidTerminate termination: BrowserRendererTermination) {
        guard case let (owner, delegate)? = target else { return }
        delegate.surface(owner, rendererDidTerminate: termination)
    }

    func surface(_ surface: WebKitSurface, rendererDidBecomeUnresponsive isUnresponsive: Bool) {
        guard case let (owner, delegate)? = target else { return }
        delegate.surface(owner, rendererDidBecomeUnresponsive: isUnresponsive)
    }
}

/// Media activity of WebKit documents, posted from an isolated script world. One handler per
/// user content controller (new targets share their opener's controller), routed by web view.
@MainActor
final class ChromiumWebContentMessages: NSObject, WKScriptMessageHandler {
    static let shared = ChromiumWebContentMessages()
    private static let name = "circaMediaActivity"
    private static let source = """
    (() => {
      let pending = false;
      const post = () => {
        if (pending) return;
        pending = true;
        setTimeout(() => { pending = false; try { window.webkit.messageHandlers.circaMediaActivity.postMessage(1); } catch (e) {} }, 100);
      };
      for (const type of ['play', 'pause', 'ended', 'volumechange', 'emptied']) document.addEventListener(type, post, true);
    })();
    """
    private struct Entry { weak var content: ChromiumWebContent? }
    private var contents: [ObjectIdentifier: Entry] = [:]
    private var controllers: [ObjectIdentifier: WeakController] = [:]
    private final class WeakController { weak var value: WKUserContentController?; init(_ value: WKUserContentController) { self.value = value } }

    func attach(_ content: ChromiumWebContent) {
        let webView = content.surface.webView
        contents = contents.filter { $0.value.content != nil }
        contents[ObjectIdentifier(webView)] = Entry(content: content)
        let controller = webView.configuration.userContentController
        controllers = controllers.filter { $0.value.value != nil }
        guard controllers[ObjectIdentifier(controller)] == nil else { return }
        controllers[ObjectIdentifier(controller)] = WeakController(controller)
        controller.add(self, contentWorld: .defaultClient, name: Self.name)
        controller.addUserScript(WKUserScript(source: Self.source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .defaultClient))
    }

    func detach(_ content: ChromiumWebContent) {
        contents[ObjectIdentifier(content.surface.webView)] = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView else { return }
        contents[ObjectIdentifier(webView)]?.content?.mediaActivityDidChange()
    }
}

/// WebKit has no public favicon API: the icon the document declares is fetched without cookies
/// or credentials and reduced to a PNG of at most 64 pixels (`BrowserFaviconImage`).
enum ChromiumWebContentFavicon {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    static func load(_ url: URL) async -> BrowserFaviconImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              data.count <= 1_048_576 else { return nil }
        return await Task.detached(priority: .utility) { png(from: data).flatMap { BrowserFaviconImage(sourceURL: url, png: $0) } }.value
    }

    private static func png(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
