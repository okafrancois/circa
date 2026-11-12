@testable import BrowserCore
import Foundation
import SQLite3
import Darwin
import Testing

@Suite("History favicon storage", .serialized)
struct BrowserHistoryFaviconTests {
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/perf-history-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private var icon: URL {
        BrowserHistoryFavicon.reference(png: Data([137,80,78,71,13,10,26,10]) + Data(repeating: 42, count: 2048))!
    }

    private func inlineEvent(_ event: BrowserHistorySyncEvent, visit: BrowserHistoryVisit) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: BrowserSyncReplica.encodeValue(event)) as! [String: Any]
        object["visit"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(visit))
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // A v7 fixture is assembled with the exact legacy payload shape, including a page icon
    // that differs from its visit. No user data or external fixture is involved.
    private func legacy(_ db: HistoryDatabase, profile: ProfileID, count: Int, malformed: Bool = false, inlineEvents: Bool = true) throws {
        try db.execute("DROP TABLE favicons")
        try db.execute("UPDATE identity SET version=7")
        try db.execute("PRAGMA user_version=7")
        try db.transaction {
            for i in 0..<count {
                let visit = BrowserHistoryVisit(url: URL(string: "https://synthetic.test/\(i % 500)")!,
                    title: "Synthetic", visitedAt: Date(), faviconReference: icon)
                let payload = malformed && i == count - 1 ? "invalid" : String(decoding: try JSONEncoder().encode(visit), as: UTF8.self)
                try db.execute("INSERT INTO visits VALUES(?,?,?,?,?,?,?,?)", [.text(visit.id.uuidString), .text(visit.url.absoluteString), .text("synthetic.test"), .number(visit.visitedAt.timeIntervalSince1970), .text(visit.title), .number(0), .text(payload), .text("synthetic")])
                try db.execute("INSERT OR REPLACE INTO pages(url,title,favicon,last,visits,typed,searchURL,searchTitle) VALUES(?,?,?, ?,1,0,?,?)", [.text(visit.url.absoluteString), .text(visit.title), .text(icon.absoluteString), .number(visit.visitedAt.timeIntervalSince1970), .text(visit.url.absoluteString), .text("synthetic")])
                let event = BrowserHistorySyncEvent(visit: visit)
                let encoded = inlineEvents ? try inlineEvent(event, visit: visit) : try BrowserSyncReplica.encodeValue(event)
                try db.execute("INSERT INTO historySyncEvents VALUES(?,?,?,0,NULL)", [.text(event.id.uuidString), .text(String(decoding: encoded, as: UTF8.self)), .number(event.expires.timeIntervalSince1970)])
            }
        }
    }

    @Test func migrationAndRollback() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID(), file = root.appendingPathComponent("history.sqlite")
        let initial = try HistoryDatabase(url: file, profileID: profile)
        try legacy(initial, profile: profile, count: 1025, malformed: true)
        try initial.close()
        #expect(throws: (any Error).self) { try HistoryDatabase(url: file, profileID: profile) }
        let old = try HistoryDatabase(openingURL: file, flags: SQLITE_OPEN_READWRITE)
        #expect(try old.scalarInt("PRAGMA user_version") == 7)
        #expect(try old.scalarInt("SELECT count(*) FROM sqlite_master WHERE name='favicons'") == 0)
        #expect(try old.scalarInt("SELECT count(*) FROM visits WHERE payload LIKE '%data:image%'") == 1024)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("history-before-favicons.sqlite").path))
        let backup = try HistoryDatabase(openingURL: root.appendingPathComponent("history-before-favicons.sqlite"), flags: SQLITE_OPEN_READWRITE)
        #expect(try backup.scalarInt("SELECT count(*) FROM visits") == 1025)
        #expect(try backup.scalarInt("PRAGMA user_version") == 7)
        try backup.close()
        try old.execute("DELETE FROM visits WHERE payload='invalid'")
        try old.close()
        let migrated = try HistoryDatabase(url: file, profileID: profile)
        #expect(try migrated.scalarInt("SELECT count(*) FROM favicons") == 1)
        #expect(try migrated.scalarInt("SELECT count(*) FROM visits WHERE payload LIKE '%data:image%'") == 0)
        #expect(try migrated.scalarInt("SELECT count(*) FROM historySyncEvents WHERE payload LIKE '%data:image%'") == 1025)
        let stored = URL(string: try migrated.scalarText("SELECT favicon FROM pages LIMIT 1"))!
        #expect(try migrated.resolveFavicon(stored) == icon)
        try migrated.close()
        let reopened = try HistoryDatabase(url: file, profileID: profile)
        #expect(try reopened.scalarInt("SELECT total_changes()") == 0)
        try reopened.close()
    }

    @Test func roundTripAndSync() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let visit = BrowserHistoryVisit(url: URL(string: "https://synthetic.test/icon")!, faviconReference: icon)
        #expect(try await store.record(visit))
        #expect(try await store.visits().first == visit)
        let index = try await store.memoryIndex()
        #expect(index.residentBytes < 1000)
        let suggestions = try await store.suggestions("")
        let stored = try #require(suggestions.first?.faviconReference)
        #expect(BrowserHistoryFavicon.isStoredReference(stored))
        #expect(try await store.resolveFavicon(stored) == icon)
        let batches = try await store.historySyncBatches()
        #expect(batches.flatMap(\.events).first?.visit?.faviconReference == nil)
        let oldEvent = try JSONDecoder().decode(BrowserHistorySyncEvent.self, from: inlineEvent(.init(visit: visit), visit: visit))
        let oldBatch = BrowserHistorySyncBatch(profileID: profile, cutoff: BrowserHistorySyncSchema.cutoff(Date()), events: [oldEvent])
        let receiver = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("receiver"))
        _ = try await receiver.applyHistorySync([oldBatch])
        #expect(try await receiver.visits().first?.faviconReference == icon)
        try await receiver.close()
        _ = try await store.delete(.all)
        #expect(try await store.resolveFavicon(stored) == nil)
        try await store.close()
    }

    @Test func tombstoneCacheAndDurability() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BrowserHistoryStore(profileID: ProfileID(), policy: .persistent, directory: root)
        #expect(try await store.syncDeletions().isEmpty)
        let deletion = BrowserHistorySyncDeletion(.all, now: Date())
        try await store.appendSyncEvent(BrowserHistorySyncEvent(deletion: deletion, time: Date()))
        #expect(try await store.syncDeletions().count == 1)
        #expect(try await store.syncDeletions().count == 1)
        let db = try #require(await store.database)
        #expect(try db.scalarText("PRAGMA journal_mode") == "wal")
        let synchronous = try db.routineTransaction { try db.scalarInt("PRAGMA synchronous") }
        #expect(synchronous == 1)
        #expect(try db.scalarInt("PRAGMA synchronous") == 2)
        enum Failure: Error { case synthetic }
        #expect(throws: Failure.self) { try db.routineTransaction { throw Failure.synthetic } }
        #expect(try db.scalarInt("PRAGMA synchronous") == 2)
        try db.execute("DELETE FROM historySyncEvents WHERE kind=1")
        #expect(try await store.syncDeletions().isEmpty)
        try await store.close()
    }

    @Test func syntheticBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["ORBIT_FAVICON_BENCHMARK"] == "1" else { return }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let folder = root.appendingPathComponent(profile.rawValue.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("history.sqlite")
        let initial = try HistoryDatabase(url: file, profileID: profile)
        let start = Date()
        try legacy(initial, profile: profile, count: 50_000, inlineEvents: false)
        let baseline = root.appendingPathComponent("baseline.sqlite")
        try initial.backupBeforeMigration(to: baseline)
        try initial.close()
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int
        let migration = Date()
        let migrated = try HistoryDatabase(url: file, profileID: profile)
        try migrated.close()
        let migrationSeconds = Date().timeIntervalSince(migration)
        let compactedSize = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int
        let insertRoot = root
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: insertRoot)
        let cpuNew = cpuTime()
        let startNew = Date()
        for i in 0..<1000 {
            _ = try await store.record(BrowserHistoryVisit(url: URL(string: "https://synthetic.test/\(i % 500)")!, title: "Synthetic", faviconReference: icon))
        }
        let newCPU = (cpuTime() - cpuNew) * 1000
        let newCost = Date().timeIntervalSince(startNew) * 1000
        try await store.close()
        let old = try HistoryDatabase(openingURL: baseline, flags: SQLITE_OPEN_READWRITE)
        try old.execute("PRAGMA journal_mode=WAL")
        try old.execute("PRAGMA synchronous=FULL")
        try old.execute("PRAGMA secure_delete=ON")
        try old.execute("PRAGMA temp_store=MEMORY")
        let cpuOld = cpuTime()
        let startOld = Date()
        for i in 0..<1000 {
            try old.transaction {
                let rows = try old.prepare("SELECT payload FROM historySyncEvents WHERE kind=1")
                defer { sqlite3_finalize(rows) }
                while try old.next(rows) { _ = try JSONDecoder().decode(BrowserHistorySyncEvent.self, from: Data(old.text(rows, 0).utf8)) }
                _ = try old.scalarText("SELECT cutoff FROM historySyncState")
                let visit = BrowserHistoryVisit(url: URL(string: "https://synthetic.test/\(i % 500)")!, title: "Synthetic", faviconReference: icon)
                let payload = String(decoding: try JSONEncoder().encode(visit), as: UTF8.self)
                try old.execute("INSERT INTO visits VALUES(?,?,?,?,?,?,?,?)", [.text(visit.id.uuidString), .text(visit.url.absoluteString), .text("synthetic.test"), .number(visit.visitedAt.timeIntervalSince1970), .text(visit.title), .number(0), .text(payload), .text("synthetic")])
                try old.execute("UPDATE pages SET title=?,favicon=?,last=?,visits=visits+1,searchTitle=? WHERE url=?", [.text(visit.title), .text(icon.absoluteString), .number(visit.visitedAt.timeIntervalSince1970), .text("synthetic"), .text(visit.url.absoluteString)])
                let event = BrowserHistorySyncEvent(visit: visit)
                try old.execute("INSERT INTO historySyncEvents VALUES(?,?,?,0,NULL)", [.text(event.id.uuidString), .text(String(decoding: try BrowserSyncReplica.encodeValue(event), as: UTF8.self)), .number(event.expires.timeIntervalSince1970)])
                try old.execute("INSERT INTO historySyncVersions VALUES(?,?,?)", [.text(visit.id.uuidString), .number(event.time.timeIntervalSince1970), .text(event.id.uuidString)])
            }
        }
        let oldCPU = (cpuTime() - cpuOld) * 1000
        let oldCost = Date().timeIntervalSince(startOld) * 1000
        try old.close()
        print("FAVICON_INSERT_BENCHMARK samples=1000 legacyMicroseconds=\(oldCost) currentMicroseconds=\(newCost) legacyCPUMicroseconds=\(oldCPU) currentCPUMicroseconds=\(newCPU)")
        let after = compactedSize
        print("FAVICON_BENCHMARK visits=50000 before=\(before) after=\(after) seedSeconds=\(migration.timeIntervalSince(start)) migrationSeconds=\(migrationSeconds)")
    }
}
