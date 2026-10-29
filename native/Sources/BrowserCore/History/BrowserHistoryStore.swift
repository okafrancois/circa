import Foundation
import SQLite3

/// One actor and one SQLite document per profile. No global/default path and no personal-data
/// diagnostics. The disabled policies never create a directory or open a database.
public actor BrowserHistoryStore {
    public let profileID: ProfileID
    public let policy: BrowserHistoryPolicy
    let database: HistoryDatabase?
    var applyingHistorySync = false
    var lastHistoryJournalPrune = Date.distantPast
    /// Separate read-only WAL connection: suggestions and index snapshots bypass this actor.
    private nonisolated let reader: HistoryReadConnection?
    private let profileDirectory: OrbitSecureDirectory?
    private let historyDirectory: OrbitSecureDirectory?
    private var profileRemoved = false
    /// Retains the checked directory identity; SQLite keeps its ordinary native VFS (IMPORT-R5).
    private nonisolated let pin: OrbitSQLiteGuard.Pin?
    public private(set) var maintenanceStatus: BrowserHistoryMaintenanceStatus = .idle

    public init(profileID: ProfileID, policy: BrowserHistoryPolicy, directory: URL) throws {
        self.profileID = profileID
        self.policy = policy
        guard policy == .persistent else {
            database = nil; reader = nil; profileDirectory = nil; historyDirectory = nil; pin = nil
            return
        }
        let parent: OrbitSecureDirectory
        let folder: OrbitSecureDirectory
        let pin: OrbitSQLiteGuard.Pin
        do {
            parent = try OrbitSecureDirectory.open(directory, create: true)
            folder = try parent.directory(profileID.rawValue.uuidString, create: true)
            pin = try OrbitSQLiteGuard.pin(folder)
        } catch { throw BrowserHistoryError.storageFailure(SQLITE_CANTOPEN) }
        historyDirectory = parent
        profileDirectory = folder
        let file = folder.url.appendingPathComponent("history.sqlite")
        self.pin = pin
        let database: HistoryDatabase
        do { database = try HistoryDatabase(url: file, profileID: profileID) }
        catch { pin.release(); throw error }
        do { reader = try HistoryReadConnection(url: file) }
        catch { try? database.close(); pin.release(); throw error }
        self.database = database
    }

    public func close() throws {
        try reader?.close()
        try database?.close()
        pin?.release()
    }

    /// Close before removing the entire profile directory, including WAL and SHM sidecars.
    /// This actor is permanently closed afterwards; queued writes cannot recreate the files.
    public func removeProfileHistory() throws {
        guard !profileRemoved, let profileDirectory, let historyDirectory else { return }
        do {
            // Refuse a stale path before SQLite closes (and may clean up its WAL sidecars).
            _ = try profileDirectory.verifiedPath("history.sqlite")
        } catch { throw BrowserHistoryError.storageFailure(SQLITE_CANTOPEN) }
        try reader?.close()
        try database?.close()
        do {
            _ = try profileDirectory.verifiedPath("history.sqlite")
            // All removals are relative to verified descriptors. Never recurse through the path
            // string: an ancestor replaced by a symlink must not redirect profile deletion.
            for entry in try profileDirectory.checkedEntries() { try profileDirectory.removeChecked(entry) }
            guard unlinkat(historyDirectory.descriptor, profileID.rawValue.uuidString, AT_REMOVEDIR) == 0 else {
                throw BrowserHistoryError.storageFailure(SQLITE_IOERR)
            }
            profileRemoved = true
            pin?.release()
            try historyDirectory.synchronize()
        } catch let error as BrowserHistoryError { throw error }
        catch { throw BrowserHistoryError.storageFailure(SQLITE_CANTOPEN) }
    }

    /// Removes an unopened profile without requiring its database to be readable.
    /// Used by profile retirement when no cached actor owns the history yet.
    public static func removeUnopenedProfileHistory(profileID: ProfileID, directory: URL) throws {
        do {
            let parent = try OrbitSecureDirectory.open(directory, create: false)
            let folder = try parent.directory(profileID.rawValue.uuidString, create: false)
            _ = try folder.verifiedPath("history.sqlite")
            try parent.removeChecked(profileID.rawValue.uuidString)
        } catch ArcImportError.backupNotFound { return }
        catch { throw BrowserHistoryError.storageFailure(SQLITE_CANTOPEN) }
    }

    @discardableResult public func record(_ visit: BrowserHistoryVisit) throws -> Bool {
        guard database != nil else { return false }
        return try insert([visit], respectsBarriers: false) == 1
    }

    /// Records a visit and returns the committed page aggregate for in-memory index updates.
    /// Returns nil when nothing was inserted (duplicate identity or disabled policy).
    public func recordReturningPage(_ visit: BrowserHistoryVisit) throws -> BrowserHistoryIndexedPage? {
        guard database != nil, try insert([visit], respectsBarriers: false) == 1 else { return nil }
        return try page(for: visit.url)
    }

    private func page(for url: URL) throws -> BrowserHistoryIndexedPage? {
        guard let database else { return nil }
        let statement = try database.prepare("SELECT \(Self.pageColumns) FROM pages WHERE url=?")
        defer { sqlite3_finalize(statement) }
        try database.bind(statement, [.text(url.absoluteString)])
        return try database.next(statement) ? Self.indexedPage(database, statement) : nil
    }

    static let pageColumns = "url,title,favicon,last,visits,typed,searchURL,searchTitle"
    static func indexedPage(_ database: HistoryDatabase, _ statement: OpaquePointer) -> BrowserHistoryIndexedPage? {
        guard let url = URL(string: database.text(statement, 0)) else { return nil }
        return BrowserHistoryIndexedPage(url: url, title: database.text(statement, 1),
            faviconReference: URL(string: database.text(statement, 2)), lastVisitedAt: sqlite3_column_double(statement, 3),
            visitCount: Int(sqlite3_column_int64(statement, 4)), typedCount: Int(sqlite3_column_int64(statement, 5)),
            searchURL: database.text(statement, 6), searchTitle: database.text(statement, 7))
    }

    /// Atomic, idempotent import seam. A mismatched profile is rejected before any write.
    @discardableResult public func importDocument(_ document: BrowserHistoryDocument) throws -> Int {
        guard document.profileID == profileID else { throw BrowserHistoryError.profileMismatch }
        guard document.version == 1 else { throw BrowserHistoryError.unsupportedVersion }
        guard database != nil else { return 0 }
        return try insert(document.visits)
    }

    func insert(_ visits: [BrowserHistoryVisit], respectsBarriers: Bool = true) throws -> Int {
        guard let database else { return 0 }
        // Validate the entire batch before starting a transaction, including redirect metadata.
        for visit in visits where !Self.accepts(visit) { throw BrowserHistoryError.invalidVisit }
        return try database.transaction {
            let statement = try database.prepare("INSERT OR IGNORE INTO visits(id,url,site,time,title,typed,payload,searchTitle) VALUES(?,?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(statement) }
            var inserted = 0
            let barriers = try syncDeletions()
            let cutoff = try syncCutoff()
            for visit in visits {
                guard visit.visitedAt >= cutoff, (!respectsBarriers || !barriers.contains(where: { $0.matches(visit) })) else { continue }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                let data = try JSONEncoder().encode(visit)
                try database.bind(statement, [.text(visit.id.uuidString), .text(visit.url.absoluteString),
                    .text(visit.url.host!.lowercased()), .number(visit.visitedAt.timeIntervalSince1970),
                    .text(visit.title), .number(Double(visit.typedCount)), .text(String(decoding: data, as: UTF8.self)), .text(Self.fold(visit.title))])
                try database.step(statement)
                guard database.changes > 0 else { continue }
                inserted += 1
                if !applyingHistorySync { try appendSyncEvent(BrowserHistorySyncEvent(visit: visit)) }
                try database.execute("""
                    INSERT INTO pages(url,title,favicon,last,visits,typed,searchURL,searchTitle)
                    VALUES(?,?,?,?,1,?,?,?) ON CONFLICT(url) DO UPDATE SET
                    title=CASE WHEN excluded.last >= pages.last THEN excluded.title ELSE pages.title END,
                    favicon=CASE WHEN excluded.last >= pages.last THEN excluded.favicon ELSE pages.favicon END,
                    last=MAX(last,excluded.last), visits=visits+1, typed=typed+excluded.typed,
                    searchTitle=CASE WHEN excluded.last >= pages.last THEN excluded.searchTitle ELSE pages.searchTitle END
                    """, [.text(visit.url.absoluteString), .text(visit.title), .text(visit.faviconReference?.absoluteString ?? ""),
                           .number(visit.visitedAt.timeIntervalSince1970), .number(Double(visit.typedCount)),
                           .text(Self.searchURL(visit.url)), .text(Self.fold(visit.title))])
            }
            return inserted
        }
    }

    /// Returns the committed page aggregate of the updated visit, if the visit still exists.
    @discardableResult
    public func updateMetadata(visitID: UUID, title: String, faviconReference: URL? = nil) throws -> BrowserHistoryIndexedPage? {
        guard let database else { return nil }
        guard faviconReference.map(BrowserHistoryFavicon.accepts) ?? true else { throw BrowserHistoryError.invalidVisit }
        return try database.transaction { () throws -> BrowserHistoryIndexedPage? in
            guard var visit = try readVisits(whereSQL: "id=?", values: [.text(visitID.uuidString)], limit: 1, offset: 0).first else { return nil }
            let titleChanged = visit.title != title
            visit.title = title
            if !applyingHistorySync { visit.faviconReference = faviconReference }
            let payload = String(decoding: try JSONEncoder().encode(visit), as: UTF8.self)
            try database.execute("UPDATE visits SET title=?,payload=?,searchTitle=? WHERE id=?", [.text(title), .text(payload), .text(Self.fold(title)), .text(visitID.uuidString)])
            if !applyingHistorySync && titleChanged { try appendSyncEvent(BrowserHistorySyncEvent(visit: visit)) }
            // A late title callback must not overwrite the metadata of a newer visit.
            try database.execute("""
                UPDATE pages SET title=?,searchTitle=?,favicon=? WHERE url=? AND
                ?=(SELECT id FROM visits WHERE url=? ORDER BY time DESC,rowid DESC LIMIT 1)
                """, [.text(title), .text(Self.fold(title)), .text(visit.faviconReference?.absoluteString ?? ""),
                       .text(visit.url.absoluteString), .text(visitID.uuidString), .text(visit.url.absoluteString)])
            return try page(for: visit.url)
        }
    }

    /// Runs on the read-only connection, never behind writes. Cancelling the calling task
    /// interrupts this request's SQLite statement and throws `CancellationError`.
    public nonisolated func suggestions(_ query: String, mode: BrowserHistorySearchMode = .substring,
                                        limit: Int = 12, now: Date = Date()) async throws -> [BrowserHistorySuggestion] {
        guard let reader, limit > 0 else { return [] }
        try Task.checkCancellation()
        let profileID = profileID
        return try await reader.perform { database in
            try Self.querySuggestions(database, profileID: profileID, query: query, mode: mode, limit: limit, now: now)
        }
    }

    /// Bounded snapshot of significant pages (typed, frequent or recent), best frecency first.
    public nonisolated func memoryIndex(capacity: Int = BrowserHistoryMemoryIndex.defaultCapacity,
                                        now: Date = Date()) async throws -> BrowserHistoryMemoryIndex {
        let profileID = profileID
        guard let reader else { return BrowserHistoryMemoryIndex(profileID: profileID, pages: []) }
        return try await reader.perform { database in
            let statement = try database.prepare("""
                SELECT \(Self.pageColumns) FROM pages
                WHERE typed>=1 OR visits>=? OR last>=?
                ORDER BY (visits+typed*4.0)/(1.0+MAX(0,?-last)/86400.0/7.0) DESC,last DESC,url ASC LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            let timestamp = now.timeIntervalSince1970
            try database.bind(statement, [.number(Double(BrowserHistoryMemoryIndex.frequentVisits)),
                                          .number(timestamp - BrowserHistoryMemoryIndex.recentInterval),
                                          .number(timestamp), .number(Double(max(0, capacity)))])
            var pages: [BrowserHistoryIndexedPage] = []
            while try database.next(statement) {
                if let page = Self.indexedPage(database, statement) { pages.append(page) }
            }
            return BrowserHistoryMemoryIndex(profileID: profileID, pages: pages, capacity: capacity)
        }
    }

    /// Short-term candidates kept per indexed arm; ranking then orders at most a few thousand rows.
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

    static func querySuggestions(_ database: HistoryDatabase, profileID: ProfileID, query: String,
                                 mode: BrowserHistorySearchMode, limit: Int, now: Date) throws -> [BrowserHistorySuggestion] {
        let (sql, values) = suggestionStatement(query, mode: mode, limit: limit, now: now)
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        try database.bind(statement, values)
        var result: [BrowserHistorySuggestion] = []
        while try database.next(statement) {
            guard let url = URL(string: database.text(statement, 0)) else { continue }
            result.append(BrowserHistorySuggestion(profileID: profileID, url: url, title: database.text(statement, 1),
                faviconReference: URL(string: database.text(statement, 2)),
                visitCount: Int(sqlite3_column_int64(statement, 4)), typedCount: Int(sqlite3_column_int64(statement, 5)),
                lastVisitedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                score: sqlite3_column_double(statement, 6)))
        }
        return result
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
            let prefix = likeLiteral(term) + "%"
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

    /// Stable newest-first pagination, with an optional half-open date range and literal search.
    public func visits(search: String = "", interval: DateInterval? = nil,
                       limit: Int = 100, offset: Int = 0) throws -> [BrowserHistoryVisit] {
        var clauses = ["1"]
        var values: [HistoryValue] = []
        if let interval { clauses += ["time>=? AND time<?"]; values += [.number(interval.start.timeIntervalSince1970), .number(interval.end.timeIntervalSince1970)] }
        if !search.isEmpty {
            // Library searches intentionally use the same Unicode folding as palette queries.
            clauses += ["(url IN (SELECT url FROM pages WHERE instr(searchURL,?)>0) OR instr(searchTitle,?)>0)"]
            values += [.text(Self.fold(search)), .text(Self.fold(search))]
        }
        return try readVisits(whereSQL: clauses.joined(separator: " AND "), values: values, limit: min(max(0, limit), 10000), offset: max(0, offset))
    }

    public func days(search: String = "", interval: DateInterval? = nil, calendar: Calendar = .current,
                     limit: Int = 100, offset: Int = 0) throws -> [BrowserHistoryDay] {
        let records = try visits(search: search, interval: interval, limit: limit, offset: offset)
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.visitedAt) }
        return grouped.keys.sorted(by: >).map { BrowserHistoryDay(day: $0, visits: grouped[$0]!) }
    }

    @discardableResult public func delete(_ deletion: BrowserHistoryDeletion, now: Date = Date()) throws -> Int {
        guard let database else { return 0 }
        let clause: String
        let values: [HistoryValue]
        switch deletion {
        case .visit(let id): clause = "id=?"; values = [.text(id.uuidString)]
        case .interval(let interval):
            clause = "time>=? AND time<?"; values = [.number(interval.start.timeIntervalSince1970), .number(interval.end.timeIntervalSince1970)]
        case .lastHour(let now): clause = "time>=?"; values = [.number(now.addingTimeInterval(-3600).timeIntervalSince1970)]
        case .lastDay(let now): clause = "time>=?"; values = [.number(now.addingTimeInterval(-86400).timeIntervalSince1970)]
        case .site(let host): clause = "site=?"; values = [.text(URL(string: "https://" + host)?.host?.lowercased() ?? host.lowercased())]
        case .all: clause = "1"; values = []
        }
        let count = try database.transaction {
            if !applyingHistorySync {
                try appendSyncEvent(BrowserHistorySyncEvent(deletion: BrowserHistorySyncDeletion(deletion, now: now), time: now))
            }
            return try deleteRows(clause: clause, values: values)
        }
        maintenanceStatus = database.checkpoint()
        return count
    }

    func deleteRows(clause: String, values: [HistoryValue]) throws -> Int {
        guard let database else { return 0 }
        let count = try database.transaction {
            try database.execute("CREATE TEMP TABLE affected AS SELECT DISTINCT url FROM visits WHERE \(clause)", values)
            defer { try? database.execute("DROP TABLE affected") }
            try database.execute("DELETE FROM visits WHERE \(clause)", values)
            let count = database.changes
            try database.execute("DELETE FROM pages WHERE url IN (SELECT url FROM affected)")
            try database.execute("""
                INSERT INTO pages(url,title,favicon,last,visits,typed,searchURL,searchTitle)
                SELECT v.url,v.title,COALESCE(json_extract(v.payload,'$.faviconReference'),''),v.time,
                (SELECT COUNT(*) FROM visits c WHERE c.url=v.url),
                (SELECT SUM(typed) FROM visits c WHERE c.url=v.url),
                '', '' FROM visits v WHERE v.url IN (SELECT url FROM affected)
                AND v.rowid=(SELECT rowid FROM visits c WHERE c.url=v.url ORDER BY time DESC,rowid DESC LIMIT 1)
                """)
            let rows = try database.prepare("SELECT url,title FROM pages WHERE url IN (SELECT url FROM affected)")
            defer { sqlite3_finalize(rows) }
            var updates: [(String, String)] = []
            while try database.next(rows) { updates.append((database.text(rows, 0), database.text(rows, 1))) }
            for (url, title) in updates {
                try database.execute("UPDATE pages SET searchURL=?,searchTitle=? WHERE url=?", [.text(Self.searchURL(URL(string: url)!)), .text(Self.fold(title)), .text(url)])
            }
            return count
        }
        // The deletion has committed. Maintenance failure must not report that mutation as failed.
        if database.withHandle({ sqlite3_get_autocommit($0) != 0 }) { maintenanceStatus = database.checkpoint() }
        return count
    }

    private func readVisits(whereSQL: String, values: [HistoryValue], limit: Int, offset: Int) throws -> [BrowserHistoryVisit] {
        guard let database, limit > 0 else { return [] }
        let statement = try database.prepare("SELECT payload FROM visits WHERE \(whereSQL) ORDER BY time DESC,rowid DESC LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(statement) }
        try database.bind(statement, values + [.number(Double(limit)), .number(Double(offset))])
        var records: [BrowserHistoryVisit] = []
        while try database.next(statement) {
            records.append(try JSONDecoder().decode(BrowserHistoryVisit.self, from: Data(database.text(statement, 0).utf8)))
        }
        return records
    }

    /// The validation `record` and `importDocument` apply to every visit. Import adapters filter
    /// with it, so one unsupported visit never rejects a whole chunk (BL-HIST-IMPORT-CHUNKS).
    public static func accepts(_ visit: BrowserHistoryVisit) -> Bool {
        isWebURL(visit.url) && visit.redirectChain.allSatisfy(isWebURL)
            && (visit.faviconReference.map(BrowserHistoryFavicon.accepts) ?? true)
            && visit.visitedAt.timeIntervalSince1970.isFinite && visit.typedCount >= 0
    }

    private static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }
    private static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased() }
    private static func searchURL(_ url: URL) -> String {
        BrowserSuggestionText.searchableURL(url)
    }
    static func likeLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}

enum HistoryValue { case text(String), number(Double) }

/// Confined to its owning actor after initialization; never shared between actors.
final class HistoryDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    var changes: Int { Int(sqlite3_changes(handle)) }

    static let currentVersion = 6

    init(openingURL url: URL, flags: Int32) throws {
        // Checked ancestors, single-link database/sidecars, and directory identity before/after open.
        let (result, opened) = OrbitSQLiteGuard.open(url.path, flags: flags)
        handle = opened
        guard result == SQLITE_OK else { sqlite3_close(handle); handle = nil; throw BrowserHistoryError.storageFailure(result) }
        sqlite3_busy_timeout(handle, 2000)
    }

    convenience init(url: URL, profileID: ProfileID) throws {
        try self.init(openingURL: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        do {
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA secure_delete=ON")
            try execute("PRAGMA temp_store=MEMORY")
            let version = try scalarInt("PRAGMA user_version")
            guard (0...Self.currentVersion).contains(version) else { throw BrowserHistoryError.unsupportedVersion }
            let hasIdentity = try scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='identity'") == 1
            if hasIdentity {
                try verifyIdentity(profileID, version: max(1, version))
            } else {
                guard version == 0, try scalarInt("SELECT COUNT(*) FROM sqlite_master") == 0 else {
                    throw BrowserHistoryError.unsupportedVersion
                }
            }
            // journal_mode persists in the file. Merely reopening an up-to-date store is read-only.
            if try scalarText("PRAGMA journal_mode").lowercased() != "wal" { try execute("PRAGMA journal_mode=WAL") }
            let initialVersion = hasIdentity && version == 0 ? 1 : version
            if initialVersion < Self.currentVersion {
                try transaction {
                    var migratingVersion = initialVersion
                    while migratingVersion < Self.currentVersion {
                        switch migratingVersion {
                        case 0: try createVersionOne(profileID)
                        case 1: try migrateToVersionTwo()
                        case 2: try migrateToVersionThree()
                        case 3: try migrateToVersionFour()
                        case 4: try migrateToVersionFive()
                        case 5: try migrateToVersionSix(profileID)
                        default: throw BrowserHistoryError.unsupportedVersion
                        }
                        migratingVersion += 1
                        try execute("UPDATE identity SET version=?", [.number(Double(migratingVersion))])
                        try execute("PRAGMA user_version=\(migratingVersion)")
                    }
                }
            }
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }

    private func verifyIdentity(_ profileID: ProfileID, version: Int) throws {
        let identity = try prepare("SELECT profile,version FROM identity")
        defer { sqlite3_finalize(identity) }
        guard try next(identity) else { throw BrowserHistoryError.unsupportedVersion }
        guard text(identity, 0) == profileID.rawValue.uuidString else { throw BrowserHistoryError.profileMismatch }
        guard Int(sqlite3_column_int(identity, 1)) == version, try !next(identity) else {
            throw BrowserHistoryError.unsupportedVersion
        }
    }

    private func createVersionOne(_ profileID: ProfileID) throws {
        try execute("CREATE TABLE identity(profile TEXT NOT NULL, version INTEGER NOT NULL)")
        try execute("INSERT INTO identity VALUES(?,1)", [.text(profileID.rawValue.uuidString)])
        try execute("CREATE TABLE visits(id TEXT PRIMARY KEY,url TEXT NOT NULL,site TEXT NOT NULL,time REAL NOT NULL,title TEXT NOT NULL,typed INTEGER NOT NULL,payload TEXT NOT NULL,searchTitle TEXT NOT NULL)")
        try execute("CREATE INDEX visits_time ON visits(time DESC)")
        try execute("CREATE INDEX visits_url_time ON visits(url,time DESC)")
        try execute("CREATE INDEX visits_site ON visits(site)")
        try execute("CREATE TABLE pages(url TEXT UNIQUE,title TEXT,favicon TEXT,last REAL,visits INTEGER,typed INTEGER,searchURL TEXT COLLATE NOCASE,searchTitle TEXT COLLATE NOCASE)")
    }

    /// Accepts both the original user_version=0/identity.version=1 document and explicit v1.
    /// Preserves the old row identities and rebuilds external-content FTS atomically.
    private func migrateToVersionTwo() throws {
        for trigger in ["pages_insert", "pages_delete", "pages_update"] { try execute("DROP TRIGGER IF EXISTS \(trigger)") }
        try execute("DROP TABLE IF EXISTS search")
        try execute("ALTER TABLE pages RENAME TO legacy_pages")
        try execute("CREATE TABLE pages(id INTEGER PRIMARY KEY,url TEXT UNIQUE,title TEXT,favicon TEXT,last REAL,visits INTEGER,typed INTEGER,searchURL TEXT COLLATE NOCASE,searchTitle TEXT COLLATE NOCASE)")
        try execute("INSERT INTO pages(id,url,title,favicon,last,visits,typed,searchURL,searchTitle) SELECT rowid,url,title,favicon,last,visits,typed,searchURL,searchTitle FROM legacy_pages")
        try execute("DROP TABLE legacy_pages")
        try execute("CREATE INDEX pages_url_prefix ON pages(searchURL)")
        try execute("CREATE INDEX pages_title_prefix ON pages(searchTitle)")
        try execute("CREATE VIRTUAL TABLE search USING fts5(searchURL,searchTitle,content='pages',content_rowid='id',tokenize='trigram')")
        try execute("INSERT INTO search(search) VALUES('rebuild')")
        try execute("INSERT INTO search(search,rank) VALUES('secure-delete',1)")
        try execute("CREATE TRIGGER pages_insert AFTER INSERT ON pages BEGIN INSERT INTO search(rowid,searchURL,searchTitle) VALUES(new.id,new.searchURL,new.searchTitle); END")
        try execute("CREATE TRIGGER pages_delete AFTER DELETE ON pages BEGIN INSERT INTO search(search,rowid,searchURL,searchTitle) VALUES('delete',old.id,old.searchURL,old.searchTitle); END")
        try execute("CREATE TRIGGER pages_update AFTER UPDATE ON pages BEGIN INSERT INTO search(search,rowid,searchURL,searchTitle) VALUES('delete',old.id,old.searchURL,old.searchTitle); INSERT INTO search(rowid,searchURL,searchTitle) VALUES(new.id,new.searchURL,new.searchTitle); END")
    }

    /// FTS sync on UPDATE fires only when an indexed column really changes (version 5): recording
    /// a visit to a known page updates its counters, which must not re-tokenize both indexes.
    static let searchUpdateTrigger = "CREATE TRIGGER pages_update AFTER UPDATE OF searchURL,searchTitle ON pages WHEN old.searchURL IS NOT new.searchURL COLLATE BINARY OR old.searchTitle IS NOT new.searchTitle COLLATE BINARY BEGIN INSERT INTO search(search,rowid,searchURL,searchTitle) VALUES('delete',old.id,old.searchURL,old.searchTitle); INSERT INTO search(rowid,searchURL,searchTitle) VALUES(new.id,new.searchURL,new.searchTitle); END"
    static let titleWordsUpdateTrigger = "CREATE TRIGGER titleWords_update AFTER UPDATE OF searchTitle ON pages WHEN old.searchTitle IS NOT new.searchTitle COLLATE BINARY BEGIN INSERT INTO titleWords(titleWords,rowid,searchTitle) VALUES('delete',old.id,old.searchTitle); INSERT INTO titleWords(rowid,searchTitle) VALUES(new.id,new.searchTitle); END"

    /// Search normalization changed; preserve visits/IDs and rebuild indexed display columns.
    /// The trigram sync trigger is suspended so changed rows are indexed once by a single rebuild,
    /// and the word index and its triggers are created after normalization.
    private func migrateToVersionThree() throws {
        try execute("DROP TRIGGER IF EXISTS pages_update")
        if try normalizeSearchURLs(where: "1") > 0 { try execute("INSERT INTO search(search) VALUES('rebuild')") }
        try execute(Self.searchUpdateTrigger)
        try execute("CREATE VIRTUAL TABLE titleWords USING fts5(searchTitle,content='pages',content_rowid='id',tokenize='unicode61',prefix='1 2 3')")
        try execute("INSERT INTO titleWords(titleWords) VALUES('rebuild')")
        try execute("INSERT INTO titleWords(titleWords,rank) VALUES('secure-delete',1)")
        try execute("CREATE TRIGGER titleWords_insert AFTER INSERT ON pages BEGIN INSERT INTO titleWords(rowid,searchTitle) VALUES(new.id,new.searchTitle); END")
        try execute("CREATE TRIGGER titleWords_delete AFTER DELETE ON pages BEGIN INSERT INTO titleWords(titleWords,rowid,searchTitle) VALUES('delete',old.id,old.searchTitle); END")
        try execute(Self.titleWordsUpdateTrigger)
    }

    /// Version three indexed the display form of URLs: Cc, bidi and other format scalars (ZWNJ,
    /// ZWJ, soft hyphen, ZWSP, BOM) were stored as literal `\u{xxxx}` escapes, so those pages
    /// could not be found by their real text. Only rows carrying that marker can differ from the
    /// unescaped normalization; every other row is skipped without recomputation. Only searchURL
    /// changes, so the title word index is untouched and both update triggers are suspended.
    private func migrateToVersionFour() throws {
        for trigger in ["pages_update", "titleWords_update"] { try execute("DROP TRIGGER IF EXISTS \(trigger)") }
        if try normalizeSearchURLs(where: "instr(searchURL,'\\u{')>0") > 0 {
            try execute("INSERT INTO search(search) VALUES('rebuild')")
        }
        try execute(Self.searchUpdateTrigger)
        try execute(Self.titleWordsUpdateTrigger)
    }

    /// Versions 2–4 re-tokenized both FTS rows (with secure-delete rewrites) on every page update,
    /// including the counter updates of each visit to a known page: importing 1M synthetic visits
    /// over 20 000 pages ran at about 460 visits/s (IMPORT-R2 measurement). Only the update triggers
    /// change; both indexes stay valid and are not rebuilt.
    private func migrateToVersionFive() throws {
        for trigger in ["pages_update", "titleWords_update"] { try execute("DROP TRIGGER IF EXISTS \(trigger)") }
        try execute(Self.searchUpdateTrigger)
        try execute(Self.titleWordsUpdateTrigger)
    }

    /// Rewrites `searchURL` with the current normalization in bounded id-ordered batches through
    /// one prepared SELECT and UPDATE; unchanged rows are skipped. Returns the number of rewrites.
    /// Callers suspend FTS update triggers and rebuild once when the result is non-zero.
    private func normalizeSearchURLs(where filter: String) throws -> Int {
        let select = try prepare("SELECT id,url,searchURL FROM pages WHERE id>? AND (\(filter)) ORDER BY id LIMIT ?")
        defer { sqlite3_finalize(select) }
        let update = try prepare("UPDATE pages SET searchURL=? WHERE id=?")
        defer { sqlite3_finalize(update) }
        var lastID: Int64 = .min
        var changed = 0
        var batch: [(Int64, String)] = []
        repeat {
            batch.removeAll(keepingCapacity: true)
            sqlite3_reset(select)
            sqlite3_bind_int64(select, 1, lastID)
            sqlite3_bind_int64(select, 2, Int64(Self.migrationBatch))
            var rows = 0
            while try next(select) {
                rows += 1
                lastID = sqlite3_column_int64(select, 0)
                guard let url = URL(string: text(select, 1)) else { continue }
                let normalized = BrowserSuggestionText.searchableURL(url)
                if normalized != text(select, 2) { batch.append((lastID, normalized)) }
            }
            sqlite3_reset(select)
            for (id, normalized) in batch {
                sqlite3_reset(update)
                try bind(update, [.text(normalized)])
                sqlite3_bind_int64(update, 2, id)
                try step(update)
            }
            changed += batch.count
            if rows < Self.migrationBatch { break }
        } while true
        return changed
    }

    private func migrateToVersionSix(_ profileID: ProfileID) throws {
        try execute("CREATE TABLE historySyncEvents(id TEXT PRIMARY KEY,payload TEXT NOT NULL,expires REAL NOT NULL,kind INTEGER NOT NULL,batch TEXT)")
        try execute("CREATE INDEX historySyncPending ON historySyncEvents(batch)")
        try execute("CREATE INDEX historySyncDeletions ON historySyncEvents(kind)")
        try execute("CREATE TABLE historySyncBatches(id TEXT PRIMARY KEY,payload TEXT NOT NULL,expires REAL NOT NULL)")
        try execute("CREATE TABLE historySyncState(cutoff REAL NOT NULL)")
        try execute("INSERT INTO historySyncState VALUES(?)", [.number(Date.distantPast.timeIntervalSince1970)])
        try execute("CREATE TABLE historySyncVersions(id TEXT PRIMARY KEY,time REAL NOT NULL,event TEXT NOT NULL)")
        let rows = try prepare("SELECT payload FROM visits WHERE time>=?")
        try bind(rows, [.number(BrowserHistorySyncSchema.cutoff(Date()).timeIntervalSince1970)])
        defer { sqlite3_finalize(rows) }
        while try next(rows) {
            let visit = try JSONDecoder().decode(BrowserHistoryVisit.self, from: Data(text(rows, 0).utf8))
            let event = BrowserHistorySyncEvent(visit: visit)
            try execute("INSERT INTO historySyncEvents(id,payload,expires,kind) VALUES(?,?,?,0)",
                [.text(event.id.uuidString), .text(String(decoding: try BrowserSyncReplica.encodeValue(event), as: UTF8.self)),
                 .number(event.expires.timeIntervalSince1970)])
            try execute("INSERT INTO historySyncVersions VALUES(?,?,?)", [.text(visit.id.uuidString),
                .number(event.time.timeIntervalSince1970), .text(event.id.uuidString)])
        }
    }

    static let migrationBatch = 2048

    func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard try next(statement) else { throw BrowserHistoryError.storageFailure(SQLITE_ERROR) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func scalarText(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard try next(statement) else { throw BrowserHistoryError.storageFailure(SQLITE_ERROR) }
        return text(statement, 0)
    }

    func checkpoint() -> BrowserHistoryMaintenanceStatus {
        guard let handle else { return .checkpointDeferred(SQLITE_MISUSE) }
        let result = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        return result == SQLITE_OK ? .complete : .checkpointDeferred(result)
    }
    deinit { sqlite3_close(handle) }
    /// Thread-safe while the connection is open; callers guarantee it cannot close concurrently.
    func interrupt() { if let handle { sqlite3_interrupt(handle) } }
    func withHandle<T>(_ body: (OpaquePointer?) -> T) -> T { body(handle) }
    func close() throws {
        guard let handle else { return }
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else { throw BrowserHistoryError.storageFailure(result) }
        self.handle = nil
    }
    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw BrowserHistoryError.closed }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw BrowserHistoryError.storageFailure(result) }
        return statement
    }
    func bind(_ statement: OpaquePointer, _ values: [HistoryValue]) throws {
        for (index, value) in values.enumerated() {
            let result: Int32
            switch value {
            case .text(let text): result = text.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .number(let number): result = sqlite3_bind_double(statement, Int32(index + 1), number)
            }
            guard result == SQLITE_OK else { throw BrowserHistoryError.storageFailure(result) }
        }
    }
    func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw BrowserHistoryError.storageFailure(result) }
    }
    func next(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw BrowserHistoryError.storageFailure(result) }
        return result == SQLITE_ROW
    }
    func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
    func execute(_ sql: String, _ values: [HistoryValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, values)
        try step(statement)
    }
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        if withHandle({ sqlite3_get_autocommit($0) == 0 }) { return try operation() }
        try execute("BEGIN IMMEDIATE")
        do { let value = try operation(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
}

extension BrowserHistoryStore {
    /// One object of `sqlite_master`.
    struct SchemaObject: Hashable { let type: String; let name: String; let table: String; let sql: String? }

    /// The exact schema this build creates, read from a fresh store in a private temporary folder
    /// (the same migration path every store follows), computed once.
    static let expectedSchema: Set<SchemaObject>? = {
        // Canonicalize only the system-owned temporary root: macOS commonly supplies /var,
        // an alias of /private/var. User-supplied history paths must still refuse all symlinks.
        guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else { return nil }
        defer { free(canonical) }
        var template = Array((String(cString: canonical) + "/orbit-history-schema-XXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else { return nil }
        let folder = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let database = try? HistoryDatabase(url: folder.appendingPathComponent("history.sqlite"), profileID: ProfileID()) else { return nil }
        defer { try? database.close() }
        return database.withHandle { $0.flatMap(schema(of:)) }
    }()

    static func schema(of handle: OpaquePointer) -> Set<SchemaObject>? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT type,name,tbl_name,sql FROM sqlite_master", -1, &statement, nil) == SQLITE_OK else { return nil }
        var result: Set<SchemaObject> = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { return nil }
            func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
            result.insert(SchemaObject(type: text(0) ?? "", name: text(1) ?? "", table: text(2) ?? "", sql: text(3)))
        }
    }

    /// Read-only validation of a history database copy before it replaces a live one (restore),
    /// opened through its checked folder: integrity; exactly one identity row naming `profileID`;
    /// the current schema version, consistent with the identity; every table, virtual table
    /// (FTS5 module, columns, tokenizer), shadow table, index and trigger of that version with
    /// exactly the SQL this build creates (IMPORT-R4 #D); no extra trigger or view; and both
    /// full-text indexes answering a query. Never migrates.
    /// `exactSchema: false` (when a backup is taken) checks integrity, identity and a supported
    /// version only; restores migrate a staged copy to the current version and then require the
    /// exact schema, so a backup from an older build stays restorable.
    static func isValidBackup(in directory: OrbitSecureDirectory, profileID: ProfileID, exactSchema: Bool = true,
                              writable: Bool = false) -> Bool {
        guard let expected = expectedSchema, let path = try? directory.verifiedPath("history.sqlite"),
              let pin = try? OrbitSQLiteGuard.pin(directory) else { return false }
        defer { pin.release() }
        let (opened, handle) = OrbitSQLiteGuard.open(path, flags: writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY)
        guard opened == SQLITE_OK, let handle else { sqlite3_close(handle); return false }
        defer { sqlite3_close(handle) }
        if writable { sqlite3_exec(handle, "PRAGMA query_only=ON", nil, nil, nil) }
        func rows(_ sql: String) -> [[String]]? {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            var result: [[String]] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { return nil }
                result.append((0..<sqlite3_column_count(statement)).map { column in
                    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
                })
            }
        }
        guard rows("PRAGMA quick_check") == [["ok"]],
              let version = rows("PRAGMA user_version")?.first?.first.flatMap(Int.init), (1...HistoryDatabase.currentVersion).contains(version),
              let identity = rows("SELECT profile, version FROM identity"), identity.count == 1,
              identity[0][0] == profileID.rawValue.uuidString, Int(identity[0][1]) == version else { return false }
        guard exactSchema else { return true }
        guard version == HistoryDatabase.currentVersion, let actual = schema(of: handle), expected.isSubset(of: actual) else { return false }
        // Extra plain tables or indexes are inert; an extra trigger or view would run code.
        let expectedNames = Set(expected.map(\.name))
        guard actual.subtracting(expected).allSatisfy({ ($0.type == "table" || $0.type == "index") && !expectedNames.contains($0.name) }) else {
            return false
        }
        return rows("SELECT count(*) FROM search WHERE search MATCH 'orbit'") != nil
            && rows("SELECT count(*) FROM titleWords WHERE titleWords MATCH 'orbit'") != nil
    }
}
