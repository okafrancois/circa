import BrowserCore
import BrowserEngine
import Foundation

extension ChromiumBrowserEngine: BrowserGmailWebSession {
    public func gmailInbox(profileID: ProfileID, account: BrowserGmailAccount) async throws -> BrowserGmailInbox {
        try await gmailInbox(profileID: profileID, feedURL: account.feedURL)
    }

    @_spi(Testing)
    public func gmailInboxFixture(profileID: ProfileID, origin: URL) async throws -> BrowserGmailInbox {
        guard origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil,
              origin.path.isEmpty, origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil else { throw BrowserGmailPreviewError.invalidResponse }
        return try await gmailInbox(profileID: profileID, feedURL: origin.appendingPathComponent("mail/u/0/feed/atom"))
    }

    private func gmailInbox(profileID: ProfileID, feedURL: URL) async throws -> BrowserGmailInbox {
        guard !isShutDown else { throw BrowserGmailPreviewError.unavailable }
        let document = ChromiumGmailDocument(feedURL: feedURL)
        let surface = makeSurface(profileID: profileID, delegate: document)
        defer { surface.dispose() }
        surface.navigate(to: feedURL)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while !document.finished && !document.failed && clock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        guard !document.signedOut else { throw BrowserGmailPreviewError.signedOut }
        guard document.finished, !document.failed, !surface.isDisposed,
              surface.navigationState.committedURL == feedURL else { throw BrowserGmailPreviewError.unavailable }
        let generation = surface.documentGeneration
        let (frameOK, frameData) = await surface.devToolsCall("Page.getFrameTree")
        guard frameOK, let tree = try JSONSerialization.jsonObject(with: frameData) as? [String: Any],
              let frameTree = tree["frameTree"] as? [String: Any], let frame = frameTree["frame"] as? [String: Any],
              let frameID = frame["id"] as? String else { throw BrowserGmailPreviewError.invalidResponse }
        let worldParams = try JSONSerialization.data(withJSONObject: ["frameId": frameID, "worldName": "OrbitInbox"])
        let (worldOK, worldData) = await surface.devToolsCall("Page.createIsolatedWorld", params: String(decoding: worldParams, as: UTF8.self))
        guard worldOK, let world = try JSONSerialization.jsonObject(with: worldData) as? [String: Any],
              let context = world["executionContextId"] as? Int else { throw BrowserGmailPreviewError.invalidResponse }
        let encodedURL = String(decoding: try JSONEncoder().encode(feedURL.absoluteString), as: UTF8.self)
        let expression = """
        (async () => {
          if (location.href !== \(encodedURL)) throw Error('document');
          const r = await fetch(\(encodedURL), {credentials:'same-origin',redirect:'manual',cache:'no-store',
            signal:AbortSignal.timeout(10000),headers:{Accept:'application/atom+xml,application/xml'}});
          if (r.type === 'opaqueredirect' || r.status === 401 || r.status === 403) return {signedOut:true};
          if (!r.ok || r.url !== \(encodedURL)) throw Error('response');
          const reader=r.body.getReader(), decoder=new TextDecoder('utf-8',{fatal:true});
          let body='', size=0;
          try { while(true) {const p=await reader.read(); if(p.done)break;
            size+=p.value.byteLength; if(size>262144)throw Error('size');
            body+=decoder.decode(p.value,{stream:true});} body+=decoder.decode(); }
          finally {await reader.cancel();}
          return {body};
        })()
        """
        let params = try JSONSerialization.data(withJSONObject: ["contextId": context, "expression": expression,
            "awaitPromise": true, "returnByValue": true])
        let (ok, data) = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: params, as: UTF8.self), timeout: .seconds(12))
        try Task.checkCancellation()
        guard ok, !surface.isDisposed, surface.documentGeneration == generation,
              surface.navigationState.committedURL == feedURL,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["exceptionDetails"] == nil,
              let result = object["result"] as? [String: Any], let value = result["value"] as? [String: Any] else {
            throw BrowserGmailPreviewError.invalidResponse
        }
        if value["signedOut"] as? Bool == true { throw BrowserGmailPreviewError.signedOut }
        guard let body = value["body"] as? String else { throw BrowserGmailPreviewError.invalidResponse }
        return try BrowserGmailInbox.decodeFeed(Data(body.utf8))
    }
}

@MainActor
private final class ChromiumGmailDocument: BrowserEngineSurfaceDelegate {
    let feedURL: URL
    var finished = false
    var failed = false
    var signedOut = false
    init(feedURL: URL) { self.feedURL = feedURL }
    func surfaceDidStartNavigation(_ surface: ChromiumSurface) { finished = false }
    func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFinishNavigation(_ surface: ChromiumSurface) { finished = true }
    func surfaceDidFailNavigation(_ surface: ChromiumSurface) { failed = true }
    func surfaceDidRequestClose(_ surface: ChromiumSurface) { failed = true }
    func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        let allowed = action.url == feedURL && action.httpMethod != "POST"
        if !allowed { failed = true; signedOut = action.url?.host == "accounts.google.com" }
        decision.decide(allowed ? .allow : .cancel)
    }
    func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> ChromiumSurface) -> ChromiumSurface? { nil }
    func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel(); failed = true }
    func surface(_ surface: ChromiumSurface, requestsPermission request: BrowserPermissionRequest) async -> BrowserPermissionDecision { .deny }
}
