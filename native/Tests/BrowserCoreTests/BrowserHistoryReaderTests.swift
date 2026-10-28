@testable import BrowserCore
import Foundation
import SQLite3
import Testing

/// Synthetic data only. Never prints titles, URLs, SQL or SQLite messages.
@Suite("History reader, memory index and migration", .serialized)
struct BrowserHistoryReaderTests {
    private static let slowSQL = """
        WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<2000000000)
        SELECT (SELECT COUNT(*) FROM pages)+COUNT(*) FROM c
        """

    @Test("Cancelling a running read interrupts only that request; queued siblings still run")
    func interruptRunningRequest() async throws {
        let (root, file, _) = try await Self.emptyStore(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = try HistoryReadConnection(url: file)
        let started = SyntheticFlag(), skippedRan = SyntheticFlag()
        let slow = Task { try await reader.perform { db in started.set(); return try db.scalarInt(Self.slowSQL) } }
        let sibling = Task { try await reader.perform { db in try db.scalarInt("SELECT 7") } }
        let superseded = Task { try await reader.perform { db in skippedRan.set(); return try db.scalarInt("SELECT 1") } }
        superseded.cancel()
        while !started.value { try await Task.sleep(for: .milliseconds(5)) }
        let clock = ContinuousClock(), start = clock.now
        slow.cancel()
        await #expect(throws: CancellationError.self) { try await slow.value }
        #expect(start.duration(to: clock.now) < .seconds(2))
        #expect(try await sibling.value == 7)
        await #expect(throws: CancellationError.self) { try await superseded.value }
        #expect(!skippedRan.value)
        // The interrupt does not leak into the next statement on the same connection.
        #expect(try await reader.perform { db in try db.scalarInt("SELECT COUNT(*) FROM pages") } == 0)
        try reader.close()
        await #expect(throws: BrowserHistoryError.closed) { try await reader.perform { db in try db.scalarInt("SELECT 1") } }
    }

    @Test("Cancellation before the first SQLite statement is retained by the request progress handler")
    func cancellationBeforeFirstStatement() async throws {
        let (root, file, _) = try await Self.emptyStore(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = try HistoryReadConnection(url: file)
        let entered = SyntheticFlag()
        let slow = Task {
            try await reader.perform { db in
                entered.set()
                Thread.sleep(forTimeInterval: 0.1)
                return try db.scalarInt(Self.slowSQL)
            }
        }
        while !entered.value { try await Task.sleep(for: .milliseconds(1)) }
        slow.cancel()
        let clock = ContinuousClock(), start = clock.now
        await #expect(throws: CancellationError.self) { try await slow.value }
        #expect(start.duration(to: clock.now) < .seconds(2))
        #expect(try await reader.perform { db in try db.scalarInt("SELECT 9") } == 9)
        try reader.close()
    }

    @Test("Closing interrupts a running read safely, and writes never wait for reads")
    func closeAndWriterIndependence() async throws {
        let (root, file, id) = try await Self.emptyStore(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        let reader = try HistoryReadConnection(url: file)
        let started = SyntheticFlag()
        let slow = Task { try await reader.perform { db in started.set(); return try db.scalarInt(Self.slowSQL) } }
        while !started.value { try await Task.sleep(for: .milliseconds(5)) }
        // The read transaction is open on another connection; WAL lets the writer commit.
        let clock = ContinuousClock(), start = clock.now
        #expect(try await store.record(BrowserHistoryVisit(url: URL(string: "https://writer.test/synthetic")!)))
        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(try await store.suggestions("writer").count == 1)
        try reader.close()
        await #expect(throws: BrowserHistoryError.closed) { try await slow.value }
        try await store.close()
        await #expect(throws: BrowserHistoryError.closed) { try await store.suggestions("writer") }
    }

    @Test("Host bonus requires a host prefix or host word start, never an arbitrary infix")
    func hostBonusIsPrefixOrWordStart() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BrowserHistoryStore(profileID: ProfileID(), policy: .persistent, directory: root)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let pages = [("https://example.test/", 9), ("https://ample.test/", 0), ("https://docs.ample.test/", 0), ("https://sub-ample.test/", 0)]
        _ = try await store.importDocument(BrowserHistoryDocument(profileID: store.profileID, visits: pages.map {
            BrowserHistoryVisit(url: URL(string: $0.0)!, title: "Synthetic", visitedAt: now, typedCount: $0.1)
        }))
        let ranked = try await store.suggestions("ample", now: now).map(\.url.absoluteString)
        #expect(ranked.last == "https://example.test/")
        #expect(Set(ranked.prefix(3)) == ["https://ample.test/", "https://docs.ample.test/", "https://sub-ample.test/"])
        let index = try await store.memoryIndex(now: now)
        #expect(index.suggestions("ample", now: now).map(\.url.absoluteString) == ranked)
        try await store.close()
    }

    @Test("Memory index membership, bonus and order agree with SQL across query shapes")
    func memoryIndexParity() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BrowserHistoryStore(profileID: ProfileID(), policy: .persistent, directory: root)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let hosts = ["cat.test", "www.animal.test", "docs.cathedral.test", "xn--bcher-kva.test", "sub-net.test", "other.test"]
        let titles = ["A-cat handbook", "Concatenate letters", "Café résumé", "100%_literal", "Reference (draft)", "", "Über Bücher"]
        var visits: [BrowserHistoryVisit] = []
        for index in 0..<240 {
            let url = URL(string: "https://\(hosts[index % hosts.count])/p\(index)/caf%C3%A9-\(index % 7)?q=\(index % 5)")!
            visits.append(BrowserHistoryVisit(url: url, title: titles[index % titles.count] + " \(index % 11)",
                visitedAt: now.addingTimeInterval(-Double(index * 3600)), typedCount: index % 3))
        }
        _ = try await store.importDocument(BrowserHistoryDocument(profileID: store.profileID, visits: visits))
        let index = try await store.memoryIndex(capacity: 10_000, now: now)
        #expect(index.count == 240)
        let queries = ["", "c", "ca", "cat", "a c", "a-c", "www.", "www.ani", "https://cat", "bü", "bücher", "café ré",
                       "%_", "%", "(", "p1", "p12 cat", "1", "re dr", "über", "net", "-net", "sub", "q=3", "\" OR *", "zz"]
        for query in queries {
            let sql = try await store.suggestions(query, limit: 50, now: now).map(\.url)
            let memory = index.suggestions(query, limit: 50, now: now).map(\.url)
            #expect(sql == memory, "query #\(queries.firstIndex(of: query)!)")
        }
        try await store.close()
    }

    @Test("Short queries use indexed, capped candidate paths and never scan every page")
    func shortQueriesAvoidFullScans() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        let store = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        try await store.close()
        let file = root.appendingPathComponent(id.rawValue.uuidString).appendingPathComponent("history.sqlite")
        let raw = try HistoryDatabase(url: file, profileID: id)
        try Self.populate(raw, pages: 100_000, legacyEvery: 0)
        try raw.close()
        let reopened = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        let reader = try HistoryReadConnection(url: file)
        for query in ["s", "ar", "sy", "a s"] {
            let (sql, values) = BrowserHistoryStore.suggestionStatement(query, mode: .substring, limit: 12, now: Date())
            let plan = try await reader.perform { db in try Self.plan(db, sql, values) }
            #expect(!plan.contains { $0.hasPrefix("SCAN pages") }, "query length \(query.count)")
        }
        try reader.close()
        let clock = ContinuousClock()
        var timings: [String] = []
        for query in ["s", "ar", "sy", "a s", "%"] {
            let start = clock.now
            let results = try await reopened.suggestions(query)
            timings.append("len\(query.count)=\(Self.milliseconds(start.duration(to: clock.now)))")
            #expect(results.count <= 12)
        }
        #expect(try await reopened.suggestions("sy").count == 12)
        print("HISTORY_SHORT_BENCH pages=100000 " + timings.joined(separator: " "))
        try await reopened.close()
    }

    @Test("Version three migration of 100k pages normalizes once, skips unchanged rows and keeps indexes consistent")
    func migrationBenchmark100k() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        var report: [String] = []
        for (label, legacyEvery) in [("all_changed", 1), ("tenth_changed", 10), ("unchanged", 0)] {
            let id = ProfileID()
            let store = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
            try await store.close()
            let folder = root.appendingPathComponent(id.rawValue.uuidString)
            let file = folder.appendingPathComponent("history.sqlite")
            let raw = try HistoryDatabase(url: file, profileID: id)
            for statement in ["DROP TRIGGER titleWords_insert", "DROP TRIGGER titleWords_delete", "DROP TRIGGER titleWords_update",
                              "DROP TABLE titleWords"] { try raw.execute(statement) }
            try Self.populate(raw, pages: 100_000, legacyEvery: legacyEvery)
            try raw.execute("UPDATE identity SET version=2")
            try raw.execute("PRAGMA user_version=2")
            try raw.close()
            // Baseline: the previous migration strategy on an identical copy.
            let copy = root.appendingPathComponent("baseline-\(label).sqlite")
            try FileManager.default.copyItem(at: file, to: copy)
            let clock = ContinuousClock()
            var start = clock.now
            let migrated = try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
            let migrationMS = Self.milliseconds(start.duration(to: clock.now))
            #expect(try await migrated.suggestions("site7.test/article/7", mode: .prefix).count >= 1)
            #expect(try await migrated.suggestions("synthetic", limit: 1).count == 1)
            try await migrated.close()
            let inspect = try HistoryDatabase(url: file, profileID: id)
            #expect(try inspect.scalarInt("PRAGMA user_version") == 5)
            #expect(try inspect.scalarInt("SELECT COUNT(*) FROM pages WHERE searchURL LIKE 'www.%'") == 0)
            #expect(try inspect.scalarInt("SELECT COUNT(*) FROM search WHERE search MATCH '\"www.site\"'") == 0)
            #expect(try inspect.scalarInt("SELECT COUNT(*) FROM titleWords WHERE titleWords MATCH 'article*'") == 100_000)
            try inspect.execute("INSERT INTO search(search,rank) VALUES('integrity-check',1)")
            try inspect.execute("INSERT INTO titleWords(titleWords,rank) VALUES('integrity-check',1)")
            try inspect.close()
            report.append("\(label)_ms=\(migrationMS)")
            // The previous per-row strategy takes minutes at this size; measured on demand only.
            if ProcessInfo.processInfo.environment["ORBIT_HISTORY_MIGRATION_BASELINE"] == "1" {
                start = clock.now
                try Self.previousMigration(copy, profileID: id)
                report.append("\(label)_previous_ms=\(Self.milliseconds(start.duration(to: clock.now)))")
            }
        }
        print("HISTORY_MIGRATION_BENCH pages=100000 " + report.joined(separator: " "))
    }

    // MARK: - Synthetic fixtures

    private static func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-history-reader-synthetic-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func emptyStore() async throws -> (root: URL, file: URL, id: ProfileID) {
        let root = try root()
        let id = ProfileID()
        try await BrowserHistoryStore(profileID: id, policy: .persistent, directory: root).close()
        return (root, root.appendingPathComponent(id.rawValue.uuidString).appendingPathComponent("history.sqlite"), id)
    }

    /// Pages only (the v3 migration never reads visits). `legacyEvery` > 0 stores the old,
    /// non-normalized `www.` form on every n-th row so that the migration must rewrite it.
    private static func populate(_ db: HistoryDatabase, pages: Int, legacyEvery: Int) throws {
        try db.execute("BEGIN IMMEDIATE")
        try db.execute("""
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<\(pages))
            INSERT INTO pages(url,title,favicon,last,visits,typed,searchURL,searchTitle)
            SELECT 'https://www.site'||(x%1000)||'.test/article/'||x, 'Synthetic article '||x, '', 100000+x, 1+(x%3), x%4,
                   CASE WHEN \(legacyEvery)>0 AND x%\(max(1, legacyEvery))=0 THEN 'www.' ELSE '' END||'site'||(x%1000)||'.test/article/'||x,
                   'synthetic article '||x FROM c
            """)
        try db.execute("COMMIT")
    }

    /// The strategy replaced by this lot, kept verbatim for a like-for-like timing baseline.
    private static func previousMigration(_ file: URL, profileID: ProfileID) throws {
        let db = try HistoryDatabase(openingURL: file, flags: SQLITE_OPEN_READWRITE)
        defer { try? db.close() }
        try db.execute("PRAGMA synchronous=FULL")
        try db.execute("PRAGMA secure_delete=ON")
        try db.execute("PRAGMA temp_store=MEMORY")
        try db.transaction {
            try db.execute("CREATE VIRTUAL TABLE titleWords USING fts5(searchTitle,content='pages',content_rowid='id',tokenize='unicode61',prefix='1 2 3')")
            try db.execute("INSERT INTO titleWords(titleWords) VALUES('rebuild')")
            try db.execute("INSERT INTO titleWords(titleWords,rank) VALUES('secure-delete',1)")
            try db.execute("CREATE TRIGGER titleWords_insert AFTER INSERT ON pages BEGIN INSERT INTO titleWords(rowid,searchTitle) VALUES(new.id,new.searchTitle); END")
            try db.execute("CREATE TRIGGER titleWords_delete AFTER DELETE ON pages BEGIN INSERT INTO titleWords(titleWords,rowid,searchTitle) VALUES('delete',old.id,old.searchTitle); END")
            try db.execute("CREATE TRIGGER titleWords_update AFTER UPDATE ON pages BEGIN INSERT INTO titleWords(titleWords,rowid,searchTitle) VALUES('delete',old.id,old.searchTitle); INSERT INTO titleWords(rowid,searchTitle) VALUES(new.id,new.searchTitle); END")
            let rows = try db.prepare("SELECT id,url FROM pages")
            var updates: [(Int, String)] = []
            while try db.next(rows) {
                if let url = URL(string: db.text(rows, 1)) {
                    updates.append((Int(sqlite3_column_int64(rows, 0)), BrowserSuggestionText.searchableURL(url)))
                }
            }
            sqlite3_finalize(rows)
            for (id, normalized) in updates {
                try db.execute("UPDATE pages SET searchURL=? WHERE id=?", [.text(normalized), .number(Double(id))])
            }
        }
    }

    private static func plan(_ db: HistoryDatabase, _ sql: String, _ values: [HistoryValue]) throws -> [String] {
        let statement = try db.prepare("EXPLAIN QUERY PLAN " + sql)
        defer { sqlite3_finalize(statement) }
        try db.bind(statement, values)
        var details: [String] = []
        while try db.next(statement) { details.append(db.text(statement, 3)) }
        return details
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

private final class SyntheticFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
