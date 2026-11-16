import BrowserCore
import BrowserEngine
import Foundation
import WebKitEngine

/// DevTools commands execute on a browser of the captured profile, never the global context.
extension ChromiumBrowserEngine: BrowserSiteDataAccess {
    private func siteDataSurface(_ origin: BrowserSiteOrigin, profileID: ProfileID) throws -> ChromiumSurface {
        guard !isShutDown, let surface = runtime.registeredSurfaces.first(where: {
            $0.engine === self && $0.profileID == profileID && !$0.isDisposed && $0.isBrowserCreated &&
                $0.navigationState.committedURL.flatMap(BrowserSiteOrigin.init(url:)) == origin
        }) else { throw BrowserSiteDataError.removalIncomplete }
        return surface
    }

    /// A tab showing `origin` in WebKit content: its site data lives in the WebKit store.
    private func webContentSiteData(_ origin: BrowserSiteOrigin, profileID: ProfileID) -> WebKitBrowserEngine? {
        guard !isShutDown, runtime.registeredSurfaces.contains(where: {
            $0.engine === self && $0.profileID == profileID && !$0.isDisposed && $0.webContent != nil &&
                $0.navigationState.committedURL.flatMap(BrowserSiteOrigin.init(url:)) == origin
        }) else { return nil }
        return webContentEngine
    }

    func siteDataCommand(_ method: String, parameters: [String: Any] = [:],
                         surface: ChromiumSurface, timeout: Duration = .seconds(8)) async throws -> [String: Any] {
        let encoded = try JSONSerialization.data(withJSONObject: parameters)
        let (ok, data) = await surface.devToolsCall(method, params: String(decoding: encoded, as: UTF8.self), timeout: timeout)
        guard ok, !surface.isDisposed,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserSiteDataError.removalIncomplete
        }
        return result
    }

    private func siteCookies(domain: String, surface: ChromiumSurface) async throws -> [[String: Any]] {
        let result = try await siteDataCommand("Network.getAllCookies", surface: surface)
        guard let cookies = result["cookies"] as? [[String: Any]] else { throw BrowserSiteDataError.removalIncomplete }
        return cookies.filter {
            guard let host = $0["domain"] as? String else { return false }
            let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return normalized == domain || normalized.hasSuffix("." + domain)
        }
    }

    public func siteData(origin: BrowserSiteOrigin, profileID: ProfileID) async -> BrowserSiteDataSummary {
        if let webKit = webContentSiteData(origin, profileID: profileID) {
            return await webKit.siteData(origin: origin, profileID: profileID)
        }
        guard let url = URL(string: origin.value), let domain = BrowserPublicSuffixList.shared.site(of: url) else {
            return BrowserSiteDataSummary(domains: [], recordCount: 0, isAvailable: false)
        }
        do {
            let surface = try siteDataSurface(origin, profileID: profileID)
            let cookies = try await siteCookies(domain: domain, surface: surface)
            let quota = try await siteDataCommand("Storage.getUsageAndQuota", parameters: ["origin": origin.value], surface: surface)
            let local = try await siteDataCommand("DOMStorage.getDOMStorageItems", parameters: [
                "storageId": ["securityOrigin": origin.value, "isLocalStorage": true]
            ], surface: surface)
            let usage = (quota["usage"] as? NSNumber)?.doubleValue ?? 0
            let entries = local["entries"] as? [[String]] ?? []
            // A worker registration can have zero quota usage.
            let workers = try await siteDataCommand("Runtime.evaluate", parameters: [
                "expression": "navigator.serviceWorker ? navigator.serviceWorker.getRegistrations().then(r => r.length) : 0",
                "returnByValue": true, "awaitPromise": true
            ], surface: surface)
            let workerCount = ((workers["result"] as? [String: Any])?["value"] as? Int) ?? 0
            let hasStorage = usage > 0 || !entries.isEmpty || workerCount > 0
            return BrowserSiteDataSummary(domains: [domain], recordCount: cookies.count + (hasStorage ? 1 : 0),
                                          cookieCount: cookies.count, hasStorage: hasStorage)
        } catch {
            return BrowserSiteDataSummary(domains: [domain], recordCount: 0, isAvailable: false)
        }
    }

    public func clearSiteData(origin: BrowserSiteOrigin, profileID: ProfileID, expectedDomains: [String]) async throws {
        if let webKit = webContentSiteData(origin, profileID: profileID) {
            try await webKit.clearSiteData(origin: origin, profileID: profileID, expectedDomains: expectedDomains)
            return
        }
        guard let url = URL(string: origin.value), let domain = BrowserPublicSuffixList.shared.site(of: url),
              expectedDomains == [domain] else { throw BrowserSiteDataError.scopeChanged }
        // Settings can clear a site no tab shows: a windowless blank page of the same profile
        // reaches the same cookie store and storage partition.
        if let surface = try? siteDataSurface(origin, profileID: profileID) {
            try await clearOriginData(origin, domain: domain, profileID: profileID, surface: surface)
        } else {
            try await withHiddenSiteDataPage(URL(string: "about:blank")!, profileID: profileID) { surface in
                try await clearOriginData(origin, domain: domain, profileID: profileID, surface: surface)
            }
        }
        // The site's cookies must not survive in the update recovery snapshots either.
        let dataRoot = URL(fileURLWithPath: runtime.rootCachePath).deletingLastPathComponent()
        await Task.detached(priority: .utility) {
            _ = try? BrowserEngineMigrationBackup.prune(profile: profileID, .site(domain), dataRoot: dataRoot)
        }.value
    }

    private func clearOriginData(_ origin: BrowserSiteOrigin, domain: String, profileID: ProfileID,
                                 surface: ChromiumSurface) async throws {
        let cookies = try await siteCookies(domain: domain, surface: surface)
        // Enumerate origin-scoped stores: `all` can also purge profile-wide GPU caches.
        _ = try await siteDataCommand("Storage.clearDataForOrigin", parameters: [
            "origin": origin.value,
            "storageTypes": "local_storage,indexeddb,cache_storage,service_workers,file_systems"
        ], surface: surface)
        for cookie in cookies {
            guard let name = cookie["name"], let host = cookie["domain"], let path = cookie["path"] else {
                throw BrowserSiteDataError.removalIncomplete
            }
            var parameters: [String: Any] = ["name": name, "domain": host, "path": path]
            if let partitionKey = cookie["partitionKey"] { parameters["partitionKey"] = partitionKey }
            _ = try await siteDataCommand("Network.deleteCookies", parameters: parameters, surface: surface)
        }
        guard try await siteCookies(domain: domain, surface: surface).isEmpty else {
            throw BrowserSiteDataError.removalIncomplete
        }
        // Invalidate in-document storage caches and the authenticated page, in this profile only.
        for target in runtime.registeredSurfaces where target.engine === self && target.profileID == profileID && !target.isDisposed {
            guard let current = target.navigationState.committedURL,
                  BrowserSiteOrigin(url: current) == origin || BrowserPublicSuffixList.shared.site(of: current) == domain else { continue }
            target.reload()
        }
    }

    /// Profile-wide erase: cookies, HTTP cache, local and session storage, IndexedDB, service
    /// workers, cache storage and file systems of this profile's own Chrome profile, through
    /// Chrome's browsing-data remover (the engine's "clear browsing data" handler, all time, site
    /// data and cached files only: history, passwords, form data and site settings stay). CEF has
    /// no profile-wide storage API and DevTools only erases origin by origin, so the handler runs in
    /// a windowless settings page of the profile, which binds it to that profile and no other.
    /// The protected-streaming WebKit store of the profile is cleared too. Open tabs keep working:
    /// Chrome invalidates their in-memory storage and the next request goes out without cookies.
    public func clearSiteData(profileID: ProfileID) async throws {
        guard persistence == .persistent, surfaceMode == .hosted else { throw BrowserSiteDataError.removalIncomplete }
        try await withHiddenSiteDataPage(URL(string: "chrome://settings/")!, profileID: profileID) { surface in
            let result = try await siteDataCommand("Runtime.evaluate", parameters: [
                "expression": Self.profileClearScript, "returnByValue": true, "awaitPromise": true
            ], surface: surface, timeout: .seconds(60))
            // Resolved by the remover's completion; open tabs may legitimately set new cookies
            // right after, so the result is not re-checked against a live cookie list.
            guard result["exceptionDetails"] == nil, (result["result"] as? [String: Any])?["value"] as? Bool == true else {
                throw BrowserSiteDataError.removalIncomplete
            }
        }
        try await webContentEngine.clearExistingSiteData(profileID: profileID)
        // Copies of the deleted cookies must not survive in the update recovery snapshots.
        try? BrowserEngineMigrationBackup.prune(profile: profileID, .cookies,
                                                dataRoot: URL(fileURLWithPath: runtime.rootCachePath).deletingLastPathComponent())
    }

    /// Initializes the handler (it must allow JavaScript before it can answer), then removes site
    /// data (`browser.clear_data.cookies`) and cached files (`browser.clear_data.cache`) for all
    /// time (period 4) and resolves once Chrome's remover finished.
    static let profileClearScript = """
        (async () => {
          if (location.protocol !== 'chrome:' || location.host !== 'settings') throw Error('page');
          const cr = await import('chrome://resources/js/cr.js');
          await cr.sendWithPromise('initializeClearBrowsingData');
          await cr.sendWithPromise('clearBrowsingData', ['browser.clear_data.cookies', 'browser.clear_data.cache'], 4);
          return true;
        })()
        """

    /// A windowless page of `profileID` showing exactly `url`, disposed when `body` returns.
    func withHiddenSiteDataPage<T>(_ url: URL, profileID: ProfileID,
                                   _ body: (ChromiumSurface) async throws -> T) async throws -> T {
        guard !isShutDown, !runtime.removingProfiles.contains(profileID), !refusedProfiles.contains(profileID) else {
            throw BrowserSiteDataError.removalIncomplete
        }
        let page = ChromiumSiteDataPage(url: url)
        let surface = makeSurface(profileID: profileID, delegate: page)
        defer { surface.dispose() }
        surface.navigate(to: url)
        let deadline = ContinuousClock.now + .seconds(15)
        while !page.finished && !page.failed && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard page.finished, !page.failed, !surface.isDisposed, surface.isBrowserCreated else {
            throw BrowserSiteDataError.removalIncomplete
        }
        return try await body(surface)
    }
}

/// Allows only the navigation it was made for; never opens windows, downloads or permissions.
@MainActor
private final class ChromiumSiteDataPage: BrowserEngineSurfaceDelegate {
    let url: URL
    var finished = false
    var failed = false
    init(url: URL) { self.url = url }
    func surfaceDidStartNavigation(_ surface: ChromiumSurface) { finished = false }
    func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFinishNavigation(_ surface: ChromiumSurface) { finished = true }
    func surfaceDidFailNavigation(_ surface: ChromiumSurface) { failed = true }
    func surfaceDidRequestClose(_ surface: ChromiumSurface) { failed = true }
    func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        let allowed = action.url == url && action.httpMethod != "POST"
        if !allowed { failed = true }
        decision.decide(allowed ? .allow : .cancel)
    }
    func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> ChromiumSurface) -> ChromiumSurface? { nil }
    func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel(); failed = true }
    func surface(_ surface: ChromiumSurface, requestsPermission request: BrowserPermissionRequest) async -> BrowserPermissionDecision { .deny }
}
