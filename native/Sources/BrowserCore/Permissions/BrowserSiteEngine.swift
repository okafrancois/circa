import Foundation

/// The web engine that renders a site's documents in a tab of the Chromium product.
public enum BrowserSiteEngine: String, Codable, Sendable, CaseIterable {
    case chromium
    /// The system WebKit, which plays FairPlay-protected streams natively.
    case webKit
}

/// Streaming services whose protected playback needs a DRM path that the Chromium product cannot
/// offer (a signed Widevine host), and that play with FairPlay in the system WebKit. Data only:
/// the list is matched by registrable-domain suffix, so `www.` and player subdomains follow.
public enum BrowserProtectedStreamingSites {
    public static let domains: [String] = [
        "netflix.com",
        "disneyplus.com",
        "max.com",
        "hbomax.com",
        "tv.apple.com",
        "primevideo.com"
    ]

    /// The listed domain `url` belongs to, nil for any other site or a non-web scheme.
    public static func domain(for url: URL?) -> String? {
        guard let host = BrowserSitePreferenceStore.host(url) else { return nil }
        let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
        return domains.first { trimmed == $0 || trimmed.hasSuffix("." + $0) }
    }

    /// The engine a navigation to `url` uses: the site's saved choice first, then the built-in
    /// list. Non-web URLs (`about:`, `file:`, internal pages) always stay on Chromium.
    public static func engine(for url: URL?, saved: BrowserSiteEngine?) -> BrowserSiteEngine {
        guard BrowserSitePreferenceStore.host(url) != nil else { return .chromium }
        if let saved { return saved }
        return domain(for: url) == nil ? .chromium : .webKit
    }

    /// The value to save when the user picks `engine` for `url`: nil when it equals the built-in
    /// default, so that a later change of the list still applies to that site.
    public static func savedChoice(_ engine: BrowserSiteEngine, for url: URL?) -> BrowserSiteEngine? {
        engine == self.engine(for: url, saved: nil) ? nil : engine
    }
}

public extension BrowserSitePreferenceStore {
    /// The engine for a navigation to `url` in `profileID` (saved per host, then built-in list).
    func siteEngine(for url: URL?, profileID: ProfileID) -> BrowserSiteEngine {
        BrowserProtectedStreamingSites.engine(for: url, saved: preferences(url: url, profileID: profileID).siteEngine)
    }

    /// Remembers `engine` for the host of `url` and returns the saved preferences.
    func setSiteEngine(_ engine: BrowserSiteEngine, for url: URL?, profileID: ProfileID) throws {
        var preferences = preferences(url: url, profileID: profileID)
        preferences.siteEngine = BrowserProtectedStreamingSites.savedChoice(engine, for: url)
        try set(preferences, url: url, profileID: profileID)
    }
}
