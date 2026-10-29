import Foundation

public enum BrowserHistorySyncSchema {
    public static let zone = "OrbitHistory"
    public static let recordType = "OrbitHistoryV1"
    public static let retention: TimeInterval = 90 * 86400
    // Leave ample room for CKRecord/system-field overhead below the 1 MB record limit.
    public static let maximumBytes = 512 * 1024
    public static let maximumEvents = 500
    public static func cutoff(_ now: Date) -> Date {
        Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 86400) * 86400 - retention)
    }
}

/// A deletion describes a time-bounded predicate, including visits not yet seen on this Mac.
/// Retain it until the expiry watermark passes its upper bound.
public struct BrowserHistorySyncDeletion: Codable, Equatable, Sendable {
    public var visitID: UUID?
    public var site: String?
    public var start: Date?
    public let end: Date
    public let endInclusive: Bool

    init(_ deletion: BrowserHistoryDeletion, now: Date) {
        visitID = nil; site = nil; start = nil; endInclusive = { if case .interval = deletion { return false }; return true }()
        switch deletion {
        case .visit(let id): visitID = id; end = .distantFuture
        case .site(let host):
            site = URL(string: "https://" + host)?.host?.lowercased() ?? host.lowercased(); end = now
        case .interval(let interval): start = interval.start; end = interval.end
        case .lastHour(let date): start = date.addingTimeInterval(-3600); end = now
        case .lastDay(let date): start = date.addingTimeInterval(-86400); end = now
        case .all: end = now
        }
    }

    func matches(_ visit: BrowserHistoryVisit) -> Bool {
        if let visitID { return visit.id == visitID }
        return (endInclusive ? visit.visitedAt <= end : visit.visitedAt < end) && (start.map { visit.visitedAt >= $0 } ?? true)
            && (site.map { visit.url.host?.lowercased() == $0 } ?? true)
    }
}

/// Append-only metadata revisions share the immutable visit UUID. The event UUID breaks ties.
public struct BrowserHistorySyncEvent: Codable, Equatable, Sendable {
    public let id: UUID
    public let time: Date
    public let visit: BrowserHistoryVisit?
    public let deletion: BrowserHistorySyncDeletion?
    public let expires: Date

    init(visit: BrowserHistoryVisit, time: Date = Date()) {
        id = UUID(); self.time = time
        // Favicons and redirect chains are local caches, not history ranking inputs.
        self.visit = BrowserHistoryVisit(id: visit.id, url: visit.url, title: visit.title,
            visitedAt: visit.visitedAt, transition: visit.transition, typedCount: visit.typedCount)
        deletion = nil; expires = visit.visitedAt
    }
    init(deletion: BrowserHistorySyncDeletion, time: Date) {
        id = UUID(); self.time = time; visit = nil; self.deletion = deletion
        // Individual identity tombstones need survive only as long as any admissible old visit.
        expires = deletion.visitID == nil ? deletion.end : time
    }
}

public struct BrowserHistorySyncBatch: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let profileID: ProfileID
    public let cutoff: Date
    public let events: [BrowserHistorySyncEvent]
    public var expires: Date { events.map(\.expires).max() ?? cutoff.addingTimeInterval(BrowserHistorySyncSchema.retention) }

    public init(id: UUID = UUID(), profileID: ProfileID, cutoff: Date, events: [BrowserHistorySyncEvent]) {
        version = 1; self.id = id; self.profileID = profileID; self.cutoff = cutoff; self.events = events
    }
    public func encoded() throws -> Data { try BrowserSyncReplica.encodeValue(self) }
    public func validate() throws {
        guard version == 1, events.count <= BrowserHistorySyncSchema.maximumEvents,
              try encoded().count <= BrowserHistorySyncSchema.maximumBytes,
              cutoff.timeIntervalSince1970.isFinite else { throw BrowserSyncError.invalidRecord }
        for event in events {
            guard event.time.timeIntervalSince1970.isFinite, event.expires.timeIntervalSince1970.isFinite,
                  (event.visit == nil) != (event.deletion == nil) else { throw BrowserSyncError.invalidRecord }
            if let visit = event.visit, !BrowserHistoryStore.accepts(visit) { throw BrowserSyncError.invalidRecord }
            if let deletion = event.deletion {
                guard deletion.end.timeIntervalSince1970.isFinite,
                      deletion.start.map({ $0 <= deletion.end }) ?? true else { throw BrowserSyncError.invalidRecord }
            }
        }
    }

    static func pack(profileID: ProfileID, cutoff: Date, events: [BrowserHistorySyncEvent]) throws -> [Self] {
        var result: [Self] = [], current: [BrowserHistorySyncEvent] = []
        var bytes = 1024
        for event in events {
            let size = try BrowserSyncReplica.encodeValue(event).count + 1
            // An unusually large visit stays local. Never exceed the CloudKit record limit.
            guard size + 1024 <= BrowserHistorySyncSchema.maximumBytes else { continue }
            if current.count == BrowserHistorySyncSchema.maximumEvents || bytes + size > BrowserHistorySyncSchema.maximumBytes {
                result.append(Self(profileID: profileID, cutoff: cutoff, events: current)); current = []; bytes = 1024
            }
            current.append(event); bytes += size
        }
        if !current.isEmpty { result.append(Self(profileID: profileID, cutoff: cutoff, events: current)) }
        return result
    }
}

public protocol BrowserHistorySyncTransport: Sendable {
    func exchange(_ batches: [BrowserHistorySyncBatch], now: Date) async throws -> [BrowserHistorySyncBatch]
    func stop() async
}

/// Uses the production wire validation and immutable conflict rules without an Apple account.
public actor BrowserHistorySyncMemoryCloud: BrowserHistorySyncTransport {
    private var records: [UUID: BrowserHistorySyncBatch] = [:]
    public var schemaAvailable: Bool
    public init(schemaAvailable: Bool = true) { self.schemaAvailable = schemaAvailable }
    public func exchange(_ batches: [BrowserHistorySyncBatch], now: Date = Date()) throws -> [BrowserHistorySyncBatch] {
        guard schemaAvailable else { throw BrowserSyncError.unavailable }
        let cutoff = BrowserHistorySyncSchema.cutoff(now)
        records = records.filter { $0.value.expires >= cutoff }
        for batch in batches where batch.expires >= cutoff {
            try batch.validate()
            guard records[batch.id].map({ $0 == batch }) ?? true else { throw BrowserSyncError.invalidRecord }
            records[batch.id] = batch
        }
        return Array(records.values)
    }
    public func stop() {}
}
