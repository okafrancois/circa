import CryptoKit
import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite(.serialized)
struct BrowserImportRecoveryTests {
    static let structural = ["afterLock", "afterBackup", "afterJournal", "afterApply", "afterPersist", "afterLedger", "afterAppearance", "afterHistoryChunk(1)", "afterHistoryChunk(2)", "afterCompletion"]
    static let structuralRestore = ["structural-restore-journal", "structural-restore-move-0", "structural-restore-move-1", "structural-restore-move-2", "structural-restore-move-3", "structural-restore-move-4", "structural-restore-cleanup"]
    static let authentication = ["auth-prepared", "auth-applying", "auth-file:Cookies", "auth-file:Local Storage/value",
                                 "auth-passwords-pending", "auth-passwords-applying", "auth-password-row", "auth-verified",
                                 "auth-before-archive", "auth-after-archive", "auth-restoring", "auth-restore-engine",
                                 "auth-restore-history", "auth-restore-file:session.json", "auth-restored"]
    static let restoration = ["recovery-journal", "recovery-profile", "recovery-file:session.json",
                              "recovery-file:Import/arc-import-ledger.json", "recovery-file:Import/space-appearance.json",
                              "recovery-file:Import/arc-import-journal.json", "recovery-authentication", "recovery-complete"]
    static let key = SymmetricKey(data: Data(repeating: 33, count: 32))

    static func inventory(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let file as URL in entries {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if relative.hasPrefix("ImportRecovery") || relative.hasPrefix("Import/Backups") || relative.hasPrefix("AuthenticationImport") || relative.hasPrefix(".orbit") { continue }
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[relative] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }
    private func child(_ root: URL, phase: String, action: String, choice: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var args: [String] = []
        if let index = CommandLine.arguments.firstIndex(of: "--test-bundle-path") {
            args += ["--test-bundle-path", CommandLine.arguments[index + 1]]
        }
        process.arguments = args + ["--filter", "BrowserImportRecoveryTests/worker", "--testing-library", "swift-testing"]
        var env = ProcessInfo.processInfo.environment
        env["ORBIT_IMPORT_RECOVERY_ROOT"] = root.path
        env["ORBIT_IMPORT_RECOVERY_PHASE"] = phase
        env["ORBIT_IMPORT_RECOVERY_ACTION"] = action
        env["ORBIT_IMPORT_RECOVERY_CHOICE"] = choice
        process.environment = env
        let log = root.appendingPathComponent(action + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        try process.run(); process.waitUntilExit()
        if process.terminationReason != .uncaughtSignal && process.terminationStatus != 0 {
            print(try String(contentsOf: log, encoding: .utf8))
        }
        return process
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_IMPORT_RECOVERY_CRASH_MATRIX"] == "1"))
    func sigkillMatrix() throws {
        for phase in Self.structural + Self.structuralRestore + Self.authentication + Self.restoration {
            for choice in ["restore", "continueWithoutImport"] {
                let fixture = try OrbitFixture.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: fixture) }
                let killed = try child(fixture, phase: phase, action: "mutate", choice: choice)
                #expect(killed.terminationReason == .uncaughtSignal && killed.terminationStatus == SIGKILL, "Missing kill: \(phase)")
                let relaunched = try child(fixture, phase: phase, action: "recover", choice: choice)
                #expect(relaunched.terminationStatus == 0, "Recovery failed: \(phase), \(choice)")
                let result = try Data(contentsOf: fixture.appendingPathComponent("result.json"))
                print("RECOVERY-MATRIX \(phase) \(choice) \(String(decoding: result, as: UTF8.self))")
            }
        }
    }
    @Test func fallbackRetainsImportedDataAndRestoresOriginalBytes() async throws {
        let fixture = try ChromiumImportTests.Fixture(); defer { fixture.remove() }
        _ = try await fixture.base.seedExistingSession()
        let root = fixture.base.sessionFile.deletingLastPathComponent()
        let before = try Self.inventory(root)
        var importer = fixture.importer(fixture.adapter())
        importer.checkpoint = { if $0 == .afterPersist { throw ArcImportError.cancelled } }
        let target = try fixture.base.target()
        do { _ = try await importer.apply(importer.prepare(for: target), to: target) } catch { }
        await target.close()
        let recovery = try #require(try BrowserImportRecovery.open(at: root))
        let fallback = try recovery.recover(.restore, copyOriginal: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        #expect(fallback)
        #expect(try Self.inventory(root) == before)
        #expect(try BrowserImportRecovery.open(at: root) == nil)
        let archives = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("ImportRecoveryHistory"), includingPropertiesForKeys: nil)
        #expect(archives.count == 1)
        #expect(FileManager.default.fileExists(atPath: archives[0].appendingPathComponent("Quarantine/session.json").path))
    }
    @Test func worker() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ORBIT_IMPORT_RECOVERY_ROOT"], let phase = env["ORBIT_IMPORT_RECOVERY_PHASE"] else { return }
        let base = URL(fileURLWithPath: path), root = base.appendingPathComponent("data")
        let session = root.appendingPathComponent("session.json")
        let choice = BrowserImportRecovery.Choice(rawValue: env["ORBIT_IMPORT_RECOVERY_CHOICE"] ?? "restore")!
        func checkpoint(_ point: String) {
            if point == phase { kill(getpid(), SIGKILL); while true { pause() } }
        }
        if env["ORBIT_IMPORT_RECOVERY_ACTION"] == "recover" {
            var offered = false, started = false
            let lease = try OrbitRecoveryRootLock(root: root)
            try OrbitAuthenticationStartupGate.runRegistered(lease: lease, product: .daily, backend: {
                throw OrbitRecoveryFailure.keyUnavailable
            }, beforeStructuralRecovery: {
                if let recovery = try BrowserImportRecovery.open(at: root) {
                    if recovery.needsRecovery {
                        offered = true; try recovery.recover(choice, holdingLock: true)
                    } else { try recovery.finishCompleted() }
                } else if let backup = try ArcImportBackups.interruptedImportBackup(at: .init(sessionFile: session)) {
                    offered = true
                    try ArcImportBackups.restore(backup, at: .init(sessionFile: session), usage: NeverRunningProbe(), holdingLock: true)
                } else if try BrowserAuthenticationRun.exists(dataRoot: root) {
                    let run = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: Self.key)
                    if run.status.phase == .restoring {
                        offered = true
                        try run.restore(confirmDeletingLaterChanges: true, usage: NeverRunningProbe(), holdingLock: true)
                    }
                }
            }, runtimeStart: {
                if phase == "auth-passwords-pending" {
                    let run = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: Self.key)
                    try run.beginPasswordApplication()
                    try run.markVerified()
                }
                started = true
            })
            let terminal = ["auth-before-archive", "auth-after-archive", "auth-passwords-pending"]
            let before = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: base.appendingPathComponent("before.json")))
            var after = try Self.inventory(root)
            if Self.structuralRestore.contains(phase) { after.removeValue(forKey: "Import/arc-import-journal.json") }
            let intact = before.filter { !terminal.contains(phase) || $0.key != "session.json" }.allSatisfy { after[$0.key] == $0.value }
            // Completed authentication intentionally keeps imported session data. Every other
            // case must recover the complete inventory, including session bytes and absences.
            if !terminal.contains(phase) { #expect(after == before) }
            else {
                #expect(before.filter { $0.key != "session.json" }.allSatisfy { after[$0.key] == $0.value })
            }
            #expect(started)
            if !terminal.contains(phase) && phase != "auth-restored" && phase != "recovery-complete" { #expect(offered) }
            let result: [String: Any] = ["started": started, "offered": offered, "inventoryEqual": intact, "files": before.count,
                                         "beforeInventory": before, "afterInventory": after]
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: base.appendingPathComponent("result.json"))
            return
        }
        let fixture = try ChromiumImportTests.Fixture()
        // SIGKILL bypasses defer: keep every source/snapshot inside the parent's disposable root.
        let source = base.appendingPathComponent("source"), snapshots = base.appendingPathComponent("snapshots")
        try FileManager.default.moveItem(at: fixture.root, to: source)
        fixture.remove()
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BrowserStore()
        for index in 0..<2 {
            let profile = await store.createProfile(name: "Existing \(index)")
            let space = try await store.createSpace(name: "Existing \(index)", profileID: profile)
            if index == 0 {
                let window = try await store.createWindow(activeSpaceID: space)
                _ = try await store.openTab(url: URL(string: "about:blank")!, from: store.captureContext(in: window), activate: true)
            }
            let engine = root.appendingPathComponent("Chromium/profile-" + profile.rawValue.uuidString.lowercased())
            try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
            for name in ["Cookies", "Login Data", "Preferences", "Local Storage/value"] {
                let file = engine.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let bytes = name == "Preferences" ? Data("{\"synthetic\":true}".utf8) : Data("synthetic pre-existing \(index) \(name)".utf8)
                try bytes.write(to: file)
            }
            let history = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("History"))
            _ = try await history.record(BrowserHistoryVisit(url: URL(string: "https://existing.example.test/\(index)")!, visitedAt: Date(timeIntervalSince1970: 1_760_000_000)))
            try await history.close()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("Chromium").path)
        try BrowserSessionFileStore().save(await store.sessionDocument(), to: session)
        try Data("{\"synthetic\":true}".utf8).write(to: root.appendingPathComponent("settings.json"))
        try Data(repeating: 33, count: 32).write(to: root.appendingPathComponent("import-auth-fixture-key"))
        try JSONEncoder().encode(Self.inventory(root)).write(to: base.appendingPathComponent("before.json"))
        let descriptor = ChromiumImportRegistry.descriptors.first { $0.id == "chrome" }!
        let adapter = ChromiumBrowserImportAdapter(descriptor: descriptor, installationID: UUID(),
            profile: .init(directory: "Default", name: "Synthetic"),
            placement: .init(importedSpace: "Imported", bookmarkFolder: "Imported Bookmarks", windowName: "Imported Window"))
        var options = ArcImportOptions(); options.historyChunkSize = 2
        var importer = BrowserImportOrchestrator(source: source, options: options, probe: NeverRunningProbe(), snapshotParent: snapshots)
        importer.adapter = adapter
        importer.checkpoint = { point in
            if String(describing: point) == phase { kill(getpid(), SIGKILL); while true { pause() } }
        }
        let target = try ArcOfflineImportTarget(sessionFile: session, usage: NeverRunningProbe())
        if Self.structural.contains(phase) || Self.structuralRestore.contains(phase) {
            let outcome = try await importer.apply(importer.prepare(for: target), to: target)
            await target.close()
            if Self.structuralRestore.contains(phase) {
                let lock = try OrbitDataDirectoryLock.acquire(root, exclusive: true)
                defer { lock.release() }
                try ArcImportRestore(id: outcome.backupID, location: .init(sessionFile: session)).run(diskSpace: OrbitSystemDiskSpaceProbe(), interruption: nil, checkpoint: checkpoint)
            }
        } else {
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
            let auth = try ChromiumAuthenticationSnapshot.capture(source: source, adapter: adapter, consent: true, parent: snapshots, probe: NeverRunningProbe())
            let run = try await BrowserAuthenticationRun.apply(preparation: importer.prepare(for: target), importer: importer, target: target,
                authentication: auth, sourcePassword: Data("mock-source".utf8), targetPassword: Data("mock_password".utf8), recoveryKey: Self.key,
                checkpoint: checkpoint)
            await target.close()
            if phase == "product-fixture" { return }
            if Self.restoration.contains(phase) {
                let recovery = try #require(try BrowserImportRecovery.open(at: root))
                try recovery.recover(choice, checkpoint: checkpoint)
            } else {
                try run.beginPasswordApplication()
                let destination = root.appendingPathComponent("Chromium/profile-" + run.status.profileID.rawValue.uuidString.lowercased() + "/Login Data")
                try Data("synthetic applied password".utf8).write(to: destination)
                checkpoint("auth-password-row")
                try run.markVerified()
                if phase.hasPrefix("auth-restore") || phase == "auth-restoring" {
                    try run.restore(confirmDeletingLaterChanges: true, usage: NeverRunningProbe())
                } else { _ = try run.archiveCompleted() }
            }
        }
        Issue.record("Crash boundary was not reached: \(phase)")
    }
}
