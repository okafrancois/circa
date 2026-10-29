import CryptoKit
import Foundation
import SQLite3

/// Normalizes v23/v24 into a fresh v24 database. Partition/origin fields are copied exactly.
/// Version 23 already has the ancestor bit; older partition formats require a separate converter.
public enum ChromiumCookieImport {
    static let columns = ["creation_utc", "host_key", "top_frame_site_key", "name", "value", "encrypted_value", "path",
        "expires_utc", "is_secure", "is_httponly", "last_access_utc", "has_expires", "is_persistent", "priority", "samesite",
        "source_scheme", "source_port", "last_update_utc", "source_type", "has_cross_site_ancestor"]
    static let texts = Set(["host_key", "top_frame_site_key", "name", "value", "path"])
    public static func convert(snapshotFile: URL, destination: URL, sourceKey: Data, targetKey: Data, now: Date = Date()) throws -> Int {
        let source = try AuthenticationSQLite(snapshotFile)
        let version = try source.version(maximum: 24, minimum: 23)
        guard Set(columns).isSubset(of: try source.columns("cookies")), !FileManager.default.fileExists(atPath: destination.path) else {
            throw BrowserAuthenticationImportError.schema
        }
        let target = try AuthenticationSQLite(destination)
        try target.execute("CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY,value LONGVARCHAR); INSERT INTO meta VALUES('version','24'),('last_compatible_version','24')")
        try target.execute("CREATE TABLE cookies(" + columns.map { $0 + (texts.contains($0) ? " TEXT" : $0 == "encrypted_value" ? " BLOB" : " INTEGER") + " NOT NULL" }.joined(separator: ",") + ")")
        try target.execute("CREATE UNIQUE INDEX cookies_unique_index ON cookies(host_key,top_frame_site_key,has_cross_site_ancestor,name,path,source_scheme,source_port)")
        try target.execute("BEGIN IMMEDIATE")
        do {
            let row = try source.statement("SELECT " + columns.joined(separator: ",") + " FROM cookies WHERE has_expires=0 OR expires_utc>\(Int64((now.timeIntervalSince1970 + 11_644_473_600) * 1_000_000))")
            defer { sqlite3_finalize(row) }
            let insert = try target.statement("INSERT INTO cookies VALUES(" + columns.map { _ in "?" }.joined(separator: ",") + ")")
            defer { sqlite3_finalize(insert) }
            var count = 0, step = sqlite3_step(row)
            while step == SQLITE_ROW {
                guard count < 1_000_000 else { throw BrowserAuthenticationImportError.invalidRecord }
                let host = try AuthenticationSQLite.text(row, 1)
                guard !host.isEmpty, try AuthenticationSQLite.text(row, 6).hasPrefix("/"),
                      [8, 9, 11, 12, 19].allSatisfy({ (0...1).contains(sqlite3_column_int(row, Int32($0))) }),
                      (0...2).contains(sqlite3_column_int(row, 13)), (-1...2).contains(sqlite3_column_int(row, 14)),
                      (0...2).contains(sqlite3_column_int(row, 15)), (-1...65535).contains(sqlite3_column_int(row, 16)),
                      (0...3).contains(sqlite3_column_int(row, 18)) else { throw BrowserAuthenticationImportError.invalidRecord }
                let hash = Data(SHA256.hash(data: Data(host.utf8)))
                let encrypted = AuthenticationSQLite.bytes(row, 5)
                var clear: Data
                if encrypted.isEmpty { clear = hash + AuthenticationSQLite.bytes(row, 4) }
                else {
                    clear = try ArcChromiumCookieCipher.decrypt(encrypted, key: sourceKey)
                    if version == 24 {
                        guard clear.prefix(32) == hash else { throw ArcAuthenticationError.hostHashMismatch }
                    } else { clear = hash + clear }
                }
                defer { clear.resetBytes(in: 0..<clear.count) }
                let converted = try ArcChromiumCookieCipher.encrypt(clear, key: targetKey)
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                for column in columns.indices {
                    if column == 5 { try AuthenticationSQLite.bind(converted, to: insert, at: 6) }
                    else if column == 4 { sqlite3_bind_text(insert, 5, "", 0, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                    else if sqlite3_bind_value(insert, Int32(column + 1), sqlite3_column_value(row, Int32(column))) != SQLITE_OK {
                        throw BrowserAuthenticationImportError.database
                    }
                }
                guard sqlite3_step(insert) == SQLITE_DONE else { throw BrowserAuthenticationImportError.database }
                count += 1; step = sqlite3_step(row)
            }
            guard step == SQLITE_DONE else { throw BrowserAuthenticationImportError.database }
            try target.execute("COMMIT")
            return count
        } catch { try? target.execute("ROLLBACK"); throw error }
    }
}
