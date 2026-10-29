import Foundation

/// Persistent organization graph; split records were added in session document version 3.
public struct BrowserOrganizationDocument: Codable, Equatable, Sendable {
    public struct Favorites: Codable, Equatable, Sendable {
        public let profileID: ProfileID
        public let items: [BrowserOrganizationNode]

        public init(profileID: ProfileID, items: [BrowserOrganizationNode]) {
            self.profileID = profileID
            self.items = items
        }
    }

    public struct SpaceSections: Codable, Equatable, Sendable {
        public let spaceID: SpaceID
        public let pinned: [BrowserOrganizationNode]
        public let today: [BrowserOrganizationNode]
        public let isPinnedCollapsed: Bool

        public init(spaceID: SpaceID, pinned: [BrowserOrganizationNode], today: [BrowserOrganizationNode],
                    isPinnedCollapsed: Bool = false) {
            self.spaceID = spaceID
            self.pinned = pinned
            self.today = today
            self.isPinnedCollapsed = isPinnedCollapsed
        }
    }

    /// Logical tabs currently in the sidebar. Archived tabs live only in `archive`.
    public let tabs: [BrowserOrganizedTab]
    public let folders: [BrowserOrganizedFolder]
    public let splits: [BrowserSplitGroup]
    public let favorites: [Favorites]
    public let spaces: [SpaceSections]
    /// Newest first.
    public let archive: [BrowserArchivedTab]
    public let archivePolicy: BrowserArchivePolicy
    public let archivedSpaces: [BrowserArchivedSpace]

    public init(tabs: [BrowserOrganizedTab], folders: [BrowserOrganizedFolder], favorites: [Favorites],
                spaces: [SpaceSections], archive: [BrowserArchivedTab], archivePolicy: BrowserArchivePolicy,
                splits: [BrowserSplitGroup] = [], archivedSpaces: [BrowserArchivedSpace] = []) {
        self.tabs = tabs
        self.folders = folders
        self.splits = splits
        self.favorites = favorites
        self.spaces = spaces
        self.archive = archive
        self.archivePolicy = archivePolicy
        self.archivedSpaces = archivedSpaces
    }

    private enum CodingKeys: String, CodingKey { case tabs, folders, splits, favorites, spaces, archive, archivePolicy, archivedSpaces }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tabs: try c.decode([BrowserOrganizedTab].self, forKey: .tabs),
                  folders: try c.decode([BrowserOrganizedFolder].self, forKey: .folders),
                  favorites: try c.decode([Favorites].self, forKey: .favorites),
                  spaces: try c.decode([SpaceSections].self, forKey: .spaces),
                  archive: try c.decode([BrowserArchivedTab].self, forKey: .archive),
                  archivePolicy: try c.decode(BrowserArchivePolicy.self, forKey: .archivePolicy),
                  splits: try c.decodeIfPresent([BrowserSplitGroup].self, forKey: .splits) ?? [],
                  archivedSpaces: try c.decodeIfPresent([BrowserArchivedSpace].self, forKey: .archivedSpaces) ?? [])
    }

    public static let empty = BrowserOrganizationDocument(tabs: [], folders: [], favorites: [], spaces: [],
                                                          archive: [], archivePolicy: BrowserArchivePolicy())
}

/// A tab row as seen from one window. Identity (`id`) is stable across windows, restarts and moves;
/// `occurrenceID` identifies this window's live document, when there is one in the active Space.
public struct BrowserOrganizationTabItem: Equatable, Sendable {
    public let id: TabID
    public let section: BrowserOrganizationSection
    /// This window's live destination when loaded here, otherwise the logical tab's last destination.
    public let url: URL
    public let pinnedURL: URL?
    public let pageTitle: String?
    public let customTitle: String?
    public let occurrenceID: TabOccurrenceID?
    /// Also true for a Favorite still live in another Space of this window: selecting it moves it.
    public let isLoadedInThisWindow: Bool
    public let isSelected: Bool
    /// Orbit shows a placeholder for a tab open in another window; the UI decides how to present it.
    public let isOpenInAnotherWindow: Bool
    /// Local activation timestamp; absent values are never inferred from creation/import dates.
    public var lastActiveAt: Date? = nil

    public var title: String? { customTitle ?? pageTitle }
    public var isAwayFromPinnedURL: Bool { pinnedURL.map { $0 != url } ?? false }
}

public struct BrowserOrganizationFolderItem: Equatable, Sendable {
    public let id: FolderID
    public let title: String
    public let isCollapsed: Bool
    public let children: [BrowserOrganizationItem]
}

public enum BrowserOrganizationItem: Equatable, Sendable, Identifiable {
    case tab(BrowserOrganizationTabItem)
    case folder(BrowserOrganizationFolderItem)
    case split(BrowserOrganizationSplitItem)

    public var id: BrowserOrganizationNode { node }

    public var node: BrowserOrganizationNode {
        switch self {
        case let .tab(item): return .tab(item.id)
        case let .folder(item): return .folder(item.id)
        case let .split(item): return .split(item.group.id)
        }
    }
}

/// One visible sidebar row, in display order.
public struct BrowserOrganizationRow: Equatable, Sendable {
    public enum Group: Equatable, Sendable {
        /// The Favorites grid.
        case favorites
        /// The vertical list: Pinned followed by Today.
        case list
    }

    public let node: BrowserOrganizationNode
    public let section: BrowserOrganizationSection
    public let group: Group
    public let depth: Int
    public let parentFolderID: FolderID?
}

/// Everything one window's sidebar shows for its active Space, captured atomically with the
/// window's context. Equal snapshots render identically; it carries no volatile timestamps.
public struct BrowserOrganizationSnapshot: Equatable, Sendable {
    /// Monotone store publication identity, including moves that later return to the same tree.
    public var organizationRevision: UInt64 = 0
    public let windowID: WindowID
    public let spaceID: SpaceID
    public let profileID: ProfileID
    /// Shared by every Space of `profileID`.
    public let favorites: [BrowserOrganizationItem]
    /// Shared by every window showing `spaceID`.
    public let pinned: [BrowserOrganizationItem]
    public let today: [BrowserOrganizationItem]
    public let isPinnedSectionCollapsed: Bool
    /// Changes whenever this profile's archive changes. The records themselves are read in
    /// command order with `archivedTabs(from:matching:)` (`BrowserWindowSession.archivedTabs`).
    public let archiveRevision: UInt64
    public let canRestoreArchivedTab: Bool
    public let autoArchiveThreshold: BrowserAutoArchiveThreshold
    public let inheritsAutoArchiveThreshold: Bool
    /// Archived tabs of this profile.
    public let archivedTabCount: Int
    /// The window's next undo/redo, only when it belongs to this profile.
    public let undoAction: BrowserOrganizationAction?
    public let redoAction: BrowserOrganizationAction?
    /// Undoable organization commands recorded so far by this window (monotonic). A change tells
    /// the shell that the window's latest undoable action is an organization command.
    public internal(set) var undoRecordCount: UInt64 = 0
    /// Stable identities of the actual replay candidates, after concurrent conflicts are skipped.
    /// Scoped to this window's journal; neither value nor the counter is session-persisted.
    public internal(set) var undoRecordID: UInt64? = nil
    public internal(set) var redoRecordID: UInt64? = nil

    public func items(in section: BrowserOrganizationSection) -> [BrowserOrganizationItem] {
        switch section {
        case .favorites: return favorites
        case .pinned: return pinned
        case .today: return today
        }
    }

    public func item(for node: BrowserOrganizationNode) -> BrowserOrganizationItem? {
        var stack = (favorites + pinned + today).reversed().map { $0 }
        while let item = stack.popLast() {
            if item.node == node { return item }
            if case let .folder(folder) = item { stack.append(contentsOf: folder.children.reversed()) }
            if case let .split(split) = item { stack.append(contentsOf: split.tabs.reversed().map(BrowserOrganizationItem.tab)) }
        }
        return nil
    }

    public func tab(_ id: TabID) -> BrowserOrganizationTabItem? {
        guard case let .tab(item)? = item(for: .tab(id)) else { return nil }
        return item
    }

    public var selectedTab: BrowserOrganizationTabItem? {
        allTabs.first { $0.isSelected }
    }

    /// Every tab in sidebar order, including those inside collapsed folders.
    public var allTabs: [BrowserOrganizationTabItem] {
        var result: [BrowserOrganizationTabItem] = []
        var stack = (favorites + pinned + today).reversed().map { $0 }
        while let item = stack.popLast() {
            switch item {
            case let .tab(tab): result.append(tab)
            case let .folder(folder): stack.append(contentsOf: folder.children.reversed())
            case let .split(split): result.append(contentsOf: split.tabs)
            }
        }
        return result
    }

    /// Visible rows in display order. Children of collapsed folders, and the Pinned section when
    /// collapsed, are omitted unless `includingCollapsed` is true.
    public func rows(includingCollapsed: Bool = false) -> [BrowserOrganizationRow] {
        var result: [BrowserOrganizationRow] = []
        func append(_ items: [BrowserOrganizationItem], section: BrowserOrganizationSection,
                    group: BrowserOrganizationRow.Group, depth: Int, parent: FolderID?) {
            for item in items {
                result.append(BrowserOrganizationRow(node: item.node, section: section, group: group,
                                                     depth: depth, parentFolderID: parent))
                if case let .folder(folder) = item, includingCollapsed || !folder.isCollapsed {
                    append(folder.children, section: section, group: group, depth: depth + 1, parent: folder.id)
                }
            }
        }
        append(favorites, section: .favorites(profileID), group: .favorites, depth: 0, parent: nil)
        if includingCollapsed || !isPinnedSectionCollapsed {
            append(pinned, section: .pinned(spaceID), group: .list, depth: 0, parent: nil)
        }
        append(today, section: .today(spaceID), group: .list, depth: 0, parent: nil)
        return result
    }

    /// Synchronous drop-target check for drag feedback. The store repeats it authoritatively.
    /// Destinations outside the active Space can only be section roots (e.g. a Space icon).
    public func validateMove(
        _ nodes: [BrowserOrganizationNode], to destination: BrowserOrganizationDestination,
        catalog: BrowserCatalogSnapshot, incomingTabsFrom source: BrowserOrganizationSnapshot? = nil
    ) -> BrowserOrganizationError? {
        guard !nodes.isEmpty else { return .emptySelection }
        var sections: [BrowserOrganizationNode: BrowserOrganizationSection] = [:]
        var folderChains: [FolderID: Set<FolderID>] = [:]
        if let source {
            guard source.profileID == profileID else { return .crossProfileMove }
            for node in nodes {
                guard let id = node.tabID, let tab = source.tab(id) else { return .notVisibleInContext }
                sections[node] = tab.section
            }
        }
        func index(_ items: [BrowserOrganizationItem], section: BrowserOrganizationSection, chain: Set<FolderID>) {
            for item in items {
                sections[item.node] = section
                if case let .folder(folder) = item {
                    let inner = chain.union([folder.id])
                    folderChains[folder.id] = inner
                    index(folder.children, section: section, chain: inner)
                }
            }
        }
        index(favorites, section: .favorites(profileID), chain: [])
        index(pinned, section: .pinned(spaceID), chain: [])
        index(today, section: .today(spaceID), chain: [])
        guard nodes.allSatisfy({ sections[$0] != nil }) else { return .notVisibleInContext }
        let target: BrowserOrganizationSection
        switch destination.container {
        case let .favorites(profile):
            guard profile == profileID else { return .crossProfileMove }
            target = .favorites(profile)
        case let .pinned(space), let .today(space):
            guard let entry = catalog.spaces.first(where: { $0.id == space }) else { return .itemMissing }
            guard entry.profileID == profileID else { return .crossProfileMove }
            target = destination.container.rootSection!
        case let .standalone(owner):
            guard owner == windowID else { return .notVisibleInContext }
            target = .today(spaceID)
        case .split: return .invalidDestination
        case let .folder(folder):
            guard let section = sections[.folder(folder)], let chain = folderChains[folder] else {
                return .notVisibleInContext
            }
            if nodes.contains(where: { $0.folderID.map(chain.contains) ?? false }) { return .cycle }
            target = section
        }
        if case .favorites = target, nodes.contains(where: { $0.splitID != nil }) { return .invalidDestination }
        if !target.acceptsFolders, nodes.contains(where: { $0.folderID != nil }) { return .invalidDestination }
        switch destination.position {
        case .start, .end: return nil
        case let .before(anchor), let .after(anchor):
            let siblings: [BrowserOrganizationItem]
            switch destination.container {
            case let .folder(folder):
                guard case let .folder(folderItem)? = item(for: .folder(folder)) else { return .notVisibleInContext }
                siblings = folderItem.children
            case .standalone: siblings = today
            case .split: return .invalidDestination
            case .favorites: siblings = favorites
            case let .pinned(space): siblings = space == spaceID ? pinned : []
            case let .today(space): siblings = space == spaceID ? today : []
            }
            return siblings.contains { $0.node == anchor } ? nil : .invalidPosition
        }
    }
}

public struct BrowserOrganizationSelection: Equatable, Sendable {
    public private(set) var nodes: Set<BrowserOrganizationNode> = []
    public private(set) var anchor: BrowserOrganizationNode?
    public private(set) var spaceID: SpaceID?
    public private(set) var profileID: ProfileID?

    public init() {}

    public var isEmpty: Bool { nodes.isEmpty }

    /// Plain click: only this row, which becomes the anchor.
    public mutating func select(_ node: BrowserOrganizationNode, in snapshot: BrowserOrganizationSnapshot) {
        bind(to: snapshot)
        guard row(for: node, in: snapshot) != nil else { return }
        nodes = [node]
        anchor = node
    }

    /// ⌘-click: adds or removes one row; the anchor moves to it.
    public mutating func toggle(_ node: BrowserOrganizationNode, in snapshot: BrowserOrganizationSnapshot) {
        bind(to: snapshot)
        guard row(for: node, in: snapshot) != nil else { return }
        if nodes.remove(node) == nil { nodes.insert(node) }
        anchor = node
    }

    /// ⇧-click: replaces the selection with the visible rows between the anchor and this row, within
    /// one group (the Favorites grid or the Pinned/Today list). Without an anchor it selects the row.
    public mutating func extend(to node: BrowserOrganizationNode, in snapshot: BrowserOrganizationSnapshot) {
        bind(to: snapshot)
        let rows = snapshot.rows()
        guard let target = rows.firstIndex(where: { $0.node == node }) else { return }
        guard let anchor, let origin = rows.firstIndex(where: { $0.node == anchor }),
              rows[origin].group == rows[target].group else {
            select(node, in: snapshot)
            return
        }
        nodes = Set(rows[min(origin, target)...max(origin, target)].map(\.node))
    }

    public mutating func clear() {
        nodes = []
        anchor = nil
    }

    /// Drops rows that are no longer visible (moved, archived, collapsed) or a whole selection made
    /// in another Space or profile.
    public mutating func reconcile(with snapshot: BrowserOrganizationSnapshot) {
        guard spaceID == snapshot.spaceID, profileID == snapshot.profileID else {
            self = BrowserOrganizationSelection()
            return
        }
        let visible = Set(snapshot.rows().map(\.node))
        nodes.formIntersection(visible)
        if let anchor, !visible.contains(anchor) { self.anchor = nil }
    }

    /// Selected nodes in display order, ready for a batch command.
    public func orderedNodes(in snapshot: BrowserOrganizationSnapshot) -> [BrowserOrganizationNode] {
        guard spaceID == snapshot.spaceID, profileID == snapshot.profileID else { return [] }
        return snapshot.rows().map(\.node).filter(nodes.contains)
    }

    private mutating func bind(to snapshot: BrowserOrganizationSnapshot) {
        guard spaceID != snapshot.spaceID || profileID != snapshot.profileID else { return }
        self = BrowserOrganizationSelection()
        spaceID = snapshot.spaceID
        profileID = snapshot.profileID
    }

    private func row(for node: BrowserOrganizationNode, in snapshot: BrowserOrganizationSnapshot) -> BrowserOrganizationRow? {
        snapshot.rows().first { $0.node == node }
    }
}
