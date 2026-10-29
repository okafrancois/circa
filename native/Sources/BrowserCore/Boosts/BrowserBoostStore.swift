import Foundation

public struct BrowserBoostDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let profileID: ProfileID
    public internal(set) var revision: UInt64
    public internal(set) var boosts: [BrowserBoost]

    public init(profileID: ProfileID) {
        version = Self.currentVersion
        self.profileID = profileID
        revision = 1
        boosts = []
    }
}

/// One authority per profile, independent of tabs/Spaces. A private-window store cannot
/// receive a file destination and never loads existing regular-profile data.
public actor BrowserBoostStore {
    public enum Persistence: Sendable {
        case memoryOnly
        case profileDirectory(URL)
    }
    public static let maximumDocumentBytes = 4 * 1024 * 1024
    public nonisolated let profileID: ProfileID
    private let destination: URL?
    private var document: BrowserBoostDocument
    private var table: BrowserBoostMatchTable
    private let beforeReplace: @Sendable () throws -> Void

    public init(profileID: ProfileID, persistence: Persistence = .memoryOnly) throws {
        try self.init(profileID: profileID, persistence: persistence, beforeReplace: {})
    }

    // Fault/process-death seam runs after file synchronization, immediately before rename.
    init(profileID: ProfileID, persistence: Persistence, beforeReplace: @escaping @Sendable () throws -> Void) throws {
        self.profileID = profileID
        self.beforeReplace = beforeReplace
        switch persistence {
        case .memoryOnly: destination = nil
        case .profileDirectory(let root):
            destination = root.appendingPathComponent(profileID.rawValue.uuidString, isDirectory: true)
                .appendingPathComponent("boosts.json")
        }
        if let destination, let bytes = try BrowserPermissionFile.load(destination, maximumBytes: Self.maximumDocumentBytes) {
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: bytes)
            switch header.version {
            case 0:
                // Orbit v0 had no revision or script consent. Migration always resets JS consent.
                let legacy = try decoder.decode(LegacyDocument.self, from: bytes)
                guard legacy.profileID == profileID else { throw BrowserBoostError.wrongProfile }
                var migrated = BrowserBoostDocument(profileID: profileID)
                migrated.boosts = legacy.boosts.map { item in
                    BrowserBoost(id: item.id, title: item.title, hostPattern: item.hostPattern,
                                 isEnabled: item.isEnabled, content: item.content)
                }
                document = migrated
            case BrowserBoostDocument.currentVersion:
                document = try decoder.decode(BrowserBoostDocument.self, from: bytes)
            default: throw BrowserBoostError.unsupportedVersion
            }
        } else { document = BrowserBoostDocument(profileID: profileID) }
        guard document.profileID == profileID else { throw BrowserBoostError.wrongProfile }
        let documentRevision = document.revision
        guard documentRevision > 0, document.boosts.allSatisfy({ $0.revision <= documentRevision }) else {
            throw BrowserBoostError.staleRevision
        }
        table = try BrowserBoostMatchTable(profileID: profileID, boosts: document.boosts)
    }

    public func applySync(_ value: BrowserBoostDocument, expected: BrowserBoostDocument) throws {
        guard document == expected, value.profileID == profileID else { throw BrowserSyncError.localChange }
        var next = document
        next.boosts = value.boosts.map { item in
            var item = item
            item.revision = document.revision + 1
            return item
        }
        try publish(next)
    }

    public func snapshot() -> BrowserBoostDocument { document }
    public func matchTable() -> BrowserBoostMatchTable { table }

    /// Creation requires nil; updates require the currently published Boost revision.
    /// Revision ownership stays here, so callers cannot publish arbitrary revision numbers.
    @discardableResult
    public func save(_ boost: BrowserBoost, expectedRevision: UInt64? = nil) throws -> BrowserBoost {
        var next = document
        var boost = boost
        if let index = next.boosts.firstIndex(where: { $0.id == boost.id }) {
            guard expectedRevision == next.boosts[index].revision else { throw BrowserBoostError.staleRevision }
            guard next.boosts[index].revision < UInt64.max else { throw BrowserBoostError.revisionExhausted }
            boost.revision = next.boosts[index].revision + 1
            next.boosts[index] = boost
        } else {
            guard expectedRevision == nil else { throw BrowserBoostError.staleRevision }
            // Recreating a removed identity must not collide with an engine's old revision cache.
            boost.revision = document.revision
            next.boosts.append(boost)
        }
        try publish(next)
        return boost
    }

    public func remove(_ id: BrowserBoostID, expectedRevision: UInt64) throws {
        guard let boost = document.boosts.first(where: { $0.id == id }), boost.revision == expectedRevision else {
            throw BrowserBoostError.staleRevision
        }
        var next = document
        next.boosts.removeAll { $0.id == id }
        try publish(next)
    }

    public func removeAll() throws {
        var next = document
        next.boosts = []
        try publish(next)
    }

    private func publish(_ candidate: BrowserBoostDocument) throws {
        guard document.revision < UInt64.max else { throw BrowserBoostError.revisionExhausted }
        var next = candidate
        next.revision = document.revision + 1
        let compiled = try BrowserBoostMatchTable(profileID: profileID, boosts: next.boosts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(next)
        guard bytes.count <= Self.maximumDocumentBytes else { throw BrowserBoostError.limitExceeded }
        if let destination {
            do {
                try BrowserPermissionFile.save(bytes, to: destination, maximumBytes: Self.maximumDocumentBytes,
                                               beforeReplace: beforeReplace)
            } catch BrowserPermissionFile.Failure.committedButNotDurable {
                document = next
                table = compiled
                throw BrowserPermissionFile.Failure.committedButNotDurable
            }
        }
        document = next
        table = compiled
    }

    private struct Header: Decodable { let version: Int }
    private struct LegacyDocument: Decodable {
        let profileID: ProfileID
        let boosts: [LegacyBoost]
    }
    private struct LegacyBoost: Decodable {
        let id: BrowserBoostID
        let title: String
        let hostPattern: BrowserBoostHostPattern
        let isEnabled: Bool
        let content: BrowserBoostContent
    }
}
