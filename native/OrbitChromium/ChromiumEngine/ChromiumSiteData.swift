import BrowserCore
import BrowserEngine
import Foundation

/// DevTools commands execute on a browser of the captured profile, never the global context.
extension ChromiumBrowserEngine: BrowserSiteOriginDataAccess {
    private func siteDataSurface(_ origin: BrowserSiteOrigin, profileID: ProfileID) throws -> ChromiumSurface {
        guard !isShutDown, let surface = runtime.registeredSurfaces.first(where: {
            $0.engine === self && $0.profileID == profileID && !$0.isDisposed && $0.isBrowserCreated &&
                $0.navigationState.committedURL.flatMap(BrowserSiteOrigin.init(url:)) == origin
        }) else { throw BrowserSiteDataError.removalIncomplete }
        return surface
    }

    private func siteDataCommand(_ method: String, parameters: [String: Any] = [:],
                                 surface: ChromiumSurface) async throws -> [String: Any] {
        let encoded = try JSONSerialization.data(withJSONObject: parameters)
        let (ok, data) = await surface.devToolsCall(method, params: String(decoding: encoded, as: UTF8.self))
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
        guard let url = URL(string: origin.value), let domain = BrowserPublicSuffixList.shared.site(of: url),
              expectedDomains == [domain] else { throw BrowserSiteDataError.scopeChanged }
        let surface = try siteDataSurface(origin, profileID: profileID)
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
}
