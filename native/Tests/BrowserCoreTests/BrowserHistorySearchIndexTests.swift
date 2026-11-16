@testable import BrowserCore
import Foundation
import SQLite3
import Testing

extension BrowserHistoryStore {
    /// The Library query of version nine, verbatim, on the writer connection.
    func legacyLibraryVisits(search: String, interval: DateInterval? = nil, limit: Int = 100, offset: Int = 0) throws -> [BrowserHistoryVisit] {
        guard let database else { return [] }
        var clauses = ["1"]
        var values: [HistoryValue] = []
        if let interval { clauses += ["time>=? AND time<?"]; values += [.number(interval.start.timeIntervalSince1970), .number(interval.end.timeIntervalSince1970)] }
        if !search.isEmpty {
            clauses += [Self.literalLibraryFilter]
            values += [.text(Self.fold(search)), .text(Self.fold(search))]
        }
        return try Self.readVisits(database, whereSQL: clauses.joined(separator: " AND "), values: values, limit: min(max(0, limit), 10000), offset: max(0, offset))
    }

    /// One forced strategy on the writer connection, so each strategy can be compared.
    func libraryVisits(search: String, plan: LibrarySearchPlan, interval: DateInterval? = nil,
                       limit: Int = 100, offset: Int = 0) throws -> [BrowserHistoryVisit] {
        guard let database else { return [] }
        var clauses = ["1"]
        var values: [HistoryValue] = []
        if let interval { clauses += ["time>=? AND time<?"]; values += [.number(interval.start.timeIntervalSince1970), .number(interval.end.timeIntervalSince1970)] }
        let filter = try Self.librarySearchFilter(database, term: Self.fold(search), window: limit + offset, plan: plan)
        return try Self.readVisits(database, whereSQL: (clauses + [filter.sql]).joined(separator: " AND "), values: values + filter.values, limit: limit, offset: offset)
    }

    func librarySearchPlan(_ search: String, window: Int = 100) throws -> LibrarySearchPlan {
        try Self.librarySearchFilter(database!, term: Self.fold(search), window: window).plan
    }

    func searchBackfillStep(batch: Int) throws -> Bool { try database!.backfillVisitSearchIndex(batch: batch) }
    var searchBackfillPending: Bool { (try? database?.visitSearchBackfillPending()) ?? false }

    /// Index-only rowids for a trigram phrase; stale entries would survive a content deletion.
    func indexedTitleRowids(_ phrase: String) throws -> Int {
        try database!.scalarInt("SELECT COUNT(*) FROM visitTitles WHERE visitTitles MATCH ?", [.text("\"\(phrase)\"")])
    }

    /// FTS5 compares an external-content index with its content table row by row.
    func checkVisitTitlesIntegrity() throws {
        try database!.execute("INSERT INTO visitTitles(visitTitles,rank) VALUES('integrity-check',1)")
    }

    func scalar(_ sql: String) throws -> Int { try database!.scalarInt(sql) }
    var readerForTesting: HistoryReadConnection? { reader }
}

/// Synthetic data only. Never prints titles, URLs or SQL.
@Suite("History search index", .serialized)
struct BrowserHistorySearchIndexTests {
    private let now = Date()

    private static func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-history-search-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ root: URL, _ profile: ProfileID) -> URL {
        root.appendingPathComponent(profile.rawValue.uuidString).appendingPathComponent("history.sqlite")
    }

    /// SplitMix64: a deterministic fixture for every run.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let words = ["Café", "naïve", "Straße", "Ünïcode", "guide", "synthetic", "Report", "日本語", "emoji😀",
                                "quote\"d", "50%", "snake_case", "back\\slash", "spaced out", "Kestrel", "ALPHA", "zebra"]
    private static let hosts = ["alpha.test", "beta.test", "xn--bcher-kva.test", "www.gamma.test", "Sub.Delta.test", "xn--ggle-5qaa.test"]

    /// URLs revisited with changing titles, so per-visit titles differ from their page title.
    private func randomVisits(_ count: Int, seed: UInt64) -> [BrowserHistoryVisit] {
        var random = Seeded(state: seed)
        let urls: [URL] = (0..<max(1, count / 4)).map { index in
            let host = Self.hosts.randomElement(using: &random)!
            let word = Self.words.randomElement(using: &random)!.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            return URL(string: "https://\(host)/\(word)/\(index)?q=\(Int.random(in: 0..<50, using: &random))")!
        }
        return (0..<count).map { index in
            let title = (0..<Int.random(in: 0...3, using: &random)).map { _ in Self.words.randomElement(using: &random)! }.joined(separator: " ")
                + (index % 3 == 0 ? " \(index % 41)" : "")
            return BrowserHistoryVisit(url: urls.randomElement(using: &random)!, title: title,
                                       visitedAt: now.addingTimeInterval(-Double(Int.random(in: 0..<2_000_000, using: &random))),
                                       transition: .link, typedCount: Int.random(in: 0...1, using: &random))
        }
    }

    private func randomTerms(_ visits: [BrowserHistoryVisit], seed: UInt64, count: Int) -> [String] {
        var random = Seeded(state: seed)
        var terms = ["\"", "%", "_", "\\", "a", "ca", "café", "CAFÉ", "CAFE", "strasse", "straße", "bücher", "xn--bcher", "ggle", "日本", "日本語",
                     "😀", "spaced out", "  ", "zzzzqq", "https://", "www.", "gamma.test/", "quote\"d", "50%", "snake_case", "back\\slash",
                     "q=1", "/1", "e\u{301}", "naïve 1", "ünï"]
        for _ in 0..<count {
            let visit = visits.randomElement(using: &random)!
            let source = Array(Bool.random(using: &random) ? visit.title : BrowserSuggestionText.searchableURL(visit.url))
            guard !source.isEmpty else { continue }
            let start = Int.random(in: 0..<source.count, using: &random)
            let length = Int.random(in: 1...min(8, source.count - start), using: &random)
            let term = String(source[start..<start + length])
            terms.append(Bool.random(using: &random) ? term.uppercased() : term)
        }
        return terms
    }

    /// Every strategy returns exactly the version-nine rows, order and pages included.
    /// `forcePlans: false` while the backfill is pending: only the served (literal) path is valid.
    private func expectParity(_ store: BrowserHistoryStore, _ terms: [String], _ label: String, forcePlans: Bool = true) async throws {
        let windows: [(DateInterval?, Int, Int)] = [(nil, 100, 0), (nil, 7, 5),
            (DateInterval(start: now.addingTimeInterval(-1_000_000), end: now.addingTimeInterval(-200_000)), 50, 0)]
        for term in terms {
            for (interval, limit, offset) in windows {
                let legacy = try await store.legacyLibraryVisits(search: term, interval: interval, limit: limit, offset: offset).map(\.id)
                let served = try await store.visits(search: term, interval: interval, limit: limit, offset: offset).map(\.id)
                #expect(served == legacy, "\(label) served term #\(terms.firstIndex(of: term)!)")
                guard forcePlans, BrowserHistoryStore.fold(term).unicodeScalars.count >= 3 else { continue }
                for plan in [BrowserHistoryStore.LibrarySearchPlan.candidates, .literal] {
                    let forced = try await store.libraryVisits(search: term, plan: plan, interval: interval, limit: limit, offset: offset).map(\.id)
                    #expect(forced == legacy, "\(label) \(plan) term #\(terms.firstIndex(of: term)!)")
                }
            }
        }
    }

    @Test("Indexed Library search returns the version-nine rows for randomized terms, before and after deletions")
    func randomizedParity() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let visits = randomVisits(3000, seed: 0x5EED)
        #expect(try await store.importDocument(BrowserHistoryDocument(profileID: profile, visits: visits)) == visits.count)
        #expect(await !store.searchBackfillPending)
        #expect(try await store.librarySearchPlan("kestrel") == .candidates)
        let terms = randomTerms(visits, seed: 0xBEEF, count: 120)
        // Matches exist for most terms; an equivalence test over empty results would prove nothing.
        var matched = 0
        for term in terms where try await !store.legacyLibraryVisits(search: term).isEmpty { matched += 1 }
        #expect(matched > terms.count * 3 / 4)
        try await expectParity(store, terms, "initial")
        // Title updates, single deletions, a site and a range keep index and content identical.
        for visit in visits.prefix(40) { try await store.updateMetadata(visitID: visit.id, title: visit.title + " Renamed") }
        for visit in visits.dropFirst(40).prefix(60) { try await store.delete(.visit(visit.id), now: now) }
        try await store.delete(.site("beta.test"), now: now)
        try await store.delete(.interval(DateInterval(start: now.addingTimeInterval(-900_000), end: now.addingTimeInterval(-800_000))), now: now)
        try await store.deleteSuggestions(url: visits[200].url, now: now)
        try await store.checkVisitTitlesIntegrity()
        try await expectParity(store, terms + ["renamed"], "after deletions")
        try await store.close()
    }

    @Test("Version nine migrates without indexing at launch; the backfill interleaves with writes and completes")
    func migrationFromNine() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        var store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let visits = randomVisits(1200, seed: 0xA11CE)
        try await store.importDocument(BrowserHistoryDocument(profileID: profile, visits: visits))
        try await store.close()
        let raw = try HistoryDatabase(url: Self.file(root, profile), profileID: profile)
        try raw.discardSearchIndexSchemaForLegacyFixture()
        try raw.execute("UPDATE identity SET version=9")
        try raw.execute("PRAGMA user_version=9")
        try raw.close()

        store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root, backfillsSearchIndex: false)
        #expect(try await store.scalar("PRAGMA user_version") == HistoryDatabase.currentVersion)
        #expect(await store.searchBackfillPending)
        #expect(try await store.scalar("SELECT COUNT(*) FROM visitTitles WHERE visitTitles MATCH '\"synthetic\"'") == 0)
        // Searches stay exact on the literal query while the backfill is pending.
        #expect(try await store.librarySearchPlan("synthetic") == .literal)
        let terms = randomTerms(visits, seed: 0xD00D, count: 40)
        try await expectParity(store, terms, "pending", forcePlans: false)

        // Writes between batches: new visits are indexed at once; deleting or renaming a pending
        // visit must not touch the index (an external-content 'delete' of an absent row corrupts it).
        #expect(try await !store.searchBackfillStep(batch: 100))
        let fresh = BrowserHistoryVisit(url: URL(string: "https://fresh.test/kestrel")!, title: "Fresh kestrel arrival", visitedAt: now)
        try await store.record(fresh)
        try await store.delete(.visit(visits[1100].id), now: now)
        try await store.updateMetadata(visitID: visits[1101].id, title: "Renamed while pending")
        try await store.delete(.site("alpha.test"), now: now)
        #expect(try await !store.searchBackfillStep(batch: 300))
        try await store.completeSearchIndexBackfill()
        #expect(await !store.searchBackfillPending)
        try await store.checkVisitTitlesIntegrity()
        #expect(try await store.librarySearchPlan("synthetic") != .literal)
        try await expectParity(store, terms + ["fresh kestrel", "renamed while"], "backfilled")
        #expect(try await store.visits(search: "Fresh kestrel").map(\.id) == [fresh.id])
        try await store.close()

        // Reopening is a no-op: nothing pending, nothing reindexed.
        store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        #expect(await !store.searchBackfillPending)
        try await store.checkVisitTitlesIntegrity()
        try await store.close()
    }

    @Test("The automatic backfill runs after opening and a newer schema is refused, never rewritten")
    func automaticBackfillAndNewerVersion() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        var store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        try await store.importDocument(BrowserHistoryDocument(profileID: profile, visits: randomVisits(5000, seed: 7)))
        try await store.close()
        let raw = try HistoryDatabase(url: Self.file(root, profile), profileID: profile)
        try raw.discardSearchIndexSchemaForLegacyFixture()
        try raw.execute("UPDATE identity SET version=9")
        try raw.execute("PRAGMA user_version=9")
        try raw.close()
        store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let deadline = ContinuousClock.now + .seconds(20)
        while await store.searchBackfillPending, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await !store.searchBackfillPending)
        try await store.checkVisitTitlesIntegrity()
        try await store.close()
        // A build that only knows version nine applies the same guard to version ten.
        let newer = try HistoryDatabase(url: Self.file(root, profile), profileID: profile)
        try newer.execute("UPDATE identity SET version=\(HistoryDatabase.currentVersion + 1)")
        try newer.execute("PRAGMA user_version=\(HistoryDatabase.currentVersion + 1)")
        try newer.close()
        #expect(throws: BrowserHistoryError.unsupportedVersion) {
            try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        }
    }

    @Test("Deletions, clear-all, cutoff maintenance and sync merges keep the title index in step")
    func deletionsReachIndex() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID(), cloud = BrowserHistorySyncMemoryCloud()
        let a = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("a"))
        let b = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("b"))
        func visit(_ marker: String, host: String = "keep.test", age: TimeInterval = 60) -> BrowserHistoryVisit {
            BrowserHistoryVisit(url: URL(string: "https://\(host)/page")!, title: "Marker \(marker)", visitedAt: now.addingTimeInterval(-age), transition: .link)
        }
        let expired = visit("expiredmark", host: "old.test", age: BrowserHistorySyncSchema.retention + 3 * 86400)
        let site = visit("sitemark", host: "gone.test"), single = visit("singlemark", host: "one.test")
        let range = visit("rangemark", host: "range.test", age: 7200), survivor = visit("survivormark")
        try await a.importDocument(BrowserHistoryDocument(profileID: profile, visits: [expired, site, single, range, survivor]))
        #expect(try await a.indexedTitleRowids("expiredmark") == 1)
        // Cutoff maintenance deletes visits older than the retention window.
        _ = try await a.historySyncBatches(now: now)
        #expect(try await a.indexedTitleRowids("expiredmark") == 0)
        #expect(try await a.visits(search: "expiredmark").isEmpty)
        // Sync merges index visits on the receiving replica.
        let incoming = try await cloud.exchange(try await a.historySyncBatches(now: now), now: now)
        try await b.applyHistorySync(incoming, now: now)
        #expect(try await b.indexedTitleRowids("sitemark") == 1)
        #expect(try await b.visits(search: "sitemark").map(\.id) == [site.id])
        try await a.delete(.site("gone.test"), now: now)
        try await a.delete(.visit(single.id), now: now)
        try await a.delete(.interval(DateInterval(start: now.addingTimeInterval(-8000), end: now.addingTimeInterval(-7000))), now: now)
        for marker in ["sitemark", "singlemark", "rangemark"] {
            #expect(try await a.indexedTitleRowids(marker) == 0, "\(marker)")
            #expect(try await a.visits(search: marker).isEmpty, "\(marker)")
        }
        // A remote deletion removes the merged rows from the other replica's index too.
        let outgoing = try await cloud.exchange(try await a.historySyncBatches(now: now), now: now)
        try await b.applyHistorySync(outgoing, now: now)
        #expect(try await b.indexedTitleRowids("sitemark") == 0)
        #expect(try await b.visits(search: "survivormark").map(\.id) == [survivor.id])
        try await a.delete(.all, now: now)
        #expect(try await a.indexedTitleRowids("survivormark") == 0)
        #expect(try await a.scalar("SELECT COUNT(*) FROM visitTitles") == 0)
        for store in [a, b] { try await store.checkVisitTitlesIntegrity() }
        try await a.close(); try await b.close()
    }

    @Test("Terms shorter than three scalars use the literal query and still match")
    func shortTermFallback() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let visit = BrowserHistoryVisit(url: URL(string: "https://xy.test/q")!, title: "Ça va", visitedAt: now)
        try await store.record(visit)
        for term in ["xy", "ÇA", "a", "é", "ca"] { #expect(try await store.librarySearchPlan(term) == .literal, "term #\(term.count)") }
        #expect(try await store.visits(search: "xy").map(\.id) == [visit.id])
        #expect(try await store.visits(search: "ÇA").map(\.id) == [visit.id])
        #expect(try await store.librarySearchPlan("ça va") == .candidates)
        #expect(try await store.visits(search: "ÇA VA").map(\.id) == [visit.id])
        try await store.close()
    }

    @Test("Superseded searches are dropped or interrupted on the reader and never run behind the latest one")
    func cancellation() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        try await store.importDocument(BrowserHistoryDocument(profileID: profile, visits: randomVisits(400, seed: 11)))
        let reader = try #require(await store.readerForTesting)
        // Occupy the reader so every search below queues, as fast typing would.
        let started = Flag()
        let blocker = Task {
            try await reader.perform { db in
                started.set()
                return try db.scalarInt("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<2000000000) SELECT COUNT(*) FROM c")
            }
        }
        while !started.value { try await Task.sleep(for: .milliseconds(5)) }
        let typed = ["s", "sy", "syn", "synt", "synth", "synthe", "synthet", "syntheti", "synthetic"]
        let searches = typed.map { term in Task { try await store.visits(search: term) } }
        for search in searches.dropLast() { search.cancel() }
        blocker.cancel()
        _ = try? await blocker.value
        for search in searches.dropLast() {
            await #expect(throws: CancellationError.self) { try await search.value }
        }
        let latest = try await searches.last!.value
        #expect(latest.map(\.id) == (try await store.legacyLibraryVisits(search: "synthetic").map(\.id)))
        #expect(!latest.isEmpty)
        try await store.close()
    }

    // MARK: - Benchmark (ORBIT_HISTORY_SEARCH_BENCH=1)

    @Test("Benchmark: Library search and writer blocking on 200k synthetic visits",
          .enabled(if: ProcessInfo.processInfo.environment["ORBIT_HISTORY_SEARCH_BENCH"] == "1"))
    func benchmark200k() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        try await BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root).close()
        let file = Self.file(root, profile)
        let raw = try HistoryDatabase(url: file, profileID: profile)
        try raw.discardSearchIndexSchemaForLegacyFixture()
        try raw.execute("UPDATE identity SET version=9")
        try raw.execute("PRAGMA user_version=9")
        var random = Seeded(state: 42)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let vocabulary = (0..<400).map { _ in String((0..<Int.random(in: 6...9, using: &random)).map { _ in letters.randomElement(using: &random)! }) }
        try raw.execute("CREATE TEMP TABLE words(id INTEGER PRIMARY KEY, w TEXT)")
        for (index, word) in vocabulary.enumerated() { try raw.execute("INSERT INTO words VALUES(?,?)", [.number(Double(index)), .text(word)]) }
        var template = String(decoding: try JSONEncoder().encode(BrowserHistoryVisit(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000000")!, url: URL(string: "https://template.test/")!,
            title: "TEMPLATE_TITLE", visitedAt: Date(timeIntervalSinceReferenceDate: 0), transition: .link)), as: UTF8.self)
        template = template.replacingOccurrences(of: "https:\\/\\/template.test\\/", with: "TEMPLATE_URL")
        let visits = 200_000, pages = 40_000
        let base = now.addingTimeInterval(-Double(visits) * 60).timeIntervalSince1970
        try raw.execute("BEGIN IMMEDIATE")
        try raw.execute("""
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<\(visits)),
            v AS (SELECT x, (x*7919)%\(pages) AS p FROM c),
            d AS (SELECT x, p, 'https://site'||(p%3000)||'.test/'||(SELECT w FROM words WHERE id=p%400)||'/'||p AS url,
                  'Synthetic '||(SELECT w FROM words WHERE id=p%400)||' article '||p||CASE WHEN x%5=0 THEN ' updated' ELSE '' END AS title,
                  upper(printf('%08x-0000-4000-8000-%012x', x, x)) AS id FROM v)
            INSERT INTO visits(id,url,site,time,title,typed,payload,searchTitle)
            SELECT id, url, 'site'||(p%3000)||'.test', \(base)+x*60, title, 0,
                   replace(replace(replace(?, '00000000-0000-4000-8000-000000000000', id), 'TEMPLATE_URL', replace(url,'/','\\/')), 'TEMPLATE_TITLE', title),
                   lower(title) FROM d
            """, [.text(template)])
        try raw.execute("""
            INSERT INTO pages(url,title,favicon,last,visits,typed,searchURL,searchTitle)
            SELECT url, title, '', MAX(time), COUNT(*), 0, substr(url,9), lower(title) FROM visits GROUP BY url
            """)
        try raw.execute("COMMIT")
        try raw.close()

        let clock = ContinuousClock()
        func ms(_ start: ContinuousClock.Instant) -> Double {
            let d = start.duration(to: clock.now); return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        var report: [String] = []
        var start = clock.now
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root, backfillsSearchIndex: false)
        report.append("open_migrate_ms=\(Int(ms(start)))")
        let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0

        let typical = vocabulary[17], rare = "article 12345", dense = "synthetic"
        let terms = [("typical", typical), ("rare", rare), ("host", "site1234.test"), ("mid", "site12"), ("dense", dense),
                     ("dense_url", ".test/"), ("absent", "qqqzzz"), ("short", "ar")]
        // Before the backfill completes, the served path is the literal query on the reader.
        #expect(try await store.librarySearchPlan(typical) == .literal)
        start = clock.now
        var maxBatch = 0.0
        while true {
            let batchStart = clock.now
            let done = try await store.searchBackfillStep(batch: BrowserHistoryStore.searchBackfillBatch)
            maxBatch = max(maxBatch, ms(batchStart))
            if done { break }
        }
        report.append("backfill_total_ms=\(Int(ms(start))) backfill_max_batch_ms=\(String(format: "%.1f", maxBatch))")
        _ = try await store.delete(.visit(UUID()), now: now) // checkpoint so the file size includes the index
        let sizeAfter = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        report.append("db_mb_before=\(sizeBefore / 1_000_000) db_mb_after=\(sizeAfter / 1_000_000)")

        // Before = the version-nine query on the writer; after = the served query on the reader.
        // Interleaved on the same data so machine load affects both alike.
        for (label, term) in terms {
            var before: [Double] = [], after: [Double] = []
            for _ in 0..<11 {
                start = clock.now; _ = try await store.legacyLibraryVisits(search: term); before.append(ms(start))
                start = clock.now; _ = try await store.visits(search: term); after.append(ms(start))
            }
            let plan = try await store.librarySearchPlan(term)
            report.append("\(label)=\(String(format: "%.1f", median(before)))->\(String(format: "%.1f", median(after)))ms(\(plan))")
            #expect(try await store.visits(search: term).map(\.id) == (try await store.legacyLibraryVisits(search: term).map(\.id)))
        }
        var deep: [Double] = []
        for _ in 0..<5 { start = clock.now; _ = try await store.visits(search: typical, limit: 100, offset: 300); deep.append(ms(start)) }
        report.append("typical_offset300_ms=\(String(format: "%.1f", median(deep)))")
        // Writer blocking: a visit recorded while a typical search runs.
        var blockedBefore: [Double] = [], blockedAfter: [Double] = []
        for index in 0..<7 {
            let legacy = Task { try await store.legacyLibraryVisits(search: rare + "\(index)") }
            try await Task.sleep(for: .milliseconds(2))
            start = clock.now
            try await store.record(BrowserHistoryVisit(url: URL(string: "https://bench.test/before/\(index)")!, title: "Bench", visitedAt: now))
            blockedBefore.append(ms(start))
            _ = try await legacy.value
            let served = Task { try await store.visits(search: rare + "\(index)") }
            try await Task.sleep(for: .milliseconds(2))
            start = clock.now
            try await store.record(BrowserHistoryVisit(url: URL(string: "https://bench.test/after/\(index)")!, title: "Bench", visitedAt: now))
            blockedAfter.append(ms(start))
            _ = try await served.value
        }
        report.append("record_during_search=\(String(format: "%.1f", median(blockedBefore)))->\(String(format: "%.1f", median(blockedAfter)))ms")
        print("HISTORY_SEARCH_BENCH visits=\(visits) pages=\(pages) " + report.joined(separator: " "))
        try await store.close()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
