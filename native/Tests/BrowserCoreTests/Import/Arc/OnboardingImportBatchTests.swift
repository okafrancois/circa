import CryptoKit
import Foundation
import Testing
@testable import BrowserCore

@Suite struct OnboardingImportBatchTests {
    @Test(arguments: [false, true])
    func selectedProfilesShareRecovery(interrupted: Bool) async throws {
        let fixture = try ChromiumImportTests.Fixture()
        defer { fixture.remove() }
        _ = try await fixture.base.seedExistingSession()
        let before = try Data(contentsOf: fixture.base.sessionFile)
        let target = try fixture.base.target()
        let key = SymmetricKey(size: .bits256)
        var inputs: [BrowserAuthenticationRun.Input] = []
        defer { for index in inputs.indices { inputs[index].discard() } }
        for directory in ["Default", "Profile 1"] {
            let database = try AuthenticationSQLite(fixture.root.appendingPathComponent(directory + "/Login Data"))
            try database.execute("CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',43),('last_compatible_version',40)")
            try database.execute("CREATE TABLE logins(id INTEGER,signon_realm TEXT,origin_url TEXT,action_url TEXT,username_element TEXT,username_value TEXT,password_element TEXT,password_value BLOB,date_created INTEGER,date_last_used INTEGER,date_password_modified INTEGER,blacklisted_by_user INTEGER,scheme INTEGER,federation_url TEXT)")
            let sourceKey = try ArcChromiumCookieCipher.deriveKey(password: Data("mock-source".utf8))
            let encrypted = try ArcChromiumCookieCipher.encrypt(Data("synthetic-password".utf8), key: sourceKey).map { String(format: "%02x", $0) }.joined()
            try database.execute("INSERT INTO logins VALUES(1,'https://login.example/','https://login.example/','','username','synthetic','password',X'\(encrypted)',10,20,30,0,0,'')")
            let adapter = fixture.adapter(directory: directory)
            let preparation = try await fixture.importer(adapter).prepare(for: target)
            let authentication = try ChromiumAuthenticationSnapshot.capture(source: fixture.root,
                adapter: adapter, consent: true, parent: fixture.base.snapshots, probe: NeverRunningProbe())
            inputs.append(.init(preparation: preparation, adapter: adapter, consent: true,
                authentication: authentication, sourcePassword: Data("mock-source".utf8),
                targetPassword: Data("mock-target".utf8)))
        }
        do {
            let run = try await BrowserAuthenticationRun.applyBatch(inputs,
                importer: fixture.importer(fixture.adapter()), target: target, recoveryKey: key,
                elapsedBeforeApply: 2.5, checkpoint: { point in
                    if interrupted && point == "auth-passwords-pending" { throw BrowserAuthenticationImportError.invalidState }
                })
            #expect(!interrupted)
            #expect(run.status.importDuration ?? 0 >= 2.5)
        } catch {
            if !interrupted { await target.close(); throw error }
        }
        await target.close()
        let root = fixture.base.sessionFile.deletingLastPathComponent()
        let run = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: key)
        #expect(run.status.profileIDs.count == 2 && run.status.passwords == 2)
        #expect(Set(run.status.sourceProfiles) == Set(["Default", "Profile 1"]))
        #expect(run.status.phase == .passwordsPending)
        #expect(run.status.outcome?.historyInserted == 8)
        let groups = try run.passwordGroupsForRuntime()
        #expect(groups.map(\.profileID) == run.status.profileIDs)
        #expect(groups.map { $0.passwords.count } == [1, 1])
        #expect(throws: BrowserAuthenticationImportError.invalidState) { try run.passwordsForRuntime() }
        let document = try BrowserSessionFileStore().load(from: fixture.base.sessionFile)
        #expect(run.status.profileIDs.allSatisfy { id in document.profiles.contains { $0.id == id } })
        if !interrupted {
            try run.beginPasswordApplication()
            try run.markVerified()
            #expect(run.status.phase == .verified)
        }
        try run.restore(confirmDeletingLaterChanges: true, usage: NeverRunningProbe())
        #expect(try Data(contentsOf: fixture.base.sessionFile) == before)
        for id in run.status.profileIDs {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Chromium/profile-" + id.rawValue.uuidString.lowercased()).path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("History/" + id.rawValue.uuidString).path))
        }
    }

    @Test func rejectsDuplicateOrUnconsentedSelection() async throws {
        let fixture = try ChromiumImportTests.Fixture()
        defer { fixture.remove() }
        _ = try await fixture.base.seedExistingSession()
        let before = try Data(contentsOf: fixture.base.sessionFile)
        let target = try fixture.base.target()
        let adapter = fixture.adapter(), importer = fixture.importer(fixture.adapter())
        let preparation = try await importer.prepare(for: target)
        defer { preparation.discard() }
        let input = BrowserAuthenticationRun.Input(preparation: preparation, adapter: adapter, consent: true)
        do {
            _ = try await BrowserAuthenticationRun.applyBatch([input, input], importer: importer, target: target, recoveryKey: SymmetricKey(size: .bits256))
            Issue.record("Duplicate profile was accepted")
        } catch { #expect(error as? BrowserAuthenticationImportError == .targetNotFresh) }
        do {
            _ = try await BrowserAuthenticationRun.applyBatch([.init(preparation: preparation, adapter: adapter, consent: false)],
                importer: importer, target: target, recoveryKey: SymmetricKey(size: .bits256))
            Issue.record("Missing consent was accepted")
        } catch { #expect(error as? BrowserAuthenticationImportError == .consentRequired) }
        await target.close()
        #expect(try Data(contentsOf: fixture.base.sessionFile) == before)
    }
}
