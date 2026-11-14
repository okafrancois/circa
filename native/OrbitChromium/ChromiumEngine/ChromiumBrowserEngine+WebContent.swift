import BrowserCore
import BrowserEngine
import Foundation
import WebKitEngine

/// Protected-streaming WebKit content of this engine's tabs (`ChromiumSurface+WebContent.swift`).
/// One WebKit engine per Chromium engine: a persistent engine uses one persistent
/// `WKWebsiteDataStore` per profile (`WKWebsiteDataStore(forIdentifier:)`, the profile UUID), a
/// private engine memory-only stores. WebKit stores its persistent data in its own container,
/// outside the Orbit data root, so confined runs (`webContentPersistence = .ephemeral`) never
/// persist WebKit data.
extension ChromiumBrowserEngine {
    public static var hostsSiteEngineSwitching: Bool { true }

    public func useSiteEnginePreferences(_ preferences: BrowserSitePreferenceStore) {
        siteEnginePreferences = preferences
    }

    /// The engine for a navigation to `url` in `profileID`.
    func siteEngine(for url: URL, profileID: ProfileID) -> BrowserSiteEngine {
        if let siteEnginePreferences { return siteEnginePreferences.siteEngine(for: url, profileID: profileID) }
        return BrowserProtectedStreamingSites.engine(for: url, saved: nil)
    }

    var canHostWebContent: Bool { !isShutDown && webContentEnabled }

    func makeWebContent(for surface: ChromiumSurface) -> ChromiumWebContent? {
        guard canHostWebContent, !surface.isDisposed else { return nil }
        let inner = webContentEngine.makeSurface(profileID: surface.profileID, delegate: ChromiumWebContentRelay())
        return ChromiumWebContent(surface: inner)
    }
}
