import Foundation
import SQLite3
import Testing
@testable import BrowserCore

@Suite("Command Bar history equivalence", .serialized)
struct CommandBarHistoryTests {
    @Test("Indexed empty and short-symbol paths preserve 4000 queries over 100k pages")
    func equivalence100k() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-cmdbar-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let records = (0..<100_000).map { index in
            BrowserHistoryVisit(url: URL(string: "https://site\(index % 100).test/article/\(index)\(index % 997 == 0 ? "~!" : "")")!,
                title: ["Synthetic résumé", "東京 guide", "مرحبا report", "Café planning"][index % 4] + " \(index)",
                visitedAt: Date(timeIntervalSince1970: Double(1_000_000 + index * 17)), typedCount: index % 5)
        }
        _ = try await store.importDocument(.init(profileID: profile, visits: records))
        try await store.compareOriginalQueries(now: now)
        try await store.close()
        // Reversing only the additive objects recreates a v6 store without touching content.
        let file = root.appendingPathComponent(profile.rawValue.uuidString).appendingPathComponent("history.sqlite")
        let legacy = try HistoryDatabase(url: file, profileID: profile)
        try legacy.discardSuggestionSchemaForLegacyFixture()
        try legacy.execute("UPDATE identity SET version=6")
        try legacy.execute("PRAGMA user_version=6")
        try legacy.close()
        let migrated = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        #expect(try await migrated.suggestions("~!", now: now).count == 12)
        try await migrated.close()
    }

    @Test("Warm membership reuse preserves scores through query widening and index mutations")
    func warmEquivalence() {
        let profile = ProfileID(), now = Date(timeIntervalSince1970: 2_000_000)
        let pages = (0..<3750).map { index in
            let url = URL(string: "https://site\(index % 100).test/article/\(index)")!
            let title = ["Synthetic résumé", "東京 guide", "مرحبا report", "Café planning"][index % 4] + " \(index)"
            return BrowserHistoryIndexedPage(url: url, title: title, faviconReference: nil, lastVisitedAt: Double(1_000_000 + index), visitCount: index % 19 + 1, typedCount: index % 5,
                searchURL: BrowserSuggestionText.searchableURL(url), searchTitle: BrowserSuggestionText.fold(title))
        }
        let original = OriginalMemoryIndex(profileID: profile, pages: pages, capacity: 3750)
        var index = BrowserHistoryMemoryIndex(profileID: profile, pages: pages, capacity: 3750)
        var cache = BrowserHistoryMemoryIndex.QueryCache()
        let seeds = ["", "s", "sy", "syn", "synthetic", "synthetic résumé", "rés", "re", "東京", "مرحبا", "~", "%", "article/1"]
        for n in 0..<2000 {
            let query = seeds[n % seeds.count]
            #expect(original.suggestions(query, now: now) == index.suggestions(query, cache: &cache, now: now))
        }
        index.upsert(pages[0], now: now.timeIntervalSince1970)
        #expect(original.suggestions("s", now: now) == index.suggestions("s", cache: &cache, now: now))
    }
}

private extension BrowserHistoryStore {
    func compareOriginalQueries(now: Date) throws {
        guard let database else { return }
        try database.registerMatchingFunctions()
        let seeds = ["", "~", "~!", "!", "?", "%", "sy", "art", "résumé", "東京", "مرحبا", "site1", "article/999", "cafe"]
        var oldTimes: [String: [Double]] = [:], newTimes: [String: [Double]] = [:]
        var counts: [String: [Int]] = [:]
        func execute(_ sql: String, _ values: [HistoryValue]) throws -> ([String], Int, Int) {
            let statement = try database.prepare(sql)
            defer { sqlite3_finalize(statement) }
            try database.bind(statement, values)
            var rows: [String] = []
            while try database.next(statement) {
                rows.append((0..<7).map { database.text(statement, Int32($0)) }.joined(separator: "\u{1f}"))
            }
            return (rows, Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0)), Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0)))
        }
        for n in 0..<4000 {
            let query = n >= 2000 ? "article/\(n * 37 % 100_000)" : seeds[n % seeds.count]
            let old = OriginalHistoryRanking.suggestionStatement(query, mode: .substring, limit: 12, now: now)
            let new = Self.suggestionStatement(query, mode: .substring, limit: 12, now: now)
            let start = ProcessInfo.processInfo.systemUptime
            let a = try execute(old.sql, old.values)
            let middle = ProcessInfo.processInfo.systemUptime
            let b = try execute(new.sql, new.values)
            oldTimes[query, default: []].append((middle-start)*1000)
            newTimes[query, default: []].append((ProcessInfo.processInfo.systemUptime-middle)*1000)
            counts[query] = [a.1, b.1, a.2, b.2]
            #expect(a.0 == b.0, "Recorded SQL query \(n)")
        }
        print("CMDBAR_SQL_EQ queries=4000 history_pages=100000")
        for query in ["", "~!", "sy"] {
            let old = oldTimes[query]!.sorted(), new = newTimes[query]!.sorted()
            print("CMDBAR_SQL kind=\(query.isEmpty ? "empty" : query) old_p50_ms=\(old[old.count/2]) new_p50_ms=\(new[new.count/2]) old_new_vm_and_fullscan_steps=\(counts[query]!)")
        }
    }
}

private enum OriginalHistoryRanking {
    static let shortTermCandidates = 1500
    /// Indexed matches an arm may read before ranking. Frecency depends on `now`, so no static
    /// index can return pages in frecency order; each arm instead reads up to this many matches
    /// from its index and keeps its `shortTermCandidates` best by the unchanged frecency formula.
    /// Arms with at most this many matches therefore select exactly by frecency, never by B-tree
    /// or rowid order. Ranking every match of a one-letter term measured 5–10x the bounded cost on
    /// 100k pages. Past the budget, LIKE arms read in index order and the title word arm newest
    /// pages first; the warm memory index (typed, frequent and recent pages, best frecency first)
    /// is merged by the palette and covers the significant pages such a truncation could miss.
    static let shortTermScanBudget = 10_000

    /// `source` selects `id,last,visits,typed` and binds its own budget; appends `now`, cap.
    /// Match quality is nearly uniform inside an arm (host prefix, or title word start), so the
    /// arm ranks by frecency alone; the outer query applies the full key to the union.
    private static func rankedArm(_ source: String) -> String {
        // Wrapped so that the arm's ORDER BY and LIMIT are legal inside a UNION.
        "SELECT id FROM (SELECT id FROM (\(source)) ORDER BY (visits+typed*4.0)/(1.0+MAX(0,?-last)/86400.0/7.0) DESC,last DESC LIMIT ?)"
    }

    static func suggestionStatement(_ query: String, mode: BrowserHistorySearchMode, limit: Int,
                                    now: Date) -> (sql: String, values: [HistoryValue]) {
        let matchTerms = BrowserHistoryMatching.terms(query).filter { !$0.text.isEmpty }
        let terms = matchTerms.map(\.text)
        var values: [HistoryValue] = [.number(now.timeIntervalSince1970)]
        var clauses: [String] = []
        // A long substring term drives the candidate set through the trigram index; other terms
        // are then cheap row predicates. Without one, the first short term drives through capped
        // B-tree prefix and word-prefix arms instead of scanning every page.
        var hasDriver = mode == .prefix || matchTerms.contains { !$0.isShort }
        var firstLong = true
        let budget = HistoryValue.number(Double(shortTermScanBudget))
        let ranked: [HistoryValue] = [.number(now.timeIntervalSince1970), .number(Double(shortTermCandidates))]
        for matchTerm in matchTerms {
            let term = matchTerm.text
            let prefix = BrowserHistoryStore.likeLiteral(term) + "%"
            let phrase = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
            if mode == .prefix {
                // Independent arms preserve B-tree prefix indexes and indexed word starts,
                // including after punctuation. The literal check preserves escaped symbols.
                clauses.append("""
                    pages.rowid IN (
                      SELECT id FROM pages WHERE searchURL LIKE ? ESCAPE '\\'
                      UNION SELECT id FROM pages WHERE searchTitle LIKE ? ESCAPE '\\'
                      UNION SELECT rowid FROM titleWords WHERE titleWords MATCH ? AND instr(searchTitle,?)>0
                    )
                    """)
                values += [.text(prefix), .text(prefix), .text(phrase), .text(term)]
            } else if !matchTerm.isShort && firstLong {
                clauses.append("pages.rowid IN (SELECT rowid FROM search WHERE search MATCH ?)")
                values.append(.text("\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""))
                firstLong = false
            } else if !BrowserHistoryMatching.usesWordStart(matchTerm, in: matchTerms) {
                if !hasDriver {
                    // Symbol-led short query: no token index applies; bounded literal scan.
                    hasDriver = true
                    clauses.append("pages.rowid IN (\(rankedArm("SELECT id,last,visits,typed FROM pages WHERE instr(searchURL,?)>0 OR instr(searchTitle,?)>0 LIMIT ?")))")
                    values += [.text(term), .text(term), budget] + ranked
                }
                clauses.append("(instr(searchURL,?)>0 OR instr(searchTitle,?)>0)")
                values += [.text(term), .text(term)]
            } else {
                if !hasDriver {
                    hasDriver = true
                    clauses.append("""
                        pages.rowid IN (
                          \(rankedArm("SELECT id,last,visits,typed FROM pages WHERE searchURL LIKE ? ESCAPE '\\' LIMIT ?"))
                          UNION \(rankedArm("SELECT id,last,visits,typed FROM pages WHERE searchTitle LIKE ? ESCAPE '\\' LIMIT ?"))
                          UNION \(rankedArm("""
                            SELECT pages.id AS id,last,visits,typed FROM (SELECT rowid AS word FROM titleWords
                            WHERE titleWords MATCH ? ORDER BY rowid DESC LIMIT ?) JOIN pages ON pages.id=word
                            """))
                        )
                        """)
                    values += [.text(prefix), budget] + ranked + [.text(prefix), budget] + ranked + [.text(phrase), budget] + ranked
                }
                // Exact membership shared with the in-memory index: URL prefix or title word start.
                clauses.append("(searchURL LIKE ? ESCAPE '\\' OR orbit_word_start(searchTitle,?))")
                values += [.text(prefix), .text(term)]
            }
        }
        let filter = clauses.isEmpty ? "1" : clauses.joined(separator: " AND ")
        // Match quality dominates frecency within each tier, with stable deterministic ties.
        // Host quality requires a host prefix or host word start, never an arbitrary infix.
        let first = terms.first ?? ""
        let bonus = first.isEmpty ? "0.0"
            : "(CASE WHEN orbit_host_start(searchURL,?) THEN 1000 ELSE 0 END + CASE WHEN orbit_word_start(searchTitle,?) THEN 100 ELSE 0 END)"
        let sql = """
            SELECT url,title,favicon,last,visits,typed,
              (visits+typed*4.0)/(1.0+MAX(0,?-last)/86400.0/7.0) AS score
            FROM pages WHERE \(filter) ORDER BY \(bonus) DESC,score DESC,last DESC,url ASC LIMIT ?
            """
        if !first.isEmpty { values += [.text(first), .text(first)] }
        values.append(.number(Double(min(limit, 1000))))
        return (sql, values)
    }

}
private struct OriginalMemoryIndex: Sendable {
    public static let defaultCapacity = 3000
    public static let frequentVisits = 3
    public static let recentInterval: Double = 30 * 86400

    private struct Entry: Sendable {
        var page: BrowserHistoryIndexedPage
        var searchURL: [UInt8]
        var searchTitle: [UInt8]
        var urlBytes: [UInt8]
        init(_ page: BrowserHistoryIndexedPage) {
            self.page = page
            searchURL = Array(page.searchURL.utf8)
            searchTitle = Array(page.searchTitle.utf8)
            urlBytes = Array(page.url.absoluteString.utf8)
        }
    }

    public let profileID: ProfileID
    public let capacity: Int
    private var entries: [Entry] = []
    private var positions: [String: Int] = [:]

    public var count: Int { entries.count }
    /// Upserts may temporarily exceed the capacity; the owner rebuilds to trim.
    public var needsTrim: Bool { entries.count > capacity + capacity / 4 }

    public init(profileID: ProfileID, pages: [BrowserHistoryIndexedPage], capacity: Int = BrowserHistoryMemoryIndex.defaultCapacity) {
        self.profileID = profileID
        self.capacity = capacity
        entries.reserveCapacity(min(pages.count, capacity))
        for page in pages.prefix(capacity) where positions[page.url.absoluteString] == nil {
            positions[page.url.absoluteString] = entries.count
            entries.append(Entry(page))
        }
    }

    public func contains(_ url: URL) -> Bool { positions[url.absoluteString] != nil }

    /// Applies an authoritative aggregate read back after a committed write.
    public mutating func upsert(_ page: BrowserHistoryIndexedPage, now: Double) {
        let key = page.url.absoluteString
        if let position = positions[key] { entries[position] = Entry(page); return }
        guard page.isSignificant(now: now) else { return }
        positions[key] = entries.count
        entries.append(Entry(page))
    }

    /// Same membership, bonus and ordering as `BrowserHistoryStore.suggestions(_:mode: .substring)`,
    /// restricted to the indexed pages.
    public func suggestions(_ query: String, limit: Int = 12, now: Date = Date()) -> [BrowserHistorySuggestion] {
        guard limit > 0 else { return [] }
        let terms = BrowserHistoryMatching.terms(query).filter { !$0.bytes.isEmpty }
        let first = terms.first?.bytes ?? []
        let timestamp = now.timeIntervalSince1970
        var ranked: [(bonus: Int, score: Double, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            let quality: Int? = entry.searchURL.withUnsafeBufferPointer { url in
                entry.searchTitle.withUnsafeBufferPointer { title in
                    guard BrowserHistoryMatching.matches(searchURL: url, searchTitle: title, terms: terms) else { return nil }
                    return BrowserHistoryMatching.bonus(searchURL: url, searchTitle: title, first: first)
                }
            }
            guard let quality else { continue }
            let page = entry.page
            ranked.append((quality, BrowserHistoryMatching.frecency(visits: page.visitCount, typed: page.typedCount,
                                                                    last: page.lastVisitedAt, now: timestamp), index))
        }
        ranked.sort { a, b in
            if a.bonus != b.bonus { return a.bonus > b.bonus }
            if a.score != b.score { return a.score > b.score }
            let left = entries[a.index], right = entries[b.index]
            if left.page.lastVisitedAt != right.page.lastVisitedAt { return left.page.lastVisitedAt > right.page.lastVisitedAt }
            return left.urlBytes.lexicographicallyPrecedes(right.urlBytes)
        }
        return ranked.prefix(min(limit, 1000)).map { item in
            let page = entries[item.index].page
            return BrowserHistorySuggestion(profileID: profileID, url: page.url, title: page.title,
                faviconReference: page.faviconReference, visitCount: page.visitCount, typedCount: page.typedCount,
                lastVisitedAt: Date(timeIntervalSince1970: page.lastVisitedAt), score: item.score)
        }
    }
}

// Downgrade only the suggestion acceleration objects in synthetic legacy fixtures.
extension HistoryDatabase {
    func discardSuggestionSchemaForLegacyFixture() throws {
        for name in ["shortSymbols_insert", "shortSymbols_delete", "shortSymbols_update"] { try execute("DROP TRIGGER IF EXISTS \(name)") }
        try execute("DROP TABLE IF EXISTS shortSymbols")
        try execute("DROP INDEX IF EXISTS pages_weight_last")
    }
}
