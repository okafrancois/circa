import Foundation
import os

/// Scheme allowlist for shell-issued loads (`BrowserEngineSurface.navigate(to:)`).
///
/// A browser-initiated load bypasses the page navigation policy for some URLs: engines run
/// `javascript:` URLs directly in the current document and handle debug pages such as
/// `chrome://crash`, `chrome://kill` or `chrome://hang` before any navigation callback. Every
/// shell path (address field, restore, scripting, link routing, external opens) ends in
/// `navigate(to:)`, so engine surfaces refuse anything outside this list there. The per-surface
/// policy (file grants, Settings and password manager grants) still applies to what passes.
///
/// Script execution requested explicitly by the user goes through the engine's script evaluation
/// service, never through a `javascript:` load.
public enum BrowserNavigableURL {
    /// Built-in Chromium pages the product opens on purpose: Settings (and its language page),
    /// the password manager, extension management, history, and the tab discard diagnostics used
    /// by the performance probe. Debug and crash pages are deliberately absent.
    public static let exposedChromePages: Set<String> = [
        "settings", "password-manager", "extensions", "history", "discards"
    ]

    private static let refusalLog = Logger(subsystem: "local.orbit", category: "navigation-guard")
    private static let refused = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    public static func isShellNavigable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        let hasAuthorityExtras = components.user != nil || components.password != nil || components.port != nil
        switch scheme {
        case "http", "https":
            return components.host?.isEmpty == false
        case "about":
            // Only the blank document; other about: pages map to engine internal pages.
            return components.percentEncodedPath == "blank" && components.host == nil
        case "data", "blob":
            return true
        case "file":
            // Local documents still need the shell's per-surface file grant at the policy layer.
            let host = components.host?.lowercased() ?? ""
            return (host.isEmpty || host == "localhost") && !hasAuthorityExtras
        case "view-source":
            return isViewSourceOfWebDocument(url)
        case "chrome-extension":
            return isExtensionDocument(url)
        case "chrome":
            guard !hasAuthorityExtras, let host = components.percentEncodedHost?.lowercased(),
                  host.utf8.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || $0 == UInt8(ascii: "-") })
            else { return false }
            return exposedChromePages.contains(host)
        default:
            return false
        }
    }

    /// `isShellNavigable`, logging the first refusal of each scheme (and Chromium page) once,
    /// without the rest of the address.
    public static func admits(_ url: URL, engine: String) -> Bool {
        guard !isShellNavigable(url) else { return true }
        let scheme = url.scheme?.lowercased() ?? "none"
        let page = scheme == "chrome" ? (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedHost ?? "") : ""
        let key = "\(engine) \(scheme) \(page)"
        let first = refused.withLock { $0.insert(key).inserted }
        if first {
            refusalLog.notice("Refused shell load: engine=\(engine, privacy: .public) scheme=\(scheme, privacy: .public) page=\(page, privacy: .public)")
        }
        return false
    }

    /// A source document wraps exactly one absolute HTTP(S) URL.
    public static func isViewSourceOfWebDocument(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "view-source",
              let document = URL(string: String(url.absoluteString.dropFirst("view-source:".count))) else { return false }
        return ["http", "https"].contains(document.scheme?.lowercased() ?? "")
            && document.host?.isEmpty == false
    }

    /// A Chrome extension document with a stable ID or an MV3 dynamic UUID, without credentials
    /// or port.
    public static func isExtensionDocument(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "chrome-extension", let host = url.host,
              url.user == nil, url.password == nil, url.port == nil else { return false }
        let stableID = host.utf8.count == 32
            && host.utf8.allSatisfy { (UInt8(ascii: "a")...UInt8(ascii: "p")).contains($0) }
        let dynamicID = UUID(uuidString: host).map { $0.uuidString.lowercased() == host } ?? false
        return stableID || dynamicID
    }
}
