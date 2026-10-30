import CryptoKit
import Foundation
import OrbitImportSynthetic
import SQLite3
import Testing
@testable import BrowserCore

@Suite struct ArcPasswordSourceTests {
    @Test func discardingBackupErasesPasswordUndo() throws {
        let base = URL(fileURLWithPath: "/private/tmp/password-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Target"), source = base.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let journal = try ArcPasswordImportJournal.create(root: root, key: SymmetricKey(size: .bits256), groups: [], skipped: 0,
            sourcePassword: Data("source".utf8), targetPassword: Data("target".utf8))
        let sessions = ArcSiteSessionImport(dataRoot: root)
        _ = try sessions.run(.init(sourceRoot: source, profiles: [], passwordJobID: journal.id), keys: journal.connectionKeys())
        #expect(sessions.hasBackup)
        #expect(try sessions.latestPasswordJobID == journal.id)
        try sessions.discardLatestBackup()
        #expect(!sessions.hasBackup)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ArcPasswordImport/" + journal.id.uuidString + ".sealed").path))
    }

    @Test func connectionRestoreKeepsPasswordBackupUntilStoreUndoFinishes() throws {
        let root = URL(fileURLWithPath: "/private/tmp/password-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journal = try ArcPasswordImportJournal.create(root: root, key: SymmetricKey(size: .bits256), groups: [], skipped: 0,
            sourcePassword: Data("source".utf8), targetPassword: Data("target".utf8))
        let sessions = ArcSiteSessionImport(dataRoot: root)
        _ = try sessions.run(.init(sourceRoot: root.appendingPathComponent("Source"), profiles: [], passwordJobID: journal.id), keys: journal.connectionKeys())
        _ = try sessions.restoreLatest()
        #expect(sessions.hasBackup)
        #expect(try sessions.latestPasswordJobID == journal.id)
        try sessions.markPasswordsRestored(jobID: journal.id)
        #expect(!sessions.hasBackup)
    }

    @Test func decodeAndWAL() async throws {
        let exported = ProcessInfo.processInfo.environment["ORBIT_PASSWORD_EXPORT_FIXTURE"] == "1"
        let root = exported ? URL(fileURLWithPath: "/private/tmp/import-arc-passwords/gui/ArcSource")
            : URL(fileURLWithPath: "/private/tmp/orbit-password-source-" + UUID().uuidString)
        defer { if !exported { try? FileManager.default.removeItem(at: root) } }
        try ArcSyntheticData.writeDataDirectory(at: root)
        let sourceKey = try ArcChromiumCookieCipher.deriveKey(password: Data("mock-source".utf8))
        var databases: [AuthenticationSQLite] = []
        for profile in ["Default", "Profile 1"] {
            let directory = root.appendingPathComponent("User Data/" + profile)
            try FileManager.default.removeItem(at: directory.appendingPathComponent("Login Data"))
            try FileManager.default.removeItem(at: directory.appendingPathComponent("Cookies"))
            let database = try AuthenticationSQLite(directory.appendingPathComponent("Login Data")); databases.append(database)
            try database.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
            try database.execute("CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',43),('last_compatible_version',40)")
            try database.execute("CREATE TABLE logins(id INTEGER,signon_realm TEXT,origin_url TEXT,action_url TEXT,username_element TEXT,username_value TEXT,password_element TEXT,password_value BLOB,date_created INTEGER,date_last_used INTEGER,date_password_modified INTEGER,blacklisted_by_user INTEGER,scheme INTEGER,federation_url TEXT)")
            for (index, name) in ["new", "equal", "conflict", "blocked", "federated", "empty", "passkey"].enumerated() {
                let clear = name == "empty" || name == "blocked" ? "" : "synthetic-" + name
                let encrypted = try ArcChromiumCookieCipher.encrypt(Data(clear.utf8), key: sourceKey).map { String(format: "%02x", $0) }.joined()
                try database.execute("INSERT INTO logins VALUES(\(index),'https://fixture.test/','https://fixture.test/\(name)','','username','\(name == "blocked" ? "" : name)','password',X'\(encrypted)',13000000000000001,13000000000000002,13000000000000003,\(name == "blocked" ? 1 : 0),\(name == "passkey" ? 4 : 0),'\(name == "federated" ? "https://identity.test/" : "")')")
            }
        }
        let profiles = [ArcSiteSessionProfile(sourceDirectory: "Default", targetID: ProfileID()), .init(sourceDirectory: "Profile 1", targetID: ProfileID())]
        let result = try ArcPasswordImportSource.read(root: root.appendingPathComponent("User Data"), profiles: profiles,
            sourcePassword: Data("mock-source".utf8), probe: BrowserImportRunningProbe(running: { false }))
        #expect(result.groups.count == 2 && result.groups.allSatisfy { $0.1.count == 4 })
        #expect(result.skipped == 6)
        #expect(result.groups[0].1[0].password == "synthetic-new")
        #expect(result.groups[0].1[0].created == 13000000000000001)
        #expect(result.groups[0].1.last?.blocked == true)
        #expect(result.groups[0].1.last?.username.isEmpty == true)
        #expect(result.groups[0].1.last?.password.isEmpty == true)
        let fixture = try OrbitImportTestFixture(); defer { fixture.remove() }
        _ = try await fixture.seedExistingSession()
        let target = try fixture.target()
        let importer = ArcImporter(source: root, probe: BrowserImportRunningProbe(running: { false }))
        let preparation = try await importer.prepare(for: target)
        let expectedNames = preparation.plan.profiles.filter { $0.sourceDirectory != nil }.map(\.name)
        #expect(preparation.report.passwordProfiles?.map(\.name) == expectedNames)
        #expect(preparation.report.passwordProfiles?.map(\.count) == [7, 7, 0])
        let encoded = try JSONEncoder().encode(preparation.report)
        for name in expectedNames { #expect(encoded.range(of: Data(name.utf8)) == nil) }
        if ProcessInfo.processInfo.environment["ORBIT_PASSWORD_EXPORT_REVIEW"] == "1" {
            try encoded.write(to: URL(fileURLWithPath: "/private/tmp/import-arc-passwords/review-report.json"))
            // Synthetic presentation evidence only; production report serialization omits names.
            try JSONEncoder().encode(expectedNames).write(to: URL(fileURLWithPath: "/private/tmp/import-arc-passwords/review-profile-names.json"))
        }
        preparation.discard(); await target.close()
        withExtendedLifetime(databases) {}
    }
}
