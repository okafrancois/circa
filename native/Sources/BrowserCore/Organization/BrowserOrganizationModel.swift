import Foundation
import Darwin


public struct FolderID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// One sidebar node. A tab node is a logical tab (`TabID`): it exists once in the organization and
/// may have zero or more live occurrences, at most one per window.
public enum BrowserOrganizationNode: Hashable, Sendable {
    case tab(TabID)
    case folder(FolderID)
    case split(SplitGroupID)

    public var splitID: SplitGroupID? {
        if case let .split(id) = self { return id }; return nil
    }

    public var tabID: TabID? {
        if case let .tab(id) = self { return id }
        return nil
    }

    public var folderID: FolderID? {
        if case let .folder(id) = self { return id }
        return nil
    }
}

extension BrowserOrganizationNode: Codable {
    private enum CodingKeys: String, CodingKey { case tab, folder, split }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tab = try container.decodeIfPresent(TabID.self, forKey: .tab)
        let folder = try container.decodeIfPresent(FolderID.self, forKey: .folder)
        let split = try container.decodeIfPresent(SplitGroupID.self, forKey: .split)
        switch (tab, folder, split) {
        case let (tab?, nil, nil): self = .tab(tab)
        case let (nil, folder?, nil): self = .folder(folder)
        case let (nil, nil, split?): self = .split(split)
        default:
            throw DecodingError.dataCorruptedError(forKey: .tab, in: container,
                debugDescription: "A sidebar node is exactly one tab, folder or split.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .tab(id): try container.encode(id, forKey: .tab)
        case let .folder(id): try container.encode(id, forKey: .folder)
        case let .split(id): try container.encode(id, forKey: .split)
        }
    }
}

/// Top-level sidebar sections. Favorites are shared by every Space of one profile; Pinned and Today
/// belong to one Space and are shared by every window showing it.
public enum BrowserOrganizationSection: Hashable, Sendable {
    case favorites(ProfileID)
    case pinned(SpaceID)
    case today(SpaceID)

    public var spaceID: SpaceID? {
        switch self {
        case .favorites: return nil
        case let .pinned(id), let .today(id): return id
        }
    }

    /// Favorites and Pinned tabs keep a pinned (home) URL; Today tabs never do.
    public var keepsPinnedURL: Bool {
        if case .today = self { return false }
        return true
    }

    public var acceptsFolders: Bool {
        if case .pinned = self { return true }
        return false
    }
}

/// A list that directly holds nodes: a section root or a folder.
public enum BrowserOrganizationContainer: Hashable, Sendable {
    case favorites(ProfileID)
    case pinned(SpaceID)
    case today(SpaceID)
    case folder(FolderID)
    case split(SplitGroupID)
    /// A machine-local ordered list owned by one standalone window.
    case standalone(WindowID)

    public init(_ section: BrowserOrganizationSection) {
        switch section {
        case let .favorites(id): self = .favorites(id)
        case let .pinned(id): self = .pinned(id)
        case let .today(id): self = .today(id)
        }
    }

    /// Nil for folders, whose section depends on where the folder currently lives.
    public var rootSection: BrowserOrganizationSection? {
        switch self {
        case let .favorites(id): return .favorites(id)
        case let .pinned(id): return .pinned(id)
        case let .today(id): return .today(id)
        case .folder, .split, .standalone: return nil
        }
    }
}

/// Anchors survive concurrent insertions better than indices captured by a stale UI.
public enum BrowserOrganizationPosition: Hashable, Sendable {
    case start
    case end
    case before(BrowserOrganizationNode)
    case after(BrowserOrganizationNode)
}

public struct BrowserOrganizationDestination: Hashable, Sendable {
    public let container: BrowserOrganizationContainer
    public let position: BrowserOrganizationPosition

    public init(_ container: BrowserOrganizationContainer, position: BrowserOrganizationPosition = .end) {
        self.container = container
        self.position = position
    }
}

/// The persistent part of a logical tab. Live engine state (history, DOM, forms) is never stored.
/// A machine-local destination learned from a committed pinned navigation chain.
public struct BrowserPinnedLandingAlias: Codable, Equatable, Sendable {
    public let pinnedURL: URL
    public let url: URL
}

/// Native user consent for one canonical document in one local profile. Session data only.
public struct BrowserLocalDocument: Codable, Equatable, Sendable {
    public let profileID: ProfileID
    public let canonicalPath: String

    public init?(userOpened url: URL, profileID: ProfileID) {
        guard Self.isLocal(url),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        self.profileID = profileID
        canonicalPath = Self.canonicalPath(for: url)
    }

    /// Do not require existence: an absent document must reach the engine's file-not-found page.
    /// Compare against the stored path without resolving it again, so a symlink swap cannot
    /// change the document originally authorized by the user.
    public func matches(_ url: URL, profileID: ProfileID) -> Bool {
        self.profileID == profileID && Self.isLocal(url)
            && Self.canonicalPath(for: url) == canonicalPath
    }

    /// Resolve existing ancestors even after deletion. Foundation may shorten system aliases
    /// differently for existing and absent files; realpath keeps their identity stable.
    public static func canonicalPath(for url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var suffix: [String] = []
        while true {
            if let canonical = realpath(path, nil) {
                defer { free(canonical) }
                let root = String(cString: canonical)
                return root + (root == "/" || suffix.isEmpty ? "" : "/") + suffix.reversed().joined(separator: "/")
            }
            guard path != "/", !path.isEmpty else { return url.standardizedFileURL.path }
            suffix.append((path as NSString).lastPathComponent)
            path = (path as NSString).deletingLastPathComponent
        }
    }

    private static func isLocal(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
            && url.user == nil && url.password == nil && url.port == nil
    }
}

public struct BrowserOrganizedTab: Codable, Equatable, Sendable {
    public let id: TabID
    /// Last committed destination reported by any occurrence, or the URL to load when none is live.
    public internal(set) var url: URL
    /// Last web title reported by the engine. Distinct from the user's custom title.
    public internal(set) var pageTitle: String?
    public internal(set) var customTitle: String?
    public internal(set) var customIcon: BrowserSpaceIcon?
    /// Reference URL of a Favorite or Pinned tab. Always nil in Today.
    public internal(set) var pinnedURL: URL?
    public internal(set) var pinnedLandingAlias: BrowserPinnedLandingAlias?
    public var pinnedLandingURL: URL? {
        pinnedLandingAlias.flatMap { $0.pinnedURL == pinnedURL ? $0.url : nil }
    }
    /// Provider ownership and cached revision; machine-local and excluded from sync.
    public internal(set) var liveFolderChild: BrowserLiveFolderChild?
    /// Exact native user provenance, persisted locally and never admitted from sync/import.
    public internal(set) var localDocument: BrowserLocalDocument?
    public let createdAt: Date
    /// Last time the tab was the visible selection of a window. Basis of auto-archiving.
    public internal(set) var lastActiveAt: Date

    public init(id: TabID, url: URL, pageTitle: String? = nil, customTitle: String? = nil,
                pinnedURL: URL? = nil, createdAt: Date, lastActiveAt: Date,
                liveFolderChild: BrowserLiveFolderChild? = nil, customIcon: BrowserSpaceIcon? = nil,
                pinnedLandingAlias: BrowserPinnedLandingAlias? = nil, localDocument: BrowserLocalDocument? = nil) {
        self.id = id
        self.url = url
        self.pageTitle = pageTitle
        self.customTitle = customTitle
        self.customIcon = customIcon
        self.pinnedURL = pinnedURL
        self.pinnedLandingAlias = pinnedLandingAlias
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.liveFolderChild = liveFolderChild
        self.localDocument = localDocument
    }

    /// The custom title wins over the web title; callers localize their own fallback.
    public var resolvedTitle: String? { customTitle ?? pageTitle }

    /// The form in which a web title is stored: control characters replaced, trimmed, bounded,
    /// nil when empty. Engine titles are never refused.
    public static func normalizedPageTitle(_ title: String?) -> String? {
        BrowserOrganizationState.sanitizedPageTitle(title)
    }
}

public struct BrowserOrganizedFolder: Codable, Equatable, Sendable {
    public let id: FolderID
    public internal(set) var title: String
    public internal(set) var isCollapsed: Bool
    public internal(set) var children: [BrowserOrganizationNode]
    public internal(set) var liveFolder: BrowserLiveFolderConfiguration?
    public let createdAt: Date

    public init(id: FolderID, title: String, isCollapsed: Bool = false,
                children: [BrowserOrganizationNode] = [], createdAt: Date,
                liveFolder: BrowserLiveFolderConfiguration? = nil) {
        self.id = id
        self.title = title
        self.isCollapsed = isCollapsed
        self.children = children
        self.liveFolder = liveFolder
        self.createdAt = createdAt
    }
}

/// A tab removed from the sidebar. Distinct from closing a live occurrence of a Pinned tab.
public struct BrowserArchivedTab: Codable, Equatable, Sendable, Identifiable {
    public enum Reason: String, Codable, Sendable {
        case closed
        /// Inactivity threshold reached.
        case automatic
        case cleared
        /// Explicit deletion of a Pinned/Favorite tab or of a folder's contents.
        case removed
    }

    public enum Origin: String, Codable, Sendable { case favorites, pinned, today, quickWindow }

    public var id: TabID { tab.id }
    /// The logical tab as it was when archived; restoration keeps its identity and custom title.
    public let tab: BrowserOrganizedTab
    public let profileID: ProfileID
    /// The Space it was archived from. For a Favorite, the Space where the command was issued.
    public let spaceID: SpaceID
    public let origin: Origin
    public var isLittleWindow: Bool { origin == .quickWindow }
    public let reason: Reason
    public let archivedAt: Date
    /// Optional for existing sessions. Explicitly retains a historical origin after its Space
    /// changes profile, without accepting an unmarked cross-profile archive reference.
    public internal(set) var spaceProfileWasChanged: Bool? = nil

    public init(tab: BrowserOrganizedTab, profileID: ProfileID, spaceID: SpaceID,
                origin: Origin, reason: Reason, archivedAt: Date) {
        self.tab = tab
        self.profileID = profileID
        self.spaceID = spaceID
        self.origin = origin
        self.reason = reason
        self.archivedAt = archivedAt
    }
}

/// Inactivity delay before a Today tab is archived. Nil interval means never.
public struct BrowserAutoArchiveThreshold: Hashable, Sendable {
    public let interval: TimeInterval?

    private init(interval: TimeInterval?) { self.interval = interval }

    public static let never = BrowserAutoArchiveThreshold(interval: nil)
    public static let oneHour = BrowserAutoArchiveThreshold(interval: 3600)
    public static let sixHours = BrowserAutoArchiveThreshold(interval: 6 * 3600)
    public static let twelveHours = BrowserAutoArchiveThreshold(interval: 12 * 3600)
    public static let oneDay = BrowserAutoArchiveThreshold(interval: 24 * 3600)
    public static let sevenDays = BrowserAutoArchiveThreshold(interval: 7 * 24 * 3600)
    public static let thirtyDays = BrowserAutoArchiveThreshold(interval: 30 * 24 * 3600)

    /// Arbitrary delays support tests and future settings; non-positive or non-finite values are refused.
    public static func after(_ interval: TimeInterval) throws -> BrowserAutoArchiveThreshold {
        guard interval.isFinite, interval > 0 else { throw BrowserOrganizationError.invalidThreshold }
        return BrowserAutoArchiveThreshold(interval: interval)
    }

    var isValid: Bool { interval.map { $0.isFinite && $0 > 0 } ?? true }
}

extension BrowserAutoArchiveThreshold: Codable {
    private enum CodingKeys: String, CodingKey { case kind, seconds }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "never": self = .never
        case "after": self.init(interval: try container.decode(TimeInterval.self, forKey: .seconds))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                debugDescription: "Unknown auto-archive threshold kind.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let interval {
            try container.encode("after", forKey: .kind)
            try container.encode(interval, forKey: .seconds)
        } else {
            try container.encode("never", forKey: .kind)
        }
    }
}

/// Profile-scoped inactivity settings. Profiles without an override use the shared default,
/// initially 12 hours.
/// The archive count limit bounds the persisted session document.
public struct BrowserArchivePolicy: Equatable, Sendable {
    public var defaultThreshold: BrowserAutoArchiveThreshold
    public var profileThresholds: [ProfileID: BrowserAutoArchiveThreshold]
    /// Oldest records are purged beyond this count, keeping the session document within its budget.
    public var maximumArchivedTabs: Int

    public init(defaultThreshold: BrowserAutoArchiveThreshold = .twelveHours,
                profileThresholds: [ProfileID: BrowserAutoArchiveThreshold] = [:],
                maximumArchivedTabs: Int = 1_000) {
        self.defaultThreshold = defaultThreshold
        self.profileThresholds = profileThresholds
        self.maximumArchivedTabs = maximumArchivedTabs
    }

    public func threshold(for profileID: ProfileID) -> BrowserAutoArchiveThreshold {
        profileThresholds[profileID] ?? defaultThreshold
    }
}

extension BrowserArchivePolicy: Codable {
    private struct ProfileThreshold: Codable {
        let profileID: ProfileID
        let threshold: BrowserAutoArchiveThreshold
    }

    private enum CodingKeys: String, CodingKey { case defaultThreshold, profileThresholds, maximumArchivedTabs }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultThreshold = try container.decode(BrowserAutoArchiveThreshold.self, forKey: .defaultThreshold)
        maximumArchivedTabs = try container.decode(Int.self, forKey: .maximumArchivedTabs)
        var thresholds: [ProfileID: BrowserAutoArchiveThreshold] = [:]
        for entry in try container.decode([ProfileThreshold].self, forKey: .profileThresholds) {
            guard thresholds.updateValue(entry.threshold, forKey: entry.profileID) == nil else {
                throw BrowserSessionError.duplicateIdentity
            }
        }
        profileThresholds = thresholds
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultThreshold, forKey: .defaultThreshold)
        try container.encode(maximumArchivedTabs, forKey: .maximumArchivedTabs)
        let entries = profileThresholds
            .sorted { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }
            .map { ProfileThreshold(profileID: $0.key, threshold: $0.value) }
        try container.encode(entries, forKey: .profileThresholds)
    }
}

/// Undoable organization commands; UI lots derive localized menu labels ("Undo Pin Tab") from them.
public enum BrowserOrganizationAction: String, Sendable, Equatable {
    case moveItems, pinTabs, unpinTabs, addToFavorites, removeFromFavorites
    case exportSpace, convertFolderToSpace
    case createFolder, duplicateFolder, renameFolder, deleteFolder, renameTab, importBookmarks
    case changeTabIcon, editPinnedURL
    case archiveTabs, closeTabs, clearToday, restoreArchivedTab, deleteArchivedTabs
    case createSplit, addSplitPane, closeSplitPane, unsplit, swapSplitPanes, orientSplit, resizeSplit
}

public enum BrowserFolderDeletion: Sendable, Equatable {
    case keepContents
    /// Every descendant tab is archived with reason `.removed`.
    case archiveContents
}

public enum BrowserOrganizationError: Error, Equatable, Sendable {
    case itemMissing
    case providerOwnedItem
    case archivedTabMissing
    /// The item exists but is not in the captured window's Space or profile.
    case notVisibleInContext
    case invalidDestination
    case crossProfileMove
    case cycle
    /// The anchor is not a child of the destination container.
    case invalidPosition
    case invalidTitle
    case invalidIcon
    case notPinned
    case emptySelection
    case nothingToUndo
    case nothingToRedo
    /// Later changes touched the same items; the record was discarded without mutation.
    case undoConflict
    case invalidThreshold
}
