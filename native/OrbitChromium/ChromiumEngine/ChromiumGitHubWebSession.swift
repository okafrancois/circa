import BrowserCore
import BrowserEngine
import Foundation

extension ChromiumBrowserEngine: BrowserGitHubWebSession {
    public func pullRequests(profileID: ProfileID, query: String, page: Int) async throws -> BrowserProfileWebResponse {
        try await githubPullRequests(profileID: profileID, query: query, page: page, origin: URL(string: "https://github.com")!)
    }

    @_spi(Testing)
    public func pullRequestsFixture(profileID: ProfileID, query: String, page: Int, origin: URL) async throws -> BrowserProfileWebResponse {
        guard origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil,
              origin.path.isEmpty, origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil else {
            throw BrowserGitHubProviderError.invalidConfiguration
        }
        return try await githubPullRequests(profileID: profileID, query: query, page: page, origin: origin)
    }

    private func githubPullRequests(profileID: ProfileID, query: String, page: Int, origin: URL) async throws -> BrowserProfileWebResponse {
        guard !isShutDown, page > 0, page <= 40, query.utf8.count <= 2_000 else {
            throw BrowserGitHubProviderError.invalidConfiguration
        }
        let owner = ChromiumGitHubDocument(origin: origin)
        let surface = makeSurface(profileID: profileID, delegate: owner)
        // Ownership and delegate are recorded before navigation; never attach this surface to
        // a shell window or navigate an existing user tab. Cookies remain in this profile.
        defer { surface.dispose() }
        surface.navigate(to: origin.appendingPathComponent("pulls"))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(25))
        while !owner.finished && !owner.failed && clock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        guard owner.finished, !owner.failed, !surface.isDisposed,
              let url = surface.navigationState.committedURL, owner.allowed(url) else {
            throw BrowserGitHubProviderError.invalidResponse
        }
        guard url.path == "/pulls" else { throw BrowserGitHubProviderError.signedOut }
        let generation = surface.documentGeneration
        let (frameOK, frameData) = await surface.devToolsCall("Page.getFrameTree")
        guard frameOK, let tree = try JSONSerialization.jsonObject(with: frameData) as? [String: Any],
              let frameTree = tree["frameTree"] as? [String: Any], let frame = frameTree["frame"] as? [String: Any],
              let frameID = frame["id"] as? String else { throw BrowserGitHubProviderError.invalidResponse }
        let worldParams = try JSONSerialization.data(withJSONObject: ["frameId": frameID, "worldName": "OrbitGitHub"])
        let (worldOK, worldData) = await surface.devToolsCall("Page.createIsolatedWorld", params: String(decoding: worldParams, as: UTF8.self))
        guard worldOK, let world = try JSONSerialization.jsonObject(with: worldData) as? [String: Any],
              let context = world["executionContextId"] as? Int else { throw BrowserGitHubProviderError.invalidResponse }
        var target = URLComponents(url: origin.appendingPathComponent("pulls"), resolvingAgainstBaseURL: false)!
        target.queryItems = [.init(name: "q", value: query), .init(name: "page", value: String(page))]
        let encodedURL = String(decoding: try JSONEncoder().encode(target.url!.absoluteString), as: UTF8.self)
        // Isolated world avoids page replacements of fetch/JSON. Manual redirects never forward
        // authenticated requests outside the fixed origin, including login and organization SSO.
        let encodedOrigin = String(decoding: try JSONEncoder().encode(origin.absoluteString), as: UTF8.self)
        let expression = """
        (async () => {
          if (location.origin !== \(encodedOrigin) || location.pathname !== '/pulls') throw Error('origin');
          const r = await fetch(\(encodedURL), {credentials:'same-origin', redirect:'manual', cache:'no-store',
            signal:AbortSignal.timeout(20000), headers:{Accept:'text/html'}});
          if (r.type === 'opaqueredirect') return {status:401,url:location.href,body:''};
          if (r.url !== \(encodedURL)) throw Error('redirect');
          const reader = r.body.getReader(); let body = ''; let size = 0; const decoder = new TextDecoder();
          try { while (true) { const part = await reader.read(); if (part.done) break;
            size += part.value.byteLength; if (size > 8388608) throw Error('size');
            body += decoder.decode(part.value, {stream:true}); } body += decoder.decode(); }
          finally { await reader.cancel(); }
          return {status:r.status,url:r.url,body,retryAfter:r.headers.get('retry-after')};
        })()
        """
        let params = try JSONSerialization.data(withJSONObject: ["contextId": context, "expression": expression,
            "awaitPromise": true, "returnByValue": true])
        let (ok, data) = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: params, as: UTF8.self), timeout: .seconds(25))
        try Task.checkCancellation()
        guard ok, !surface.isDisposed, surface.documentGeneration == generation,
              surface.navigationState.committedURL == url,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["exceptionDetails"] == nil,
              let result = object["result"] as? [String: Any], let value = result["value"] as? [String: Any],
              let status = value["status"] as? Int, let rawURL = value["url"] as? String,
              let responseURL = URL(string: rawURL), owner.allowed(responseURL),
              let body = value["body"] as? String else { throw BrowserGitHubProviderError.invalidResponse }
        return .init(status: status, url: responseURL, body: body, retryAfter: value["retryAfter"] as? String)
    }
}

@MainActor
private final class ChromiumGitHubDocument: BrowserEngineSurfaceDelegate {
    var finished = false
    var failed = false
    let origin: URL
    init(origin: URL) { self.origin = origin }
    func allowed(_ url: URL) -> Bool {
        url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port && url.user == nil && url.password == nil
            && (url.path == "/pulls" || url.path == "/login" || url.path.hasPrefix("/sessions/"))
    }
    func surfaceDidStartNavigation(_ surface: ChromiumSurface) { finished = false }
    func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFinishNavigation(_ surface: ChromiumSurface) { finished = true }
    func surfaceDidFailNavigation(_ surface: ChromiumSurface) { failed = true }
    func surfaceDidRequestClose(_ surface: ChromiumSurface) { failed = true }
    func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        let allow = action.url.map(allowed) == true && action.httpMethod != "POST"
        if !allow { failed = true }
        decision.decide(allow ? .allow : .cancel)
    }
    func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> ChromiumSurface) -> ChromiumSurface? { nil }
    func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel(); failed = true }
    func surface(_ surface: ChromiumSurface, requestsPermission request: BrowserPermissionRequest) async -> BrowserPermissionDecision { .deny }
}
