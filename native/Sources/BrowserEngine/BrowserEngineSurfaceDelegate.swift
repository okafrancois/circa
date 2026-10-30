import AppKit
import BrowserCore
import BrowserShell

/// Modifier keys captured with the user gesture that started an engine request.
public struct BrowserModifierKeys: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)
}

/// How a navigation was initiated, as the engine reports it (CONTRACT-R2).
/// WebKit: `WKNavigationAction.navigationType`; `.typed` when the request is the one the shell
/// started with `navigate(to:)`; `.redirect` inferred for an `.other` main-frame question while a
/// provisional navigation is in progress. CEF: `CefRequest::GetTransitionType()` source
/// (`TT_LINK`, `TT_EXPLICIT`, `TT_FORM_SUBMIT`, `TT_RELOAD`) and qualifiers
/// (`TT_FORWARD_BACK_FLAG`, `TT_CLIENT_REDIRECT_FLAG`/`TT_SERVER_REDIRECT_FLAG`), and
/// `OnBeforeBrowse(is_redirect)`.
public enum BrowserNavigationKind: String, Sendable, Equatable {
    /// A link activated in the page (click, keyboard, script `click()`).
    case linkActivation
    /// A form submission or resubmission.
    case formSubmission
    case reload
    /// A history traversal (back, forward, history index).
    case backForward
    /// A server or client redirect of a navigation in progress.
    case redirect
    /// Started by the shell (`navigate(to:)`: address field, bookmark, restored tab).
    case typed
    /// Script-initiated (`location`, `window.open` without a link) or unknown.
    case other
}

/// Where the page asked a navigation to happen (CONTRACT-R2). CEF: the window-open disposition
/// of `OnBeforePopup`/`OnOpenURLFromTab` (`CEF_WOD_CURRENT_TAB`, `CEF_WOD_NEW_FOREGROUND_TAB`,
/// `CEF_WOD_NEW_BACKGROUND_TAB`, `CEF_WOD_NEW_WINDOW`, `CEF_WOD_NEW_POPUP`). WebKit: a nil
/// `targetFrame` or `createWebView` with window features and modifier keys.
public enum BrowserNavigationDisposition: String, Sendable, Equatable {
    case currentTab
    case newForegroundTab
    case newBackgroundTab
    case newWindow
    /// A sized window requested with window features (`window.open` with a size or position).
    case popup
}

/// A navigation that the engine is about to start in an existing surface.
/// Nil metadata means the engine cannot observe it, never a default: WebKit, for example, does
/// not expose whether a navigation carries a user gesture.
public struct BrowserNavigationAction: Sendable, Equatable {
    public var url: URL?
    /// The engine recommends a download, for example for a `download` attribute.
    public var shouldPerformDownload: Bool
    /// Nil when the engine cannot tell, for example for a new target.
    public var isMainFrame: Bool?
    public var modifiers: BrowserModifierKeys
    /// 0 for none or primary, 1 for secondary, 2 for middle, as reported by the engine.
    public var buttonNumber: Int
    public var kind: BrowserNavigationKind
    /// Upper-case HTTP method (`GET`, `POST`); nil when unknown.
    public var httpMethod: String?
    /// Whether the request carries a body (form POST); nil when the engine does not expose it.
    public var hasBody: Bool?
    /// Whether a user gesture started the navigation (CEF `user_gesture`); nil when unknown.
    public var isUserGesture: Bool?
    public var disposition: BrowserNavigationDisposition
    /// Engine-reported parent frame. Nil for main frames and adapters without this metadata.
    public var parentFrameURL: URL?

    public init(url: URL?, shouldPerformDownload: Bool = false, isMainFrame: Bool? = nil,
                modifiers: BrowserModifierKeys = [], buttonNumber: Int = 0,
                kind: BrowserNavigationKind = .other, httpMethod: String? = nil, hasBody: Bool? = nil,
                isUserGesture: Bool? = nil, disposition: BrowserNavigationDisposition = .currentTab, parentFrameURL: URL? = nil) {
        self.url = url
        self.parentFrameURL = parentFrameURL
        self.shouldPerformDownload = shouldPerformDownload
        self.isMainFrame = isMainFrame
        self.modifiers = modifiers
        self.buttonNumber = buttonNumber
        self.kind = kind
        self.httpMethod = httpMethod
        self.hasBody = hasBody
        self.isUserGesture = isUserGesture
        self.disposition = disposition
    }
}

/// A navigation that changed the address without a new document (CONTRACT-R2): fragment
/// navigations and the History API (`pushState`, `replaceState`, `popstate`). No commit, no new
/// `documentGeneration`; `navigationState.url` already shows `url` when it is reported.
public struct BrowserSameDocumentNavigation: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// Only the fragment changed (anchors, `location.hash`).
        case fragment
        /// The History API changed the address. Public WebKit and CEF APIs do not tell push,
        /// replace and pop apart.
        case historyState
    }

    public var url: URL
    public var kind: Kind

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }

    /// Classifies a same-document address change from the previous address.
    public init(url: URL, previous: URL?) {
        self.url = url
        func withoutFragment(_ url: URL?) -> String? {
            guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.fragment = nil
            return components.string
        }
        kind = previous != nil && withoutFragment(url) == withoutFragment(previous) ? .fragment : .historyState
    }
}

public enum BrowserNavigationActionPolicy: Sendable, Equatable {
    case allow
    case cancel
    case download
}

/// One open answer to an engine policy question, handed to the delegate with the question.
/// Engines ask synchronously and read the answer as soon as the delegate returns:
/// - The delegate answers with `decide(_:)` before returning, from state the shell prepared
///   ahead (ownership, routing rules, site settings). This is the only mode of engines whose
///   native hook is synchronous, such as stock CEF `OnBeforeBrowse`; the UI thread is never
///   blocked waiting for an answer.
/// - When `canSuspend` is true (the engine advertises `suspendablePolicyDecisions`), the delegate
///   may call `suspend()` and `decide(_:)` later. The engine keeps the original request suspended
///   natively, with its method, body, opener and user gesture, and resumes it.
/// - An unanswered question, a refused suspension, or a surface disposed while suspended resolves
///   to `fallback`, which is always the non-destructive answer.
/// No mode cancels and replays a request: a cancelled navigation is gone, and neither the engine
/// nor the shell re-issues its URL to emulate a decision.
@MainActor
public final class BrowserPolicyDecision<Policy: Sendable & Equatable> {
    public let canSuspend: Bool
    public let fallback: Policy
    /// The resolved answer, nil while open.
    public private(set) var policy: Policy?
    public private(set) var isSuspended = false
    private var isSynchronousTurnOpen = true
    private var onResolve: ((Policy) -> Void)?

    /// Engine side. `onResolve` runs exactly once, possibly inside the delegate call.
    public init(canSuspend: Bool, fallback: Policy, onResolve: @escaping (Policy) -> Void) {
        self.canSuspend = canSuspend
        self.fallback = fallback
        self.onResolve = onResolve
    }

    public var isResolved: Bool { policy != nil }

    /// Answers the question. The first answer wins; later calls are ignored.
    public func decide(_ policy: Policy) {
        guard self.policy == nil else { return }
        self.policy = policy
        let resolve = onResolve
        onResolve = nil
        resolve?(policy)
    }

    /// Keeps the question open after the delegate returns. Returns false, and the delegate must
    /// answer now, when the engine cannot suspend, after an answer, or after the delegate call.
    @discardableResult
    public func suspend() -> Bool {
        guard canSuspend, policy == nil, isSynchronousTurnOpen else { return false }
        isSuspended = true
        return true
    }

    /// Engine side: call right after the delegate returns. An unanswered, unsuspended question
    /// resolves to `fallback`.
    public func endSynchronousTurn() {
        isSynchronousTurnOpen = false
        if policy == nil, !isSuspended { decide(fallback) }
    }

    /// Engine side: resolves a still open question with `fallback`, for example on disposal.
    public func abandon() {
        isSynchronousTurnOpen = false
        decide(fallback)
    }
}

/// The response of a navigation, before the engine renders or downloads it.
public struct BrowserNavigationResponse: @unchecked Sendable {
    /// Foundation's response type; header access goes through `HTTPURLResponse` when available.
    public let response: URLResponse
    public let canShowMIMEType: Bool
    public let isForMainFrame: Bool

    public init(response: URLResponse, canShowMIMEType: Bool, isForMainFrame: Bool) {
        self.response = response
        self.canShowMIMEType = canShowMIMEType
        self.isForMainFrame = isForMainFrame
    }
}

public enum BrowserNavigationResponsePolicy: Sendable, Equatable {
    case allow
    case cancel
    case download
}

/// A request to open a new target: `window.open`, `target=_blank`, modified clicks.
/// The engine-created surface inherits the source profile, opener and original request,
/// including POST bodies; the shell decides where it lives or refuses it. Metadata as for
/// `BrowserNavigationAction`; nil means unknown.
public struct BrowserNewSurfaceRequest: Sendable, Equatable {
    public var url: URL?
    public var modifiers: BrowserModifierKeys
    public var buttonNumber: Int
    public var kind: BrowserNavigationKind
    public var httpMethod: String?
    public var hasBody: Bool?
    public var isUserGesture: Bool?
    /// Never `.currentTab`.
    public var disposition: BrowserNavigationDisposition

    public init(url: URL?, modifiers: BrowserModifierKeys = [], buttonNumber: Int = 0,
                kind: BrowserNavigationKind = .other, httpMethod: String? = nil, hasBody: Bool? = nil,
                isUserGesture: Bool? = nil, disposition: BrowserNavigationDisposition = .newForegroundTab) {
        self.url = url
        self.modifiers = modifiers
        self.buttonNumber = buttonNumber
        self.kind = kind
        self.httpMethod = httpMethod
        self.hasBody = hasBody
        self.isUserGesture = isUserGesture
        self.disposition = disposition
    }
}

public enum BrowserPermissionKind: Sendable, Equatable {
    case camera
    case microphone
    case cameraAndMicrophone
    case geolocation
    case notifications
    case other(String)
}

public struct BrowserPermissionRequest: Sendable, Equatable {
    public var kind: BrowserPermissionKind
    /// Scheme, host and port of the requesting origin; never a full URL with path or query.
    public var origin: String
    public var isMainFrame: Bool

    public init(kind: BrowserPermissionKind, origin: String, isMainFrame: Bool) {
        self.kind = kind
        self.origin = origin
        self.isMainFrame = isMainFrame
    }
}

public enum BrowserPermissionDecision: Sendable, Equatable {
    case grant
    case deny
    /// Let the engine apply its default behaviour, usually its own prompt.
    case engineDefault
}

/// A download that the engine started for a surface. The shell either adopts it into its
/// coordinator, by creating exactly one transfer, or cancels it.
@MainActor
public protocol BrowserEngineDownload: AnyObject {
    var suggestedFilename: String { get }
    var sourceURL: URL? { get }
    func cancel()
    /// Creates the transfer adapter, at most once.
    func makeTransfer(
        chooseDestination: @escaping @MainActor (String) async -> URL?
    ) -> any BrowserEngineDownloadTransfer
}

@MainActor
public protocol BrowserEngineDownloadTransfer: BrowserDownloadTransfer {
    var onInvalidate: (() -> Void)? { get set }
    /// Starts sequenced reporting. Call synchronously after a successful registration.
    func attach(_ registration: BrowserDownloadRegistration)
}

/// One page-first key down in flight (CONTRACT, BL-CONTRACT-KEY-RECEIPT). The owner creates it
/// when the engine is about to send a shortcut candidate to the page, with the state its command
/// would target; the engine hands it back once if the page declines the key. The owner then
/// revalidates that state before acting: a selection, document or focus change in between drops
/// the command instead of applying it to the new target. Engines never re-send the key to the
/// page and never dispatch it a second time themselves.
@MainActor
public final class BrowserKeyReceipt {
    /// Shell state captured when the key went to the page.
    public let context: Any
    public private(set) var isConsumed = false

    public init(context: Any) { self.context = context }

    /// True exactly once: a receipt answers one unhandled key.
    public func consume() -> Bool {
        guard !isConsumed else { return false }
        isConsumed = true
        return true
    }
}

/// Where a key down goes before the page sees it (CONTRACT, BL-CONTRACT-KEY-RECEIPT).
public enum BrowserKeyRouting {
    /// The browser keeps the key; the page never receives it.
    case browser
    /// The page receives the key first. With a receipt, a key the page declines comes back through
    /// `surface(_:pageDidNotHandleKey:receipt:)`; without one, the engine's native fallback applies
    /// (WebKit and Alloy CEF: the application's main menu).
    case page(receipt: BrowserKeyReceipt?)
}

/// Engine-to-shell events for one surface. Implemented by the shell object that owns the
/// surface (a window controller today; Peek and Little Orbit containers later).
/// Every callback must re-verify ownership: a surface may have been closed, transferred
/// elsewhere or belong to a closed window by the time an event arrives.
@MainActor
public protocol BrowserEngineSurfaceDelegate<Surface>: AnyObject {
    associatedtype Surface: BrowserEngineSurface

    /// A completed native drop, never a renderer request. Return true after accepting it.
    func surface(_ surface: Surface, openDroppedFiles urls: [URL]) -> Bool

    func surfaceDidStartNavigation(_ surface: Surface)
    /// A new main-frame document committed and is displayable: find and zoom state of the previous
    /// document is obsolete. This is the contract-level signal that an engine-created surface has
    /// something to show (owners promote new targets on their first commit). A response that
    /// becomes a download never commits. CEF: `CefLoadHandler::OnLoadStart` for the main frame,
    /// called after commit; WebKit: `didCommit`.
    func surfaceDidCommitNavigation(_ surface: Surface)
    func surfaceDidFinishNavigation(_ surface: Surface)
    func surfaceDidFailNavigation(_ surface: Surface)
    /// The address changed without a new document (fragment, History API). Never preceded by a
    /// commit; find and zoom state stay valid. Default: nothing. CEF: `OnAddressChange` for the
    /// main frame without `OnLoadStart`; WebKit: a `url` change outside a provisional navigation.
    func surface(_ surface: Surface, didNavigateWithinDocument navigation: BrowserSameDocumentNavigation)

    /// Answer through `decision` (see `BrowserPolicyDecision`); its fallback is `.cancel`.
    /// `.download` converts the original request only with `navigationDownloadConversion`;
    /// other engines treat it as `.allow` and let their download handler decide.
    func surface(_ surface: Surface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>)
    /// Optional, asked only by engines with `navigationResponsePolicy`; the default allows. Answer
    /// through `decision`; its fallback is `.cancel`. Shell behaviour must not depend on it:
    /// download versus render is the engine's native decision (non-renderable MIME type or
    /// `Content-Disposition: attachment`), reported through `didStartDownload`, and a document is
    /// displayable at its commit, not at its response.
    func surface(_ surface: Surface, decidePolicyFor response: BrowserNavigationResponse,
                 decision: BrowserPolicyDecision<BrowserNavigationResponsePolicy>)

    /// Call `make` at most once, synchronously, to obtain the engine-created surface. Return it
    /// to accept the target or nil to refuse; a refused surface is released by the engine. The
    /// created surface starts with this delegate; an accepting owner (Peek, Little Orbit) may set
    /// its own `delegate` before returning. Its events start after this method returns.
    func surface(_ surface: Surface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> Surface) -> Surface?

    /// The document asked to close itself, for example with `window.close()`.
    func surfaceDidRequestClose(_ surface: Surface)

    /// A native engine focus request targets this exact live surface, including inactive Spaces.
    func surfaceDidRequestActivation(_ surface: Surface)

    func surface(_ surface: Surface, didStartDownload download: any BrowserEngineDownload)

    /// Permission prompts stay asynchronous: engines hold them natively (WebKit decision
    /// handlers, CEF permission callbacks) without blocking navigation.
    func surface(_ surface: Surface,
                 requestsPermission request: BrowserPermissionRequest) async -> BrowserPermissionDecision

    /// Page-first keyboard, asked by engines that expose the step (CEF `OnPreKeyEvent`) for key
    /// downs with Command, Control or Option, Escape, Tab and function keys. Default: the page,
    /// without a receipt.
    func surface(_ surface: Surface, willSendKeyToPage event: NSEvent) -> BrowserKeyRouting
    /// The page declined a key sent with `receipt` (CEF `OnKeyEvent`). Return true when the owner
    /// handled it. False lets the key end there: the engine performs no other dispatch. Default:
    /// false.
    func surface(_ surface: Surface, pageDidNotHandleKey event: NSEvent, receipt: BrowserKeyReceipt) -> Bool

    // MARK: Page-initiated surfaces (CH-ESSENTIALS, `BrowserPageInteraction.swift`)

    /// A JavaScript dialog of the surface's document. The engine holds the page until the answer;
    /// owners present it over that document only (tab-modal), never over another tab, and apply
    /// the dialog rules (one at a time, prevented additional dialogs). Default: `.suppressed`.
    func surface(_ surface: Surface, runJavaScriptDialog dialog: BrowserJavaScriptDialog) async -> BrowserJavaScriptDialogResponse
    /// The engine dropped the surface's pending dialogs (navigation, renderer gone, close): their
    /// answers are ignored from now on and their UI must go. Default: nothing.
    func surfaceDidResetJavaScriptDialogs(_ surface: Surface)
    /// An HTTP server or proxy asks for credentials. Nil cancels the request (the page then shows
    /// the server's 401/407 response). Default: nil.
    func surface(_ surface: Surface,
                 requestsCredentialsFor challenge: BrowserAuthenticationChallenge) async -> BrowserCredential?
    /// The page opened a file chooser. Return the chosen files, or nil to cancel. Default: nil.
    func surface(_ surface: Surface, runFileChooser request: BrowserFileChooserRequest) async -> [URL]?
    /// The user asked for the context menu of the document (`pageContextMenus`). The engine shows no
    /// menu of its own; the owner builds one and performs page commands through
    /// `performContextMenuCommand(_:for:)`. Default: no menu.
    func surface(_ surface: Surface, showContextMenu request: BrowserContextMenuRequest)
    /// The document entered or left element fullscreen (Fullscreen API). The engine sizes the
    /// element to the surface's host view; the owner gives that view the whole screen (and gives
    /// it back) and calls `exitElementFullscreen()` for Escape. Default: nothing.
    func surface(_ surface: Surface, didChangeElementFullscreen isFullscreen: Bool)
    /// The document's renderer process ended. The surface keeps its address and history; `reload()`
    /// starts a new renderer. Engines also report `surfaceDidFailNavigation`. Default: nothing.
    func surface(_ surface: Surface, rendererDidTerminate termination: BrowserRendererTermination)
    /// The document's renderer stopped responding (true) or recovered (false). The owner offers to
    /// wait or exit the page (`perform(.waitForUnresponsiveRenderer)` /
    /// `.terminateUnresponsiveRenderer`). Default: nothing (the engine keeps waiting).
    func surface(_ surface: Surface, rendererDidBecomeUnresponsive isUnresponsive: Bool)
}

public extension BrowserEngineSurfaceDelegate {
    func surface(_ surface: Surface, openDroppedFiles urls: [URL]) -> Bool { false }
    func surfaceDidRequestActivation(_ surface: Surface) {}
    func surface(_ surface: Surface, didNavigateWithinDocument navigation: BrowserSameDocumentNavigation) {}

    func surface(_ surface: Surface, decidePolicyFor response: BrowserNavigationResponse,
                 decision: BrowserPolicyDecision<BrowserNavigationResponsePolicy>) {
        decision.decide(.allow)
    }

    func surface(_ surface: Surface,
                 requestsPermission request: BrowserPermissionRequest) async -> BrowserPermissionDecision {
        .engineDefault
    }

    func surface(_ surface: Surface, willSendKeyToPage event: NSEvent) -> BrowserKeyRouting {
        .page(receipt: nil)
    }

    func surface(_ surface: Surface, pageDidNotHandleKey event: NSEvent, receipt: BrowserKeyReceipt) -> Bool {
        false
    }

    func surface(_ surface: Surface, runJavaScriptDialog dialog: BrowserJavaScriptDialog) async -> BrowserJavaScriptDialogResponse {
        .suppressed
    }

    func surfaceDidResetJavaScriptDialogs(_ surface: Surface) {}

    func surface(_ surface: Surface,
                 requestsCredentialsFor challenge: BrowserAuthenticationChallenge) async -> BrowserCredential? {
        nil
    }

    func surface(_ surface: Surface, runFileChooser request: BrowserFileChooserRequest) async -> [URL]? { nil }

    func surface(_ surface: Surface, showContextMenu request: BrowserContextMenuRequest) {}

    func surface(_ surface: Surface, didChangeElementFullscreen isFullscreen: Bool) {}

    func surface(_ surface: Surface, rendererDidTerminate termination: BrowserRendererTermination) {}

    func surface(_ surface: Surface, rendererDidBecomeUnresponsive isUnresponsive: Bool) {}
}
