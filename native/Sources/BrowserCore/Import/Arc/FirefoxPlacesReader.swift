import Foundation
import SQLite3

/// These handles only open private snapshots; query_only still permits hot-journal recovery.
enum FirefoxPlacesReader {
    static func database(_ file: URL) throws -> AuthenticationSQLite {
        let db = try AuthenticationSQLite(file)
        try db.execute("PRAGMA trusted_schema=OFF; PRAGMA query_only=ON")
        return db
    }
    static func integer(_ db: AuthenticationSQLite, _ sql: String) throws -> Int {
        let row = try db.statement(sql); defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW else { throw ArcImportError.historyDatabaseUnreadable }
        return Int(sqlite3_column_int64(row, 0))
    }
    static func count(_ file: URL, table: String) throws -> Int { try integer(database(file), "SELECT count(*) FROM " + table) }
    static func bookmarks(file: URL, identity: ArcImportIdentity, importedAt: Date, counts: inout [String: Int]) throws -> [BrowserImportPlan.Node] {
        let db = try database(file)
        let row = try db.statement("SELECT b.id,b.parent,b.type,b.guid,b.title,b.dateAdded,p.url FROM moz_bookmarks b LEFT JOIN moz_places p ON b.fk=p.id ORDER BY b.parent,b.position,b.id")
        defer { sqlite3_finalize(row) }
        struct Record { let id: Int64; let type: Int; let guid: String; let title: String; let date: Date; let url: String }
        var children: [Int64: [Record]] = [:], roots: [String: Record] = [:], total = 0
        var step = sqlite3_step(row)
        while step == SQLITE_ROW {
            total += 1; guard total <= 100_000 else { throw ArcImportError.unsupportedSourceFile }
            let micros = sqlite3_column_int64(row, 5), seconds = Double(micros) / 1_000_000
            let value = try Record(id: sqlite3_column_int64(row, 0), type: Int(sqlite3_column_int(row, 2)),
                guid: AuthenticationSQLite.text(row, 3), title: AuthenticationSQLite.text(row, 4),
                date: seconds > 0 && seconds < 4_102_444_800 ? Date(timeIntervalSince1970: seconds) : importedAt,
                url: AuthenticationSQLite.text(row, 6))
            children[sqlite3_column_int64(row, 1), default: []].append(value)
            roots[value.guid] = value; step = sqlite3_step(row)
        }
        guard step == SQLITE_DONE else { throw ArcImportError.historyDatabaseUnreadable }
        var seen = Set<Int64>()
        func node(_ record: Record, depth: Int) throws -> BrowserImportPlan.Node? {
            guard depth <= 64, seen.insert(record.id).inserted else { throw ArcImportError.unreadableSourceDocument }
            let key = record.guid.isEmpty ? String(record.id) : record.guid
            if record.type == 3 { counts["bookmarkSeparators", default: 0] += 1; return nil }
            if record.type == 1 {
                guard let url = ChromiumBookmarkReader.safeURL(record.url) else { counts["unsupportedBookmarks", default: 0] += 1; return nil }
                return .tab(.init(id: identity.tab("bookmark:" + key), url: url,
                    pageTitle: BrowserOrganizationState.sanitizedPageTitle(record.title), pinnedURL: url, createdAt: record.date, lastActiveAt: importedAt))
            }
            guard record.type == 2 else { counts["unsupportedBookmarks", default: 0] += 1; return nil }
            return .folder(.init(id: identity.folder("bookmark:" + key), title: record.title, isCollapsed: false, children: [], createdAt: record.date),
                try (children[record.id] ?? []).compactMap { try node($0, depth: depth + 1) })
        }
        return try ["toolbar_____", "menu________", "unfiled_____", "mobile______"].compactMap { guid in
            try roots[guid].flatMap { try node($0, depth: 0) }
        }
    }
}

public final class FirefoxHistoryReader: BrowserImportHistoryReader {
    private let db: AuthenticationSQLite
    private let row: OpaquePointer
    private let directory: String
    private let identity: ArcImportIdentity
    private var finished = false
    public private(set) var counts = ArcHistoryScanCounts()
    public let totalVisits: Int
    init(file: URL, directory: String, identity: ArcImportIdentity) throws {
        self.directory = directory; self.identity = identity
        db = try FirefoxPlacesReader.database(file)
        totalVisits = try FirefoxPlacesReader.integer(db, "SELECT count(*) FROM moz_historyvisits")
        row = try db.statement("SELECT v.id,v.visit_date,v.visit_type,p.url,p.title,p.typed FROM moz_historyvisits v JOIN moz_places p ON p.id=v.place_id ORDER BY v.id")
    }
    deinit { sqlite3_finalize(row) }
    public func nextChunk(size: Int) throws -> [BrowserHistoryVisit]? {
        if finished { return nil }
        var visits: [BrowserHistoryVisit] = [], rows = 0
        while rows < max(1, size) {
            let step = sqlite3_step(row)
            if step == SQLITE_DONE { finished = true; break }
            guard step == SQLITE_ROW else { throw ArcImportError.historyDatabaseUnreadable }
            counts.rows += 1; rows += 1
            let type = sqlite3_column_int(row, 2)
            // Embed/framed/download visits are not document navigations. The place-level typed
            // bit is aggregate evidence, not a dated typed visit; only type=2 adds a typed count.
            if ![1, 2, 3, 5, 6, 9].contains(type) { counts.subframesOrHidden += 1; continue }
            let text = try AuthenticationSQLite.text(row, 3)
            guard text.utf8.count <= 4096 else { counts.oversizedURLs += 1; continue }
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { counts.nonWebURLs += 1; continue }
            guard url.user == nil, url.password == nil else { counts.credentialURLs += 1; continue }
            let time = sqlite3_column_int64(row, 1), seconds = Double(time) / 1_000_000
            guard seconds > 0 && seconds < 4_102_444_800 else { counts.invalidTimes += 1; continue }
            let title = String((BrowserOrganizationState.sanitizedPageTitle(try AuthenticationSQLite.text(row, 4)) ?? "").prefix(1024))
            let transition: BrowserHistoryTransition = type == 2 ? .typed : type == 9 ? .reload : [5, 6].contains(type) ? .redirect : .link
            let visit = BrowserHistoryVisit(id: identity.uuid("visit", [directory, String(sqlite3_column_int64(row, 0)), String(time), text]),
                url: url, title: title, visitedAt: Date(timeIntervalSince1970: seconds), transition: transition, typedCount: type == 2 ? 1 : 0)
            guard BrowserHistoryStore.accepts(visit) else { counts.nonWebURLs += 1; continue }
            visits.append(visit); counts.importable += 1
            counts.importableTextBytes += Int64(text.utf8.count + title.utf8.count)
        }
        return rows == 0 ? nil : visits
    }
}
