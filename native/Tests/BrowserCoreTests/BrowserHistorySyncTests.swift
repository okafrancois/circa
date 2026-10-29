@testable import BrowserCore
import CloudKit
import Foundation
import Testing

@Suite("History sync", .serialized)
struct BrowserHistorySyncTests {
    private let now = Date()
    private func visit(_ path: String, at date: Date? = nil, id: UUID = UUID()) -> BrowserHistoryVisit {
        BrowserHistoryVisit(id: id, url: URL(string: "https://example.test/" + path)!, title: path,
            visitedAt: date ?? now.addingTimeInterval(-60), transition: .typed,
            faviconReference: URL(string: "https://example.test/icon.png"), typedCount: 1)
    }
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-history-sync-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func sync(_ store: BrowserHistoryStore, _ cloud: BrowserHistorySyncMemoryCloud, at date: Date? = nil) async throws {
        let date = date ?? now
        let batches = try await store.historySyncBatches(now: date)
        let incoming = try await cloud.exchange(batches, now: date)
        try await store.applyHistorySync(incoming, now: date)
    }

    @Test("Two Macs converge with imported and local visits, stable identities, metadata and ranking")
    func twoMacs() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID(), cloud = BrowserHistorySyncMemoryCloud()
        let a = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("a"))
        let b = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("b"))
        let first = visit("shared"), second = visit("shared")
        #expect(try await a.record(first))
        #expect(try await b.importDocument(BrowserHistoryDocument(profileID: profile, visits: [second])) == 1)
        try await a.updateMetadata(visitID: first.id, title: "Updated synthetic title", faviconReference: first.faviconReference)
        try await sync(a, cloud); try await sync(b, cloud); try await sync(a, cloud)
        for store in [a, b] {
            #expect(try await store.visits().count == 2)
            #expect(try await store.visits().first(where: { $0.id == first.id })?.title == "Updated synthetic title")
            let suggestion = try await store.suggestions("shared", now: now).first
            #expect(suggestion?.visitCount == 2)
            #expect(suggestion?.typedCount == 2)
            #expect(suggestion?.profileID == profile)
            let index = try await store.memoryIndex(now: now)
            #expect(index.suggestions("shared", now: now).first?.visitCount == 2)
        }
        try await b.updateMetadata(visitID: first.id, title: "Final synthetic title")
        try await sync(b, cloud); try await sync(a, cloud)
        #expect(try await a.visits().first(where: { $0.id == first.id })?.faviconReference == first.faviconReference)
        #expect(try await a.visits().first(where: { $0.id == first.id })?.title == "Final synthetic title")
        try await sync(a, cloud); try await sync(b, cloud)
        #expect(try await b.visits().count == 2)
        try await a.close(); try await b.close()
    }

    @Test("Clear history covers an unseen offline visit and survives restart and stale replay")
    func clearOffline() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID(), cloud = BrowserHistorySyncMemoryCloud()
        let a = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("a"))
        let bRoot = root.appendingPathComponent("b")
        let b = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: bRoot)
        let old = visit("old"), unseen = visit("offline")
        try await a.record(old); try await sync(a, cloud)
        try await b.record(unseen)
        let stale = try await b.historySyncBatches(now: now)
        #expect(try await a.delete(.all, now: now) == 1)
        try await sync(a, cloud); try await sync(b, cloud); try await sync(a, cloud)
        #expect(try await a.visits().isEmpty)
        #expect(try await b.visits().isEmpty)
        try await b.close()
        let reopened = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: bRoot)
        try await reopened.applyHistorySync(stale, now: now)
        #expect(try await reopened.importDocument(BrowserHistoryDocument(profileID: profile, visits: [unseen])) == 0)
        #expect(try await reopened.visits().isEmpty)
        let later = visit("new", at: now.addingTimeInterval(1))
        #expect(try await reopened.record(later))
        try await sync(reopened, cloud, at: now.addingTimeInterval(2)); try await sync(a, cloud, at: now.addingTimeInterval(2))
        #expect(try await a.visits().map(\.id) == [later.id])
        try await a.close(); try await reopened.close()
    }

    @Test("Site, individual and range deletions converge without crossing profiles or hosts")
    func deletionScopes() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID(), cloud = BrowserHistorySyncMemoryCloud()
        let a = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("a"))
        let b = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("b"))
        let sub = BrowserHistoryVisit(url: URL(string: "https://sub.example.test/keep")!, visitedAt: now.addingTimeInterval(-20))
        let first = visit("first"), offline = visit("offline")
        try await a.importDocument(BrowserHistoryDocument(profileID: profile, visits: [first, sub]))
        try await sync(a, cloud); try await sync(b, cloud)
        try await b.record(offline)
        try await a.delete(.site("EXAMPLE.TEST"), now: now)
        try await sync(a, cloud); try await sync(b, cloud); try await sync(a, cloud)
        #expect(try await b.visits().map(\.id) == [sub.id])
        try await b.delete(.visit(sub.id), now: now)
        try await sync(b, cloud); try await sync(a, cloud)
        #expect(try await a.visits().isEmpty)
        let rangeStart = visit("range-start", at: now.addingTimeInterval(2))
        let rangeEnd = visit("range-end", at: now.addingTimeInterval(3))
        try await b.importDocument(BrowserHistoryDocument(profileID: profile, visits: [rangeStart, rangeEnd]))
        try await b.delete(.interval(DateInterval(start: rangeStart.visitedAt, end: rangeEnd.visitedAt)), now: now.addingTimeInterval(4))
        try await sync(b, cloud, at: now.addingTimeInterval(4)); try await sync(a, cloud, at: now.addingTimeInterval(4))
        #expect(try await a.visits().map(\.id) == [rangeEnd.id])
        let other = try BrowserHistoryStore(profileID: ProfileID(), policy: .persistent, directory: root)
        try await other.record(first)
        try await other.applyHistorySync(try await a.historySyncBatches(now: now), now: now)
        #expect(try await other.visits().count == 1)
        try await a.close(); try await b.close(); try await other.close()
    }

    @Test("Expiry watermark prevents an offline Mac from reviving visits after tombstones are pruned")
    func expiry() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID(), cloud = BrowserHistorySyncMemoryCloud()
        let a = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("a"))
        let b = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("b"))
        let old = visit("old")
        try await b.record(old)
        let stale = try await b.historySyncBatches(now: now)
        let later = now.addingTimeInterval(92 * 86400)
        try await sync(a, cloud, at: later)
        try await a.applyHistorySync(stale, now: later)
        #expect(try await a.visits().isEmpty)
        try await sync(b, cloud, at: later); try await sync(a, cloud, at: later)
        #expect(try await b.visits().isEmpty)
        #expect(try await !b.record(old))
        #expect(try await a.historySyncBatches(now: later).allSatisfy { $0.events.isEmpty })
        try await a.close(); try await b.close()
    }

    @Test("Private and ephemeral history produces no records and accepts no remote data")
    func privateExclusion() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-history-sync-disabled-\(UUID())")
        let profile = ProfileID()
        let batch = BrowserHistorySyncBatch(profileID: profile, cutoff: BrowserHistorySyncSchema.cutoff(now), events: [.init(visit: visit("remote"))])
        for policy in [BrowserHistoryPolicy.private, .ephemeral] {
            let store = try BrowserHistoryStore(profileID: profile, policy: policy, directory: root)
            #expect(try await !store.record(visit("private")))
            #expect(try await store.historySyncBatches(now: now).isEmpty)
            #expect(try await !store.applyHistorySync([batch], now: now))
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Thousands of visits pack into stable records under count and byte limits, including oversized visits")
    func batching() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let visits = (0..<2400).map { visit("page-\($0)") }
        try await store.importDocument(BrowserHistoryDocument(profileID: profile, visits: visits))
        let batches = try await store.historySyncBatches(now: now)
        #expect(batches.count >= 5 && batches.count < 10)
        #expect(batches.flatMap(\.events).count == visits.count)
        #expect(try await store.historySyncBatches(now: now) == batches)
        for batch in batches { try batch.validate() }
        let large = BrowserHistoryVisit(url: URL(string: "https://example.test/large")!, title: String(repeating: "x", count: 600_000), visitedAt: now)
        try await store.record(large)
        let smaller = try BrowserHistorySyncBatch.pack(profileID: profile, cutoff: now, events: (0..<10).map { _ in
            .init(visit: BrowserHistoryVisit(url: URL(string: "https://example.test/big")!, title: String(repeating: "x", count: 120_000), visitedAt: now))
        })
        #expect(smaller.count > 1)
        for batch in smaller { try batch.validate() }
        let withLarge = try await store.historySyncBatches(now: now)
        #expect(withLarge == batches)
        #expect(try await store.visits(limit: 3000).count == 2401)
        try await store.close()
    }

    @Test("Missing history schema fails closed while organization records still exchange")
    func missingSchema() async throws {
        let cloud = BrowserHistorySyncMemoryCloud(schemaAvailable: false)
        let batch = BrowserHistorySyncBatch(profileID: ProfileID(), cutoff: now, events: [])
        await #expect(throws: BrowserSyncError.unavailable) { try await cloud.exchange([batch], now: now) }
        let organization = BrowserSyncMemoryCloud()
        var replica = BrowserSyncReplica(device: "synthetic")
        var projection = BrowserSyncProjection()
        projection.entries["profile:synthetic"] = ["name": Data("Synthetic".utf8)]
        try replica.capture(projection, now: now)
        let result = try await organization.exchange(account: "synthetic", records: Array(replica.records.values))
        #expect(result.count == 1)
    }
}

// Downgrade fixtures must remove tables introduced after the version they model.
extension HistoryDatabase {
    func discardSyncSchemaForLegacyFixture() throws {
        for table in ["historySyncEvents", "historySyncBatches", "historySyncState", "historySyncVersions"] {
            try execute("DROP TABLE \(table)")
        }
    }
}
