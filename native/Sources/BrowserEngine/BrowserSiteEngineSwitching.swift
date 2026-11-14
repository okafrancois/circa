import BrowserCore

/// A surface that can show its current site with either engine, keeping the tab, its occurrence
/// and its window. Moving between engines never carries cookies or storage: each engine keeps its
/// own per-profile site data.
@MainActor
public protocol BrowserSiteEngineSwitching: AnyObject {
    /// The engine that renders the displayed document.
    var siteEngine: BrowserSiteEngine { get }
    /// Loads the current address again with `engine`. False when there is nothing to reload
    /// (no web address, disposed surface) or `engine` is already in use.
    @discardableResult func reload(with engine: BrowserSiteEngine) -> Bool
}

public extension BrowserEngine {
    /// True when this engine's surfaces offer `siteEngineSwitching`. A protocol requirement, not a
    /// dynamic cast: casts to protocols conformed in another module can be folded away.
    static var hostsSiteEngineSwitching: Bool { false }
    func useSiteEnginePreferences(_ preferences: BrowserSitePreferenceStore) {}
}

public extension BrowserEngineSurface {
    var siteEngineSwitching: (any BrowserSiteEngineSwitching)? { nil }
}
