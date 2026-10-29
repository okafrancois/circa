import CryptoKit
import Darwin
import Foundation
import SQLite3
import Testing
@testable import BrowserCore

@Suite(.serialized)
struct FirefoxImportTests {
    static let csv = "url,username,password,httpRealm,formActionOrigin,guid,timeCreated,timeLastUsed,timePasswordChanged\r\nhttp://127.0.0.1:18080/login,synthetic-user,synthetic-secret,,http://127.0.0.1:18080/,{synthetic},1700000000000,1700000000000,1700000000000\r\n"
    static let profile = BrowserImportSourceProfile(directory: "Profiles/default", name: "Synthetic")
    static func adapter(zen: Bool = false, consent: Bool = true) -> FirefoxBrowserImportAdapter {
        .init(descriptor: FirefoxImportRegistry.descriptors[zen ? 1 : 0], installationID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, profile: profile,
              placement: .init(importedSpace: "Imported", bookmarkFolder: "Imported Bookmarks", windowName: "Imported Window"), authenticationConsent: consent)
    }
    static func moz(_ value: [String: Any]) throws -> Data { mozBytes(try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)) }
    static func mozBytes(_ data: Data) -> Data {
        var result = Data("mozLz40\0".utf8)
        result += Data((0..<4).map { UInt8(truncatingIfNeeded: data.count >> ($0 * 8)) })
        result.append(UInt8(min(15, data.count) << 4))
        if data.count >= 15 {
            var remaining = data.count - 15
            while remaining >= 255 { result.append(255); remaining -= 255 }
            result.append(UInt8(remaining))
        }
        result += data; return result
    }
    static func tab(_ url: String, pinned: Bool = false) -> [String: Any] {
        ["entries": [["url": "https://old.example.test/", "title": "Old"], ["url": url, "title": "Known title"]], "index": 2, "pinned": pinned]
    }
    @discardableResult static func populate(_ source: URL, wal: Bool = false) throws -> AuthenticationSQLite {
        let profile = source.appendingPathComponent(Self.profile.directory)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("[General]\nStartWithLastProfile=1\n[Profile0]\nName=Synthetic\nIsRelative=1\nPath=Profiles/default\nDefault=1\n[Profile1]\nName=Other\nIsRelative=1\nPath=Profiles/other\n[InstallONE]\nDefault=Profiles/default\nLocked=1\n".utf8).write(to: source.appendingPathComponent("profiles.ini"))
        try Data("[ONE]\nDefault=Profiles/default\nLocked=1\n".utf8).write(to: source.appendingPathComponent("installs.ini"))
        let db = try AuthenticationSQLite(profile.appendingPathComponent("places.sqlite"))
        if wal { try db.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0") }
        try db.execute("PRAGMA user_version=80; CREATE TABLE moz_places(id INTEGER PRIMARY KEY,url TEXT,title TEXT,typed INTEGER); CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY,place_id INTEGER,visit_date INTEGER,visit_type INTEGER); CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY,parent INTEGER,type INTEGER,guid TEXT,title TEXT,dateAdded INTEGER,fk INTEGER,position INTEGER)")
        try db.execute("INSERT INTO moz_places VALUES(1,'https://bookmark.example.test/','Saved',1),(2,'file:///synthetic','Local',0),(3,'https://user:secret@credential.example.test/','Credentials',0),(4,'https://history.example.test/','History',1)")
        let time = Int64(Date().timeIntervalSince1970 * 1_000_000)
        for i in 1...7 { try db.execute("INSERT INTO moz_historyvisits VALUES(\(i),4,\(time - Int64(i * 1000)),\([1,2,3,5,6,9,4][i-1]))") }
        try db.execute("INSERT INTO moz_historyvisits VALUES(8,2,\(time),1),(9,3,\(time),1),(10,4,0,1)")
        try db.execute("INSERT INTO moz_bookmarks VALUES(1,0,2,'root________','',1700000000000000,NULL,0),(2,1,2,'toolbar_____','Toolbar',1700000000000000,NULL,0),(3,1,2,'menu________','Menu',1700000000000000,NULL,1),(4,1,2,'unfiled_____','Unfiled',1700000000000000,NULL,2),(5,1,2,'mobile______','Mobile',1700000000000000,NULL,3),(6,2,2,'nested______','Nested 日本語',1700000001000000,NULL,0),(7,6,1,'saved_______','Saved title',1700000002000000,1,0),(8,6,3,'separator___','',0,NULL,1),(9,6,1,'filtered____','Filtered',0,2,2)")
        try cookies(profile.appendingPathComponent("cookies.sqlite"))
        let session: [String: Any] = ["version": ["sessionrestore", 1], "windows": [["tabs": [tab("https://open.example.test/"), tab("https://pin.example.test/", pinned: true)], "_closedTabs": [["state": tab("https://closed.example.test/")]]], ["isPrivate": true, "tabs": [tab("https://private.example.test/")]]], "_closedWindows": [["tabs": [tab("https://closed-window.example.test/")]]]]
        try moz(session).write(to: profile.appendingPathComponent("sessionstore.jsonlz4"))
        try Data("{\"logins\":[{\"encryptedUsername\":\"SYNTHETIC\",\"encryptedPassword\":\"SYNTHETIC\"}]}".utf8).write(to: profile.appendingPathComponent("logins.json"))
        try Data("{\"addons\":[{\"id\":\"synthetic.extension\"}]}".utf8).write(to: profile.appendingPathComponent("extensions.json"))
        for (name, table) in [("formhistory.sqlite", "moz_formhistory"), ("permissions.sqlite", "moz_perms")] {
            let other = try AuthenticationSQLite(profile.appendingPathComponent(name)); try other.execute("CREATE TABLE \(table)(id INTEGER); INSERT INTO \(table) VALUES(1),(2)")
        }
        try moz(["engines": [["name": "Synthetic Search"]]]).write(to: profile.appendingPathComponent("search.json.mozlz4"))
        return db
    }
    static func cookies(_ file: URL, version: Int = 17) throws {
        let db = try AuthenticationSQLite(file)
        try db.execute("PRAGMA user_version=\(version); CREATE TABLE moz_cookies(id INTEGER PRIMARY KEY,host TEXT,path TEXT,name TEXT,value TEXT,expiry INTEGER,isSecure INTEGER,isHttpOnly INTEGER,originAttributes TEXT,sameSite INTEGER,rawSameSite INTEGER,creationTime INTEGER,lastAccessed INTEGER,updateTime INTEGER,isPartitionedAttributeSet INTEGER)")
        let expiry = Int64((Date().timeIntervalSince1970 + 86400) * (version >= 16 ? 1000 : 1))
        for (i, attrs) in ["", "^userContextId=1", "^userContextId=2", "^partitionKey=%28https%2Cexample.test%29"].enumerated() {
            try db.execute("INSERT INTO moz_cookies VALUES(\(i + 1),'127.0.0.1','/','session','synthetic-cookie',\(expiry),0,1,'\(attrs)',\(version < 15 ? 1 : 3),0,1700000000000000,1700000000000000,1700000000000000,0)")
        }
    }
    struct Fixture {
        let base: OrbitImportTestFixture
        let source: URL
        let writer: AuthenticationSQLite
        init(wal: Bool = false) throws {
            base = try .init(); source = base.root.appendingPathComponent("FirefoxSource")
            writer = try FirefoxImportTests.populate(source, wal: wal)
        }
        func importer(_ adapter: FirefoxBrowserImportAdapter = FirefoxImportTests.adapter()) -> BrowserImportOrchestrator {
            var importer = base.importer(); importer.source = source; importer.adapter = adapter; importer.options.historyChunkSize = 2; return importer
        }
        func snapshot(_ adapter: FirefoxBrowserImportAdapter = FirefoxImportTests.adapter()) throws -> ArcSourceSnapshot {
            try adapter.snapshot(source: source, parent: base.snapshots, probe: NeverRunningProbe(), diskSpace: OrbitSystemDiskSpaceProbe())
        }
    }
    @Test func metadataOnlyInjectedInventoryAndExternalAdmission() throws {
        let a = Self.adapter()
        let data = Data("[Profile0]\nPath=Profiles/second\nName=Second\nIsRelative=1\n[Profile1]\nPath=/tmp/synthetic-external\nName=External\nIsRelative=0\n[Profile2]\nPath=../escape\nIsRelative=1\n[Profile3]\nPath=Profiles/default\nIsRelative=1\n".utf8)
        let profiles = try a.discoverProfiles(metadata: data, installs: Data("[ONE]\nDefault=Profiles/default\n".utf8))
        #expect(profiles.count == 3 && profiles[0].directory == "Profiles/default")
        #expect(FirefoxImportRegistry.installed { $0 == "app.zen-browser.zen" ? [URL(fileURLWithPath: "/synthetic/Zen.app")] : [] }.map(\.id) == ["zen"])
        #expect(throws: (any Error).self) { try a.discoverProfiles(metadata: Data("[Profile0]\nPath=x\nPath=y".utf8)) }
    }
    @Test func placesWALHistoryTreesFiltersAndStableIdentity() async throws {
        let f = try Fixture(wal: true); defer { f.base.remove() }
        let sourceFile = f.source.appendingPathComponent(Self.profile.directory + "/places.sqlite")
        let before = try Data(contentsOf: sourceFile)
        let target = try f.base.target(), importer = f.importer(), preparation = try await importer.prepare(for: target)
        #expect(preparation.report.history.importable == 6)
        #expect(preparation.report.history.credentialURLs == 1 && preparation.report.history.nonWebURLs == 1 && preparation.report.history.invalidTimes == 1)
        #expect(preparation.plan.counts.pinnedFolders == 6 && preparation.plan.counts.pinnedTabs == 2 && preparation.plan.counts.todayTabs == 1)
        #expect(preparation.report.sourceCounts?["bookmarkSeparators"] == 1)
        #expect(preparation.report.sourceCounts?["privateWindows"] == 1 && preparation.report.sourceCounts?["closedTabs"] == 1)
        #expect(preparation.report.sourceCounts?["containerCookies"] == 2 && preparation.report.sourceCounts?["partitionedOrIsolatedCookies"] == 1)
        #expect(preparation.report.capabilities?["passwords"] == .needsExport)
        let reader = try Self.adapter().historyReader(file: preparation.snapshot.historyDatabases[Self.profile.directory]!, directory: Self.profile.directory)
        let visits = try reader.nextChunk(size: 100)!
        #expect(visits.filter { $0.typedCount > 0 }.count == 1)
        #expect(visits.contains { $0.transition == .reload } && visits.filter { $0.transition == .redirect }.count == 2)
        let outcome = try await importer.apply(preparation, to: target)
        #expect(outcome.historyInserted == 6)
        let doc = await target.sessionDocument()
        #expect(doc.organization.tabs.contains { $0.pageTitle == "Saved title" && $0.createdAt == Date(timeIntervalSince1970: 1_700_000_002) })
        await target.close()
        try ArcImportBackups.restore(outcome.backupID, at: target.location, usage: NeverRunningProbe())
        #expect(try Data(contentsOf: sourceFile) == before)
    }
    @Test func cookieVersionsEncryptionIsolationConsentAndUndo() async throws {
        let f = try Fixture(); defer { f.base.remove() }
        for version in [10, 14, 15, 16, 17] {
            let file = f.base.root.appendingPathComponent("cookies-\(version).sqlite"), output = f.base.root.appendingPathComponent("converted-\(version)")
            try Self.cookies(file, version: version)
            let key = try ArcChromiumCookieCipher.deriveKey(password: Data("mock_password".utf8))
            let result = try FirefoxCookieImport.convert(file: file, destination: output, targetKey: key)
            #expect(result == (1, 3))
            let db = try AuthenticationSQLite(output), row = try db.statement("SELECT host_key,value,encrypted_value,samesite,is_httponly,expires_utc FROM cookies")
            defer { sqlite3_finalize(row) }
            #expect(sqlite3_step(row) == SQLITE_ROW)
            let clear = try ArcChromiumCookieCipher.decrypt(AuthenticationSQLite.bytes(row, 2), key: key)
            #expect(clear == Data(SHA256.hash(data: Data("127.0.0.1".utf8))) + Data("synthetic-cookie".utf8))
            #expect(try AuthenticationSQLite.text(row, 1) == "" && sqlite3_column_int(row, 3) == -1 && sqlite3_column_int(row, 4) == 1)
            let sourceExpiry = try FirefoxPlacesReader.integer(FirefoxPlacesReader.database(file), "SELECT expiry FROM moz_cookies WHERE id=1")
            #expect(sqlite3_column_int64(row, 5) == Int64(sourceExpiry) * (version >= 16 ? 1000 : 1_000_000) + 11_644_473_600_000_000)
        }
        _ = try await f.base.seedExistingSession()
        let before = try Data(contentsOf: f.base.sessionFile), target = try f.base.target(), importer = f.importer()
        let prep = try await importer.prepare(for: target)
        await #expect(throws: BrowserAuthenticationImportError.consentRequired) {
            try await BrowserAuthenticationRun.applyFirefox(preparation: prep, importer: importer, target: target, adapter: Self.adapter(), consent: false, targetPassword: Data(), recoveryKey: BrowserImportRecoveryTests.key)
        }
        let run = try await BrowserAuthenticationRun.applyFirefox(preparation: prep, importer: importer, target: target, adapter: Self.adapter(), passwordCSV: Data(Self.csv.utf8), consent: true, targetPassword: Data("mock_password".utf8), recoveryKey: BrowserImportRecoveryTests.key)
        #expect(run.status.cookies == 1 && run.status.passwords == 1)
        #expect(try run.passwordsForRuntime()[0].password == "synthetic-secret")
        await target.close()
        try run.restore(confirmDeletingLaterChanges: true, usage: NeverRunningProbe())
        #expect(try Data(contentsOf: f.base.sessionFile) == before)
    }
    @Test func sessionPrecedenceMozBoundsAndZenWorkspaces() throws {
        let f = try Fixture(); defer { f.base.remove() }
        let snapshot = try f.snapshot(); defer { snapshot.remove() }
        let root = try OrbitSecureDirectory.open(snapshot.directory, create: false)
        let backups = try root.directory("sessionstore-backups", create: true)
        try backups.write(Self.moz(["version": ["sessionrestore",1], "windows": [["tabs": [Self.tab("https://recovery.example.test/")]]]]), to: "recovery.jsonlz4")
        #expect(try FirefoxSessionReader.read(root: root, zen: false).windows[0].tabs[0].url.host == "open.example.test")
        try root.write(Data("broken".utf8), to: "sessionstore.jsonlz4")
        #expect(try FirefoxSessionReader.read(root: root, zen: false).windows[0].tabs[0].url.host == "recovery.example.test")
        try backups.write(Self.moz(["version": ["sessionrestore",1], "windows": [["tabs": [Self.tab("https://previous.example.test/")]]]]), to: "previous.jsonlz4")
        #expect(try FirefoxSessionReader.read(root: root, zen: false).windows[0].tabs[0].url.host == "recovery.example.test")
        for bytes in [Data(), Data("mozLz40\0".utf8) + Data([255,255,255,127]), Data(Self.mozBytes(Data("abc".utf8)).dropLast())] {
            #expect(throws: (any Error).self) { try MozLz4.decode(bytes) }
        }
        var tab = Self.tab("https://workspace.example.test/"); tab["zenWorkspace"] = "work"
        var isolated = tab; isolated["userContextId"] = 2
        var essential = Self.tab("https://essential.example.test/"); essential["zenEssential"] = true; essential["_zenPinnedInitialState"] = ["entry": ["url": "https://essential-base.example.test/"]]
        try root.write(Self.moz(["spaces": [["uuid":"work", "name":"Work", "containerTabId":0], ["uuid":"container", "name":"Container", "containerTabId":2]], "tabs": [tab, isolated, essential], "groups":[["id":"unsupported"]]]), to: "zen-sessions.jsonlz4")
        let result = try FirefoxSessionReader.read(root: root, zen: true)
        #expect(result.windows.count == 2 && result.windows[1].name == "Work")
        #expect(result.windows[0].tabs[0].pinnedURL?.host == "essential-base.example.test" && result.counts["unsupportedIsolatedTabs"] == 1 && result.counts["unsupportedWorkspaces"] == 1)
    }
    @Test func locksSymlinksMalformedSchemaAndConsentManifest() throws {
        let f = try Fixture(); defer { f.base.remove() }
        let profile = f.source.appendingPathComponent(Self.profile.directory)
        for name in ["parent.lock", ".parentlock", "lock"] {
            try FileManager.default.createSymbolicLink(atPath: profile.appendingPathComponent(name).path, withDestinationPath: "127.0.0.1:+999999")
            #expect(throws: ArcImportError.arcIsRunning) { try f.snapshot() }
            try FileManager.default.removeItem(at: profile.appendingPathComponent(name))
        }
        let snapshot = try f.snapshot(Self.adapter(consent: false)); defer { snapshot.remove() }
        #expect(!FileManager.default.fileExists(atPath: snapshot.directory.appendingPathComponent("cookies.sqlite").path))
        try FileManager.default.createSymbolicLink(atPath: profile.appendingPathComponent("sessionstore-backups").path, withDestinationPath: profile.path)
        // Missing optional subdirectories are allowed, but selected content cannot follow symlinks.
        let file = profile.appendingPathComponent("sessionstore.jsonlz4")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: profile.appendingPathComponent("logins.json"))
        #expect(throws: (any Error).self) { try f.snapshot() }
    }
    @Test func legacyZenAndMalformedBounds() throws {
        let f = try Fixture(); defer { f.base.remove() }
        try f.writer.execute("CREATE TABLE zen_workspaces(uuid TEXT,name TEXT,container_id INTEGER,position INTEGER,created_at INTEGER); INSERT INTO zen_workspaces VALUES('legacy','Legacy',0,0,1)")
        let profile = f.source.appendingPathComponent(Self.profile.directory)
        var tab = Self.tab("https://legacy.example.test/"); tab["zenWorkspace"] = "legacy"
        try Self.moz(["version": ["sessionrestore",1], "windows": [["tabs": [tab]]]]).write(to: profile.appendingPathComponent("sessionstore.jsonlz4"))
        let snapshot = try f.snapshot(Self.adapter(zen: true)); defer { snapshot.remove() }
        let root = try OrbitSecureDirectory.open(snapshot.directory, create: false)
        #expect(try FirefoxSessionReader.read(root: root, zen: true).windows.first?.name == "Legacy")
        let badCookie = f.base.root.appendingPathComponent("future.sqlite")
        let db = try AuthenticationSQLite(badCookie); try db.execute("PRAGMA user_version=18")
        #expect(throws: BrowserAuthenticationImportError.schema) { try FirefoxCookieImport.inspect(file: badCookie) }
        let oversized = profile.appendingPathComponent("sessionstore.jsonlz4")
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(MozLz4.maximumBytes + 1)); try handle.close()
        #expect(throws: ArcImportError.unsupportedSourceFile) { try f.snapshot() }
        #expect(throws: (any Error).self) { try FirefoxSessionReader.json(Data((String(repeating: "[", count: 65) + String(repeating: "]", count: 65)).utf8)) }
        // A real overlapping match, followed by a final literal-only sequence.
        let block = Data("mozLz40\0".utf8) + Data([14,0,0,0,0x10,97,1,0,0x90]) + Data(repeating: 98, count: 9)
        #expect(try MozLz4.decode(block) == Data("aaaaabbbbbbbbb".utf8))
    }
    @Test func regularParentLockQueriesOwningProcess() throws {
        let f = try Fixture(); defer { f.base.remove() }
        let lock = f.source.appendingPathComponent(Self.profile.directory + "/.parentlock")
        try Data().write(to: lock)
        let unlocked = try f.snapshot(); unlocked.remove()
        let child = Process(), ready = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'r+'); fcntl.lockf(f,fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.read()", lock.path]
        child.standardOutput = ready; let input = Pipe(); child.standardInput = input
        try child.run()
        defer { try? input.fileHandleForWriting.close(); child.waitUntilExit() }
        #expect(String(data: ready.fileHandleForReading.availableData, encoding: .utf8)?.contains("ready") == true)
        #expect(throws: ArcImportError.arcIsRunning) { try f.snapshot() }
    }
    @Test func productRestore() throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_FIREFOX_RESTORE_ROOT"] else { return }
        let run = try BrowserAuthenticationRun.open(dataRoot: URL(fileURLWithPath: path), recoveryKey: BrowserImportRecoveryTests.key)
        try run.restore(confirmDeletingLaterChanges: true, usage: NeverRunningProbe())
        #expect(run.status.phase == .restored)
    }
}
