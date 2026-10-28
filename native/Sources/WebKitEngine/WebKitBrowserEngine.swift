import BrowserCore
import BrowserEngine
import Foundation
import WebKit

/// WebKit backend for development and fallback. Site data is ephemeral: one non-persistent
/// `WKWebsiteDataStore` per profile, shared by every window of the engine.
@MainActor
public final class WebKitBrowserEngine: BrowserPrivateEngine {
    public let persistence = BrowserWebsiteDataPersistence.ephemeral
    public let kind = BrowserEngineKind.webKit
    public let capabilities: BrowserEngineCapabilities = [.cacheBypassingReload,
        .downloadResume, .snapshots, .mediaPlaybackState, .mediaCaptureState,
        .mediaCapturePermissions, .liveSurfaceTransfer, .suspendablePolicyDecisions,
        .navigationResponsePolicy, .navigationDownloadConversion, .profileRemoval,
        // CH-ESSENTIALS: WKWebView's print operation. No DevTools API (Web Inspector stays on
        // WebKit's own context menu), no page context menus to report (WebKit shows its own), no
        // public beforeunload hook.
        .printing, .safeBrowsing
    ]
    public var extensions: (any BrowserExtensionHost)? { nil }
    public var conformanceProbe: (any BrowserEngineConformanceProbe<WebKitSurface>)? { WebKitConformanceProbe() }
    /// Engine resume entry point; tests substitute it to observe resume ordering.
    public var resumeDownload: WebKitDownloadTransfer.ResumeDownload = WebKitDownloadTransfer.defaultResumeDownload
    let pageZoom = WebKitPageZoomStore()
    var permissionSurfaces: [WeakPermissionSurface] = []
    private var dataStores: [ProfileID: WKWebsiteDataStore] = [:]

    public init() {}

    public func profile(for profileID: ProfileID) -> BrowserEngineProfile {
        _ = websiteDataStore(for: profileID)
        return BrowserEngineProfile(profileID: profileID, persistence: .ephemeral)
    }

    public func websiteDataStore(for profileID: ProfileID) -> WKWebsiteDataStore {
        if let existing = dataStores[profileID] { return existing }
        let dataStore = WKWebsiteDataStore.nonPersistent()
        dataStores[profileID] = dataStore
        return dataStore
    }

    /// WebKit creates its view synchronously, so surfaces are ready on return and load nothing
    /// until `navigate(to:)`.
    public func makeSurface(
        profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<WebKitSurface>
    ) -> WebKitSurface {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore(for: profileID)
        // CH-ESSENTIALS: element fullscreen in WebKit's own fullscreen window.
        configuration.preferences.isElementFullscreenEnabled = true
        let surface = WebKitSurface(profileID: profileID, configuration: configuration, engine: self, zoomStore: pageZoom)
        surface.delegate = delegate
        return surface
    }

    public func removeProfile(_ profileID: ProfileID) async throws {
        guard !permissionSurfaces.contains(where: { $0.surface.map { $0.profileID == profileID && !$0.isDisposed } == true }) else {
            throw BrowserEngineError.profileInUse
        }
        guard let dataStore = dataStores[profileID] else { return }
        if let identifier = dataStore.identifier {
            // The persistent-store API reports failure (including retained WKWebViews). The
            // current development backend creates ephemeral stores; this branch also supports
            // a future persistent store without substituting a cookie-only erase.
            try await WKWebsiteDataStore.remove(forIdentifier: identifier)
        } else {
            try await clearSiteData(profileID: profileID)
        }
        guard !permissionSurfaces.contains(where: { $0.surface.map { $0.profileID == profileID && !$0.isDisposed } == true }) else {
            throw BrowserEngineError.profileInUse
        }
        dataStores[profileID] = nil
        pageZoom.removeProfile(profileID)
    }

    /// WebKit tears a web view down synchronously in `dispose()`; nothing is pending here.
    public func shutdown() async {}
}

/// Reads and writes cookies through the exact `WKWebsiteDataStore` of a surface's web view.
@MainActor
final class WebKitConformanceProbe: BrowserEngineConformanceProbe {
    private static let markerName = "orbit-conformance-marker"

    func writeSiteDataMarker(_ value: String, for origin: URL, through surface: WebKitSurface) async throws {
        guard let host = origin.host, let cookie = HTTPCookie(properties: [
            .name: Self.markerName, .value: value, .domain: host, .path: "/", .secure: "TRUE"
        ]) else { throw BrowserEngineError.unsupportedOperation }
        await surface.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
    }

    func readSiteDataMarker(for origin: URL, through surface: WebKitSurface) async throws -> String? {
        let cookies = await surface.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return cookies.first { $0.name == Self.markerName && $0.domain == origin.host }?.value
    }

    /// `evaluateJavaScript` runs as a user gesture. The script is an expression; its value is
    /// tagged so that `undefined`/`null` and strings survive the bridge unambiguously.
    func evaluateScript(_ script: String, in surface: WebKitSurface) async throws -> String? {
        guard !surface.isDisposed else { throw BrowserEngineError.surfaceDisposed }
        let source = String(data: try JSONEncoder().encode(script), encoding: .utf8)!
        let wrapped = "(() => { const v = (0, eval)(\(source)); return (v === undefined || v === null) ? 'n' : 'v' + String(v); })()"
        let result = try await surface.webView.evaluateJavaScript(wrapped) as? String
        guard let result, result.first == "v" else { return nil }
        return String(result.dropFirst())
    }
}
