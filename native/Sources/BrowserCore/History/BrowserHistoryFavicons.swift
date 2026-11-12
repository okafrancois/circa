import Foundation
import CryptoKit
import SQLite3

extension BrowserHistoryFavicon {
    /// Profile-local content address. Never sent to another client or fetched over a network.
    public static func isStoredReference(_ url: URL) -> Bool { url.scheme == "orbit-favicon" }
}

extension BrowserHistoryStore {
    public func resolveFavicon(_ reference: URL) throws -> URL? {
        try database?.resolveFavicon(reference)
    }
}

extension HistoryDatabase {
    func storeFavicon(_ reference: URL?) throws -> URL? {
        guard let reference else { return nil }
        if BrowserHistoryFavicon.isStoredReference(reference) { return reference }
        let value = reference.absoluteString
        let hash = faviconAddresses.value(for: reference).map { String($0.absoluteString.dropFirst("orbit-favicon:".count)) } ?? SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        try execute("INSERT OR IGNORE INTO favicons(hash,payload) VALUES(?,?)", [.text(hash), .text(value)])
        let stored = URL(string: "orbit-favicon:" + hash)!
        faviconAddresses.insert(stored, for: reference, cost: value.utf8.count + 256)
        return stored
    }

    func resolveFavicon(_ reference: URL?) throws -> URL? {
        guard let reference, BrowserHistoryFavicon.isStoredReference(reference) else { return reference }
        let rows = try prepare("SELECT payload FROM favicons WHERE hash=?")
        defer { sqlite3_finalize(rows) }
        try bind(rows, [.text(String(reference.absoluteString.dropFirst("orbit-favicon:".count)))])
        return try next(rows) ? URL(string: text(rows, 0)) : nil
    }

    /// SQLite backup includes committed WAL frames; a plain file copy would not.
    func backupBeforeMigration(to url: URL) throws {
        let destination = try HistoryDatabase(openingURL: url, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        defer { try? destination.close() }
        try withHandle { source in
            try destination.withHandle { target in
                guard let backup = sqlite3_backup_init(target, "main", source, "main") else {
                    throw BrowserHistoryError.storageFailure(SQLITE_IOERR)
                }
                let result = sqlite3_backup_step(backup, -1)
                let finish = sqlite3_backup_finish(backup)
                guard result == SQLITE_DONE, finish == SQLITE_OK else {
                    throw BrowserHistoryError.storageFailure(result == SQLITE_DONE ? finish : result)
                }
            }
        }
    }

    /// One transaction owns schema and content changes. Bounded keyset reads avoid retaining
    /// 100k decoded visits and allow a failed/interrupted migration to restart safely.
    func migrateToVersionEight() throws {
        try execute("CREATE TABLE IF NOT EXISTS favicons(hash TEXT PRIMARY KEY,payload TEXT NOT NULL)")
        var last: Int64 = 0
        while true {
            let rows = try prepare("SELECT rowid,payload FROM visits WHERE rowid>? ORDER BY rowid LIMIT 512")
            var batch: [(Int64, BrowserHistoryVisit)] = []
            do {
                defer { sqlite3_finalize(rows) }
                sqlite3_bind_int64(rows, 1, last)
                while try next(rows) {
                    batch.append((sqlite3_column_int64(rows, 0), try JSONDecoder().decode(BrowserHistoryVisit.self, from: Data(text(rows, 1).utf8))))
                }
            }
            guard !batch.isEmpty else { break }
            for (id, var visit) in batch {
                visit.faviconReference = try storeFavicon(visit.faviconReference)
                try execute("UPDATE visits SET payload=? WHERE rowid=?", [.text(String(decoding: try JSONEncoder().encode(visit), as: UTF8.self)), .number(Double(id))])
                last = id
            }
        }
        // Page icons can differ from the latest visit in older databases.
        var pageID: Int64 = 0
        while true {
            let rows = try prepare("SELECT id,favicon FROM pages WHERE id>? ORDER BY id LIMIT 512")
            var batch: [(Int64, String)] = []
            do {
                defer { sqlite3_finalize(rows) }
                sqlite3_bind_int64(rows, 1, pageID)
                while try next(rows) { batch.append((sqlite3_column_int64(rows, 0), text(rows, 1))) }
            }
            guard !batch.isEmpty else { break }
            for (id, value) in batch {
                let reference = value.isEmpty ? nil : try storeFavicon(URL(string: value))
                try execute("UPDATE pages SET favicon=? WHERE id=?", [.text(reference?.absoluteString ?? ""), .number(Double(id))])
                pageID = id
            }
        }
    }

    /// Only top-level routine writes may reduce durability. Deletions and nested sync apply
    /// keep the owning transaction's FULL setting. WAL is verified before every switch.
    func routineTransaction<T>(_ operation: () throws -> T) throws -> T {
        guard withHandle({ sqlite3_get_autocommit($0) != 0 }),
              try scalarText("PRAGMA journal_mode").lowercased() == "wal" else { return try transaction(operation) }
        try execute("PRAGMA synchronous=NORMAL")
        defer { try? execute("PRAGMA synchronous=FULL") }
        return try transaction(operation)
    }
}
