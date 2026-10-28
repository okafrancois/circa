import AppKit
import BrowserCore
import BrowserShell

// Page-initiated browser surfaces (CH-ESSENTIALS): JavaScript dialogs, HTTP authentication, file
// choosers, page context menus, element fullscreen and renderer termination, plus the page
// commands the shell starts (print, DevTools). Engines translate their native hooks into these
// engine-independent requests; the shell presents AppKit UI attached to the surface's own window
// and document, never to whatever happens to be selected when an answer arrives.
// See docs/native-port/ch-essentials-2026-10-25.md.

/// A JavaScript dialog requested by a document: `alert`, `confirm`, `prompt` or a beforeunload
/// confirmation (navigation, reload or close of a page with a `beforeunload` handler).
public struct BrowserJavaScriptDialog: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case alert
        case confirm
        case prompt(defaultText: String)
        /// The page asked to confirm leaving. Engines no longer pass the page's own message.
        case beforeUnload(isReload: Bool)
    }

    public var kind: Kind
    /// The page's message, unchanged; empty for beforeunload.
    public var message: String
    /// Scheme, host and port of the document that opened the dialog (never a full URL with path or
    /// query); nil when the engine does not tell (CEF beforeunload).
    public var origin: String?

    public init(kind: Kind, message: String, origin: String?) {
        self.kind = kind
        self.message = message
        self.origin = origin
    }

    /// Scheme, host and port of `url`, as `origin` expects.
    public static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased() else { return nil }
        guard let host = url.host, !host.isEmpty else { return scheme == "file" ? "file://" : nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(port)"
    }
}

/// The answer to a JavaScript dialog.
public enum BrowserJavaScriptDialogResponse: Sendable, Equatable {
    /// OK, or Leave/Reload for beforeunload. `text` is the prompt input (nil for other kinds).
    case accept(text: String?)
    /// Cancel or Stay. An alert treats it as dismissed.
    case cancel
    /// The shell did not show the dialog (one at a time, prevented additional dialogs, no owner).
    /// The page gets the cancel answer at once: `false`, `null`, and a beforeunload that proceeds
    /// (as Chromium does for a suppressed beforeunload dialog).
    case suppressed
}

/// An HTTP authentication challenge (basic, digest, NTLM, negotiate) of a server or a proxy.
public struct BrowserAuthenticationChallenge: Sendable, Equatable {
    /// Scheme, host and port of the request that met the challenge.
    public var origin: String
    public var host: String
    public var port: Int
    /// Realm announced by the server; nil when empty.
    public var realm: String?
    /// Authentication scheme in lower case (`basic`, `digest`...); nil when unknown.
    public var scheme: String?
    public var isProxy: Bool

    public init(origin: String, host: String, port: Int, realm: String?, scheme: String?, isProxy: Bool) {
        self.origin = origin
        self.host = host
        self.port = port
        self.realm = realm
        self.scheme = scheme
        self.isProxy = isProxy
    }
}

/// Credentials typed by the user for one challenge. Never logged, persisted or traced.
public struct BrowserCredential: Sendable, Equatable {
    public var user: String
    public var password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }
}

/// A file chooser opened by a page: `<input type=file>` (single, `multiple`, `webkitdirectory`),
/// a save dialog requested by the engine (`showSaveFilePicker`), or an engine-owned
/// existing-directory picker (for example, the genuine extension installer).
public struct BrowserFileChooserRequest: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case open
        case openMultiple
        /// Web folder upload, including its confirmation and file count.
        case openFolder
        /// Native existing-directory selection, with no upload semantics.
        case openExistingFolder
        case save
    }

    public var mode: Mode
    /// Title the page or engine asked for; nil for the default title.
    public var title: String?
    /// Suggested directory and/or file name; nil when none.
    public var defaultPath: String?
    /// The `accept` filters as given, lower case: MIME types (`image/*`, `text/plain`) and
    /// extensions with their dot (`.pdf`).
    public var acceptTypes: [String]
    /// File extensions without the dot, expanded from `acceptTypes` by the engine when it knows
    /// them; may be empty.
    public var acceptExtensions: [String]

    public init(mode: Mode, title: String? = nil, defaultPath: String? = nil,
                acceptTypes: [String] = [], acceptExtensions: [String] = []) {
        self.mode = mode
        self.title = title
        self.defaultPath = defaultPath
        self.acceptTypes = acceptTypes
        self.acceptExtensions = acceptExtensions
    }
}

/// An item supplied by Chromium's extension context-menu model for one request.
public struct BrowserExtensionMenuItem: Sendable, Equatable, Codable {
    public var commandID: Int32
    public var title: String
    public var isEnabled: Bool
    public var isChecked: Bool
    public var isSeparator: Bool
    public var children: [BrowserExtensionMenuItem]

    public init(commandID: Int32, title: String, isEnabled: Bool = true, isChecked: Bool = false,
                isSeparator: Bool = false, children: [BrowserExtensionMenuItem] = []) {
        self.commandID = commandID; self.title = title; self.isEnabled = isEnabled
        self.isChecked = isChecked; self.isSeparator = isSeparator; self.children = children
    }

    public func permits(_ id: Int32) -> Bool {
        isEnabled && !isSeparator && (children.isEmpty ? commandID == id : children.contains { $0.permits(id) })
    }
}

/// What a right click (or Control-click) in a document hit, as the engine reports it. The shell
/// builds its own menu from it and performs page commands through
/// `BrowserEngineSurface.performContextMenuCommand(_:for:)`.
public struct BrowserContextMenuRequest: Sendable, Equatable {
    public struct EditFlags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let canUndo = Self(rawValue: 1 << 0)
        public static let canRedo = Self(rawValue: 1 << 1)
        public static let canCut = Self(rawValue: 1 << 2)
        public static let canCopy = Self(rawValue: 1 << 3)
        public static let canPaste = Self(rawValue: 1 << 4)
        public static let canDelete = Self(rawValue: 1 << 5)
        public static let canSelectAll = Self(rawValue: 1 << 6)
        public static let canEditRichly = Self(rawValue: 1 << 7)
    }

    public enum MediaKind: String, Sendable, Equatable {
        case none, image, video, audio, canvas, file, plugin
    }

    public struct MediaState: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let paused = Self(rawValue: 1 << 0)
        public static let muted = Self(rawValue: 1 << 1)
        public static let loop = Self(rawValue: 1 << 2)
        public static let hasAudio = Self(rawValue: 1 << 3)
        public static let controlsVisible = Self(rawValue: 1 << 4)
        public static let canToggleControls = Self(rawValue: 1 << 5)
        public static let canPictureInPicture = Self(rawValue: 1 << 6)
    }

    /// Where the menu opens, in `hostView` coordinates with a top-left origin.
    public var location: CGPoint
    public var pageURL: URL?
    public var frameURL: URL?
    public var linkURL: URL?
    public var mediaKind: MediaKind
    /// Source of the image, video or audio element under the pointer.
    public var sourceURL: URL?
    public var hasImageContents: Bool
    /// `title` or `alt` text of the element under the pointer; nil when empty.
    public var titleText: String?
    /// Selected text; empty when none.
    public var selectionText: String
    public var isEditable: Bool
    public var editFlags: EditFlags
    public var mediaState: MediaState
    public var misspelledWord: String?
    public var spellingSuggestions: [String]
    /// The document the request belongs to: page commands for an older document are refused.
    public var documentGeneration: UInt64
    /// Page commands this engine can perform for this request.
    public var availableCommands: Set<BrowserContextMenuCommand.Kind>
    public var extensionItems: [BrowserExtensionMenuItem]

    public init(location: CGPoint, pageURL: URL? = nil, frameURL: URL? = nil, linkURL: URL? = nil,
                mediaKind: MediaKind = .none, sourceURL: URL? = nil, hasImageContents: Bool = false,
                titleText: String? = nil, selectionText: String = "", isEditable: Bool = false,
                editFlags: EditFlags = [], mediaState: MediaState = [], misspelledWord: String? = nil,
                spellingSuggestions: [String] = [], documentGeneration: UInt64,
                availableCommands: Set<BrowserContextMenuCommand.Kind> = [],
                extensionItems: [BrowserExtensionMenuItem] = []) {
        self.location = location
        self.pageURL = pageURL
        self.frameURL = frameURL
        self.linkURL = linkURL
        self.mediaKind = mediaKind
        self.sourceURL = sourceURL
        self.hasImageContents = hasImageContents
        self.titleText = titleText
        self.selectionText = selectionText
        self.isEditable = isEditable
        self.editFlags = editFlags
        self.mediaState = mediaState
        self.misspelledWord = misspelledWord
        self.spellingSuggestions = spellingSuggestions
        self.documentGeneration = documentGeneration
        self.availableCommands = availableCommands
        self.extensionItems = extensionItems
    }
}

/// A page command of a context menu, performed by the engine on the document of the request.
/// Shell commands (open a link in a new tab, Split View, copy an address, view source) never reach
/// the engine.
public enum BrowserContextMenuCommand: Sendable, Equatable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case undo, redo, cut, copy, paste, pasteAndMatchStyle, delete, selectAll
        case replaceMisspelling, addToDictionary
        case copyImage, saveImage, saveLink, saveMedia
        case mediaPlayPause, mediaMute, mediaLoop, mediaControls, mediaPictureInPicture
        case lookUp, inspect, extensionAction
    }

    case undo, redo, cut, copy, paste, pasteAndMatchStyle, delete, selectAll
    case replaceMisspelling(String)
    case addToDictionary(String)
    /// Copies the image under the pointer to the pasteboard.
    case copyImage
    /// Downloads the image, link or media target through the engine (the shell's download flow
    /// asks for the destination).
    case saveImage, saveLink, saveMedia
    case mediaPlayPause, mediaMute, mediaLoop, mediaControls, mediaPictureInPicture
    /// The system dictionary panel for the selection (macOS Look Up).
    case lookUp
    /// Opens DevTools on the element under the pointer.
    case inspect
    /// Native command ID, valid only in the exact context-menu request that supplied it.
    case extensionAction(Int32)

    public var kind: Kind {
        switch self {
        case .undo: .undo
        case .redo: .redo
        case .cut: .cut
        case .copy: .copy
        case .paste: .paste
        case .pasteAndMatchStyle: .pasteAndMatchStyle
        case .delete: .delete
        case .selectAll: .selectAll
        case .replaceMisspelling: .replaceMisspelling
        case .addToDictionary: .addToDictionary
        case .copyImage: .copyImage
        case .saveImage: .saveImage
        case .saveLink: .saveLink
        case .saveMedia: .saveMedia
        case .mediaPlayPause: .mediaPlayPause
        case .mediaMute: .mediaMute
        case .mediaLoop: .mediaLoop
        case .mediaControls: .mediaControls
        case .mediaPictureInPicture: .mediaPictureInPicture
        case .lookUp: .lookUp
        case .inspect: .inspect
        case .extensionAction: .extensionAction
        }
    }
}

/// Why a document's renderer process ended (CEF `TerminationStatus`, WebKit content process
/// termination). The document is gone until the next load or reload.
public enum BrowserRendererTermination: String, Sendable, Equatable {
    case crashed
    case killed
    case outOfMemory
    /// The engine reports a termination without a reason (WebKit).
    case unknown
}

/// Page commands started by the shell (menus, shortcuts), performed on one surface.
public enum BrowserPageCommand: Sendable, Equatable {
    /// The engine's print flow for the current document (`printing`).
    case print
    /// DevTools for the document, in its own window (`devTools`).
    case showDevTools
    /// DevTools with the element picker active (Inspect Elements, `devTools`).
    case inspectElements
    case closeDevTools
    /// Ends the renderer that `rendererDidBecomeUnresponsive` reported (Exit page); the surface then
    /// reports `rendererDidTerminate`.
    case terminateUnresponsiveRenderer
    /// Keeps waiting for the unresponsive renderer (Wait); a later hang is reported again.
    case waitForUnresponsiveRenderer
}
