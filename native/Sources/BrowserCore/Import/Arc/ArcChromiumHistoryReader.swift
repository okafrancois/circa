import Foundation
import SQLite3

/// Visits read from one Chromium `History` database and why the others were left out. Counts only.
public struct ArcHistoryScanCounts: Codable, Equatable, Sendable {
    public var rows = 0
    public var importable = 0
    /// Non-HTTP(S) schemes, missing hosts or unparsable URLs (internal pages, files, data URLs).
    public var nonWebURLs = 0
    public var credentialURLs = 0
    public var oversizedURLs = 0
    /// Subframe navigations and URLs Chromium marks hidden: not shown in Chrome's history either.
    public var subframesOrHidden = 0
    public var invalidTimes = 0
    /// URL and title bytes of the importable visits, for the disk estimate (IMPORT-R3 #3).
    public var importableTextBytes: Int64 = 0

    public init() {}

    public mutating func add(_ other: ArcHistoryScanCounts) {
        rows += other.rows
        importable += other.importable
        nonWebURLs += other.nonWebURLs
        credentialURLs += other.credentialURLs
        oversizedURLs += other.oversizedURLs
        subframesOrHidden += other.subframesOrHidden
        invalidTimes += other.invalidTimes
        importableTextBytes += other.importableTextBytes
    }
}

/// Reads Chromium's History schema (`urls`, `visits`; observed in the Electron-era import of
/// 23 October 2026, columns detected at run time) from the importer's **private snapshot copy**,
/// never from Arc's live file. Keyset pagination by visit id: each chunk is an independent query,
/// so no statement survives between chunks. SQLite messages, URLs and titles never leave this type.
public final class ArcChromiumHistoryReader {
    /// Microseconds from 1601-01-01 to 1970-01-01.
    static let chromeEpochOffset: Double = 11_644_473_600
    static let maximumURLBytes = 4096
    static let maximumTitleLength = 1024

    private var handle: OpaquePointer?
    /// Retains the private snapshot folder identity for checked-path opens (IMPORT-R5).
    private let pin: OrbitSQLiteGuard.Pin
    private let directory: String
    private let identity: ArcImportIdentity
    private let hasTransition: Bool
    private let hasHidden: Bool
    private var lastVisitID: Int64 = 0
    public private(set) var counts = ArcHistoryScanCounts()
    public let totalVisits: Int

    /// - Parameter directory: the Arc profile directory name, part of each visit's stable identity.
    public init(snapshotFile: URL, directory: String, identity: ArcImportIdentity) throws {
        self.directory = directory
        self.identity = identity
        // The private copy is opened after verifying its directory chain and single-link files;
        // read-write lets SQLite roll back a hot journal left by a crash.
        let folder: OrbitSecureDirectory
        let path: String
        do {
            folder = try OrbitSecureDirectory.open(snapshotFile.deletingLastPathComponent(), create: false)
            path = try folder.verifiedPath(snapshotFile.lastPathComponent)
            pin = try OrbitSQLiteGuard.pin(folder)
        } catch { throw ArcImportError.historyDatabaseUnreadable }
        let (opened, handle) = OrbitSQLiteGuard.open(path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX)
        guard opened == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            pin.release()
            throw ArcImportError.historyDatabaseUnreadable
        }
        do {
            for pragma in ["PRAGMA trusted_schema=OFF", "PRAGMA query_only=ON"] {
                guard sqlite3_exec(handle, pragma, nil, nil, nil) == SQLITE_OK else { throw ArcImportError.historyDatabaseUnreadable }
            }
            let tables = try Self.strings(handle, "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('urls','visits')")
            let visitColumns = Set(try Self.strings(handle, "SELECT name FROM pragma_table_info('visits')"))
            let urlColumns = Set(try Self.strings(handle, "SELECT name FROM pragma_table_info('urls')"))
            guard Set(tables) == ["urls", "visits"], visitColumns.isSuperset(of: ["id", "url", "visit_time"]),
                  urlColumns.isSuperset(of: ["id", "url", "title"]) else {
                throw ArcImportError.historyDatabaseUnreadable
            }
            hasTransition = visitColumns.contains("transition")
            hasHidden = urlColumns.contains("hidden")
            totalVisits = try Self.integer(handle, "SELECT count(*) FROM visits")
        } catch {
            sqlite3_close(handle)
            pin.release()
            throw ArcImportError.historyDatabaseUnreadable
        }
        self.handle = handle
    }

    deinit { sqlite3_close(handle); pin.release() }

    public func close() {
        sqlite3_close(handle)
        handle = nil
        pin.release()
    }

    /// The next chunk of importable visits in visit-id order, or nil at the end. A chunk may be
    /// empty when every row in its window was filtered.
    public func nextChunk(size: Int) throws -> [BrowserHistoryVisit]? {
        guard let handle else { throw ArcImportError.historyDatabaseUnreadable }
        let sql = """
            SELECT v.id, v.visit_time, \(hasTransition ? "v.transition" : "0"), u.url, u.title, \(hasHidden ? "u.hidden" : "0")
            FROM visits v JOIN urls u ON v.url = u.id WHERE v.id > ? ORDER BY v.id LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ArcImportError.historyDatabaseUnreadable
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, lastVisitID)
        sqlite3_bind_int64(statement, 2, Int64(max(1, size)))
        var visits: [BrowserHistoryVisit] = []
        var rows = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw ArcImportError.historyDatabaseUnreadable }
            rows += 1
            let visitID = sqlite3_column_int64(statement, 0)
            lastVisitID = visitID
            counts.rows += 1
            if let visit = visit(id: visitID, time: sqlite3_column_int64(statement, 1),
                                 transition: UInt32(truncatingIfNeeded: sqlite3_column_int64(statement, 2)),
                                 url: Self.text(statement, 3), title: Self.text(statement, 4),
                                 hidden: sqlite3_column_int64(statement, 5) != 0) {
                visits.append(visit)
                counts.importable += 1
                counts.importableTextBytes += Int64(visit.url.absoluteString.utf8.count + visit.title.utf8.count)
            }
        }
        return rows == 0 ? nil : visits
    }

    private func visit(id: Int64, time: Int64, transition: UInt32, url text: String, title: String,
                       hidden: Bool) -> BrowserHistoryVisit? {
        let core = transition & 0xFF
        // Chromium page transitions: 3 AUTO_SUBFRAME, 4 MANUAL_SUBFRAME (Chromium ui/base/page_transition_types.h).
        if hidden || core == 3 || core == 4 { counts.subframesOrHidden += 1; return nil }
        guard text.utf8.count <= Self.maximumURLBytes else { counts.oversizedURLs += 1; return nil }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { counts.nonWebURLs += 1; return nil }
        guard url.user == nil, url.password == nil else { counts.credentialURLs += 1; return nil }
        let seconds = Double(time) / 1_000_000 - Self.chromeEpochOffset
        guard time > 0, seconds.isFinite, seconds > 0, seconds < 4_102_444_800 else { counts.invalidTimes += 1; return nil }
        let kind: BrowserHistoryTransition
        if transition & 0x0100_0000 != 0 { kind = .backForward }        // FORWARD_BACK qualifier
        else if core == 8 { kind = .reload }                             // RELOAD
        else if core == 1 { kind = .typed }                              // TYPED
        else if transition & 0xC000_0000 != 0 { kind = .redirect }       // CLIENT/SERVER_REDIRECT qualifiers
        else { kind = .link }
        let cleanTitle = BrowserOrganizationState.sanitizedPageTitle(title).map { String($0.prefix(Self.maximumTitleLength)) } ?? ""
        let visit = BrowserHistoryVisit(id: identity.uuid("visit", [directory, String(id), String(time), text]),
                                        url: url, title: cleanTitle, visitedAt: Date(timeIntervalSince1970: seconds),
                                        transition: kind, typedCount: core == 1 ? 1 : 0)
        guard BrowserHistoryStore.accepts(visit) else { counts.nonWebURLs += 1; return nil }
        return visit
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    private static func strings(_ handle: OpaquePointer, _ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ArcImportError.historyDatabaseUnreadable
        }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(text(statement, 0)) }
        return result
    }

    private static func integer(_ handle: OpaquePointer, _ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement,
              sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            throw ArcImportError.historyDatabaseUnreadable
        }
        defer { sqlite3_finalize(statement) }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
