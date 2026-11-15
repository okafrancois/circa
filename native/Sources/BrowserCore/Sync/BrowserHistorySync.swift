import CryptoKit
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
            // Never publish the deleted host itself: a salted digest still matches it everywhere.
            site = Self.hashedSite(URL(string: "https://" + host)?.host?.lowercased() ?? host.lowercased(),
                                   salt: UUID().uuidString); end = now
        case .interval(let interval): start = interval.start; end = interval.end
        case .lastHour(let date): start = date.addingTimeInterval(-3600); end = now
        case .lastDay(let date): start = date.addingTimeInterval(-86400); end = now
        case .all: end = now
        }
    }

    func matches(_ visit: BrowserHistoryVisit) -> Bool {
        if let visitID { return visit.id == visitID }
        return matchesTime(visit) && (site.map { Self.site($0, matches: visit.url.host?.lowercased()) } ?? true)
    }

    func matchesTime(_ visit: BrowserHistoryVisit) -> Bool {
        (endInclusive ? visit.visitedAt <= end : visit.visitedAt < end) && (start.map { visit.visitedAt >= $0 } ?? true)
    }

    /// Site tombstones written before hashing carry the plain host; they still decode and match.
    /// A hashed value can never equal a host, so a build that predates hashing deletes nothing
    /// for it instead of treating it as an unrestricted deletion.
    static let hashedSitePrefix = "~h1:"

    static func hashedSite(_ host: String, salt: String) -> String {
        hashedSitePrefix + salt + ":" + digest(host, salt: salt)
    }

    static func isHashedSite(_ value: String) -> Bool { value.hasPrefix(hashedSitePrefix) }

    static func site(_ value: String, matches host: String?) -> Bool {
        guard let host else { return false }
        guard isHashedSite(value) else { return value == host }
        let parts = value.dropFirst(hashedSitePrefix.count).split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return false }
        return digest(host, salt: String(parts[0])) == parts[1]
    }

    private static func digest(_ host: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + "\n" + host).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Matches visits against tombstones, computing each salted site digest once per host.
struct BrowserHistorySyncBarriers {
    let deletions: [BrowserHistorySyncDeletion]
    private var hashedMatches: [String: Bool] = [:]

    init(_ deletions: [BrowserHistorySyncDeletion]) { self.deletions = deletions }

    mutating func matches(_ visit: BrowserHistoryVisit) -> Bool {
        for deletion in deletions {
            if let id = deletion.visitID { if visit.id == id { return true }; continue }
            guard deletion.matchesTime(visit) else { continue }
            guard let site = deletion.site else { return true }
            guard let host = visit.url.host?.lowercased() else { continue }
            guard BrowserHistorySyncDeletion.isHashedSite(site) else { if site == host { return true }; continue }
            let key = site + "|" + host
            let matched = hashedMatches[key] ?? BrowserHistorySyncDeletion.site(site, matches: host)
            hashedMatches[key] = matched
            if matched { return true }
        }
        return false
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

    /// The same tombstone with its plain site replaced by a digest salted with the event identity,
    /// so every Mac rewriting one journal row produces the same bytes.
    func hashingSite() -> Self? {
        guard var deletion, let site = deletion.site, !BrowserHistorySyncDeletion.isHashedSite(site) else { return nil }
        deletion.site = BrowserHistorySyncDeletion.hashedSite(site, salt: id.uuidString)
        return Self(id: id, time: time, deletion: deletion, expires: expires)
    }

    private init(id: UUID, time: Date, deletion: BrowserHistorySyncDeletion, expires: Date) {
        self.id = id; self.time = time; visit = nil; self.deletion = deletion; self.expires = expires
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
    /// Local-only notice that the history store dropped the saved batch `id` because it carried
    /// a deleted visit or a plain-host tombstone. Transports delete that record remotely and never
    /// upload the notice: its distant-past cutoff makes it expired everywhere.
    public static func retraction(of id: UUID, profileID: ProfileID) -> Self {
        Self(id: id, profileID: profileID, cutoff: .distantPast, events: [])
    }
    public var isRetraction: Bool { cutoff == .distantPast && events.isEmpty }
    public func encoded() throws -> Data { try BrowserSyncReplica.encodeValue(self) }
    public func validate() throws { try validate(encodedSize: encoded().count) }
    func validate(encodedSize: Int) throws {
        guard version == 1, events.count <= BrowserHistorySyncSchema.maximumEvents,
              encodedSize <= BrowserHistorySyncSchema.maximumBytes,
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
    /// Deleted records; like the CloudKit transport, a replica never uploads one again.
    private var retracted: [UUID: Date] = [:]
    public var schemaAvailable: Bool
    public init(schemaAvailable: Bool = true) { self.schemaAvailable = schemaAvailable }
    var recordedBatches: [BrowserHistorySyncBatch] { Array(records.values) }
    public func exchange(_ batches: [BrowserHistorySyncBatch], now: Date = Date()) throws -> [BrowserHistorySyncBatch] {
        guard schemaAvailable else { throw BrowserSyncError.unavailable }
        let cutoff = BrowserHistorySyncSchema.cutoff(now)
        records = records.filter { $0.value.expires >= cutoff }
        retracted = retracted.filter { $0.value >= cutoff }
        for batch in batches where batch.isRetraction && retracted[batch.id] == nil {
            retracted[batch.id] = records.removeValue(forKey: batch.id)?.expires ?? now.addingTimeInterval(BrowserHistorySyncSchema.retention)
        }
        for batch in batches where batch.expires >= cutoff && retracted[batch.id] == nil {
            try batch.validate()
            guard records[batch.id].map({ $0 == batch }) ?? true else { throw BrowserSyncError.invalidRecord }
            records[batch.id] = batch
        }
        return Array(records.values)
    }
    public func stop() {}
}
