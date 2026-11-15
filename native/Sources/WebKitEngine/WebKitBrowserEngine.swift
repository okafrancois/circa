import BrowserCore
import BrowserEngine
import Foundation
import WebKit

/// WebKit backend for development and fallback, and the protected-streaming engine of the
/// Chromium product. One `WKWebsiteDataStore` per profile, shared by every window of the engine:
/// non-persistent by default; `.persistent` uses `WKWebsiteDataStore(forIdentifier:)` with the
/// profile's UUID, so each profile keeps its own cookies across launches.
@MainActor
public final class WebKitBrowserEngine: BrowserPrivateEngine {
    public let persistence: BrowserWebsiteDataPersistence
    public let kind = BrowserEngineKind.webKit
    /// Appended to WebKit's user agent by new surfaces (`applicationNameForUserAgent`). Nil keeps
    /// WebKit's default, which streaming services reject as an unknown browser.
    public var applicationNameForUserAgent: String?
    public let capabilities: BrowserEngineCapabilities
    private static let baseCapabilities: BrowserEngineCapabilities = [.cacheBypassingReload,
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

    public init(persistence: BrowserWebsiteDataPersistence = .ephemeral) {
        self.persistence = persistence
        capabilities = persistence == .persistent ? Self.baseCapabilities.union(.persistentProfiles) : Self.baseCapabilities
    }

    public func profile(for profileID: ProfileID) -> BrowserEngineProfile {
        _ = websiteDataStore(for: profileID)
        return BrowserEngineProfile(profileID: profileID, persistence: persistence)
    }

    public func websiteDataStore(for profileID: ProfileID) -> WKWebsiteDataStore {
        if let existing = dataStores[profileID] { return existing }
        let dataStore = persistence == .persistent
            ? WKWebsiteDataStore(forIdentifier: profileID.rawValue) : WKWebsiteDataStore.nonPersistent()
        dataStores[profileID] = dataStore
        return dataStore
    }

    /// `Version/<installed Safari> Safari/605.1.15`, the suffix Safari itself sends. Services that
    /// gate playback on a known browser accept WebKit with it.
    public static func safariApplicationName(safariInfo: URL = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")) -> String {
        let info = NSDictionary(contentsOf: safariInfo)
        let version = (info?["CFBundleShortVersionString"] as? String).flatMap { value in
            value.allSatisfy { $0.isNumber || $0 == "." } && value.first?.isNumber == true ? value : nil
        } ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }

    /// WebKit creates its view synchronously, so surfaces are ready on return and load nothing
    /// until `navigate(to:)`.
    public func makeSurface(
        profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<WebKitSurface>
    ) -> WebKitSurface {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore(for: profileID)
        if let applicationNameForUserAgent { configuration.applicationNameForUserAgent = applicationNameForUserAgent }
        // CH-ESSENTIALS: element fullscreen in WebKit's own fullscreen window.
        configuration.preferences.isElementFullscreenEnabled = true
        let surface = WebKitSurface(profileID: profileID, configuration: configuration, engine: self, zoomStore: pageZoom)
        surface.delegate = delegate
        return surface
    }

    /// WebKit answers its class-level store requests on its main run loop, which exists only once
    /// a WebKit object was created in this process. A run that never showed a WebKit document
    /// (a Chromium window removing a profile) has none, and the answer would crash.
    private static let webKitInitialization: Void = { _ = WKWebsiteDataStore.nonPersistent() }()

    public func removeProfile(_ profileID: ProfileID) async throws {
        guard !permissionSurfaces.contains(where: { $0.surface.map { $0.profileID == profileID && !$0.isDisposed } == true }) else {
            throw BrowserEngineError.profileInUse
        }
        guard let dataStore = dataStores[profileID] else {
            // A persistent store this run never opened still exists on disk.
            _ = Self.webKitInitialization
            if persistence == .persistent, await WKWebsiteDataStore.allDataStoreIdentifiers.contains(profileID.rawValue) {
                try await WKWebsiteDataStore.remove(forIdentifier: profileID.rawValue)
            }
            pageZoom.removeProfile(profileID)
            return
        }
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
