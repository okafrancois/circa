import BrowserCore
import CryptoKit
import Foundation
import Testing
@testable import BrowserCore

struct BrowserImportUIFixtureTests {
    @Test func productFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_IMPORT_UI_FIXTURE"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try ChromiumImportTests.Fixture()
        defer { fixture.remove() }
        let source = root.deletingLastPathComponent().appendingPathComponent("Sources/Google/Chrome")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.root, to: source)
            let profile = source.appendingPathComponent("Default")
            let database = try AuthenticationSQLite(profile.appendingPathComponent("Cookies"))
            try database.execute("CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',24),('last_compatible_version',24)")
            try database.execute("CREATE TABLE cookies(" + ChromiumCookieImport.columns.map { $0 + (ChromiumCookieImport.texts.contains($0) ? " TEXT" : $0 == "encrypted_value" ? " BLOB" : " INTEGER") }.joined(separator: ",") + ")")
            let login = try AuthenticationSQLite(profile.appendingPathComponent("Login Data"))
            try login.execute("CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',43),('last_compatible_version',40)")
            try login.execute("CREATE TABLE logins(id INTEGER,signon_realm TEXT,origin_url TEXT,action_url TEXT,username_element TEXT,username_value TEXT,password_element TEXT,password_value BLOB,date_created INTEGER,date_last_used INTEGER,date_password_modified INTEGER,blacklisted_by_user INTEGER,scheme INTEGER,federation_url TEXT)")
            let sourceKey = try ArcChromiumCookieCipher.deriveKey(password: Data("mock-source".utf8))
            let encrypted = try ArcChromiumCookieCipher.encrypt(Data("synthetic-secret".utf8), key: sourceKey).map { String(format: "%02x", $0) }.joined()
            try login.execute("INSERT INTO logins VALUES(1,'http://127.0.0.1:18080/','http://127.0.0.1:18080/login','','username','synthetic-user','password',X'\(encrypted)',13300000000000000,13300000000000000,13300000000000000,0,0,'')")
            let cookie = try ArcChromiumCookieCipher.encrypt(Data(SHA256.hash(data: Data("127.0.0.1".utf8))) + Data("synthetic-cookie".utf8), key: sourceKey).map { String(format: "%02x", $0) }.joined()
            try database.execute("INSERT INTO cookies VALUES(13300000000000000,'127.0.0.1','','session','',X'\(cookie)','/',99999999999999999,0,1,13300000000000000,1,1,1,-1,1,18080,13300000000000000,1,0)")
            try FileManager.default.createDirectory(at: profile.appendingPathComponent("Local Storage"), withIntermediateDirectories: true)
            try Data("synthetic storage".utf8).write(to: profile.appendingPathComponent("Local Storage/value"))

        let firefox = root.deletingLastPathComponent().appendingPathComponent("Sources/Firefox")
        _ = try FirefoxImportTests.populate(firefox)
        let external = root.deletingLastPathComponent().appendingPathComponent("Sources/External")
        try FileManager.default.copyItem(at: firefox.appendingPathComponent("Profiles/default"), to: external)
        let ini = firefox.appendingPathComponent("profiles.ini")
        let metadata = try String(contentsOf: ini, encoding: .utf8)
        try (metadata + "[Profile2]\nName=External\nIsRelative=0\nPath=" + external.path + "\n").write(to: ini, atomically: true, encoding: .utf8)
        try Data(FirefoxImportTests.csv.utf8).write(to: root.deletingLastPathComponent().appendingPathComponent("Sources/Logins.csv"))
        try SafariImportTests.export(to: root.deletingLastPathComponent().appendingPathComponent("Sources/Export.zip"))
        let store = BrowserStore()
        for index in 0..<2 {
            let profile = await store.createProfile(name: "Existing \(index)")
            let space = try await store.createSpace(name: "Existing \(index)", profileID: profile)
            if index == 0 {
                let window = try await store.createWindow(activeSpaceID: space)
                _ = try await store.openTab(url: URL(string: "about:blank")!, from: store.captureContext(in: window), activate: true)
            }
        }
        try BrowserSessionFileStore().save(await store.sessionDocument(), to: root.appendingPathComponent("session.json"))
        try Data(repeating: 33, count: 32).write(to: root.appendingPathComponent("import-auth-fixture-key"))
        try Data("mock-source".utf8).write(to: root.appendingPathComponent("arc-session-source-password"))
        try Data(#"{"browsers":["chrome","firefox","safari"]}"#.utf8).write(to: root.appendingPathComponent("import-ui-inventory.json"))
    }
}
