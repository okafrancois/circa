import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import BrowserCore

@Suite("Offline source browser site sessions")
struct OrbitSiteSessionImportTests {
    struct Keys: ArcSiteSessionKeyProviding {
        var source = Data("fixture-arc-password".utf8)
        var target = Data("fixture-orbit-password".utf8)
        func sourcePassword() throws -> Data { source }
        func targetPassword() throws -> Data { target }
    }

    @Test("v24 re-encryption retains the complete host hash and binary value")
    func cipherRoundTrip() throws {
        let keys = Keys()
        let source = try ArcChromiumCookieCipher.deriveKey(password: keys.source)
        let target = try ArcChromiumCookieCipher.deriveKey(password: keys.target)
        let host = ".fixture.test"
        let clear = Data(SHA256.hash(data: Data(host.utf8))) + Data([0, 128, 255, 65, 66])
        let encrypted = try ArcChromiumCookieCipher.encrypt(clear, key: source)
        let converted = try ArcChromiumCookieCipher.reencrypt(encrypted, host: host, sourceKey: source, targetKey: target)
        #expect(encrypted.starts(with: Data("v10".utf8)))
        #expect(converted != encrypted)
        #expect(try ArcChromiumCookieCipher.decrypt(converted, key: target) == clear)
        #expect(throws: (any Error).self) {
            try ArcChromiumCookieCipher.reencrypt(converted, host: host, sourceKey: source, targetKey: target)
        }
        #expect(throws: ArcAuthenticationError.hostHashMismatch) {
            try ArcChromiumCookieCipher.reencrypt(encrypted, host: "another.test", sourceKey: source, targetKey: target)
        }
    }

    @Test("Real SQLite import merges cookies, skips expiry, copies storage and restores the backup")
    func importAndRestore() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let keys = Keys()
        try fixture.database(at: fixture.source, password: keys.source, rows: [("shared", "arc", false), ("expired", "old", true)])
        try fixture.database(at: fixture.target, password: keys.target, rows: [("shared", "orbit", false), ("retained", "target", false)])
        try fixture.storage(at: fixture.source, value: "source-storage")
        try fixture.storage(at: fixture.target, value: "target-storage")
        let before = try Data(contentsOf: fixture.target.appendingPathComponent("Cookies"))
        try fixture.importer.schedule(fixture.request)
        let result = try #require(try fixture.importer.consumePending(keys: keys))
        #expect(result.profiles == 1 && result.cookies == 1 && result.failedProfiles == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.importer.pendingFile.path))
        #expect(try fixture.values(at: fixture.target, password: keys.target) == ["shared": "arc", "retained": "target"])
        #expect(try fixture.storageValue(at: fixture.target) == "source-storage")
        let restored = try fixture.importer.restoreLatest()
        #expect(restored.restored && restored.profiles == 1)
        #expect(try Data(contentsOf: fixture.target.appendingPathComponent("Cookies")) == before)
        #expect(try fixture.storageValue(at: fixture.target) == "target-storage")
    }

    @Test("Network cookie layout imports encrypted rows and retains the same undo point")
    func networkCookieLayout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let keys = Keys()
        try fixture.database(at: fixture.source.appendingPathComponent("Network"), password: keys.source,
                             rows: [("shared", "source", false)])
        try fixture.database(at: fixture.target, password: keys.target, rows: [("shared", "target", false)])
        let before = try Data(contentsOf: fixture.target.appendingPathComponent("Cookies"))
        let result = try fixture.importer.run(fixture.request, keys: keys)
        #expect(result.cookies == 1 && result.failedProfiles == 0)
        #expect(try fixture.values(at: fixture.target, password: keys.target) == ["shared": "source"])
        _ = try fixture.importer.restoreLatest()
        #expect(try Data(contentsOf: fixture.target.appendingPathComponent("Cookies")) == before)
    }

    @Test("A fresh profile imports while a corrupt second profile rolls back independently")
    func perProfileFailure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let keys = Keys()
        try fixture.database(at: fixture.source, password: keys.source, rows: [("shared", "arc", false)])
        let second = ArcSiteSessionProfile(sourceDirectory: "Profile 1", targetID: ProfileID(UUID()))
        let secondSource = fixture.request.sourceRoot.appendingPathComponent(second.sourceDirectory)
        let secondTarget = fixture.root.appendingPathComponent("target/Chromium/" + second.targetDirectory)
        try fixture.database(at: secondSource, password: Data("wrong-password".utf8), rows: [("shared", "broken", false)])
        try fixture.storage(at: secondTarget, value: "keep-me")
        var request = fixture.request
        request.profiles.append(second)
        let result = try fixture.importer.run(request, keys: keys)
        #expect(result.profiles == 1 && result.cookies == 1 && result.failedProfiles == 1)
        #expect(try fixture.values(at: fixture.target, password: keys.target) == ["shared": "arc"])
        #expect(try fixture.storageValue(at: secondTarget) == "keep-me")
        #expect(!FileManager.default.fileExists(atPath: secondTarget.appendingPathComponent("Cookies").path))
    }

    @Test("Startup restores a profile interrupted after its backup was prepared")
    func interruptedImport() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.database(at: fixture.source, password: Keys().source, rows: [("shared", "arc", false)])
        try fixture.storage(at: fixture.target, value: "before")
        _ = try fixture.importer.run(fixture.request, keys: Keys())
        let backups = fixture.importer.directory.appendingPathComponent("Backups")
        let backup = try #require(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first)
        let file = backup.appendingPathComponent("backup.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var profiles = try #require(object["profiles"] as? [[String: Any]])
        profiles[0]["state"] = "prepared"
        object["profiles"] = profiles
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        try fixture.importer.recoverInterruptedImport()
        #expect(try fixture.storageValue(at: fixture.target) == "before")
        #expect(!FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("Cookies").path))
        try fixture.importer.recoverInterruptedImport()
    }

    @Test("A missing source does not delete existing target site storage")
    func missingSource() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.storage(at: fixture.target, value: "kept")
        let result = try fixture.importer.run(fixture.request, keys: Keys())
        #expect(result.failedProfiles == 1 && result.profiles == 0)
        #expect(try fixture.storageValue(at: fixture.target) == "kept")
    }

    /// Records whether the pending request still exists when the import first asks for keys.
    final class PendingProbe: ArcSiteSessionKeyProviding, @unchecked Sendable {
        let pendingFile: URL
        var pendingSeenByImport: Bool?
        init(pendingFile: URL) { self.pendingFile = pendingFile }
        func sourcePassword() throws -> Data {
            pendingSeenByImport = FileManager.default.fileExists(atPath: pendingFile.path)
            return Keys().source
        }
        func targetPassword() throws -> Data { Keys().target }
    }

    @Test("A pending import is consumed before profiles change and is never replayed")
    func pendingImportConsumedBeforeRun() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.storage(at: fixture.source, value: "imported-storage")
        try fixture.storage(at: fixture.target, value: "original-storage")
        try fixture.importer.schedule(fixture.request)
        let probe = PendingProbe(pendingFile: fixture.importer.pendingFile)
        let result = try #require(try fixture.importer.consumePending(keys: probe))
        #expect(probe.pendingSeenByImport == false)
        #expect(result.profiles == 1)
        // The next launch finds nothing to replay, so the undo point is still the original data.
        #expect(try fixture.importer.consumePending(keys: Keys()) == nil)
        _ = try fixture.importer.restoreLatest()
        #expect(try fixture.storageValue(at: fixture.target) == "original-storage")
    }

    @Test("A pending restore is consumed before restoring and never reaches an older backup")
    func pendingRestoreConsumedBeforeRun() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.storage(at: fixture.source, value: "first-import")
        try fixture.storage(at: fixture.target, value: "original-storage")
        _ = try fixture.importer.run(fixture.request, keys: Keys(), now: Date().addingTimeInterval(-10))
        for name in ["Local Storage", "IndexedDB", "WebStorage"] {
            try FileManager.default.removeItem(at: fixture.source.appendingPathComponent(name))
        }
        try fixture.storage(at: fixture.source, value: "second-import")
        _ = try fixture.importer.run(fixture.request, keys: Keys())
        var request = fixture.request
        request.action = .restore
        try fixture.importer.schedule(request)
        _ = try #require(try fixture.importer.consumePending(keys: Keys()))
        #expect(!FileManager.default.fileExists(atPath: fixture.importer.pendingFile.path))
        #expect(try fixture.storageValue(at: fixture.target) == "first-import")
        #expect(try fixture.importer.consumePending(keys: Keys()) == nil)
        #expect(try fixture.storageValue(at: fixture.target) == "first-import")
    }

    struct Fixture {
        let root: URL
        let profile = ArcSiteSessionProfile(sourceDirectory: "Default", targetID: ProfileID(UUID()))
        var source: URL { root.appendingPathComponent("source/Default") }
        var target: URL { root.appendingPathComponent("target/Chromium/" + profile.targetDirectory) }
        var importer: ArcSiteSessionImport { .init(dataRoot: root.appendingPathComponent("target")) }
        var request: ArcSiteSessionRequest { .init(sourceRoot: root.appendingPathComponent("source"), profiles: [profile]) }
        init() throws {
            root = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path).appendingPathComponent("orbit-site-sessions-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func storage(at directory: URL, value: String) throws {
            for name in ["Local Storage", "IndexedDB", "WebStorage"] {
                let url = directory.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data(value.utf8).write(to: url.appendingPathComponent("fixture"))
            }
        }
        func storageValue(at directory: URL) throws -> String {
            try String(contentsOf: directory.appendingPathComponent("Local Storage/fixture"), encoding: .utf8)
        }
        func open(_ directory: URL) throws -> OpaquePointer {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var db: OpaquePointer?
            #expect(sqlite3_open(directory.appendingPathComponent("Cookies").path, &db) == SQLITE_OK)
            return try #require(db)
        }
        func database(at directory: URL, password: Data, rows: [(String, String, Bool)]) throws {
            let db = try open(directory)
            defer { sqlite3_close(db) }
            #expect(sqlite3_exec(db, "CREATE TABLE meta(key TEXT PRIMARY KEY, value INTEGER); INSERT INTO meta VALUES ('version',24),('last_compatible_version',24); CREATE TABLE cookies(host_key TEXT, name TEXT UNIQUE, encrypted_value BLOB, value TEXT, has_expires INTEGER, expires_utc INTEGER, top_frame_site_key TEXT, has_cross_site_ancestor INTEGER)", nil, nil, nil) == SQLITE_OK)
            let key = try ArcChromiumCookieCipher.deriveKey(password: password)
            for (name, value, expired) in rows {
                let clear = Data(SHA256.hash(data: Data("fixture.test".utf8))) + Data(value.utf8)
                let cipher = try ArcChromiumCookieCipher.encrypt(clear, key: key)
                let hex = cipher.map { String(format: "%02x", $0) }.joined()
                let expiry = expired ? "1" : "99999999999999999"
                #expect(sqlite3_exec(db, "INSERT INTO cookies VALUES ('fixture.test','\(name)',X'\(hex)','',1,\(expiry),'https://partition.test',1)", nil, nil, nil) == SQLITE_OK)
            }
        }
        func values(at directory: URL, password: Data) throws -> [String: String] {
            let db = try open(directory)
            defer { sqlite3_close(db) }
            let key = try ArcChromiumCookieCipher.deriveKey(password: password)
            var row: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "SELECT name, encrypted_value, top_frame_site_key, has_cross_site_ancestor FROM cookies", -1, &row, nil) == SQLITE_OK)
            defer { sqlite3_finalize(row) }
            var values: [String: String] = [:]
            while sqlite3_step(row) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(row, 0))
                let cipher = Data(bytes: sqlite3_column_blob(row, 1)!, count: Int(sqlite3_column_bytes(row, 1)))
                let clear = try ArcChromiumCookieCipher.decrypt(cipher, key: key)
                #expect(String(cString: sqlite3_column_text(row, 2)) == "https://partition.test")
                #expect(sqlite3_column_int(row, 3) == 1)
                values[name] = String(decoding: clear.dropFirst(32), as: UTF8.self)
            }
            return values
        }
    }
}
