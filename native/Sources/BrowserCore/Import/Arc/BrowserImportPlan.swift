import CryptoKit
import Foundation

/// Model content to merge into a store, already mapped to native identities. Engine-independent;
/// never logged (it holds titles and URLs). Counts are exposed through `BrowserImportPlanCounts`.
public struct BrowserImportPlan: Sendable, Equatable {
    public struct Profile: Sendable, Equatable {
        public let id: ProfileID
        /// The Arc profile it comes from; recorded in the ledger with `id`.
        public let sourceKey: ArcProfileKey
        public let name: String
        /// Chromium directory under Arc's `User Data`, used to read its History only.
        public let sourceDirectory: String?
        /// True when Arc's default profile is merged into the target's existing first profile.
        public let isAdopted: Bool
        public var mappingKey: String? = nil
    }

    public struct Space: Sendable, Equatable {
        public let id: SpaceID
        public let profileID: ProfileID
        public let name: String
        public let appearance: ArcSpaceAppearance
    }

    public indirect enum Node: Sendable, Equatable {
        case tab(BrowserOrganizedTab)
        /// The folder's own `children` is empty; its content is the associated node list.
        case folder(BrowserOrganizedFolder, [Node])
    }

    public struct Sections: Sendable, Equatable {
        public let spaceID: SpaceID
        public let pinned: [Node]
        public let today: [BrowserOrganizedTab]
    }

    public struct Favorites: Sendable, Equatable {
        public let profileID: ProfileID
        public let tabs: [BrowserOrganizedTab]
    }

    public struct HistorySource: Sendable, Equatable {
        public let profileID: ProfileID
        public let directory: String
    }

    public var registration: BrowserImportRegistration? = nil
    public var profiles: [Profile] = []
    public var spaces: [Space] = []
    public var favorites: [Favorites] = []
    public var sections: [Sections] = []
    /// Newest first.
    public var archive: [BrowserArchivedTab] = []
    public var historySources: [HistorySource] = []
    public var skipped = BrowserImportPlanSkips()

    public init() {}

    public var counts: BrowserImportPlanCounts {
        var counts = BrowserImportPlanCounts()
        counts.profiles = profiles.count
        counts.spaces = spaces.count
        counts.favorites = favorites.reduce(0) { $0 + $1.tabs.count }
        counts.todayTabs = sections.reduce(0) { $0 + $1.today.count }
        counts.archivedTabs = archive.count
        func walk(_ nodes: [Node]) {
            for node in nodes {
                switch node {
                case .tab: counts.pinnedTabs += 1
                case let .folder(_, children): counts.pinnedFolders += 1; walk(children)
                }
            }
        }
        for section in sections { walk(section.pinned) }
        return counts
    }
}

public struct BrowserImportPlanCounts: Codable, Equatable, Sendable {
    public var profiles = 0
    public var spaces = 0
    public var favorites = 0
    public var pinnedTabs = 0
    public var pinnedFolders = 0
    public var todayTabs = 0
    public var archivedTabs = 0
    public init() {}
}

/// Source content the mapping could not place, by reason. Counts only.
public struct BrowserImportPlanSkips: Codable, Equatable, Sendable {
    /// Profiles referenced only by Favorites: the native model needs a Space to show them.
    public var profilesWithoutSpace = 0
    public var favoritesWithoutSpace = 0
    /// Archive records naming no Space or profile (Little Arc, unknown sources).
    public var unattributedArchives = 0
    /// Archive records naming a Space or profile that is not imported.
    public var archivesWithoutSpace = 0
    public var duplicateIdentities = 0
    public var todayTabsExcluded = 0
    public var archivedTabsExcluded = 0
    public init() {}
}

public struct ArcImportIdentity: Sendable, Equatable {
    public let namespace: String

    public init(namespace: String = "arc") { self.namespace = namespace }

    /// SHA-256 name-based UUID (RFC 9562 version 8, custom).
    public func uuid(_ kind: String, _ parts: [String]) -> UUID {
        let separator = "\u{1F}"
        let name = (["orbit-import/1", namespace, kind] + parts).joined(separator: separator)
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public func profile(_ key: ArcProfileKey) -> ProfileID {
        switch key {
        case let .directory(name): return ProfileID(uuid("profile", [name]))
        case let .unresolved(digest): return ProfileID(uuid("profile-unresolved", [digest]))
        }
    }
    public func space(_ sourceID: String) -> SpaceID { SpaceID(uuid("space", [sourceID])) }
    public func tab(_ sourceID: String) -> TabID { TabID(uuid("tab", [sourceID])) }
    public func folder(_ sourceID: String) -> FolderID { FolderID(uuid("folder", [sourceID])) }
    public func archivedTab(_ key: String) -> TabID { TabID(uuid("archive", [key])) }
}
