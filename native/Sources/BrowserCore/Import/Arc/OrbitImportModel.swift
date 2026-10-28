import Foundation

// Engine-independent source data decoded by the local browser importer.

/// Errors carry codes only: never a path, URL, title, profile or Space name.
public enum ArcImportError: Error, Equatable, Sendable {
    /// No `StorableSidebar.json` at the chosen location.
    case sourceNotFound
    /// A source file is a symbolic link, not a regular file, or above the size bound.
    case unsupportedSourceFile
    case unreadableSourceDocument
    case unrecognizedSidebarFormat
    /// Arc is running: its files may change while being copied. The importer never quits Arc.
    case arcIsRunning
    /// A source file changed while it was copied; quit Arc and retry.
    case sourceChangedDuringCopy
    case snapshotFailed
    case historyDatabaseUnreadable
    /// Another import is in progress in this process.
    case importInProgress
    /// The target session is used by a running Orbit (offline tools only).
    case targetInUse
    case targetUnreadable
    case backupFailed
    case backupNotFound
    case restoreFailed
    case cancelled
    /// The confirmation does not match the counts of a fresh dry run.
    case confirmationMismatch
    /// A path component of the source or destination is a symbolic link.
    case symbolicLinkInPath
    /// The source folder and Orbit's data folder contain one another.
    case sourceOverlapsTarget
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    /// The merged session would exceed what Orbit reads back at launch.
    case sessionTooLarge(projectedBytes: Int, limitBytes: Int)
    /// The backup is incomplete or unreadable; nothing was changed.
    case backupInvalid
    /// A restore journal appeared after this session was loaded: reopen the target so recovery
    /// runs before anything is read.
    case restoreInterrupted
    /// A file the import reads or writes in place has more than one hard link.
    case hardLinkedFile
    /// The restore journal exists but cannot be read: every operation on this session is blocked
    /// until `orbit-import recover-restore` puts the parked files back (evidence is kept).
    case restoreJournalUnreadable
    /// An import state file (ledger, journal, appearance) exists but cannot be read.
    case stateFileUnreadable
}

public enum ArcProfileKey: Hashable, Sendable, Codable {
    /// A Chromium profile directory under `User Data` (`Default`, `Profile 1`, …). Observed.
    case directory(String)
    /// A descriptor that names no directory (legacy opaque id); digest of its canonical form.
    case unresolved(String)

    public var directory: String? {
        if case let .directory(name) = self { return name }
        return nil
    }

    /// Stable string form used as a ledger key (directory names and digests only).
    public var ledgerKey: String {
        switch self {
        case let .directory(name): return "directory:" + name
        case let .unresolved(digest): return "unresolved:" + digest
        }
    }

    public init?(ledgerKey: String) {
        if ledgerKey.hasPrefix("directory:") { self = .directory(String(ledgerKey.dropFirst(10))) }
        else if ledgerKey.hasPrefix("unresolved:") { self = .unresolved(String(ledgerKey.dropFirst(11))) }
        else { return nil }
    }
}

public struct ArcImportedProfile: Sendable, Equatable {
    public let key: ArcProfileKey
    /// `User Data/Local State` → `profile.info_cache[directory].name`. Observed field.
    public let displayName: String?
}

public struct ArcImportedTab: Sendable, Equatable {
    /// Arc sidebar item id (observed `id`), or the archive record key.
    public let sourceID: String
    /// `data.tab.savedURL` (observed). Arc's sidebar does not store a distinct live URL.
    public let savedURL: URL
    /// `data.tab.savedTitle` (observed): the last web title.
    public let savedTitle: String?
    /// Item `title` (observed field): non-null when the user renamed the item (interpretation
    /// consistent with the Electron reconstruction; reconstruction).
    public let customTitle: String?
    public let createdAt: Date?
    /// `data.tab.timeLastActiveAt` (observed).
    public let lastActiveAt: Date?
}

public struct ArcImportedFolder: Sendable, Equatable {
    public let sourceID: String
    public let title: String?
    public let isCollapsed: Bool
    public let createdAt: Date?
    public let children: [ArcImportedNode]
}

public indirect enum ArcImportedNode: Sendable, Equatable {
    case tab(ArcImportedTab)
    case folder(ArcImportedFolder)
}

/// Representative colour, icon and the raw theme for a later, more faithful rendering.
public struct ArcSpaceAppearance: Sendable, Equatable, Codable {
    /// `#rrggbb` from `customInfo.windowTheme.primaryColorPalette.tintedLight`, else `midTone`,
    /// else a hexadecimal `color`. Components are converted as-is; no Display P3 → sRGB conversion.
    public var colorHex: String?
    /// `customInfo.iconType.emoji_v2`, `icon` or `symbol` (observed `emoji_v2`).
    public var icon: String?
    /// Canonical JSON of `customInfo.windowTheme`, bounded; nil when absent or oversized.
    public var theme: String?

    public init(colorHex: String? = nil, icon: String? = nil, theme: String? = nil) {
        self.colorHex = colorHex
        self.icon = icon
        self.theme = theme
    }

    public var isEmpty: Bool { colorHex == nil && icon == nil && theme == nil }
}

public struct ArcImportedSpace: Sendable, Equatable {
    public let sourceID: String
    public let profile: ArcProfileKey
    public let title: String?
    public let appearance: ArcSpaceAppearance
    /// `containerIDs`/`newContainerIDs` `pinned` root (observed), folders kept.
    public let pinned: [ArcImportedNode]
    /// `unpinned` root (observed). Native Today holds tabs only; folders are flattened.
    public let today: [ArcImportedTab]
}

public struct ArcImportedFavorites: Sendable, Equatable {
    /// `topAppsContainerIDs` pairs a profile descriptor with its container (observed).
    public let profile: ArcProfileKey
    /// Native Favorites hold tabs only; Arc folder wrappers are flattened.
    public let tabs: [ArcImportedTab]
}

public struct ArcImportedArchiveRecord: Sendable, Equatable {
    public let key: String
    public let tab: ArcImportedTab
    public let archivedAt: Date?
    /// `reason` (observed field; values not decoded).
    public let reason: String?
    /// The source Space when `source.space._0` names one (observed variant).
    public let spaceSourceID: String?
    /// A profile descriptor carried by the record when no Space is named (reconstruction).
    public let profile: ArcProfileKey?
}

/// Counters only; never names, titles, URLs or paths. Counters are diagnostic, not exclusive.
public struct ArcSidebarDiagnostics: Codable, Equatable, Sendable {
    public var malformedRecords = 0
    public var duplicateSpaces = 0
    public var duplicateItems = 0
    public var duplicateArchives = 0
    public var invalidURLs = 0
    public var missingURLs = 0
    public var unsupportedItems = 0
    /// Folder wrappers in Favorites or Today whose tabs were kept flat.
    public var flattenedFolders = 0
    /// Split groups (`data.splitView`) kept as separate tabs: no native split model on main yet.
    public var flattenedSplits = 0
    public var unresolvedProfiles = 0
    public var unattributedArchives = 0
    public var missingReferences = 0
    public var repeatedReferences = 0
    public var cycles = 0
    public var depthLimit = 0
    public var recoveredParentReferences = 0
    /// Items reachable from no Space or Favorites root; Arc does not display them either.
    public var disconnectedItems = 0
    public var missingTimestamps = 0
    public var invalidTimestamps = 0
    public var oversizedThemes = 0
    /// Favorites of a profile that owns no Space (unusable in the native model).
    public var favoritesWithoutSpace = 0

    public init() {}
}

public struct ArcSidebarGraph: Sendable, Equatable {
    /// Top-level `version` of `StorableSidebar.json`.
    public let formatVersion: Int?
    public let formatRecognized: Bool
    public let profiles: [ArcImportedProfile]
    public let spaces: [ArcImportedSpace]
    public let favorites: [ArcImportedFavorites]
    public let archive: [ArcImportedArchiveRecord]
    public let diagnostics: ArcSidebarDiagnostics
}
