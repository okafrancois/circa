import Foundation

/// Private database only. Record identities are logical model UUIDs, never URLs or titles.
public enum BrowserSyncSchema {
    public static let version = 1
    public static let container = "iCloud.io.github.okatech.orbit"
    public static let zone = "OrbitOrganization"
    public static let recordType = "OrbitOrganizationV1"
}

public enum BrowserSyncError: Error, Equatable, Sendable {
    case unsupportedVersion, invalidRecord, signedOut, accountChanged, unavailable, localChange
}

public struct BrowserSyncStamp: Codable, Equatable, Comparable, Sendable {
    public let time: Int64
    public let device: String
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.time, lhs.device) < (rhs.time, rhs.device)
    }
}

public struct BrowserSyncField: Codable, Equatable, Sendable {
    public let value: Data
    public let stamp: BrowserSyncStamp
}

public struct BrowserSyncRecord: Codable, Equatable, Sendable {
    public var version = BrowserSyncSchema.version
    public let id: String
    public var fields: [String: BrowserSyncField]
    /// Independent existence register. Ordinary edits cannot revive a deleted item.
    public var life: BrowserSyncStamp
    public var deleted: Bool

    public mutating func merge(_ other: Self) throws {
        guard version == BrowserSyncSchema.version, other.version == version, id == other.id else {
            throw BrowserSyncError.unsupportedVersion
        }
        for (key, field) in other.fields where fields[key].map({ $0.stamp < field.stamp }) ?? true {
            fields[key] = field
        }
        if life < other.life { life = other.life; deleted = other.deleted }
    }
}

/// Fractional lexicographic keys. Unchanged siblings retain their keys; identity breaks ties
/// between simultaneous insertions. Keys can grow without floating-point precision loss.
public struct BrowserSyncOrder: Codable, Equatable, Comparable, Sendable {
    public let digits: [UInt16]
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.digits.lexicographicallyPrecedes(rhs.digits) }
    public static func between(_ lower: Self?, _ upper: Self?) -> Self {
        var result: [UInt16] = []
        var bounded = true
        for index in 0...4096 {
            let low = lower.flatMap { index < $0.digits.count ? $0.digits[index] : nil } ?? 0
            let high = bounded ? (upper.flatMap { index < $0.digits.count ? $0.digits[index] : nil } ?? UInt16.max) : UInt16.max
            if Int(high) - Int(low) > 1 { result.append(low + (high - low) / 2); return .init(digits: result) }
            result.append(low)
            if low < high { bounded = false }
        }
        return .init(digits: result + [32767])
    }
}

public struct BrowserSyncPlacement: Codable, Equatable, Sendable {
    public let parent: String
    /// Valid root to use if concurrent folder moves produce a cycle or delete the parent.
    public let root: String
    public let order: BrowserSyncOrder
}

public struct BrowserSyncProjection: Equatable, Sendable {
    public var entries: [String: [String: Data]] = [:]
    public var lists: [String: [String]] = [:]
    public var roots: [String: String] = [:]
    public init() {}
}

/// Durable outbox, merge metadata and observed projection. Persist before any network operation.
/// Tombstones are retained indefinitely until a future acknowledged-device compaction protocol.
public struct BrowserSyncReplica: Codable, Sendable {
    public var version = BrowserSyncSchema.version
    public let device: String
    public private(set) var records: [String: BrowserSyncRecord] = [:]
    public private(set) var baseline: [String: [String: Data]] = [:]
    internal var tick: Int64 = 0
    public init(device: String = UUID().uuidString) { self.device = device }

    private mutating func stamp(now: Date) -> BrowserSyncStamp {
        tick = max(tick + 1, Int64(now.timeIntervalSince1970 * 1_000_000))
        return .init(time: tick, device: device)
    }

    public mutating func capture(_ projection: BrowserSyncProjection, now: Date = Date()) throws {
        guard version == BrowserSyncSchema.version else { throw BrowserSyncError.unsupportedVersion }
        let editStamp = stamp(now: now)
        var entries = projection.entries
        // Decode only listed baseline placements, once, including malformed suffix values
        // that the original eager traversal would reject even when an order was reusable.
        var placements: [String: BrowserSyncPlacement] = [:]
        let decoder = JSONDecoder()
        for id in Set(projection.lists.values.flatMap { $0 }) {
            if let bytes = baseline[id]?["placement"] {
                placements[id] = try decoder.decode(BrowserSyncPlacement.self, from: bytes)
            }
        }
        for (parent, ids) in projection.lists {
            var previous: BrowserSyncOrder?
            for (index, id) in ids.enumerated() {
                let old = placements[id]
                let order: BrowserSyncOrder
                if let old, old.parent == parent, previous.map({ $0 < old.order }) ?? true {
                    order = old.order
                } else {
                    let next = ids.dropFirst(index + 1).lazy.compactMap { nextID -> BrowserSyncOrder? in
                        guard let placement = placements[nextID], placement.parent == parent,
                              previous.map({ $0 < placement.order }) ?? true else { return nil }
                        return placement.order
                    }.first
                    order = .between(previous, next)
                }
                let placement = BrowserSyncPlacement(parent: parent, root: projection.roots[id] ?? parent, order: order)
                entries[id, default: [:]]["placement"] = try Self.encodeValue(placement)
                previous = order
            }
        }
        for id in baseline.keys where entries[id] == nil {
            guard var record = records[id], !record.deleted else { continue }
            record.deleted = true; record.life = editStamp; records[id] = record
        }
        for (id, fields) in entries {
            let prior = baseline[id]
            var record = records[id] ?? .init(id: id, fields: [:], life: editStamp, deleted: false)
            if prior == nil && record.deleted { record.deleted = false; record.life = editStamp }
            // Explicit nulls represent removal of an optional field.
            for key in Set(fields.keys).union(prior?.keys.map { $0 } ?? []) {
                let value = fields[key] ?? Data("null".utf8)
                if prior?[key] != value { record.fields[key] = .init(value: value, stamp: editStamp) }
            }
            records[id] = record
        }
        baseline = entries
    }

    public mutating func merge(_ incoming: [BrowserSyncRecord]) throws {
        for record in incoming {
            guard record.version == BrowserSyncSchema.version else { throw BrowserSyncError.unsupportedVersion }
            tick = max(tick, record.life.time, record.fields.values.map(\.stamp.time).max() ?? 0)
            if var local = records[record.id] { try local.merge(record); records[record.id] = local }
            else { records[record.id] = record }
        }
    }

    public var visible: [String: [String: Data]] {
        records.filter { !$0.value.deleted }.mapValues { $0.fields.mapValues(\.value) }
    }

    /// Only acknowledge fields actually materialized locally. Invalid/incomplete graph members
    /// remain in the replica for a later fetch, rather than becoming local deletions.
    public mutating func acknowledge(_ projection: BrowserSyncProjection) throws {
        baseline = projection.entries
        for (id, fields) in baseline {
            if let placement = records[id]?.fields["placement"] { baseline[id] = fields.merging(["placement": placement.value]) { _, new in new } }
        }
    }

    static func encodeValue<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

public protocol BrowserSyncTransport: Sendable {
    func account() async throws -> String?
    func exchange(_ records: [BrowserSyncRecord]) async throws -> [BrowserSyncRecord]
    func stop() async
}

/// Separate private databases per identity, with the same field merge rules as the real adapter.
public actor BrowserSyncMemoryCloud {
    private var databases: [String: [String: BrowserSyncRecord]] = [:]
    public init() {}
    func exchange(account: String, records: [BrowserSyncRecord]) throws -> [BrowserSyncRecord] {
        var database = databases[account] ?? [:]
        for record in records {
            if var current = database[record.id] { try current.merge(record); database[record.id] = current }
            else { database[record.id] = record }
        }
        databases[account] = database
        return Array(database.values)
    }
}

public actor BrowserSyncMemoryTransport: BrowserSyncTransport {
    private let cloud: BrowserSyncMemoryCloud
    private var identity: String?
    public init(cloud: BrowserSyncMemoryCloud, account: String?) { self.cloud = cloud; identity = account }
    public func setAccount(_ account: String?) { identity = account }
    public func account() -> String? { identity }
    public func exchange(_ records: [BrowserSyncRecord]) async throws -> [BrowserSyncRecord] {
        guard let identity else { throw BrowserSyncError.signedOut }
        return try await cloud.exchange(account: identity, records: records)
    }
    public func stop() {}
}

public struct BrowserSyncAccountMarker: Codable, Equatable, Sendable {
    public private(set) var identity: String?
    public private(set) var signedOut = false
    public init() {}
    public mutating func admit(_ current: String?) throws {
        guard let current else { signedOut = true; throw BrowserSyncError.signedOut }
        guard identity == nil || identity == current else { throw BrowserSyncError.accountChanged }
        identity = current; signedOut = false
    }
}
