import AppKit
import BrowserCore
import BrowserShell

/// A value snapshot of the observable navigation state of one surface.
public struct BrowserNavigationState: Equatable, Sendable {
    /// Last known opaque site colour, retained while a new document is being measured.
    public var pageTint: BrowserPageTint?
    /// The displayed address, which can be provisional while a navigation is pending.
    public var url: URL?
    /// The address of the last committed document.
    public var committedURL: URL?
    public var title: String?
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// Nil when unknown or when the engine lacks `BrowserEngineCapabilities.favicons`.
    public var faviconURL: URL?
    /// Owned PNG from the exact surface/profile, never a global URL loader. Memory only.
    public var faviconImage: BrowserFaviconImage?

    /// False while a document reset is awaiting engine metadata. Legacy engines expose
    /// settled metadata when not loading; Chromium explicitly announces every transition.
    public var faviconMetadataIsSettled: Bool = true
    public var faviconRevision: UInt64 = 0

    public init(
        url: URL? = nil, committedURL: URL? = nil, title: String? = nil, isLoading: Bool = false,
        canGoBack: Bool = false, canGoForward: Bool = false, faviconURL: URL? = nil
    ) {
        self.url = url
        self.committedURL = committedURL
        self.title = title
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.faviconURL = faviconURL
    }
}

public enum BrowserPageZoomCommand: Sendable, Equatable {
    case increase
    case decrease
    case reset
}

public struct BrowserSnapshotRequest: Sendable, Equatable {
    /// Output width in points; nil keeps the surface width. Height follows the aspect ratio.
    public var width: CGFloat?
    /// Wait for pending screen updates before capturing.
    public var afterScreenUpdates: Bool
    /// Explicit user capture only; passive thumbnails keep the viewport default.
    public var fullPage: Bool
    /// The document to capture, from `documentGeneration`. When set, the capture fails with
    /// `documentChanged` unless this exact document is visible from start to completion, so a
    /// thumbnail can never show another document than the one it was requested for.
    public var documentGeneration: UInt64?

    public init(width: CGFloat? = nil, afterScreenUpdates: Bool = true, documentGeneration: UInt64? = nil, fullPage: Bool = false) {
        self.width = width
        self.afterScreenUpdates = afterScreenUpdates
        self.fullPage = fullPage
        self.documentGeneration = documentGeneration
    }
}

/// A captured image and the document generation it shows.
public struct BrowserSurfaceSnapshot: @unchecked Sendable {
    public let image: CGImage
    public let documentGeneration: UInt64

    public init(image: CGImage, documentGeneration: UInt64) {
        self.image = image
        self.documentGeneration = documentGeneration
    }
}

/// Where the shell currently shows a surface, maintained by its owner.
/// Engines use it to give extensions stable `windows`/`tabs` identities: the extension tab id is
/// derived from the surface itself and stays the same for its whole life, across moves between
/// windows, Peek and Little Orbit (as a Chrome tab keeps its id when dragged to another window);
/// the extension window id follows `windowID`, and a change of `windowID` is reported to
/// extensions as a detach followed by an attach. Engine-private host ids (CEF `browser_id`) are
/// never exposed as either id.
public struct BrowserSurfacePlacement: Sendable, Equatable {
    public enum Container: Sendable, Equatable {
        /// Not shown by any owner: newly created, or in transit between owners.
        case none
        /// A tab of `windowID`, recorded in the model as `occurrenceID`.
        case tab
        /// A Peek panel over `windowID`.
        case peek
        /// A Little Orbit window.
        case quickWindow
    }

    public var container: Container
    public var windowID: WindowID?
    public var occurrenceID: TabOccurrenceID?

    public init(container: Container, windowID: WindowID? = nil, occurrenceID: TabOccurrenceID? = nil) {
        self.container = container
        self.windowID = windowID
        self.occurrenceID = occurrenceID
    }

    public static let detached = BrowserSurfacePlacement(container: .none)

    public static func tab(windowID: WindowID, occurrenceID: TabOccurrenceID) -> BrowserSurfacePlacement {
        BrowserSurfacePlacement(container: .tab, windowID: windowID, occurrenceID: occurrenceID)
    }
}

public enum BrowserMediaPlaybackState: Sendable, Equatable {
    case unknown
    case none
    case playing
    case paused
    case suspended
}

public enum BrowserMediaCaptureState: Sendable, Equatable {
    case unknown
    case none
    case active
    case muted
}

public enum BrowserDeveloperPanel: String, Sendable { case console, network, elements }

/// Nil Booleans mean that the engine cannot observe the value, never that it is false.
public struct BrowserMediaState: Sendable, Equatable {
    public var playback: BrowserMediaPlaybackState
    public var camera: BrowserMediaCaptureState
    public var microphone: BrowserMediaCaptureState
    public var isAudible: Bool?
    /// Engine-reported audio playback activity, when acoustic audibility is unavailable.
    /// A running audio graph or an audio track can contain silence; this is not isAudible.
    public var isAudioPlaying: Bool?
    public var isAudioMuted: Bool?

    public init(
        playback: BrowserMediaPlaybackState = .unknown, camera: BrowserMediaCaptureState = .unknown,
        microphone: BrowserMediaCaptureState = .unknown, isAudible: Bool? = nil, isAudioMuted: Bool? = nil,
        isAudioPlaying: Bool? = nil
    ) {
        self.playback = playback
        self.camera = camera
        self.microphone = microphone
        self.isAudible = isAudible
        self.isAudioPlaying = isAudioPlaying
        self.isAudioMuted = isAudioMuted
    }
}

/// One live document container of an engine, bound to one immutable profile for its life.
/// Ownership: the shell decides where `hostView` is placed (content card, Split pane, Peek,
/// Little Orbit) and is the only party that reparents it. The engine never creates windows for a
/// surface; new targets go through `BrowserEngineSurfaceDelegate`. A surface has exactly one
/// owner and one delegate at a time; moves between owners go through `BrowserSurfaceTransfer`,
/// which changes both in one main-actor turn and never disposes or reloads the document.
/// Creation and readiness:
/// 1. `BrowserEngine.makeSurface(profileID:delegate:)` returns synchronously. It starts no
///    request and delivers no delegate event; `hostView` can be placed immediately.
/// 2. The caller records ownership and observers (`onChange`, `onDispose`, `placement`).
/// 3. The caller starts the first load with `navigate(to:)`. Events may then arrive
///    synchronously, inside that call, and reach an owner that already knows the surface.
/// `isReady` is false while the engine still creates the native document host asynchronously
/// (CEF: between `CreateBrowser` and `OnAfterCreated`). Commands issued before readiness are queued
/// by the adapter in call order and never dropped; `focusDocument()` is applied once ready.
/// Engine-created surfaces (new targets) are ready when `make()` returns and keep the request the
/// engine created them for; their events start after the delegate's `createSurfaceFor` returns.
/// Teardown: `dispose()` is synchronous for the shell (detaches `hostView`, stops events, answers
/// suspended policy decisions with their fallback); the engine may finish closing the document
/// later and then reports `isTeardownComplete`; `BrowserEngine.shutdown()` waits for that.
@MainActor
public protocol BrowserEngineSurface: BrowserFindSurface {
    var profileID: ProfileID { get }
    var hostView: NSView { get }
    var isDisposed: Bool { get }
    /// True once the engine finished closing the native document after `dispose()` (CEF:
    /// `OnBeforeClose`; WebKit: synchronously in `dispose()`). Engine-reported, never inferred
    /// from `isDisposed`; conformance requires it for every disposed surface once `shutdown()`
    /// returns. The default, false, fails conformance until an adapter reports it.
    var isTeardownComplete: Bool { get }
    /// See "Creation and readiness". Engines whose hosts exist on creation are always ready.
    var isReady: Bool { get }
    /// The single receiver of this surface's engine events, held weakly. A change takes effect
    /// for the next event, including later events of a navigation already in flight; decisions
    /// already handed out stay with the delegate that received them. Shell code changes it only
    /// inside a `BrowserSurfaceTransfer` so that owner and receiver move together. Without a
    /// delegate, policy questions get their fallback, new targets are refused and downloads
    /// cancelled.
    var delegate: (any BrowserEngineSurfaceDelegate<Self>)? { get set }
    /// Maintained by the owner; see `BrowserSurfacePlacement`. Starts as `.detached`.
    var placement: BrowserSurfacePlacement { get set }
    /// `currentURL`, inherited from `BrowserSurface`, prefers a shell-requested destination that
    /// has not committed yet; `navigationState.url` is what the engine displays.
    var navigationState: BrowserNavigationState { get }
    /// Opt-in observation for visible developer chrome. Engines without a colour source use nil.
    func setPageTintObservationEnabled(_ enabled: Bool)
    /// Native page colors as unpremultiplied ARGB. Changes are delivered through onChange.
    var pageThemeColor: UInt32? { get }
    var pageBackgroundColor: UInt32? { get }
    /// Current factor, 1 meaning actual size. Zoom commands may apply asynchronously; the change
    /// is reported through `onChange`. Zoom is defined for a committed document: before the first
    /// commit an engine may ignore zoom commands (Chromium indexes zoom by host).
    var pageZoom: Double { get }

    /// Coalesced observation hook for URL, title, history and zoom changes. Loading transitions
    /// are reported through the delegate's navigation lifecycle callbacks.
    var onChange: (() -> Void)? { get set }
    /// Called once, synchronously, at the start of `dispose()`.
    var onDispose: (() -> Void)? { get set }

    func navigate(to url: URL)
    /// Starts a history navigation and returns its destination, or nil when there is none.
    @discardableResult func goBack() -> URL?
    @discardableResult func goForward() -> URL?
    func reload()
    func stopLoading()
    /// After a cancelled quit, the stopped request no longer owns the displayed address.
    func cancelStoppedNavigationTracking()

    /// Moves keyboard focus into the document: the engine's document responder inside `hostView`
    /// becomes first responder and the engine focuses the page (CEF: `SetFocus(true)`). Returns
    /// false when `hostView` is not in a window. Shell code never calls
    /// `makeFirstResponder(hostView)` itself: a plain parent view is not the document responder.
    @discardableResult func focusDocument() -> Bool

    /// Applies the zoom policy of the engine. Engines without `nativeSiteZoom` scope the factor
    /// to the profile and host inside the adapter.
    func performZoom(_ command: BrowserPageZoomCommand)

    /// Captures the visible document. Throws `unsupportedOperation` without `snapshots`,
    /// `surfaceDisposed` after disposal and `documentChanged` when `request.documentGeneration`
    /// is not the document captured.
    func captureSnapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserSurfaceSnapshot
    /// Self-contained MHTML of this exact document, including its subresources.
    func archivePage(documentGeneration: UInt64) async throws -> Data
    func requestMediaState() async -> BrowserMediaState
    func captureStateForSuspension() async -> BrowserSuspensionState?
    /// Cheap final veto for native media/capture activity that arrived during an async check.
    var allowsSuspension: Bool { get }
    func restoreAfterSuspension(_ state: BrowserSuspensionState) async
    /// Throws `unsupportedOperation` without `audioMuting`.
    func setAudioMuted(_ muted: Bool) throws
    /// Selection lifecycle for the native video PiP window. Returning to its tab closes only
    /// PiP entered automatically; a manually requested PiP session remains user-owned.
    func updateAutomaticPictureInPicture(isSelected: Bool, allowed: Bool)
    func showDeveloperPanel(_ panel: BrowserDeveloperPanel) throws

    // MARK: Page surfaces (CH-ESSENTIALS)

    /// Asks the document whether it may close, running its beforeunload handlers (and their
    /// dialog through the delegate) when the engine has `beforeUnloadOnClose`. True: the shell
    /// closes it now. False: the user chose to stay; nothing changes. Never closes the surface
    /// itself. Default: true at once.
    func confirmClose() async -> Bool
    /// Leaves element fullscreen (Escape, the shell's own exit). Default: nothing.
    func exitElementFullscreen()
    /// Performs a context menu page command for `request` (`pageContextMenus`). Throws
    /// `documentChanged` when the request belongs to an older document, `unsupportedOperation`
    /// when the command is not in `request.availableCommands`.
    func performContextMenuCommand(_ command: BrowserContextMenuCommand, for request: BrowserContextMenuRequest) throws
    /// The shell's menu for `request` closed without a page command (nothing chosen, or a shell
    /// command): the engine releases its native menu. Default: nothing.
    func contextMenuDidClose(_ request: BrowserContextMenuRequest)
    /// A page command of the shell (`printing`, `devTools`). Throws `unsupportedOperation` when the
    /// engine lacks the capability.
    func perform(_ command: BrowserPageCommand) throws
}

public extension BrowserEngineSurface {
    func setPageTintObservationEnabled(_ enabled: Bool) {}
    func archivePage(documentGeneration: UInt64) async throws -> Data { throw BrowserEngineError.unsupportedOperation }
    func showDeveloperPanel(_ panel: BrowserDeveloperPanel) throws {
        try perform(panel == .elements ? .inspectElements : .showDevTools)
    }
    func updateAutomaticPictureInPicture(isSelected: Bool, allowed: Bool) {}
    func captureStateForSuspension() async -> BrowserSuspensionState? { nil }
    var allowsSuspension: Bool { false }
    func restoreAfterSuspension(_ state: BrowserSuspensionState) async {}
    var isReady: Bool { true }
    var isTeardownComplete: Bool { false }

    func confirmClose() async -> Bool { true }
    func exitElementFullscreen() {}
    func performContextMenuCommand(_ command: BrowserContextMenuCommand, for request: BrowserContextMenuRequest) throws {
        throw BrowserEngineError.unsupportedOperation
    }
    func contextMenuDidClose(_ request: BrowserContextMenuRequest) {}
    func perform(_ command: BrowserPageCommand) throws { throw BrowserEngineError.unsupportedOperation }

    /// Captures this surface's current delegate and observers, for a `rebind` closure: when a move
    /// out of the current owner fails, the surface comes back with exactly this binding.
    func restoringBinding() -> (Self) -> Void {
        weak let delegate = delegate
        let onChange = onChange
        let onDispose = onDispose
        let placement = placement
        return { surface in
            surface.delegate = delegate
            surface.onChange = onChange
            surface.onDispose = onDispose
            surface.placement = placement
        }
    }

    /// The generation of the visible document. It changes exactly when a different document
    /// commits, including same-URL reloads; find, zoom indicators and snapshots are scoped to it.
    var documentGeneration: UInt64 { findDocumentGeneration }
}

public extension BrowserEngineSurface {
    var pageThemeColor: UInt32? { nil }
    var pageBackgroundColor: UInt32? { nil }
}
