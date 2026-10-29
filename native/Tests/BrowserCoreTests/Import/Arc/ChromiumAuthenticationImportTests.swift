import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import BrowserCore

@Suite struct ChromiumAuthenticationImportTests {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: String(cString: realpath(FileManager.default.temporaryDirectory.path, nil)!)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    @Test(arguments: [40, 41, 42, 43]) func passwordSchemas(version: Int) throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Login Data")
        let key = try ArcChromiumCookieCipher.deriveKey(password: Data("mock_password".utf8))
        let database = try AuthenticationSQLite(file)
        try database.execute("CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',\(version)),('last_compatible_version',40)")
        try database.execute("CREATE TABLE logins(id INTEGER,signon_realm TEXT,origin_url TEXT,action_url TEXT,username_element TEXT,username_value TEXT,password_element TEXT,password_value BLOB,date_created INTEGER,date_last_used INTEGER,date_password_modified INTEGER,blacklisted_by_user INTEGER,scheme INTEGER,federation_url TEXT)")
        let encrypted = try ArcChromiumCookieCipher.encrypt(Data("synthetic-secret".utf8), key: key).map { String(format: "%02x", $0) }.joined()
        try database.execute("INSERT INTO logins VALUES(1,'http://127.0.0.1:18080/','http://127.0.0.1:18080/login','','username','synthetic-user','password',X'\(encrypted)',10,20,30,0,0,'')")
        let result = try ChromiumPasswordReader.read(snapshotFile: file, sourceKey: key)
        #expect(result.passwords.count == 1)
        #expect(result.passwords[0].password == "synthetic-secret")
        #expect(result.passwords[0].modified == 30)
        #expect(!String(describing: result.passwords[0]).contains("synthetic-secret"))
        try database.execute("UPDATE meta SET value=44 WHERE key='version'")
        #expect(throws: BrowserAuthenticationImportError.schema) { try ChromiumPasswordReader.read(snapshotFile: file, sourceKey: key) }
    }
    @Test(arguments: [23, 24]) func cookieSchemas(version: Int) throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let key = try ArcChromiumCookieCipher.deriveKey(password: Data("mock-source".utf8))
        let targetKey = try ArcChromiumCookieCipher.deriveKey(password: Data("mock-target".utf8))
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("target")
        let database = try AuthenticationSQLite(source)
        try database.execute("CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',\(version)),('last_compatible_version',\(version))")
        try database.execute("CREATE TABLE cookies(" + ChromiumCookieImport.columns.map { $0 + (ChromiumCookieImport.texts.contains($0) ? " TEXT" : $0 == "encrypted_value" ? " BLOB" : " INTEGER") }.joined(separator: ",") + ")")
        let host = "127.0.0.1", value = Data([0, 128, 255, 65])
        let clear = (version == 24 ? Data(SHA256.hash(data: Data(host.utf8))) : Data()) + value
        let cipher = try ArcChromiumCookieCipher.encrypt(clear, key: key).map { String(format: "%02x", $0) }.joined()
        try database.execute("INSERT INTO cookies VALUES(1,'127.0.0.1','https://partition.test','session','',X'\(cipher)','/',99999999999999999,0,1,2,1,1,1,-1,1,18080,3,1,1)")
        #expect(try ChromiumCookieImport.convert(snapshotFile: source, destination: destination, sourceKey: key, targetKey: targetKey) == 1)
        let target = try AuthenticationSQLite(destination)
        #expect(try target.version(maximum: 24, minimum: 24) == 24)
        let row = try target.statement("SELECT encrypted_value,top_frame_site_key,has_cross_site_ancestor,source_port,value FROM cookies")
        defer { sqlite3_finalize(row) }
        #expect(sqlite3_step(row) == SQLITE_ROW)
        #expect(try ArcChromiumCookieCipher.decrypt(AuthenticationSQLite.bytes(row, 0), key: targetKey) == Data(SHA256.hash(data: Data(host.utf8))) + value)
        #expect(try AuthenticationSQLite.text(row, 1) == "https://partition.test")
        #expect(sqlite3_column_int(row, 2) == 1)
        #expect(sqlite3_column_int(row, 3) == 18080)
        #expect(try AuthenticationSQLite.text(row, 4) == "")
    }
    @Test func csv() throws {
        let csv = "\u{feff}name,url,username,password,note\r\nExample,http://127.0.0.1:18080/login,\"user,one\",\"line1\nline2\"\"quote\",note\r\n"
        let result = try BrowserPasswordCSV.read(Data(csv.utf8))
        #expect(result.passwords.count == 1)
        #expect(result.passwords[0].realm == "http://127.0.0.1:18080/")
        #expect(result.passwords[0].username == "user,one")
        #expect(result.passwords[0].password == "line1\nline2\"quote")
        for invalid in ["url,username,password\nx,u,\"unterminated", "url,url,username,password\na,b,c,d", "url,username,password\nhttps://fixture.test,u,\"p\"garbage"] {
            #expect(throws: BrowserAuthenticationImportError.invalidCSV) { try BrowserPasswordCSV.read(Data(invalid.utf8)) }
        }
    }
    @Test func identities() {
        #expect(BrowserSafeStorageIdentity.verified(sourceID: "brave")?.account == "Brave")
        #expect(BrowserSafeStorageIdentity.verified(sourceID: "dia")?.account == "Dia")
        #expect(BrowserSafeStorageIdentity.verified(sourceID: "chrome-beta") == nil)
    }
    @Test func freshRunAndRestartRestore() async throws {
        let fixture = try ChromiumImportTests.Fixture(); defer { fixture.remove() }
        let exported = ProcessInfo.processInfo.environment["ORBIT_IMPORT_AUTH_FIXTURE"] == "1"
        let root = exported ? URL(fileURLWithPath: "/private/tmp/import-auth/synthetic-data") : fixture.base.sessionFile.deletingLastPathComponent()
        let key = SymmetricKey(data: Data(repeating: 33, count: 32))
        if exported, ProcessInfo.processInfo.environment["ORBIT_IMPORT_AUTH_RESTORE"] == "1" {
            let run = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: key)
            try run.restore(confirmDeletingLaterChanges: true, usage: NeverRunningProbe())
            #expect(run.status.phase == .restored)
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let session = root.appendingPathComponent("session.json")
        let store = BrowserStore()
        let other = await store.createProfile(name: "Synthetic existing")
        let space = try await store.createSpace(name: "Existing", profileID: other)
        _ = try await store.createWindow(activeSpaceID: space)
        try BrowserSessionFileStore().save(await store.sessionDocument(), to: session)
        let before = try Data(contentsOf: session)
        let engineSibling = root.appendingPathComponent("Chromium/profile-" + other.rawValue.uuidString.lowercased())
        try FileManager.default.createDirectory(at: engineSibling, withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: engineSibling.appendingPathComponent("sentinel"))
        let sourceProfile = fixture.root.appendingPathComponent("Default")
        let sourceKey = try ArcChromiumCookieCipher.deriveKey(password: Data("mock-source".utf8))
        do {
            let database = try AuthenticationSQLite(sourceProfile.appendingPathComponent("Login Data"))
            try database.execute("CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',43),('last_compatible_version',40)")
            try database.execute("CREATE TABLE logins(id INTEGER,signon_realm TEXT,origin_url TEXT,action_url TEXT,username_element TEXT,username_value TEXT,password_element TEXT,password_value BLOB,date_created INTEGER,date_last_used INTEGER,date_password_modified INTEGER,blacklisted_by_user INTEGER,scheme INTEGER,federation_url TEXT)")
            let encrypted = try ArcChromiumCookieCipher.encrypt(Data("synthetic-secret".utf8), key: sourceKey).map { String(format: "%02x", $0) }.joined()
            try database.execute("INSERT INTO logins VALUES(1,'http://127.0.0.1:18080/','http://127.0.0.1:18080/login','http://127.0.0.1:18080/submit','username','synthetic-user','password',X'\(encrypted)',13300000000000000,13300000000000000,13300000000000000,0,0,'')")
        }
        try FileManager.default.createDirectory(at: sourceProfile.appendingPathComponent("Network"), withIntermediateDirectories: true)
        do {
            let database = try AuthenticationSQLite(sourceProfile.appendingPathComponent("Network/Cookies"))
            try database.execute("CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',23),('last_compatible_version',23)")
            try database.execute("CREATE TABLE cookies(" + ChromiumCookieImport.columns.map { $0 + (ChromiumCookieImport.texts.contains($0) ? " TEXT" : $0 == "encrypted_value" ? " BLOB" : " INTEGER") }.joined(separator: ",") + ")")
            let encrypted = try ArcChromiumCookieCipher.encrypt(Data("synthetic-signed-in".utf8), key: sourceKey).map { String(format: "%02x", $0) }.joined()
            let now = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
            try database.execute("INSERT INTO cookies VALUES(\(now),'127.0.0.1','','session','',X'\(encrypted)','/',\(now + 86400000000),0,1,\(now),1,1,1,-1,1,18080,\(now),1,0)")
        }
        let adapter = fixture.adapter(), importer = fixture.importer(fixture.adapter())
        let authentication = try ChromiumAuthenticationSnapshot.capture(source: fixture.root, adapter: adapter, consent: true,
            parent: fixture.base.snapshots, probe: NeverRunningProbe())
        defer { authentication.discard() }
        #expect(authentication.cookieFile?.lastPathComponent == "Cookies")
        #expect(authentication.cookieFile?.deletingLastPathComponent().lastPathComponent == "Network")
        let target = try ArcOfflineImportTarget(sessionFile: session, usage: NeverRunningProbe())
        let run: BrowserAuthenticationRun
        do {
            run = try await BrowserAuthenticationRun.apply(preparation: importer.prepare(for: target), importer: importer, target: target,
                authentication: authentication, sourcePassword: Data("mock-source".utf8), targetPassword: Data("mock_password".utf8), recoveryKey: key)
        } catch { await target.close(); throw error }
        await target.close()
        #expect(run.status.phase == .passwordsPending)
        #expect(run.status.cookies == 1 && run.status.passwords == 1)
        #expect(try run.passwordsForRuntime().first?.password == "synthetic-secret")
        let bytes = try Data(contentsOf: root.appendingPathComponent("AuthenticationImport/run.sealed"))
        #expect(bytes.range(of: Data("synthetic-secret".utf8)) == nil)
        #expect(throws: (any Error).self) { try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: SymmetricKey(size: .bits256)) }
        if exported {
            try Data(repeating: 33, count: 32).write(to: root.appendingPathComponent("import-auth-fixture-key"))
            return
        }
        let reopened = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: key)
        #expect(throws: BrowserAuthenticationImportError.restoreConfirmationRequired) {
            try reopened.restore(confirmDeletingLaterChanges: false, usage: NeverRunningProbe())
        }
        try reopened.restore(confirmDeletingLaterChanges: true, usage: NeverRunningProbe())
        #expect(try Data(contentsOf: session) == before)
        #expect(try String(contentsOf: engineSibling.appendingPathComponent("sentinel"), encoding: .utf8) == "untouched")
        let again = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: key)
        #expect(again.status.phase == .restored)
        try again.restore(confirmDeletingLaterChanges: true, usage: NeverRunningProbe())
        #expect(try Data(contentsOf: session) == before)
        let archive = try again.archiveCompleted()
        #expect(try !BrowserAuthenticationRun.exists(dataRoot: root))
        let archived = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: key, archiveID: archive)
        #expect(archived.status.phase == .restored)
    }

    @Test func interruptedRunRestores() async throws {
        let fixture = try ChromiumImportTests.Fixture(); defer { fixture.remove() }
        _ = try await fixture.base.seedExistingSession()
        let before = try Data(contentsOf: fixture.base.sessionFile)
        var importer = fixture.importer(fixture.adapter())
        importer.checkpoint = { point in if point == .afterPersist { throw BrowserAuthenticationImportError.invalidState } }
        let auth = try ChromiumAuthenticationSnapshot.capture(source: fixture.root, adapter: fixture.adapter(), consent: true,
            parent: fixture.base.snapshots, probe: NeverRunningProbe())
        defer { auth.discard() }
        let target = try fixture.base.target(), key = SymmetricKey(size: .bits256)
        do {
            _ = try await BrowserAuthenticationRun.apply(preparation: importer.prepare(for: target), importer: importer, target: target,
                authentication: auth, sourcePassword: Data("mock-source".utf8), targetPassword: Data("mock-target".utf8), recoveryKey: key)
            Issue.record("Injected interruption did not stop apply")
        } catch { }
        await target.close()
        let root = fixture.base.sessionFile.deletingLastPathComponent()
        let run = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: key)
        #expect(run.status.phase == .applying)
        try run.restore(confirmDeletingLaterChanges: true, usage: NeverRunningProbe())
        #expect(try Data(contentsOf: fixture.base.sessionFile) == before)
    }
    @Test func snapshotAdmission() throws {
        let fixture = try ChromiumImportTests.Fixture(); defer { fixture.remove() }
        #expect(throws: BrowserAuthenticationImportError.consentRequired) {
            try ChromiumAuthenticationSnapshot.capture(source: fixture.root, adapter: fixture.adapter(), consent: false,
                parent: fixture.base.snapshots, probe: NeverRunningProbe())
        }
        #expect(throws: ArcImportError.arcIsRunning) {
            try ChromiumAuthenticationSnapshot.capture(source: fixture.root, adapter: fixture.adapter(), consent: true,
                parent: fixture.base.snapshots, probe: AlwaysRunningProbe())
        }
        let login = fixture.root.appendingPathComponent("Default/Login Data")
        try FileManager.default.createSymbolicLink(at: login, withDestinationURL: fixture.root.appendingPathComponent("Local State"))
        #expect(throws: (any Error).self) {
            try ChromiumAuthenticationSnapshot.capture(source: fixture.root, adapter: fixture.adapter(), consent: true,
                parent: fixture.base.snapshots, probe: NeverRunningProbe())
        }
    }

}
