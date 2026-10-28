import AppKit
import BrowserCore
import BrowserShell

/// Engine families known to the shell. Used for diagnostics and capability reporting only;
/// shell features must branch on `BrowserEngineCapabilities`, never on the kind.
public enum BrowserEngineKind: String, Sendable {
    case webKit
    case chromium
    case synthetic
}

/// Behaviours that a shell feature must check before offering them. A missing capability
/// blocks the path explicitly; it is never emulated by replaying a URL or scraping a page.
public struct BrowserEngineCapabilities: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Find can count without selecting and reports exact totals and ordinals.
    public static let exactFindCount = Self(rawValue: 1 << 0)
    /// The engine persists zoom per profile and site by itself.
    public static let nativeSiteZoom = Self(rawValue: 1 << 1)
    public static let downloadPause = Self(rawValue: 1 << 2)
    /// Resume uses engine resume state, never a replacement request.
    public static let downloadResume = Self(rawValue: 1 << 3)
    public static let snapshots = Self(rawValue: 1 << 4)
    public static let mediaPlaybackState = Self(rawValue: 1 << 5)
    public static let mediaCaptureState = Self(rawValue: 1 << 6)
    /// The engine reports whether a document is currently audible.
    public static let audibleState = Self(rawValue: 1 << 7)
    public static let audioMuting = Self(rawValue: 1 << 8)
    public static let favicons = Self(rawValue: 1 << 9)
    public static let mediaCapturePermissions = Self(rawValue: 1 << 10)
    /// A live surface can move between shell containers (window, Split pane, Peek, Little Orbit)
    /// without reloading, losing its opener, form state or history. Moves go through
    /// `BrowserSurfaceTransfer`, which changes owner and delegate together.
    public static let liveSurfaceTransfer = Self(rawValue: 1 << 11)
    /// Site data can survive relaunch in a store bound to the profile.
    public static let persistentProfiles = Self(rawValue: 1 << 12)
    /// Installation, update and APIs of Chrome Web Store extensions.
    public static let chromeWebStoreExtensions = Self(rawValue: 1 << 13)
    public static let devTools = Self(rawValue: 1 << 14)
    public static let printing = Self(rawValue: 1 << 15)
    /// Native Save Page As flow for the displayed document.
    public static let pageSaving = Self(rawValue: 1 << 24)
    /// Snapshots can include the complete scrollable document.
    public static let fullPageSnapshots = Self(rawValue: 1 << 25)
    /// A policy question can stay open after the delegate returns (`BrowserPolicyDecision.suspend()`):
    /// the engine holds the original request natively and resumes it, never replays it. Without
    /// this capability the delegate answers synchronously from state it prepared ahead, as stock
    /// CEF `CefRequestHandler::OnBeforeBrowse` requires.
    public static let suspendablePolicyDecisions = Self(rawValue: 1 << 16)
    /// The engine asks `decidePolicyFor response` for main-frame responses before rendering or
    /// downloading them (WebKit). Stock CEF has no such UI-thread hook: Chromium decides download
    /// versus render itself and reports downloads through `didStartDownload`. Shell features never
    /// depend on the response question; the first commit is the contract-level "displayable"
    /// signal (see `surfaceDidCommitNavigation`).
    public static let navigationResponsePolicy = Self(rawValue: 1 << 17)
    /// A `.download` answer converts the original request into a download natively, without a
    /// new request (WebKit `WKNavigationActionPolicy.download`/`WKNavigationResponsePolicy.download`).
    /// Without it an engine never recommends a download (`shouldPerformDownload`) and treats a
    /// `.download` answer as `.allow`: its own download handler decides (CEF `OnBeforeDownload`
    /// for non-renderable or attachment responses), never `StartDownload` on the same URL.
    public static let navigationDownloadConversion = Self(rawValue: 1 << 18)
    /// Removal of all engine-owned storage for an unused profile, with completion and errors.
    public static let profileRemoval = Self(rawValue: 1 << 19)
    /// The engine reports context menu requests (`showContextMenu`) instead of showing its own menu,
    /// and performs `BrowserContextMenuCommand`s (CH-ESSENTIALS).
    public static let pageContextMenus = Self(rawValue: 1 << 20)
    /// `confirmClose()` runs the document's beforeunload handlers, with the dialog through
    /// `runJavaScriptDialog`, before the shell closes a tab (CH-ESSENTIALS).
    public static let beforeUnloadOnClose = Self(rawValue: 1 << 21)
    /// Warnings for dangerous sites and downloads from a working Safe Browsing service (WebKit: the
    /// fraudulent-website warning, on by default). Chromium without a Google API key has none
    /// (CHROMIUM-APP-R3): the shell shows it as unavailable.
    public static let safeBrowsing = Self(rawValue: 1 << 22)
    /// The engine renders Chrome extension documents (`chrome-extension://<id>/…`) in its surfaces
    /// and frames and enforces their access rules itself (installed and enabled extension,
    /// web-accessible resources for frames a site embeds, profile). The shell then lets such
    /// navigations proceed instead of cancelling them as unknown schemes (EXT-OUTCOME-R1).
    public static let extensionDocuments = Self(rawValue: 1 << 23)
}

/// A tab the engine created by itself in a shell window (`setEngineTabAdoption`).
public struct BrowserEngineTabRequest: Sendable, Equatable {
    /// The document the engine is loading, when known.
    public var url: URL?
    /// The profile of the native browser that holds the tab; the shell never changes it.
    public var profileID: ProfileID
    /// The engine activates the tab (an extension's `active: true`, the default).
    public var isForeground: Bool

    public init(url: URL?, profileID: ProfileID, isForeground: Bool) {
        self.url = url
        self.profileID = profileID
        self.isForeground = isForeground
    }
}

public enum BrowserEngineError: Error, Equatable, Sendable {
    case unsupportedOperation
    case surfaceDisposed
    case snapshotUnavailable
    /// The requested document generation is no longer, or not yet, the visible document.
    case documentChanged
    case profileInUse
    /// Removal started but left engine artifacts of the profile behind (CHROMIUM-APP-R2).
    case profileRemovalIncomplete
}

public enum BrowserWebsiteDataPersistence: Sendable, Equatable {
    /// Site data lives in memory and disappears with the engine.
    case ephemeral
    /// Site data persists in an engine store derived from the profile identity.
    case persistent
}

/// A profile's isolated engine storage: cookies, caches, site storage, permissions,
/// service workers and, where supported, extensions. A profile maps to exactly one store for
/// the engine's lifetime; distinct profiles never share one.
public struct BrowserEngineProfile: Sendable, Equatable {
    public let profileID: ProfileID
    public let persistence: BrowserWebsiteDataPersistence

    public init(profileID: ProfileID, persistence: BrowserWebsiteDataPersistence) {
        self.profileID = profileID
        self.persistence = persistence
    }
}

/// The engine-independent entry point. The shell owns windows, layout, selection, Spaces and
/// persistence; an engine owns documents, their processes and per-profile site data.
/// Threading: every requirement runs on the main actor. Callbacks arrive on the main actor.
@MainActor
public protocol BrowserEngine: AnyObject {
    associatedtype Surface: BrowserEngineSurface

    var kind: BrowserEngineKind { get }
    var capabilities: BrowserEngineCapabilities { get }

    /// Resolves, creating on first use, the isolated store of a profile.
    func profile(for profileID: ProfileID) -> BrowserEngineProfile

    /// Creates a live surface in the profile's store, bound to `delegate` (held weakly).
    /// Creation never loads: the surface delivers no delegate event and starts no request until
    /// the caller's first command. The caller records ownership and observers, sets `placement`,
    /// then starts the first load with `navigate(to:)`. See "Creation and readiness" on
    /// `BrowserEngineSurface`.
    func makeSurface(profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<Surface>) -> Surface

    /// Extension services. Nil when the engine has none; callers must not emulate them.
    var extensions: (any BrowserExtensionHost)? { get }
    /// Narrow native manager route; does not imply inventory, actions or Store compatibility.
    var extensionManagement: (any BrowserExtensionManagement)? { get }

    /// Shell windows (CHROMIUM-APP). The shell shows the surfaces whose `placement.windowID` is
    /// `windowID` in `window`. Engines that model windows natively (hosted Chromium: one logical
    /// Chrome `Browser` per window and profile, the source of extension `windows`/`tabs`
    /// identities) bind those surfaces to it. Call before the first placement naming the window;
    /// repeated calls with the same pair are ignored. Default: nothing.
    func shellWindowDidOpen(_ windowID: WindowID, window: NSWindow)
    /// The shell window closes. Its surfaces were disposed or moved away before. Default: nothing.
    func shellWindowWillClose(_ windowID: WindowID)
    /// (EXT-OUTCOME-R1) Tabs the engine creates by itself in a shell window — an extension's
    /// `chrome.tabs.create`, an options page opened in a tab, onboarding after an install —
    /// are offered to `adopt`, synchronously, before they exist natively. `adopt` returns the
    /// surface made through its `make` closure once the shell recorded it, or nil to leave the
    /// tab unhosted. Nil removes the handler (call it before `shellWindowWillClose`). Engines
    /// without such tabs ignore it. Default: nothing.
    func setEngineTabAdoption(for windowID: WindowID,
                              _ adopt: (@MainActor (BrowserEngineTabRequest, () -> Surface) -> Surface?)?)
    /// (CHROMIUM-APP-R2) The shell is about to move live surfaces of one window into the tabs of
    /// `windowID` (a tab or a Split group, `liveSurfaceTransfer`), before it releases them. An
    /// engine whose tabs belong to native windows moves them now, all or none (hosted Chromium:
    /// `TabStripModel` detach and insert, `tabs.onDetached/onAttached`). False refuses the move:
    /// every surface stays where it was and the shell gives the move up. Should the shell move
    /// fail later, the surfaces return to their source placement, and the engine follows that
    /// placement again. Default: true.
    func shellWillMoveSurfaces(_ surfaces: [Surface], toWindow windowID: WindowID) -> Bool
    /// (CHROMIUM-APP-R3) The move announced by `shellWillMoveSurfaces` settled: `committed` when the
    /// destination recorded the surfaces, false when they went back to their source (refusal,
    /// failed recording, released nothing). An engine keeps its source state (a native window, the
    /// tab's index) until this call, and restores it when not committed. Default: nothing.
    func shellDidFinishMovingSurfaces(_ surfaces: [Surface], toWindow windowID: WindowID, committed: Bool)
    /// (CHROMIUM-APP-R2) The live tabs of `windowID`, in its sidebar order (Favorites, Pinned,
    /// Today, then live tabs of other Spaces). Engines exposing tab indices to extensions mirror
    /// it. Sent when the order changes. Default: nothing.
    func shellWindowTabOrderDidChange(_ windowID: WindowID, surfaces: [Surface])

    /// Engine-side hooks used only by `BrowserEngineConformance` to observe behaviour the shell
    /// API cannot, such as real store isolation. Nil fails conformance.
    var conformanceProbe: (any BrowserEngineConformanceProbe<Surface>)? { get }

    /// Removes every engine-owned artifact of an unused profile, including cookies, cache,
    /// preferences, extensions and encrypted storage. Idempotent for an absent profile. Must
    /// reject live surfaces, await native teardown, and throw on incomplete or failed cleanup.
    /// The shell quarantines the model identity before calling this method.
    func removeProfile(_ profileID: ProfileID) async throws

    /// Releases engine-wide resources. Call after every surface has been disposed. Returns only
    /// once each disposed surface finished its asynchronous engine teardown (CEF: `OnBeforeClose`
    /// for every browser) and reports `isTeardownComplete`, and process-wide state is released;
    /// the engine is unusable afterwards. The application bounds the wait
    /// (`BrowserTermination.detachAndShutDown`), so a hang delays quitting but never blocks it.
    func shutdown() async
}

public extension BrowserEngine {
    var extensionManagement: (any BrowserExtensionManagement)? { nil }
    var conformanceProbe: (any BrowserEngineConformanceProbe<Surface>)? { nil }
    /// Source-compatible migration only; absence is never treated as successful cleanup.
    func removeProfile(_ profileID: ProfileID) async throws { throw BrowserEngineError.unsupportedOperation }

    func shellWindowDidOpen(_ windowID: WindowID, window: NSWindow) {}
    func shellWindowWillClose(_ windowID: WindowID) {}
    func setEngineTabAdoption(for windowID: WindowID,
                              _ adopt: (@MainActor (BrowserEngineTabRequest, () -> Surface) -> Surface?)?) {}
    func shellWillMoveSurfaces(_ surfaces: [Surface], toWindow windowID: WindowID) -> Bool { true }
    func shellDidFinishMovingSurfaces(_ surfaces: [Surface], toWindow windowID: WindowID, committed: Bool) {}
    func shellWindowTabOrderDidChange(_ windowID: WindowID, surfaces: [Surface]) {}

    @available(*, unavailable, message: """
        Create with makeSurface(profileID:delegate:), record ownership, then call navigate(to:). \
        See docs/native-port/engine-contract-changes.md.
        """)
    func makeSurface(
        profileID: ProfileID, initialURL: URL?, delegate: (any BrowserEngineSurfaceDelegate<Surface>)?
    ) -> Surface {
        fatalError("unavailable")
    }
}

/// Behavioural probes that let the conformance harness prove what declared identifiers cannot.
/// Implementations must go through the very store that the surface's documents use (WebKit: the
/// web view's `WKWebsiteDataStore`; CEF: the browser's `GetRequestContext()` cookie manager),
/// never a parallel registry keyed by profile.
@MainActor
public protocol BrowserEngineConformanceProbe<Surface>: AnyObject {
    associatedtype Surface: BrowserEngineSurface

    /// Stores a site-data marker (a cookie of `origin`) as documents of `surface` would.
    func writeSiteDataMarker(_ value: String, for origin: URL, through surface: Surface) async throws
    /// Reads the marker as documents of `surface` would see it; nil when absent.
    func readSiteDataMarker(for origin: URL, through surface: Surface) async throws -> String?
    /// Evaluates `script` in the main frame of the surface's current document, as a user gesture
    /// (so it may open popups and submit forms), and returns its result converted to a string, nil
    /// for `undefined`/`null`. Used to drive and observe loopback fixture pages (focus, opener,
    /// POST bodies). Real engines must implement it (WebKit: `evaluateJavaScript`; CEF: DevTools
    /// `Runtime.evaluate` with `userGesture`); the default throws `unsupportedOperation`.
    func evaluateScript(_ script: String, in surface: Surface) async throws -> String?
}

public extension BrowserEngineConformanceProbe {
    func evaluateScript(_ script: String, in surface: Surface) async throws -> String? {
        throw BrowserEngineError.unsupportedOperation
    }
}
