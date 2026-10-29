import CryptoKit
import Foundation
import SQLite3

/// Schema 10–14 carries rawSameSite, 15 removes it, 16 changes expiry to milliseconds,
/// and 17 adds updateTime. Every nonempty origin-attribute suffix is rejected: no container,
/// private-browsing or partition jar can collapse into the ordinary target profile.
enum FirefoxCookieImport {
    static func inspect(file: URL) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        try rows(file: file, counts: &counts) { _ in }
        return counts
    }
    static func rows(file: URL, counts: inout [String: Int], consume: ([String: Any]) throws -> Void) throws {
        let db = try FirefoxPlacesReader.database(file)
        let version = try FirefoxPlacesReader.integer(db, "PRAGMA user_version")
        guard (10...17).contains(version) else { throw BrowserAuthenticationImportError.schema }
        let raw = version < 15 ? "rawSameSite" : "sameSite"
        let partition = version >= 13 ? "isPartitionedAttributeSet" : "0"
        let update = version >= 17 ? "updateTime" : "creationTime"
        let row = try db.statement("SELECT host,path,name,value,expiry,isSecure,isHttpOnly,originAttributes,sameSite,\(raw),creationTime,lastAccessed,\(update),\(partition) FROM moz_cookies ORDER BY id")
        defer { sqlite3_finalize(row) }
        var total = 0, step = sqlite3_step(row)
        while step == SQLITE_ROW {
            total += 1; guard total <= 1_000_000 else { throw BrowserAuthenticationImportError.invalidRecord }
            defer { step = sqlite3_step(row) }
            let attributes = try AuthenticationSQLite.text(row, 7)
            guard attributes.isEmpty, sqlite3_column_int(row, 13) == 0 else {
                counts[attributes.contains("userContextId=") ? "containerCookies" : "partitionedOrIsolatedCookies", default: 0] += 1; continue
            }
            let host = try AuthenticationSQLite.text(row, 0), path = try AuthenticationSQLite.text(row, 1)
            let name = try AuthenticationSQLite.text(row, 2), value = try AuthenticationSQLite.text(row, 3)
            let plainHost = host.hasPrefix(".") ? String(host.dropFirst()) : host
            guard !plainHost.isEmpty, plainHost.utf8.count <= 253, !host.contains(where: { $0.isWhitespace || "/:@?#\\".contains($0) }),
                  path.hasPrefix("/"), path.utf8.count <= 4096, name.utf8.count + value.utf8.count <= 4096,
                  ![host, path, name, value].contains(where: { $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
                  (0...1).contains(sqlite3_column_int(row, 5)), (0...1).contains(sqlite3_column_int(row, 6)) else {
                throw BrowserAuthenticationImportError.invalidRecord
            }
            var sameSite = sqlite3_column_int(row, 8)
            if version < 15 && sameSite == 1 && sqlite3_column_int(row, 9) == 0 { sameSite = 3 }
            // Gecko NONE/LAX/STRICT/UNSET -> Chromium NO_RESTRICTION/LAX/STRICT/UNSPECIFIED.
            guard (0...3).contains(sameSite) else { throw BrowserAuthenticationImportError.invalidRecord }
            let rawExpiry = sqlite3_column_int64(row, 4)
            let expiry = Double(rawExpiry) / (version >= 16 ? 1000 : 1)
            guard expiry.isFinite, expiry > 0, expiry < 4_102_444_800 else { counts["invalidCookieExpiry", default: 0] += 1; continue }
            if expiry <= Date().timeIntervalSince1970 { counts["expiredCookies", default: 0] += 1; continue }
            counts["cookies", default: 0] += 1
            func chromeTime(_ column: Int32) throws -> Int64 {
                let micros = sqlite3_column_int64(row, column)
                guard micros >= 0, micros < 4_102_444_800_000_000 else { throw BrowserAuthenticationImportError.invalidRecord }
                return micros + 11_644_473_600_000_000
            }
            try consume(["host_key": host, "path": path, "name": name, "value": value,
                "expires_utc": rawExpiry * (version >= 16 ? 1000 : 1_000_000) + 11_644_473_600_000_000, "is_secure": Int64(sqlite3_column_int(row, 5)),
                "is_httponly": Int64(sqlite3_column_int(row, 6)), "samesite": Int64(sameSite == 3 ? -1 : sameSite),
                "creation_utc": try chromeTime(10), "last_access_utc": try chromeTime(11), "last_update_utc": try chromeTime(12)])
        }
        guard step == SQLITE_DONE else { throw BrowserAuthenticationImportError.database }
    }
    static func convert(file: URL, destination: URL, targetKey: Data) throws -> (Int, Int) {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw BrowserAuthenticationImportError.invalidState }
        let target = try AuthenticationSQLite(destination)
        try target.execute("CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY,value LONGVARCHAR); INSERT INTO meta VALUES('version','24'),('last_compatible_version','24')")
        try target.execute("CREATE TABLE cookies(" + ChromiumCookieImport.columns.map { $0 + (ChromiumCookieImport.texts.contains($0) ? " TEXT" : $0 == "encrypted_value" ? " BLOB" : " INTEGER") + " NOT NULL" }.joined(separator: ",") + ")")
        try target.execute("CREATE UNIQUE INDEX cookies_unique_index ON cookies(host_key,top_frame_site_key,has_cross_site_ancestor,name,path,source_scheme,source_port)")
        let insert = try target.statement("INSERT INTO cookies VALUES(" + ChromiumCookieImport.columns.map { _ in "?" }.joined(separator: ",") + ")")
        defer { sqlite3_finalize(insert) }
        var counts: [String: Int] = [:]
        try target.execute("BEGIN IMMEDIATE")
        do {
            try rows(file: file, counts: &counts) { values in
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                var clear = Data(SHA256.hash(data: Data((values["host_key"] as! String).utf8))) + Data((values["value"] as! String).utf8)
                defer { clear.resetBytes(in: 0..<clear.count) }
                let encrypted = try ArcChromiumCookieCipher.encrypt(clear, key: targetKey)
                for (index, column) in ChromiumCookieImport.columns.enumerated() {
                    let position = Int32(index + 1)
                    if column == "encrypted_value" { try AuthenticationSQLite.bind(encrypted, to: insert, at: position) }
                    else if ChromiumCookieImport.texts.contains(column) {
                        let text = column == "value" ? "" : values[column] as? String ?? ""
                        sqlite3_bind_text(insert, position, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    } else {
                        let defaults: [String: Int64] = ["has_expires": 1, "is_persistent": 1, "priority": 1, "source_port": -1]
                        sqlite3_bind_int64(insert, position, values[column] as? Int64 ?? defaults[column] ?? 0)
                    }
                }
                guard sqlite3_step(insert) == SQLITE_DONE else { throw BrowserAuthenticationImportError.database }
            }
            try target.execute("COMMIT")
        } catch { try? target.execute("ROLLBACK"); throw error }
        return (counts["cookies"] ?? 0, counts.filter { $0.key != "cookies" }.values.reduce(0, +))
    }
}
