@testable import BrowserCore
import Foundation
import Testing
import SQLite3

@Suite("Profile history", .serialized)
struct BrowserHistoryTests {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-history-synthetic-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func visit(_ path: String, title: String = "Synthetic page", at time: Double = 1000,
                       typed: Int = 0, id: UUID = UUID()) -> BrowserHistoryVisit {
        BrowserHistoryVisit(id: id, url: URL(string: "https://example.test/\(path)")!, title: title,
                            visitedAt: Date(timeIntervalSince1970: time), transition: typed > 0 ? .typed : .link,
                            redirectChain: [URL(string: "https://redirect.test/start")!],
                            faviconReference: URL(string: "https://example.test/icon.png")!, typedCount: typed)
    }

    @Test("Visits and metadata survive reopening without crossing profiles")
    func durableProfiles() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let a = ProfileID(), b = ProfileID()
        let store = try BrowserHistoryStore(profileID: a, policy: .persistent, directory: root)
        let other = try BrowserHistoryStore(profileID: b, policy: .persistent, directory: root)
        let record = visit("first", typed: 1)
        #expect(try await store.record(record))
        #expect(try await other.visits().isEmpty)
        #expect(try await other.suggestions("first").isEmpty)
        try await store.updateMetadata(visitID: record.id, title: "Updated synthetic title", faviconReference: record.faviconReference)
        try await store.close()
        let reopened = try BrowserHistoryStore(profileID: a, policy: .persistent, directory: root)
        let records = try await reopened.visits()
        #expect(records.count == 1)
        #expect(records.first?.transition == .typed)
        #expect(records.first?.redirectChain == record.redirectChain)
        #expect(records.first?.title == "Updated synthetic title")
        #expect(records.first?.faviconReference == record.faviconReference)
        #expect(try await reopened.suggestions("UPDATED").first?.profileID == a)
        try await reopened.close(); try await other.close()
    }

    @Test("Private and ephemeral stores never create files or retain history")
    func disabledPolicies() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-history-disabled-\(UUID())")
        for policy in [BrowserHistoryPolicy.private, .ephemeral] {
            let id = ProfileID()
            let store = try BrowserHistoryStore(profileID: id, policy: policy, directory: root)
            #expect(try await !store.record(visit("private")))
            #expect(try await store.importDocument(BrowserHistoryDocument(profileID: id, visits: [visit("import")])) == 0)
            #expect(try await store.visits().isEmpty)
            #expect(try await store.suggestions("private").isEmpty)
            #expect(try await store.delete(.all) == 0)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Imports are atomic, profile-bound, retry-safe and preserve supplied metadata")
    func imports() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        let store = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        let records = [visit("a"), visit("b", typed: 3)]
        let document = BrowserHistoryDocument(profileID: id, visits: records)
        #expect(try await store.importDocument(document) == 2)
        #expect(try await store.importDocument(document) == 0)
        await #expect(throws: BrowserHistoryError.profileMismatch) {
            try await store.importDocument(BrowserHistoryDocument(profileID: ProfileID(), visits: records))
        }
        let invalid = BrowserHistoryVisit(url: URL(string: "https://user:password@example.test/no")!)
        await #expect(throws: BrowserHistoryError.invalidVisit) {
            try await store.importDocument(BrowserHistoryDocument(profileID: id, visits: [visit("rollback"), invalid]))
        }
        #expect(try await store.visits().count == 2)
        #expect(try await store.suggestions("rollback").isEmpty)
        try await store.close()
    }

    @Test("Prefix, literal substring, Unicode title and frecency queries return useful deterministic suggestions")
    func searchAndRanking() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        let store = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        let now = Date(timeIntervalSince1970: 500000)
        let records = [visit("docs-guide", title: "CAFÉ Guide", at: 499900, typed: 3),
                       visit("docs-other", title: "Other guide", at: 499990),
                       visit("percent%25_under_score", title: "100%_literal", at: 499990)]
        _ = try await store.importDocument(BrowserHistoryDocument(profileID: id, visits: records))
        #expect(try await store.suggestions("GUIDE", now: now).first?.url == records[0].url)
        #expect(try await store.suggestions("example.test/docs", mode: .prefix, now: now).count == 2)
        #expect(try await store.suggestions("https://example.test/docs", mode: .prefix, now: now).count == 2)
        #expect(try await store.suggestions("cafe", now: now).first?.title == "CAFÉ Guide")
        #expect(try await store.suggestions("100%_", mode: .prefix).count == 1)
        #expect(try await store.suggestions("%_").count == 1)
        #expect(try await store.suggestions("\" OR *").isEmpty)
        #expect(try await store.suggestions("", limit: 1).count == 1)
        #expect(try await store.suggestions("", limit: 0).isEmpty)
        #expect(try await store.visits(search: "cafe").count == 1)
        try await store.close()
    }

    @Test("Deleting visits updates aggregates, metadata and search through restart")
    func deletion() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        let store = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        let old = visit("repeat", title: "Old title", at: 100, typed: 1)
        let new = visit("repeat", title: "New title", at: 200, typed: 2)
        _ = try await store.importDocument(BrowserHistoryDocument(profileID: id, visits: [old, new, visit("keep", at: 300)]))
        #expect(try await store.suggestions("repeat").first?.visitCount == 2)
        #expect(try await store.visits(search: "Old title").map(\.id) == [old.id])
        try await store.updateMetadata(visitID: old.id, title: "Late old title")
        #expect(try await store.suggestions("repeat").first?.title == "New title")
        #expect(try await store.delete(.visit(new.id)) == 1)
        let suggestion = try await store.suggestions("repeat").first
        #expect(suggestion?.typedCount == 1)
        #expect(suggestion?.visitCount == 1)
        #expect(suggestion?.title == "Late old title")
        #expect(try await store.suggestions("New title").isEmpty)
        #expect(try await store.delete(.interval(DateInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 300)))) == 1)
        #expect(try await store.visits().count == 1)
        #expect(try await store.delete(.all) == 1)
        try await store.close()
        let reopened = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        #expect(try await reopened.visits().isEmpty)
        #expect(try await reopened.suggestions("").isEmpty)
        try await reopened.close()
    }

    @Test("Deletion windows and exact host scope preserve other sites, subdomains and profiles")
    func deletionScopes() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        let store = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        let now = Date(timeIntervalSince1970: 200000)
        let records = [visit("hour", at: 199000), visit("day", at: 180000), visit("old", at: 100000),
                       BrowserHistoryVisit(url: URL(string: "https://sub.example.test/keep")!, visitedAt: Date(timeIntervalSince1970: 100000))]
        _ = try await store.importDocument(BrowserHistoryDocument(profileID: id, visits: records))
        #expect(try await store.delete(.lastHour(now: now)) == 1)
        #expect(try await store.delete(.lastDay(now: now)) == 1)
        #expect(try await store.delete(.site("EXAMPLE.TEST")) == 1)
        #expect(try await store.visits().first?.url.host == "sub.example.test")
        try await store.close()
    }

    @Test("Library groups by caller calendar and offers stable date-filtered pagination")
    func dayGroups() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        let store = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        _ = try await store.importDocument(BrowserHistoryDocument(profileID: id, visits: [visit("a", at: 1), visit("b", at: 2), visit("c", at: 90000)]))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = try await store.days(calendar: calendar)
        #expect(days.count == 2)
        #expect(days.last?.visits.count == 2)
        #expect(try await store.visits(limit: 1, offset: 1).first?.url.path == "/b")
        #expect(try await store.visits(interval: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86400)).count == 2)
        try await store.close()
    }

    @Test("A copied database cannot be silently opened as another profile")
    func identityCheck() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let a = ProfileID(), b = ProfileID()
        let store = try BrowserHistoryStore(profileID: a, policy: .persistent, directory: root)
        try await store.close()
        try FileManager.default.copyItem(at: root.appendingPathComponent(a.rawValue.uuidString), to: root.appendingPathComponent(b.rawValue.uuidString))
        #expect(throws: BrowserHistoryError.profileMismatch) {
            try BrowserHistoryStore(profileID: b, policy: .persistent, directory: root)
        }
    }

    @Test("Legacy version zero and one migrate atomically with stable page identities", arguments: [0, 1])
    func legacyMigration(version: Int) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        let store = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        let record = visit("migration", title: "Migration synthetic title", typed: 2)
        _ = try await store.record(record)
        try await store.close()
        let url = root.appendingPathComponent(id.rawValue.uuidString).appendingPathComponent("history.sqlite")
        let raw = try HistoryTestSQL(url)
        try raw.makeLegacy(version: version)
        try raw.close()
        let migrated = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        #expect(try await migrated.visits() == [record])
        #expect(try await migrated.suggestions("migration").first?.typedCount == 2)
        try await migrated.close()
        let inspect = try HistoryTestSQL(url)
        #expect(try inspect.integer("PRAGMA user_version") == HistoryDatabase.currentVersion)
        #expect(try inspect.integer("SELECT version FROM identity") == HistoryDatabase.currentVersion)
        #expect(try inspect.integer("SELECT COUNT(*) FROM pragma_table_info('pages') WHERE name='id' AND type='INTEGER' AND pk=1") == 1)
        let pageID = try inspect.integer("SELECT id FROM pages")
        try inspect.execute("VACUUM; INSERT INTO search(search,rank) VALUES('integrity-check',1)")
        #expect(try inspect.integer("SELECT id FROM pages") == pageID)
        try inspect.close()
        let reopened = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        #expect(try await reopened.suggestions("migration").first?.url == record.url)
        try await reopened.close()
    }

    @Test("Up-to-date opens perform no schema or FTS mutations and keep temporary URL tables in memory")
    func connectionSettingsAndReadOnlyReopen() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.sqlite")
        let id = ProfileID()
        let first = try HistoryDatabase(url: url, profileID: id)
        #expect(try first.scalarInt("PRAGMA temp_store") == 2)
        #expect(try first.scalarInt("SELECT v FROM search_config WHERE k='secure-delete'") == 1)
        try first.close()
        let bytes = try Data(contentsOf: url)
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let reopened = try HistoryDatabase(url: url, profileID: id)
        #expect(try reopened.scalarInt("SELECT total_changes()") == 0)
        #expect(try reopened.scalarInt("PRAGMA temp_store") == 2)
        try reopened.close()
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == modified)
    }

    @Test("Unsupported future versions are refused and failed migrations roll back the complete schema")
    func migrationFailureSafety() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        let store = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        _ = try await store.record(visit("rollback-migration"))
        try await store.close()
        let url = root.appendingPathComponent(id.rawValue.uuidString).appendingPathComponent("history.sqlite")
        let raw = try HistoryTestSQL(url)
        try raw.execute("PRAGMA user_version=999")
        try raw.close()
        let bytes = try Data(contentsOf: url)
        #expect(throws: BrowserHistoryError.unsupportedVersion) {
            try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        }
        #expect(try Data(contentsOf: url) == bytes)
        let legacy = try HistoryTestSQL(url)
        try legacy.makeLegacy(version: 0)
        try legacy.execute("ALTER TABLE pages DROP COLUMN searchTitle")
        try legacy.close()
        #expect(throws: (any Error).self) {
            try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        }
        let inspect = try HistoryTestSQL(url)
        #expect(try inspect.integer("PRAGMA user_version") == 0)
        #expect(try inspect.integer("SELECT version FROM identity") == 1)
        #expect(try inspect.integer("SELECT COUNT(*) FROM pragma_table_info('pages') WHERE name='id'") == 0)
        #expect(try inspect.integer("SELECT COUNT(*) FROM sqlite_master WHERE name='search'") == 1)
        #expect(try inspect.integer("SELECT COUNT(*) FROM visits") == 1)
        try inspect.close()
    }

    @Test("A reader blocking WAL cleanup cannot turn a committed deletion into a failure")
    func checkpointAfterCommittedDelete() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        let store = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        _ = try await store.record(visit("checkpoint"))
        let url = root.appendingPathComponent(id.rawValue.uuidString).appendingPathComponent("history.sqlite")
        let reader = try HistoryTestSQL(url)
        try reader.execute("BEGIN; SELECT COUNT(*) FROM visits")
        #expect(try await store.delete(.all) == 1)
        #expect(try await store.visits().isEmpty)
        #expect(await store.maintenanceStatus == .checkpointDeferred(SQLITE_BUSY))
        try reader.execute("ROLLBACK")
        try reader.close()
        #expect(try await store.delete(.all) == 0)
        #expect(await store.maintenanceStatus == .complete)
        try await store.close()
    }

    @Test("Recent deletion includes future clock skew and profile cleanup removes only its own document")
    func skewAndProfileCleanup() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let a = ProfileID(), b = ProfileID()
        let store = try BrowserHistoryStore(profileID: a, policy: .persistent, directory: root)
        let other = try BrowserHistoryStore(profileID: b, policy: .persistent, directory: root)
        let now = Date(timeIntervalSince1970: 200000)
        _ = try await store.record(visit("future-hour", at: 200060))
        #expect(try await store.delete(.lastHour(now: now)) == 1)
        _ = try await store.record(visit("future-day", at: 200060))
        #expect(try await store.delete(.lastDay(now: now)) == 1)
        _ = try await store.record(visit("cleanup"))
        _ = try await other.record(visit("other-profile"))
        try await store.removeProfileHistory()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(a.rawValue.uuidString).path))
        #expect(try await other.visits().count == 1)
        await #expect(throws: BrowserHistoryError.closed) { try await store.record(visit("stale")) }
        try await store.removeProfileHistory()
        try await other.close()
    }

    @Test("Synthetic 100k history benchmark measures startup, transactional import, inserts and palette latency")
    func benchmark() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        let store = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        let records = (0..<100000).map { index in
            BrowserHistoryVisit(url: URL(string: "https://site\(index % 1000).test/article/\(index)")!,
                                title: "Synthetic article \(index)", visitedAt: Date(timeIntervalSince1970: Double(100000 + index)),
                                transition: .imported, typedCount: index % 4)
        }
        let clock = ContinuousClock()
        var start = clock.now
        #expect(try await store.importDocument(BrowserHistoryDocument(profileID: id, visits: records)) == 100000)
        let importMS = milliseconds(start.duration(to: clock.now))
        try await store.close()
        let sizes = try compactedBenchmarkSizes(root: root, profileID: id)
        start = clock.now
        let reopened = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        let startupMS = milliseconds(start.duration(to: clock.now))
        var queries: [Double] = []
        for index in 0..<50 {
            start = clock.now
            let results = try await reopened.suggestions("article/\(90100 + index)")
            queries.append(milliseconds(start.duration(to: clock.now)))
            #expect(results.count == 1)
        }
        var prefixes: [Double] = []
        for index in 0..<50 {
            start = clock.now
            let results = try await reopened.suggestions("site\(index).test/art", mode: .prefix)
            prefixes.append(milliseconds(start.duration(to: clock.now)))
            #expect(results.count == 12)
        }
        start = clock.now
        _ = try await reopened.suggestions("ar")
        let shortMS = milliseconds(start.duration(to: clock.now))
        var inserts: [Double] = []
        for index in 0..<25 {
            start = clock.now
            _ = try await reopened.record(visit("single-\(index)"))
            inserts.append(milliseconds(start.duration(to: clock.now)))
        }
        queries.sort(); prefixes.sort(); inserts.sort()
        print("HISTORY_BENCH synthetic=100000 import_ms=\(importMS) startup_ms=\(startupMS) substring_p50_ms=\(queries[25]) substring_p95_ms=\(queries[47]) prefix_p50_ms=\(prefixes[25]) prefix_p95_ms=\(prefixes[47]) short_broad_ms=\(shortMS) insert_p50_ms=\(inserts[12]) insert_p95_ms=\(inserts[23]) insert_mean_ms=\(inserts.reduce(0,+)/Double(inserts.count)) database_bytes=\(sizes.full) pages_only_bytes=\(sizes.pages) weight_index_bytes=\(sizes.weight)")
        #expect(queries[47] < 5)
        #expect(prefixes[47] < 5)
        try await reopened.close()
    }

    /// Compare complete history and pages plus their indexes on exactly 100k pages, with
    /// compaction identical in each implementation. Both files are private synthetic fixtures.
    private func compactedBenchmarkSizes(root: URL, profileID: ProfileID) throws -> (full: Int, pages: Int, weight: Int) {
        let file = root.appendingPathComponent(profileID.rawValue.uuidString).appendingPathComponent("history.sqlite")
        let full = try HistoryDatabase(openingURL: file, flags: SQLITE_OPEN_READWRITE)
        try full.execute("VACUUM")
        try full.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let fullBytes = try full.scalarInt("PRAGMA page_count") * full.scalarInt("PRAGMA page_size")
        try full.close()
        let pages = try HistoryDatabase(url: root.appendingPathComponent("pages-only.sqlite"), profileID: profileID)
        try pages.execute("ATTACH DATABASE ? AS corpus", [.text(file.path)])
        try pages.execute("INSERT INTO pages(id,url,title,favicon,last,visits,typed,searchURL,searchTitle) SELECT id,url,title,favicon,last,visits,typed,searchURL,searchTitle FROM corpus.pages")
        try pages.execute("DETACH DATABASE corpus")
        try pages.execute("VACUUM")
        try pages.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let pageSize = try pages.scalarInt("PRAGMA page_size")
        let pageBytes = try pages.scalarInt("PRAGMA page_count") * pageSize
        // The difference after removing only this index measures its compacted storage cost.
        if try pages.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name='pages_weight_last'") > 0 {
            try pages.execute("DROP INDEX pages_weight_last")
            try pages.execute("VACUUM")
        }
        let withoutWeight = try pages.scalarInt("PRAGMA page_count") * pageSize
        try pages.close()
        return (fullBytes, pageBytes, pageBytes - withoutWeight)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

/// Only synthetic test databases are accepted by callers. Never prints SQL or SQLite messages.
private final class HistoryTestSQL {
    private var handle: OpaquePointer?
    init(_ url: URL) throws {
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard result == SQLITE_OK else { sqlite3_close(handle); handle = nil; throw BrowserHistoryError.storageFailure(result) }
    }
    deinit { sqlite3_close(handle) }
    func close() throws {
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else { throw BrowserHistoryError.storageFailure(result) }
        handle = nil
    }
    func execute(_ sql: String) throws {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw BrowserHistoryError.storageFailure(result) }
    }
    func integer(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK else { throw BrowserHistoryError.storageFailure(result) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw BrowserHistoryError.storageFailure(SQLITE_ERROR) }
        return Int(sqlite3_column_int64(statement, 0))
    }
    func makeLegacy(version: Int) throws {
        try execute("""
            DROP INDEX IF EXISTS pages_weight_last;
            DROP TABLE historySyncEvents; DROP TABLE historySyncBatches;
            DROP TABLE historySyncState; DROP TABLE historySyncVersions;
            DROP TRIGGER pages_insert; DROP TRIGGER pages_delete; DROP TRIGGER pages_update;
            DROP TRIGGER titleWords_insert; DROP TRIGGER titleWords_delete; DROP TRIGGER titleWords_update;
            DROP TABLE titleWords;
            DROP TABLE search;
            ALTER TABLE pages RENAME TO latest_pages;
            CREATE TABLE pages(url TEXT UNIQUE,title TEXT,favicon TEXT,last REAL,visits INTEGER,typed INTEGER,
                               searchURL TEXT COLLATE NOCASE,searchTitle TEXT COLLATE NOCASE);
            INSERT INTO pages(rowid,url,title,favicon,last,visits,typed,searchURL,searchTitle)
                SELECT id,url,title,favicon,last,visits,typed,searchURL,searchTitle FROM latest_pages;
            DROP TABLE latest_pages;
            CREATE VIRTUAL TABLE search USING fts5(searchURL,searchTitle,content='pages',content_rowid='rowid',tokenize='trigram');
            INSERT INTO search(search) VALUES('rebuild');
            UPDATE identity SET version=1;
            PRAGMA user_version=\(version);
            """)
    }
}
