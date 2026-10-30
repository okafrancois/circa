import CryptoKit
import Foundation

public enum BrowserLiveFolderProvider: String, Codable, Hashable, Sendable {
    case githubPullRequests
}

/// Proposed filter data only; defaults pending reference evidence. Relationship filters are
/// proposed as a union, with drafts acting as an inclusion modifier; no query logic lives here.
public enum BrowserLiveFolderFilter: String, Codable, Hashable, CaseIterable, Sendable {
    case authored, reviewRequested, assigned, mentioned, teamReview, drafts
}

/// Synced configuration deliberately has no connection, account, cache or credential fields.
public struct BrowserLiveFolderConfiguration: Codable, Equatable, Sendable {
    public var provider: BrowserLiveFolderProvider
    public var filters: Set<BrowserLiveFolderFilter>
    public var excludedRepositories: Set<String>
    public var isEnabled: Bool
    public var creation: Creation

    public enum Creation: String, Codable, Sendable { case automatic, userEnabled }

    public init(provider: BrowserLiveFolderProvider = .githubPullRequests,
                filters: Set<BrowserLiveFolderFilter> = [.authored, .reviewRequested],
                excludedRepositories: Set<String> = [], isEnabled: Bool = true,
                creation: Creation = .userEnabled) {
        self.provider = provider
        self.filters = filters
        self.excludedRepositories = excludedRepositories
        self.isEnabled = isEnabled
        self.creation = creation
    }

    // Sets encode in a canonical order so repeated sync projections cannot invent edits.
    private enum CodingKeys: String, CodingKey { case provider, filters, excludedRepositories, isEnabled, creation }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encode(filters.sorted { $0.rawValue < $1.rawValue }, forKey: .filters)
        try c.encode(excludedRepositories.sorted(), forKey: .excludedRepositories)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(creation, forKey: .creation)
    }
}

/// Logical provider identity, independent of title, URL, ordering and authentication mechanism.
public struct BrowserLiveFolderItemID: Codable, Hashable, Sendable {
    public let provider: BrowserLiveFolderProvider
    public let itemID: String
    public init(provider: BrowserLiveFolderProvider = .githubPullRequests, itemID: String) {
        self.provider = provider; self.itemID = itemID
    }

    /// Folder scope prevents collisions between materializations in different profiles/folders.
    /// The identity itself remains provider + item ID. Never reuse this ID for a user-pinned copy.
    public func tabID(in folderID: FolderID, incarnation: UInt64 = 0) -> TabID {
        let parts = [folderID.rawValue.uuidString, provider.rawValue, itemID, String(incarnation)]
        let input = parts.map { "\($0.utf8.count):\($0)" }.joined()
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        return TabID(UUID(uuid: uuid))
    }
}

public struct BrowserLiveFolderChild: Codable, Equatable, Sendable {
    public let folderID: FolderID
    public let identity: BrowserLiveFolderItemID
    public let fingerprint: String
    public init(folderID: FolderID, identity: BrowserLiveFolderItemID, fingerprint: String) {
        self.folderID = folderID; self.identity = identity; self.fingerprint = fingerprint
    }
}

public struct BrowserLiveFolderFetchedItem: Equatable, Sendable {
    public let identity: BrowserLiveFolderItemID
    public let url: URL
    public let title: String?
    /// Opaque material revision chosen by the provider adapter, not an upstream notification.
    public let fingerprint: String
    public init(identity: BrowserLiveFolderItemID, url: URL, title: String?, fingerprint: String) {
        self.identity = identity; self.url = url; self.title = title; self.fingerprint = fingerprint
    }
}

public struct BrowserLiveFolderFetch: Equatable, Sendable {
    public enum Coverage: Sendable { case complete, partial }
    public let generation: UInt64
    public let coverage: Coverage
    public let items: [BrowserLiveFolderFetchedItem]
    public init(generation: UInt64, coverage: Coverage, items: [BrowserLiveFolderFetchedItem]) {
        self.generation = generation; self.coverage = coverage; self.items = items
    }
}

public enum BrowserLiveFolderReconciler {
    public struct Result: Equatable, Sendable {
        public let accepted: Bool
        public let folder: BrowserOrganizedFolder
        public let children: [BrowserOrganizedTab]
        /// Caller inserts these ordinary tabs in Today, retaining their live logical identities.
        public let preserved: [BrowserOrganizedTab]
        public let removed: Set<TabID>
    }

    /// Pure reconciliation. Partial coverage retains absent rows and their order. Complete
    /// coverage adopts fetched order. Callers supply selected/visibly open identities explicitly.
    public static func reconcile(_ folder: BrowserOrganizedFolder, children: [BrowserOrganizedTab],
                                 fetched: BrowserLiveFolderFetch, generation: UInt64,
                                 preserving: Set<TabID> = [], occupiedTabIDs: Set<TabID> = [], now: Date) throws -> Result {
        guard let config = folder.liveFolder else { throw BrowserOrganizationError.invalidDestination }
        guard fetched.generation == generation, config.isEnabled else {
            return Result(accepted: false, folder: folder, children: children, preserved: [], removed: [])
        }
        guard children.count == folder.children.count,
              Set(children.map(\.id)).count == children.count,
              Set(children.compactMap { $0.liveFolderChild?.identity }).count == children.count,
              Set(children.map { BrowserOrganizationNode.tab($0.id) }) == Set(folder.children),
              children.allSatisfy({ $0.liveFolderChild?.folderID == folder.id
                  && $0.liveFolderChild?.identity.provider == config.provider }) else {
            throw BrowserOrganizationError.providerOwnedItem
        }
        let existing = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0) })
        let existingByIdentity = Dictionary(uniqueKeysWithValues: children.compactMap { tab in
            tab.liveFolderChild.map { ($0.identity, tab) }
        })
        var seen: Set<BrowserLiveFolderItemID> = []
        var rows: [BrowserOrganizedTab] = []
        for item in fetched.items {
            guard item.identity.provider == config.provider, !item.identity.itemID.isEmpty else {
                throw BrowserOrganizationError.providerOwnedItem
            }
            try BrowserSessionDocument.validateDestination(item.url)
            guard seen.insert(item.identity).inserted else { continue }
            let previous = existingByIdentity[item.identity]
            var incarnation: UInt64 = 0
            var id = previous?.id ?? item.identity.tabID(in: folder.id)
            // A previously detached open page is now ordinary and keeps its identity. Returning
            // provider membership gets a separate deterministic incarnation, then reuses it.
            while previous == nil && occupiedTabIDs.contains(id) {
                incarnation += 1
                id = item.identity.tabID(in: folder.id, incarnation: incarnation)
            }
            var tab = previous ?? BrowserOrganizedTab(id: id, url: item.url, pinnedURL: item.url,
                                                         createdAt: now, lastActiveAt: now)
            // Keep the live destination stable during refresh; only update the provider's home URL.
            if tab.url == tab.pinnedURL { tab.url = item.url }
            tab.pinnedURL = item.url
            tab.pageTitle = BrowserOrganizedTab.normalizedPageTitle(item.title)
            tab.liveFolderChild = .init(folderID: folder.id, identity: item.identity, fingerprint: item.fingerprint)
            rows.append(tab)
        }
        let fetchedIDs = Set(rows.map(\.id))
        let absent = folder.children.compactMap { $0.tabID.flatMap { existing[$0] } }.filter { !fetchedIDs.contains($0.id) }
        var preserved: [BrowserOrganizedTab] = []
        var removed: Set<TabID> = []
        switch fetched.coverage {
        case .partial:
            let updates = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            rows = folder.children.compactMap { $0.tabID.flatMap { updates[$0] ?? existing[$0] } }
                + rows.filter { existing[$0.id] == nil }
        case .complete:
            for var tab in absent {
                if preserving.contains(tab.id) {
                    tab.liveFolderChild = nil; tab.pinnedURL = nil
                    preserved.append(tab)
                } else { removed.insert(tab.id) }
            }
        }
        var next = folder; next.children = rows.map { .tab($0.id) }
        return Result(accepted: true, folder: next, children: rows, preserved: preserved, removed: removed)
    }
}

/// Separate local, profile-scoped authority. Never embed in the organization or sync documents.
/// Persistence is supplied by the later data layer; Codable supports its own local file only.
public struct BrowserLiveFolderLocalStore: Codable, Equatable, Sendable {
    public let profileID: ProfileID
    private var generations: [BrowserLiveFolderProvider: UInt64] = [:]
    private var lastSeen: [BrowserLiveFolderItemID: String] = [:]
    public private(set) var disabledAutomaticProviders: Set<BrowserLiveFolderProvider> = []
    public init(profileID: ProfileID) { self.profileID = profileID }

    public func generation(for provider: BrowserLiveFolderProvider) -> UInt64 { generations[provider] ?? 0 }
    /// Advance before any connection rebind/disconnect or configuration change, before fetching.
    @discardableResult public mutating func advanceGeneration(for provider: BrowserLiveFolderProvider) -> UInt64 {
        let next = generation(for: provider) + 1
        generations[provider] = next
        return next
    }
    public func isUnread(_ item: BrowserLiveFolderItemID, fingerprint: String) -> Bool { lastSeen[item] != fingerprint }
    public mutating func acknowledge(_ item: BrowserLiveFolderItemID, fingerprint: String) { lastSeen[item] = fingerprint }
    public func lastSeenFingerprint(for item: BrowserLiveFolderItemID) -> String? { lastSeen[item] }
    public func allowsAutomaticCreation(for provider: BrowserLiveFolderProvider) -> Bool { !disabledAutomaticProviders.contains(provider) }
    public mutating func disableAutomaticCreation(for provider: BrowserLiveFolderProvider) {
        disabledAutomaticProviders.insert(provider)
        advanceGeneration(for: provider)
    }
    public mutating func reenableAutomaticCreation(for provider: BrowserLiveFolderProvider) {
        disabledAutomaticProviders.remove(provider)
        advanceGeneration(for: provider)
    }
    /// Account rebinding must forget read fingerprints as well as invalidating in-flight results.
    public mutating func resetConnection(for provider: BrowserLiveFolderProvider) {
        lastSeen = lastSeen.filter { $0.key.provider != provider }
        advanceGeneration(for: provider)
    }
}
