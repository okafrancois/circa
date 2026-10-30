import BrowserCore
import BrowserEngine
import CryptoKit
import Darwin
import Foundation
import Testing

@MainActor
private final class ImportPasswordStore: BrowserPasswordStore {
    var rows: [ProfileID: [BrowserPasswordRecord]] = [:]
    var adds = 0, removes = 0
    var unavailable = false
    var verificationSnapshot: [ProfileID: [BrowserPasswordRecord]]?
    var lists = 0
    var persisted: URL?
    let key = SymmetricKey(data: Data(repeating: 73, count: 32))
    struct DiskRow: Codable { var profile: ProfileID; var value: ImportedBrowserPassword }
    func list(profileID: ProfileID) async throws -> [BrowserPasswordRecord] {
        if unavailable { throw BrowserPasswordStoreError.unavailable }
        lists += 1
        if lists == 2, let snapshot = verificationSnapshot {
            verificationSnapshot = nil
            return snapshot[profileID] ?? []
        }
        return rows[profileID] ?? []
    }
    func add(_ value: BrowserPasswordRecord, profileID: ProfileID) async throws {
        guard !(rows[profileID] ?? []).contains(where: { $0.primaryKey == value.primaryKey }) else { throw BrowserPasswordStoreError.conflict }
        rows[profileID, default: []].append(value); adds += 1; try save()
    }
    func update(_ value: BrowserPasswordRecord, replacing key: BrowserPasswordKey, profileID: ProfileID) async throws {
        rows[profileID]?.removeAll { $0.primaryKey == key }; rows[profileID, default: []].append(value); try save()
    }
    func remove(_ key: BrowserPasswordKey, profileID: ProfileID) async throws {
        rows[profileID]?.removeAll { $0.primaryKey == key }; removes += 1; try save()
    }
    func changes(profileID: ProfileID) async throws -> AsyncStream<BrowserPasswordStoreChange> { AsyncStream { $0.finish() } }
    func save() throws {
        guard let persisted else { return }
        let values = rows.flatMap { profile, values in values.map { row -> DiskRow in
            var value = try! BrowserPasswordCSV.read(Data("url,username,password\nhttps://fixture.test/,fixture,secret\n".utf8)).passwords[0]
            value.realm = row.primaryKey.signonRealm; value.origin = row.primaryKey.originURL
            value.username = row.primaryKey.usernameValue; value.usernameElement = row.primaryKey.usernameElement
            value.passwordElement = row.primaryKey.passwordElement; value.password = row.passwordValue
            value.action = row.actionURL; value.created = row.dateCreated; value.lastUsed = row.dateLastUsed
            value.modified = row.datePasswordModified; value.blocked = row.blockedByUser; value.scheme = row.scheme
            return .init(profile: profile, value: value)
        } }
        try AES.GCM.seal(JSONEncoder().encode(values), using: key).combined!.write(to: persisted, options: .atomic)
    }
    func load() throws {
        guard let persisted, FileManager.default.fileExists(atPath: persisted.path) else { return }
        let values = try JSONDecoder().decode([DiskRow].self, from: AES.GCM.open(.init(combined: Data(contentsOf: persisted)), using: key))
        for row in values { rows[row.profile, default: []].append(ArcPasswordImportTests.record(row.value)) }
    }
}

@Suite(.serialized)
@MainActor
struct ArcPasswordImportTests {
    static let key = SymmetricKey(data: Data(repeating: 52, count: 32))
    static let profile = ProfileID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    static func values() throws -> [ImportedBrowserPassword] {
        try BrowserPasswordCSV.read(Data("url,username,password\nhttps://fixture.test/new,new,synthetic-secret-new\nhttps://fixture.test/equal,equal,synthetic-secret-equal\nhttps://fixture.test/conflict,conflict,synthetic-secret-source\nhttps://fixture.test/blocked,,\n".utf8)).passwords
    }
    static func record(_ value: ImportedBrowserPassword) -> BrowserPasswordRecord {
        .init(primaryKey: .init(signonRealm: value.realm, originURL: value.origin, usernameElement: value.usernameElement,
            usernameValue: value.username, passwordElement: value.passwordElement), actionURL: value.action, passwordValue: value.password,
            dateCreated: value.created, dateLastUsed: value.lastUsed, datePasswordModified: value.modified, blockedByUser: value.blocked, scheme: value.scheme)
    }
    func temporary() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-password-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    func job(_ root: URL) throws -> ArcPasswordImportJournal {
        var values = try Self.values()
        var blocked = values[0]; blocked.origin = "https://blocked.test/"; blocked.realm = blocked.origin
        blocked.username = ""; blocked.password = ""; blocked.blocked = true
        values = Array(values.prefix(3)) + [blocked]
        return try .create(root: root, key: Self.key, groups: [(Self.profile, values)], skipped: 3,
            sourcePassword: Data("synthetic-source-key".utf8), targetPassword: Data("synthetic-target-key".utf8))
    }
    fileprivate func seed(_ store: ImportPasswordStore) throws {
        let values = try Self.values()
        var changed = Self.record(values[2]); changed.passwordValue = "synthetic-orbit-value"
        var equal = Self.record(values[1]); equal.primaryKey.usernameElement = "different-form-element"
        store.rows[Self.profile] = [equal, changed]
    }
    @Test func conflictsUndoAndEncryption() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportPasswordStore(); try seed(store)
        let job = try job(root); try job.activate()
        try await ArcPasswordImportRunner.run(job, store: store)
        #expect(job.counts.added == 2 && job.counts.alreadyPresent == 1 && job.counts.kept == 1 && job.counts.skipped == 3)
        #expect(store.adds == 2 && store.rows[Self.profile]?.count == 4)
        try await ArcPasswordImportRunner.run(job, store: store)
        #expect(store.adds == 2)
        let sealed = try Data(contentsOf: root.appendingPathComponent("ArcPasswordImport/" + job.id.uuidString + ".sealed"))
        for secret in ["synthetic-secret", "fixture.test", "synthetic-source-key", "synthetic-target-key"] { #expect(sealed.range(of: Data(secret.utf8)) == nil) }
        #expect(job.rows.allSatisfy { $0.credential.password.isEmpty })
        var edited = try #require(store.rows[Self.profile]?.first { $0.primaryKey.usernameValue == "new" })
        edited.passwordValue = "edited-after-import"
        try await store.update(edited, replacing: edited.primaryKey, profileID: Self.profile)
        try job.activate(restoring: true)
        try await ArcPasswordImportRunner.run(job, store: store)
        #expect(job.counts.removed == 1 && job.counts.retained == 1)
        #expect(store.rows[Self.profile]?.count == 3)
        #expect(store.rows[Self.profile]?.contains { $0.passwordValue == "edited-after-import" } == true)
    }
    @Test func startupOrdering() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportPasswordStore(); try seed(store)
        let journal = try job(root); try journal.activate()
        var events: [String] = []
        await BrowserPasswordStartupGate.run(root: root, open: { try .open(root: root, key: Self.key, id: $0) }, apply: { loaded in
            events.append("profiles-ready")
            await Task.yield()
            #expect(!events.contains("sync-started"))
            try await ArcPasswordImportRunner.run(loaded, store: store)
            events.append("passwords-verified")
        }, choose: { Issue.record("Successful apply must not prompt"); return .continueWithoutImport },
            startApplication: { events += ["sync-started", "window-created", "page-created"] })
        #expect(events == ["profiles-ready", "passwords-verified", "sync-started", "window-created", "page-created"])
        #expect(try ArcPasswordImportJournal.activeID(root: root) == nil)
    }

    enum StartupFailure: CaseIterable { case unavailable, corruptJournal, missingKey, verificationMismatch }
    @Test(arguments: StartupFailure.allCases, [BrowserImportRecovery.Choice.restore, .continueWithoutImport])
    func failuresAlwaysLaunch(cause: StartupFailure, choice: BrowserImportRecovery.Choice) async throws {
        for undo in [false, true] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let store = ImportPasswordStore(); try seed(store)
            let journal = try job(root); try journal.activate()
            if undo {
                try await ArcPasswordImportRunner.run(journal, store: store)
                try journal.activate(restoring: true)
            }
            let sealed = root.appendingPathComponent("ArcPasswordImport/" + journal.id.uuidString + ".sealed")
            if cause == .corruptJournal { try Data("damaged fixture".utf8).write(to: sealed) }
            if cause == .unavailable { store.unavailable = true }
            if cause == .verificationMismatch { store.verificationSnapshot = store.rows; store.lists = 0 }
            let original = try Data(contentsOf: sealed)
            var decisions = 0, launches = 0, attempts = 0
            await BrowserPasswordStartupGate.run(root: root, open: { id in
                if cause == .missingKey { throw BrowserAuthenticationImportError.invalidState }
                return try .open(root: root, key: Self.key, id: id)
            }, apply: { loaded in
                #expect(launches == 0)
                attempts += 1
                try await ArcPasswordImportRunner.run(loaded, store: store)
            }, choose: {
                #expect(launches == 0)
                #expect((try? ArcPasswordImportJournal.activeID(root: root)) == nil)
                decisions += 1; return choice
            }, startApplication: { launches += 1 })
            #expect(decisions == 1 && launches == 1)
            #expect(attempts <= (choice == .restore ? 2 : 1))
            #expect(try ArcPasswordImportJournal.activeID(root: root) == nil)
            if choice == .continueWithoutImport {
                #expect(FileManager.default.fileExists(atPath: sealed.path))
                if cause == .corruptJournal || cause == .missingKey { #expect(try Data(contentsOf: sealed) == original) }
                else { #expect(try ArcPasswordImportJournal.open(root: root, key: Self.key, id: journal.id).phase == .abandoned) }
            } else if cause != .verificationMismatch {
                #expect(!FileManager.default.fileExists(atPath: sealed.path))
                let quarantine = root.appendingPathComponent("ArcPasswordImport/quarantine")
                let preserved = try FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
                #expect(preserved.count == 1)
                // Store unavailability can persist a new undo phase before the failed restore;
                // unreadable input must be preserved byte-for-byte.
                if cause == .corruptJournal || cause == .missingKey { #expect(try Data(contentsOf: preserved[0]) == original) }
            }
            await BrowserPasswordStartupGate.run(root: root, open: { _ in throw BrowserPasswordStoreError.unavailable },
                apply: { _ in Issue.record("No second automatic attempt") },
                choose: { Issue.record("No repeated alert"); return .restore }, startApplication: { launches += 1 })
            #expect(launches == 2)
        }
    }

    @Test(arguments: [BrowserImportRecovery.Choice.restore, .continueWithoutImport])
    func partialIntentCanBeRestoredAfterDecision(choice: BrowserImportRecovery.Choice) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportPasswordStore(); try seed(store)
        let journal = try job(root); try journal.activate()
        var launches = 0
        await BrowserPasswordStartupGate.run(root: root, open: { id in
            let loaded = try ArcPasswordImportJournal.open(root: root, key: Self.key, id: id)
            loaded.checkpoint = { if $0 == "password-after-add:0" { throw BrowserPasswordStoreError.backendFailure } }
            return loaded
        }, apply: { try await ArcPasswordImportRunner.run($0, store: store) }, choose: { choice }, startApplication: { launches += 1 })
        #expect(launches == 1 && store.adds == 1)
        if choice == .continueWithoutImport {
            let retained = try ArcPasswordImportJournal.open(root: root, key: Self.key, id: journal.id)
            #expect(retained.phase == .abandoned && retained.rows[0].state == .intent)
            #expect(retained.rows.allSatisfy { $0.credential.password.isEmpty })
            try retained.activate(restoring: true)
            try await ArcPasswordImportRunner.run(retained, store: store)
        }
        #expect(store.rows[Self.profile]?.count == 2 && store.removes == 1)
    }

    @Test func restoreFailureQuarantinesAndLaunches() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ImportPasswordStore(); try seed(store)
        let journal = try job(root); try journal.activate()
        var launches = 0
        await BrowserPasswordStartupGate.run(root: root, open: { id in
            let loaded = try ArcPasswordImportJournal.open(root: root, key: Self.key, id: id)
            loaded.checkpoint = { point in
                if point == "password-after-add:0" || point == "password-before-remove:0" { throw BrowserPasswordStoreError.backendFailure }
            }
            return loaded
        }, apply: { try await ArcPasswordImportRunner.run($0, store: store) }, choose: { .restore }, startApplication: { launches += 1 })
        #expect(launches == 1 && store.rows[Self.profile]?.count == 3)
        #expect(try ArcPasswordImportJournal.activeID(root: root) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("ArcPasswordImport/quarantine").path).count == 1)
    }

    @Test func worker() async throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_PASSWORD_CHILD_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        let id = try JSONDecoder().decode(UUID.self, from: Data(contentsOf: root.appendingPathComponent("id.json")))
        if ProcessInfo.processInfo.environment["ORBIT_PASSWORD_ALERT_CHILD"] == "1" {
            await BrowserPasswordStartupGate.run(root: root, open: { try .open(root: root, key: Self.key, id: $0) },
                apply: { _ in throw BrowserPasswordStoreError.unavailable }, choose: {
                    if ProcessInfo.processInfo.environment["ORBIT_PASSWORD_KILL"] == "password-alert" { kill(getpid(), SIGKILL) }
                    Issue.record("The decision must not repeat after a crash"); return .restore
                }, startApplication: { try? Data("launched".utf8).write(to: root.appendingPathComponent("launched")) })
            return
        }
        let job = try ArcPasswordImportJournal.open(root: root, key: Self.key, id: id)
        let store = ImportPasswordStore(); store.persisted = root.appendingPathComponent("mock-store.sealed")
        try store.load()
        job.checkpoint = { point in
            if ProcessInfo.processInfo.environment["ORBIT_PASSWORD_KILL"] == point { kill(getpid(), SIGKILL) }
        }
        if job.phase == .staged { try job.activate() }
        if ProcessInfo.processInfo.environment["ORBIT_PASSWORD_UNDO"] == "1", job.phase == .complete { try job.activate(restoring: true) }
        try await ArcPasswordImportRunner.run(job, store: store)
        if job.phase == .complete {
            #expect(job.counts.added == 2 && job.counts.alreadyPresent == 1 && job.counts.kept == 1)
            #expect(store.rows[Self.profile]?.count == 4)
        } else { #expect(job.phase == .restored && store.rows[Self.profile]?.count == 2) }
    }
    /// Child crash tests must not block unrelated MainActor transfer deadlines.
    private func launchAndWait(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() }
            catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
    }

    @Test func sigkillDuringDecisionDoesNotRepeat() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try job(root); try journal.activate()
        try JSONEncoder().encode(journal.id).write(to: root.appendingPathComponent("id.json"))
        func child(killPoint: String) async throws -> Process {
            let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            var args: [String] = []
            if let index = CommandLine.arguments.firstIndex(of: "--test-bundle-path") { args += ["--test-bundle-path", CommandLine.arguments[index + 1]] }
            process.arguments = args + ["--filter", "ArcPasswordImportTests/worker", "--testing-library", "swift-testing"]
            var env = ProcessInfo.processInfo.environment
            env["ORBIT_PASSWORD_CHILD_ROOT"] = root.path; env["ORBIT_PASSWORD_ALERT_CHILD"] = "1"; env["ORBIT_PASSWORD_KILL"] = killPoint
            process.environment = env; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try await launchAndWait(process); return process
        }
        let killed = try await child(killPoint: "password-alert")
        #expect(killed.terminationReason == .uncaughtSignal && killed.terminationStatus == SIGKILL)
        #expect(try ArcPasswordImportJournal.activeID(root: root) == nil)
        #expect(try await child(killPoint: "").terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ArcPasswordImport/" + journal.id.uuidString + ".sealed").path))
    }

    @Test func sigkillMatrix() async throws {
        let apply = ["password-pending", "password-active", "password-baseline", "password-intent:0", "password-after-add:0", "password-owned:0",
                     "password-intent:3", "password-after-add:3", "password-owned:3", "password-verified", "password-complete"]
        let undo = ["password-undo-pending", "password-before-remove:0", "password-after-remove:0", "password-removed:0",
                    "password-before-remove:3", "password-after-remove:3", "password-removed:3", "password-restored"]
        for point in apply + undo {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let job = try job(root)
            try JSONEncoder().encode(job.id).write(to: root.appendingPathComponent("id.json"))
            let store = ImportPasswordStore(); try seed(store); store.persisted = root.appendingPathComponent("mock-store.sealed"); try store.save()
            func child(kill point: String, restoring: Bool) async throws -> Process {
                let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                var args: [String] = []
                if let index = CommandLine.arguments.firstIndex(of: "--test-bundle-path") { args += ["--test-bundle-path", CommandLine.arguments[index + 1]] }
                process.arguments = args + ["--filter", "ArcPasswordImportTests/worker", "--testing-library", "swift-testing"]
                var env = ProcessInfo.processInfo.environment
                env["ORBIT_PASSWORD_CHILD_ROOT"] = root.path; env["ORBIT_PASSWORD_KILL"] = point; env["ORBIT_PASSWORD_UNDO"] = restoring ? "1" : "0"
                process.environment = env; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try await launchAndWait(process); return process
            }
            if undo.contains(point) { #expect(try await child(kill: "", restoring: false).terminationStatus == 0) }
            let killed = try await child(kill: point, restoring: undo.contains(point))
            #expect(killed.terminationReason == .uncaughtSignal && killed.terminationStatus == SIGKILL, "Missing checkpoint: \(point)")
            #expect(try await child(kill: "", restoring: undo.contains(point)).terminationStatus == 0, "Replay failed: \(point)")
            #expect(try await child(kill: "", restoring: undo.contains(point)).terminationStatus == 0, "Second replay failed: \(point)")
        }
    }
}
