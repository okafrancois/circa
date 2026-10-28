import BrowserCore
import Foundation
import WebKit

extension WebKitBrowserEngine: BrowserSiteDataAccess, BrowserSitePermissionAvailability {
    public var supportedSitePermissions: Set<BrowserSitePermission> {
        if #available(macOS 27.0, *) { return [.camera, .microphone, .geolocation] }
        return [.camera, .microphone]
    }

    func registerPermissionSurface(_ surface: WebKitSurface) {
        permissionSurfaces.removeAll { $0.surface == nil || $0.surface?.isDisposed == true }
        permissionSurfaces.append(WeakPermissionSurface(surface))
    }

    public func revokeSitePermission(_ permission: BrowserSitePermission?, origin: BrowserSiteOrigin, profileID: ProfileID) async {
        let surfaces = permissionSurfaces.compactMap(\.surface)
        for surface in surfaces {
            guard !surface.isDisposed, surface.profileID == profileID,
                  surface.committedURL.flatMap(BrowserSiteOrigin.init(url:)) == origin else { continue }
            let generation = surface.findDocumentGeneration
            if permission == nil || permission == .camera { await surface.webView.setCameraCaptureState(.none) }
            guard !surface.isDisposed, surface.findDocumentGeneration == generation else { continue }
            if permission == nil || permission == .microphone { await surface.webView.setMicrophoneCaptureState(.none) }
        }
    }

    private func records(origin: BrowserSiteOrigin, profileID: ProfileID) async -> [WKWebsiteDataRecord] {
        guard let host = URL(string: origin.value)?.host?.lowercased() else { return [] }
        let records = await websiteDataStore(for: profileID).dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        // WebKit reports domain records, not tuple origins. Never imply an exact-origin erase.
        return records.filter {
            let domain = $0.displayName.lowercased()
            return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
        }
    }

    public func siteData(origin: BrowserSiteOrigin, profileID: ProfileID) async -> BrowserSiteDataSummary {
        let records = await records(origin: origin, profileID: profileID)
        return BrowserSiteDataSummary(domains: Array(Set(records.map(\.displayName))), recordCount: records.count)
    }

    public func clearSiteData(origin: BrowserSiteOrigin, profileID: ProfileID, expectedDomains: [String]) async throws {
        let store = websiteDataStore(for: profileID)
        let records = await records(origin: origin, profileID: profileID)
        guard Set(records.map(\.displayName)).isSubset(of: Set(expectedDomains)) else { throw BrowserSiteDataError.scopeChanged }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        guard await self.records(origin: origin, profileID: profileID).isEmpty else { throw BrowserSiteDataError.removalIncomplete }
    }

    public func clearSiteData(profileID: ProfileID) async throws {
        let store = websiteDataStore(for: profileID)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        guard await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()).isEmpty else { throw BrowserSiteDataError.removalIncomplete }
    }
}

@MainActor
final class WeakPermissionSurface {
    weak var surface: WebKitSurface?
    init(_ surface: WebKitSurface) { self.surface = surface }
}
