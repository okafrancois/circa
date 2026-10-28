import BrowserEngine
import Foundation

/// Common scheme/download boundary. Local HTML needs an explicit shell grant, carried by the
/// live surface across transfers; a remote document cannot grant itself filesystem access.
@MainActor
enum BrowserNavigationPolicy {
    private final class FileGrant {
        weak var surface: AnyObject?
        let url: URL
        init(surface: AnyObject, url: URL) { self.surface = surface; self.url = url }
    }
    private final class SettingsGrant {
        weak var surface: AnyObject?
        init(_ surface: AnyObject) { self.surface = surface }
    }
    private static var settings: [ObjectIdentifier: SettingsGrant] = [:]

    /// The explicit Settings handoff and shell-created/restored settings tabs grant access to
    /// this hierarchy. A page cannot grant itself arbitrary privileged chrome:// navigation.
    static func authorizeChromiumSettings(for surface: AnyObject) {
        settings = settings.filter { $0.value.surface != nil }
        settings[ObjectIdentifier(surface)] = SettingsGrant(surface)
    }

    static func isChromiumSettingsURL(_ url: URL) -> Bool {
        url.scheme == "chrome" && url.host == "settings" && url.user == nil && url.password == nil && url.port == nil
    }

    static func allowsChromiumSettings(_ url: URL, surface: AnyObject) -> Bool {
        isChromiumSettingsURL(url) && settings[ObjectIdentifier(surface)]?.surface === surface
    }

    private static var files: [ObjectIdentifier: FileGrant] = [:]

    static func authorizeLocalDocument(_ url: URL, for surface: AnyObject) {
        files = files.filter { $0.value.surface != nil }
        guard url.isFileURL, url.host == nil || url.host == "", ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased()) else { return }
        files[ObjectIdentifier(surface)] = FileGrant(surface: surface, url: url.resolvingSymlinksInPath().standardizedFileURL)
    }

    private static func allowsFile<Surface: BrowserEngineSurface>(_ url: URL, surface: Surface,
                                                                 kind: BrowserNavigationKind? = nil) -> Bool {
        guard url.isFileURL, let grant = files[ObjectIdentifier(surface)], grant.surface === surface else { return false }
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL
        let scope = grant.url.deletingLastPathComponent().path + "/"
        guard candidate.path.hasPrefix(scope), ["html", "htm", "xhtml"].contains(candidate.pathExtension.lowercased()) else { return false }
        return kind == .typed && candidate == grant.url || kind == .backForward
            || surface.navigationState.committedURL?.isFileURL == true
            || kind == nil && candidate == grant.url
    }

    /// Source documents may wrap one absolute HTTP(S) URL only. A file grant never authorizes
    /// a source wrapper, and nested wrappers must not inherit the inner document's permissions.
    static func allowsViewSource(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "view-source",
              let document = URL(string: String(url.absoluteString.dropFirst("view-source:".count))) else { return false }
        return ["http", "https"].contains(document.scheme?.lowercased() ?? "")
            && document.host?.isEmpty == false
    }

    /// A Chrome extension document with a stable ID or an MV3 dynamic UUID, without credentials
    /// or port. Only an engine claiming `extensionDocuments` renders it; that engine's extension
    /// system decides access (installed and enabled, web-accessible resources, profile). The shell
    /// grants nothing more than not cancelling it, and never routes or downloads it.
    static func isExtensionDocument(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "chrome-extension", let host = url.host,
              url.user == nil, url.password == nil, url.port == nil else { return false }
        let stableID = host.utf8.count == 32
            && host.utf8.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "p")).contains($0) }
        let dynamicID = UUID(uuidString: host).map { $0.uuidString.lowercased() == host } ?? false
        return stableID || dynamicID
    }
    static func action<Surface: BrowserEngineSurface>(_ action: BrowserNavigationAction, surface: Surface,
        held: Bool, routesEnabled: Bool, hooks: BrowserSurfaceEventHooks<Surface>,
        extensionDocuments: Bool = false) -> BrowserNavigationActionPolicy {
        guard held, let url = action.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if action.shouldPerformDownload { return ["http", "https", "blob", "data"].contains(scheme) ? .download : .cancel }
        if extensionDocuments, isExtensionDocument(url) { return .allow }
        guard ["http", "https", "about", "blob", "data"].contains(scheme)
                || allowsViewSource(url) || allowsChromiumSettings(url, surface: surface) || allowsFile(url, surface: surface, kind: action.kind) else { return .cancel }
        if routesEnabled, case .handled(let policy) = hooks.routeNavigation(from: surface, action: action) { return policy }
        return .allow
    }

    static func response<Surface: BrowserEngineSurface>(_ response: BrowserNavigationResponse, surface: Surface,
                                                        held: Bool, extensionDocuments: Bool = false) -> BrowserNavigationResponsePolicy {
        guard held, let url = response.response.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        return ["http", "https", "about", "blob", "data"].contains(scheme) || allowsViewSource(url) || allowsChromiumSettings(url, surface: surface) || allowsFile(url, surface: surface)
            || extensionDocuments && isExtensionDocument(url) ? .allow : .cancel
    }
}
