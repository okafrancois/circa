import AppKit
import BrowserCore
import BrowserEngine
import Foundation
import WebKitEngine


/// The engine this build hosts. WebKit is the development and fallback backend.
typealias ActiveEngine = WebKitBrowserEngine

typealias OrbitEnvironment = BrowserEnvironment<ActiveEngine>
typealias OrbitWindowController = BrowserWindowController<ActiveEngine>

@MainActor
func makeActiveEngine() -> ActiveEngine { WebKitBrowserEngine() }

@MainActor
func makePrivateEngine() -> ActiveEngine { WebKitBrowserEngine() }

/// Session file used without `--session-file` or `--ephemeral`.
func activeDefaultSessionFile() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Orbit Native", isDirectory: true)
        .appendingPathComponent("session.json")
}

/// Synthetic-run confinement of the session file: none for WebKit previews, which never use the
/// Chromium data root or the mock Keychain.
func activeSyntheticDataGuard() -> SyntheticDataGuard? { nil }

/// Fingerprint of the stable signing certificate built into the product: none, a WebKit preview
/// is never the Orbit product.
func activeDeveloperSigningTeam() -> String? { nil }

func activeStableSigningRoot() -> String? { nil }

/// WebKit previews have no separate engine root.
func activeEngineRootHadDataAtLaunch() -> Bool { false }

/// Process entry for this build. WebKit needs nothing before AppKit starts.
@MainActor
enum OrbitLauncher {
    static var siteSessionResult: ArcSiteSessionResult?
    static var siteSessionFailed = false
    static func run() {
        let application = NSApplication.shared
        let delegate = OrbitApplication()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

// Names kept for the WebKit preview build and its windowless integration tests.
typealias PreviewEnvironment = BrowserEnvironment<WebKitBrowserEngine>
typealias PreviewWindowController = BrowserWindowController<WebKitBrowserEngine>
typealias PreviewSurface = WebKitSurface

extension BrowserEnvironment where Engine == WebKitBrowserEngine {
    /// A temporary WebKit environment that never touches a session file.
    convenience init() {
        self.init(engine: WebKitBrowserEngine())
    }

    static func open(sessionFile: URL?) async throws -> BrowserEnvironment {
        try await open(engine: WebKitBrowserEngine(), sessionFile: sessionFile)
    }
}

/// PEEK-R2 interim seam: WebKit describes the navigation or new target being asked about, until
/// CONTRACT-R2 carries this metadata in the contract itself.
extension WebKitBrowserEngine: BrowserNavigationMetadataSource {
    func pendingNavigationMetadata(for surface: AnyObject) -> BrowserNavigationMetadata? {
        guard let metadata = (surface as? WebKitSurface)?.pendingActionMetadata else { return nil }
        let kind: BrowserNavigationMetadata.Kind = switch metadata.kind {
        case .linkActivated: .linkActivation
        case .formSubmitted, .formResubmitted: .formSubmission
        case .backForward: .backForward
        case .reload: .reload
        case .redirect: .redirect
        case .other: .other
        }
        return BrowserNavigationMetadata(kind: kind, httpMethod: metadata.httpMethod, hasBody: metadata.hasBody)
    }
}

func activeSiteSessionConfiguration() -> OrbitProductConfiguration? { nil }
