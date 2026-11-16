import Foundation
import SQLite3

/// Library history search. Version ten adds `visitTitles`, a trigram FTS5 index over every
/// visit's folded title; URLs (with ASCII hosts since version nine) are matched through the
/// page-level trigram index `search`. Both indexes only select candidates: the original literal
/// `instr` predicates still decide membership and the original ORDER BY decides order, so the
/// result is identical to the full scan. A trigram phrase can only miss a row whose column lacks
/// one of the term's trigrams, which a literal substring of three or more scalars never does.
/// Shorter terms (no trigram), and stores whose backfill is still running, use the scan.
///
/// The index follows `visits` rowids. SQLite keeps rowids through VACUUM and VACUUM INTO for
/// this schema in practice, and the only in-place VACUUM runs before any visit is indexed.
extension HistoryDatabase {
    static let visitTitlesTriggers = ["visitTitles_insert", "visitTitles_delete", "visitTitles_update"]

    /// Rows in (indexedThrough, pendingThrough] predate version ten and wait for the backfill;
    /// every other row is indexed by the triggers. The single state row is removed once done.
    private static func indexed(_ row: String) -> String {
        "NOT EXISTS (SELECT 1 FROM visitSearchBackfill WHERE \(row).rowid>indexedThrough AND \(row).rowid<=pendingThrough)"
    }

    /// Creates the index and its triggers only; existing visits are indexed off-launch by
    /// `backfillVisitSearchIndex`. Idempotent: any partial objects are replaced.
    func migrateToVersionTen() throws {
        for trigger in Self.visitTitlesTriggers { try execute("DROP TRIGGER IF EXISTS \(trigger)") }
        try execute("DROP TABLE IF EXISTS visitTitles")
        try execute("DROP TABLE IF EXISTS visitSearchBackfill")
        try execute("CREATE TABLE visitSearchBackfill(indexedThrough INTEGER NOT NULL,pendingThrough INTEGER NOT NULL)")
        try execute("CREATE VIRTUAL TABLE visitTitles USING fts5(searchTitle,content='visits',tokenize='trigram')")
        try execute("INSERT INTO visitTitles(visitTitles,rank) VALUES('secure-delete',1)")
        try execute("CREATE TRIGGER visitTitles_insert AFTER INSERT ON visits WHEN \(Self.indexed("new")) BEGIN INSERT INTO visitTitles(rowid,searchTitle) VALUES(new.rowid,new.searchTitle); END")
        try execute("CREATE TRIGGER visitTitles_delete AFTER DELETE ON visits WHEN \(Self.indexed("old")) BEGIN INSERT INTO visitTitles(visitTitles,rowid,searchTitle) VALUES('delete',old.rowid,old.searchTitle); END")
        try execute("CREATE TRIGGER visitTitles_update AFTER UPDATE OF searchTitle ON visits WHEN old.searchTitle IS NOT new.searchTitle COLLATE BINARY AND \(Self.indexed("old")) BEGIN INSERT INTO visitTitles(visitTitles,rowid,searchTitle) VALUES('delete',old.rowid,old.searchTitle); INSERT INTO visitTitles(rowid,searchTitle) VALUES(new.rowid,new.searchTitle); END")
        try resetVisitSearchBackfill()
    }

    /// Marks every current visit as unindexed. Only valid while the index holds no visit.
    func resetVisitSearchBackfill() throws {
        try execute("DELETE FROM visitSearchBackfill")
        try execute("INSERT INTO visitSearchBackfill SELECT 0,MAX(rowid) FROM visits HAVING COUNT(*)>0")
    }

    func visitSearchBackfillPending() throws -> Bool {
        try scalarInt("SELECT COUNT(*) FROM visitSearchBackfill") > 0
    }

    /// Indexes the next `batch` pending visits in one short transaction and returns true once
    /// every visit is indexed. Restartable at any point: progress commits with the rows.
    func backfillVisitSearchIndex(batch: Int) throws -> Bool {
        try routineTransaction {
            let state = try prepare("SELECT indexedThrough,pendingThrough FROM visitSearchBackfill")
            defer { sqlite3_finalize(state) }
            guard try next(state) else { return true }
            let from = sqlite3_column_int64(state, 0), through = sqlite3_column_int64(state, 1)
            sqlite3_reset(state)
            let bound = try prepare("SELECT rowid FROM visits WHERE rowid>? AND rowid<=? ORDER BY rowid LIMIT 1 OFFSET ?")
            defer { sqlite3_finalize(bound) }
            sqlite3_bind_int64(bound, 1, from)
            sqlite3_bind_int64(bound, 2, through)
            sqlite3_bind_int64(bound, 3, Int64(max(1, batch) - 1))
            let upper = try next(bound) ? sqlite3_column_int64(bound, 0) : through
            sqlite3_reset(bound)
            let insert = try prepare("INSERT INTO visitTitles(rowid,searchTitle) SELECT rowid,searchTitle FROM visits WHERE rowid>? AND rowid<=?")
            defer { sqlite3_finalize(insert) }
            sqlite3_bind_int64(insert, 1, from)
            sqlite3_bind_int64(insert, 2, upper)
            try step(insert)
            if upper >= through {
                try execute("DELETE FROM visitSearchBackfill")
                return true
            }
            let advance = try prepare("UPDATE visitSearchBackfill SET indexedThrough=?")
            defer { sqlite3_finalize(advance) }
            sqlite3_bind_int64(advance, 1, upper)
            try step(advance)
            return false
        }
    }
}

extension BrowserHistoryStore {
    /// Visits indexed per backfill transaction: a few milliseconds of writer time each.
    static let searchBackfillBatch = 512

    /// Indexes visits recorded before version ten. Recording, sync and deletions interleave
    /// between batches; deletions of not-yet-indexed rows never touch the index.
    public func completeSearchIndexBackfill() async throws {
        while let database, try !database.backfillVisitSearchIndex(batch: Self.searchBackfillBatch) {
            await Task.yield()
        }
    }

    /// Candidate visits collected from the indexes before giving up on them: a term matching
    /// more visits fills a page of results within a short time-ordered literal scan instead.
    /// Collecting costs about the budget; the scan reads about window × visits / matches rows,
    /// so both strategies cost the same near √(window × visits).
    static func librarySearchCandidateBudget(window: Int, visits: Int) -> Int {
        min(50_000, max(1000, window, Int(Double(max(1, window) * max(1, visits)).squareRoot())))
    }

    static func queryVisits(_ database: HistoryDatabase, search: String, interval: DateInterval?,
                            limit: Int, offset: Int) throws -> [BrowserHistoryVisit] {
        let limit = min(max(0, limit), 10000), offset = max(0, offset)
        var clauses = ["1"]
        var values: [HistoryValue] = []
        if let interval {
            clauses.append("time>=? AND time<?")
            values += [.number(interval.start.timeIntervalSince1970), .number(interval.end.timeIntervalSince1970)]
        }
        if !search.isEmpty {
            // Library searches intentionally use the same Unicode folding as palette queries.
            let filter = try librarySearchFilter(database, term: fold(search), window: limit + offset)
            clauses.append(filter.sql)
            values += filter.values
        }
        return try readVisits(database, whereSQL: clauses.joined(separator: " AND "), values: values, limit: limit, offset: offset)
    }

    enum LibrarySearchPlan: Equatable { case literal, candidates }

    /// The literal filter of earlier versions: `instr` over every page and every scanned visit.
    static let literalLibraryFilter = "(url IN (SELECT url FROM pages WHERE instr(searchURL,?)>0) OR instr(searchTitle,?)>0)"

    /// Visits of pages whose search URL contains the term, then visits whose own title does.
    /// The trigram index drives each arm lazily; `instr` keeps the literal semantics exactly.
    private static let urlCandidates = """
        SELECT visits.rowid FROM search CROSS JOIN pages ON pages.id=search.rowid CROSS JOIN visits ON visits.url=pages.url
        WHERE search MATCH ? AND instr(pages.searchURL,?)>0 LIMIT ?
        """
    private static let titleCandidates = """
        SELECT visits.rowid FROM visitTitles CROSS JOIN visits ON visits.rowid=visitTitles.rowid
        WHERE visitTitles MATCH ? AND instr(visits.searchTitle,?)>0 LIMIT ?
        """

    /// Every visit row the literal filter accepts, or nil past `budget` candidates.
    private static func candidateRowids(_ database: HistoryDatabase, term: String, budget: Int) throws -> Set<Int64>? {
        let phrase = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        var rowids = Set<Int64>()
        // Titles first: a term common in titles exhausts the budget before the URL arm has to
        // walk the page index, whose trigram lists cover page titles too.
        for (sql, match) in [(titleCandidates, phrase), (urlCandidates, "searchURL:" + phrase)] {
            let statement = try database.prepare(sql)
            defer { sqlite3_finalize(statement) }
            try database.bind(statement, [.text(match), .text(term), .number(Double(budget + 1))])
            while try database.next(statement) {
                rowids.insert(sqlite3_column_int64(statement, 0))
                if rowids.count > budget { return nil }
            }
        }
        return rowids
    }

    /// Terms of three or more scalars on a fully indexed store read their candidates from the
    /// trigram indexes; the time order, interval and pagination then apply to those rows only.
    /// `plan` forces a strategy (tests compare both on the same data).
    static func librarySearchFilter(_ database: HistoryDatabase, term: String, window: Int,
                                    plan forced: LibrarySearchPlan? = nil) throws -> (plan: LibrarySearchPlan, sql: String, values: [HistoryValue]) {
        let literal = (LibrarySearchPlan.literal, literalLibraryFilter, [HistoryValue.text(term), .text(term)])
        guard forced != .literal, term.unicodeScalars.count >= BrowserHistoryMatching.substringMinimumScalars,
              try !database.visitSearchBackfillPending() else { return literal }
        let visits = forced == .candidates ? 0 : try database.scalarInt("SELECT COALESCE(MAX(rowid),0) FROM visits")
        let budget = forced == .candidates ? 100_000_000 : librarySearchCandidateBudget(window: window, visits: visits)
        guard let rowids = try candidateRowids(database, term: term, budget: budget) else { return literal }
        let list = "[" + rowids.map(String.init).joined(separator: ",") + "]"
        return (.candidates, "rowid IN (SELECT value FROM json_each(?))", [.text(list)])
    }
}
