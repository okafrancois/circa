import AppKit
import BrowserEngine

@MainActor
final class BrowserExternalProtocolGate {
    static let shared = BrowserExternalProtocolGate()

    /// Schemes Chromium refuses to hand to the system (ExternalProtocolHandler's denylist) or that
    /// browsers handle themselves.
    static let deniedSchemes: Set<String> = [
        "http", "https", "about", "blob", "data", "file", "filesystem", "javascript", "vbscript", "view-source",
        "chrome", "chrome-untrusted", "chrome-extension", "devtools", "ws", "wss", "ftp",
        "afp", "disk", "disks", "hcp", "ie.http", "mk", "ms-help", "nntp", "res", "shell", "vnd.ms.radio"
    ]

    /// Display name of the application that opens `url`; nil when none. Replaceable by tests.
    var applicationName: (URL) -> String? = { url in
        NSWorkspace.shared.urlForApplication(toOpen: url).map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
    }
    /// Hands the URL to the system. Replaceable by tests and the hidden smoke (never launches there).
    var opener: (URL) -> Void = { url in NSWorkspace.shared.open(url) }
    private var pending: Set<ObjectIdentifier> = []
    /// Observation for tests and the smoke: decisions taken, in order.
    private(set) var log: [(scheme: String, outcome: String)] = []

    static func isExternal(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !deniedSchemes.contains(scheme)
    }

    /// Takes over a navigation to another application's URL. True when `action` was such a link: the
    /// caller cancels the navigation. A confirmation may follow on `hostView`, over its own page.
    func handle(_ action: BrowserNavigationAction, hostView: NSView, surface: ObjectIdentifier, pageURL: URL?) -> Bool {
        guard let url = action.url, Self.isExternal(url), let scheme = url.scheme?.lowercased() else { return false }
        if action.isMainFrame == false, action.isUserGesture != true {
            log.append((scheme, "dropped-subframe-without-gesture"))
            return true
        }
        guard !pending.contains(surface) else {
            log.append((scheme, "dropped-confirmation-pending"))
            return true
        }
        guard let application = applicationName(url) else {
            // As Chromium on macOS: nothing to open, nothing shown.
            log.append((scheme, "no-application"))
            return true
        }
        pending.insert(surface)
        log.append((scheme, "confirmation"))
        let spec = BrowserPageDialogText.externalProtocol(application: application,
                                                          origin: BrowserJavaScriptDialog.origin(of: pageURL))
        Task { @MainActor [weak self] in
            let result = await BrowserPageDialogCenter.shared.present(spec, on: hostView, surface: surface)
            guard let self else { return }
            self.pending.remove(surface)
            self.log.append((scheme, result.accepted ? "opened" : "cancelled"))
            if result.accepted { self.opener(url) }
        }
        return true
    }
}
