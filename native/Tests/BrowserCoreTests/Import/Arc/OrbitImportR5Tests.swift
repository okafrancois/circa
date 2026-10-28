@testable import BrowserCore
import Darwin
import Foundation
import Testing

@Suite("source browser import R5 recovery", .serialized)
struct OrbitImportR5Tests {
    private let backupID = "20261025T210000Z-12345678"

    private func interrupted() throws -> (URL, ArcImportDataLocation, Data) {
        let root = try OrbitFixture.temporaryDirectory("orbit-r5-recovery")
        let location = ArcImportDataLocation(sessionFile: root.appendingPathComponent("session.json"))
        let imports = try OrbitSecureDirectory.open(location.importDirectory, create: true)
        let previous = try imports.directory(".restore-\(backupID)/previous", create: true)
        let staged = try imports.directory(".restore-\(backupID)/staged", create: true)
        let original = Data("synthetic original bytes".utf8)
        try previous.write(original, to: "session.json")
        try staged.write(Data("synthetic replacement bytes".utf8), to: "session.json")
        let moves = [ArcImportRestore.Move(from: "session.json", to: "Import/.restore-\(backupID)/previous/session.json"),
                     ArcImportRestore.Move(from: "Import/.restore-\(backupID)/staged/session.json", to: "session.json")]
        try imports.write(ArcImportFiles.encoder().encode(ArcImportRestore.Journal(backupID: backupID, phase: .swapping, moves: moves)),
                          to: ArcImportRestore.journalName)
        return (root, location, original)
    }

    @Test("R5-2 A completed rollback with partly deleted staging survives repeated recovery")
    func completedRollbackCleanup() throws {
        let (root, location, original) = try interrupted()
        defer { try? FileManager.default.removeItem(at: root) }
        let journalURL = ArcImportRestore.journalFile(location)
        // Exact crash boundary: rollback and durable marker completed, then staging was unlinked.
        var journal = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        journal["phase"] = "rollbackCompleted"
        try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)
        let previous = location.importDirectory.appendingPathComponent(".restore-\(backupID)/previous/session.json")
        try FileManager.default.moveItem(at: previous, to: location.sessionFile)
        try FileManager.default.removeItem(at: location.importDirectory.appendingPathComponent(".restore-\(backupID)/staged/session.json"))
        for _ in 0..<5 {
            try ArcImportBackups.recoverInterruptedRestore(at: location)
            #expect(try Data(contentsOf: location.sessionFile) == original)
        }
        #expect(!ArcImportBackups.hasInterruptedRestore(at: location))
    }

    @Test("R5-3 An inaccessible previous folder blocks both recovery paths and retains the journal")
    func inaccessiblePrevious() throws {
        for readable in [true, false] {
            let (root, location, original) = try interrupted()
            defer { try? FileManager.default.removeItem(at: root) }
            let previous = location.importDirectory.appendingPathComponent(".restore-\(backupID)/previous")
            if !readable { try Data("{".utf8).write(to: ArcImportRestore.journalFile(location)) }
            #expect(chmod(previous.path, 0) == 0)
            defer { chmod(previous.path, 0o700) }
            #expect(throws: (any Error).self) {
                try ArcImportBackups.recoverRestore(at: location, usage: NeverRunningProbe())
            }
            #expect(ArcImportBackups.hasInterruptedRestore(at: location))
            #expect(!FileManager.default.fileExists(atPath: location.sessionFile.path))
            #expect(chmod(previous.path, 0o700) == 0)
            #expect(try Data(contentsOf: previous.appendingPathComponent("session.json")) == original)
            _ = try ArcImportBackups.recoverRestore(at: location, usage: NeverRunningProbe())
            #expect(try Data(contentsOf: location.sessionFile) == original)
            _ = try ArcImportBackups.recoverRestore(at: location, usage: NeverRunningProbe())
            #expect(try Data(contentsOf: location.sessionFile) == original)
        }
    }

    @Test("R5-3 A linked restore work directory is refused without discarding the marker")
    func linkedWorkIsNotAbsence() throws {
        let (root, location, original) = try interrupted()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = location.importDirectory.appendingPathComponent(".restore-\(backupID)")
        let parked = root.appendingPathComponent("held-work")
        try FileManager.default.moveItem(at: work, to: parked)
        try FileManager.default.createSymbolicLink(at: work, withDestinationURL: parked)
        try Data("{".utf8).write(to: ArcImportRestore.journalFile(location))
        #expect(throws: (any Error).self) {
            try ArcImportBackups.recoverRestore(at: location, usage: NeverRunningProbe())
        }
        #expect(ArcImportBackups.hasInterruptedRestore(at: location))
        #expect(try Data(contentsOf: parked.appendingPathComponent("previous/session.json")) == original)
    }

    @Test("A completed explicit recovery resumes evidence moves without deleting unresolved originals")
    func completedEvidenceRecovery() throws {
        let (root, location, original) = try interrupted()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = ArcImportRestore.journalFile(location)
        var journal = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        journal["phase"] = "rollbackCompleted"
        journal["evidenceRelativePath"] = "Recovered/synthetic-evidence"
        journal["evidenceWorks"] = [".restore-\(backupID)"]
        try JSONSerialization.data(withJSONObject: journal).write(to: marker)
        try Data("synthetic occupied destination".utf8).write(to: location.sessionFile)
        for _ in 0..<5 { try ArcImportBackups.recoverInterruptedRestore(at: location) }
        let saved = location.importDirectory.appendingPathComponent("Recovered/synthetic-evidence/restore-\(backupID)/previous/session.json")
        #expect(try Data(contentsOf: saved) == original)
        #expect(try Data(contentsOf: location.sessionFile) == Data("synthetic occupied destination".utf8))
    }


    @Test("An inaccessible Import ancestor is a pending recovery, never an absent journal")
    func inaccessibleImportRoot() throws {
        let (root, location, original) = try interrupted()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(chmod(location.importDirectory.path, 0) == 0)
        defer { chmod(location.importDirectory.path, 0o700) }
        #expect(ArcImportBackups.hasInterruptedRestore(at: location))
        #expect(throws: (any Error).self) { try ArcImportBackups.recoverInterruptedRestore(at: location) }
        #expect(!FileManager.default.fileExists(atPath: location.sessionFile.path))
        #expect(chmod(location.importDirectory.path, 0o700) == 0)
        try ArcImportBackups.recoverInterruptedRestore(at: location)
        #expect(try Data(contentsOf: location.sessionFile) == original)
    }


    @Test("Backup creation never records an inaccessible existing history as absent")
    func inaccessibleHistoryBackup() throws {
        let root = try OrbitFixture.temporaryDirectory("orbit-r5-backup")
        defer { try? FileManager.default.removeItem(at: root) }
        let location = ArcImportDataLocation(sessionFile: root.appendingPathComponent("session.json"))
        let profile = ProfileID()
        let folder = try OrbitSecureDirectory.open(location.historyDirectory, create: true)
            .directory(profile.rawValue.uuidString, create: true)
        let bytes = Data("synthetic retained database bytes".utf8)
        try folder.write(bytes, to: "history.sqlite")
        #expect(chmod(folder.path, 0) == 0)
        defer { chmod(folder.path, 0o700) }
        #expect(throws: ArcImportError.backupFailed) {
            try ArcImportBackups.create(at: location, session: nil, historyProfiles: [profile], now: Date())
        }
        #expect(ArcImportBackups.manifests(at: location).isEmpty)
        #expect(chmod(folder.path, 0o700) == 0)
        #expect(folder.read("history.sqlite") == bytes)
    }


    @Test("A corrupt journal after partial rollback cleanup refuses ambiguous reversal of the live session")
    func corruptCompletedCleanupIsAmbiguous() throws {
        let (root, location, original) = try interrupted()
        defer { try? FileManager.default.removeItem(at: root) }
        let imports = try OrbitSecureDirectory.open(location.importDirectory, create: false)
        let backup = try imports.directory("Backups/" + backupID, create: true)
        let manifest = ArcImportBackupManifest(id: backupID, createdAt: Date(), sessionPresent: true,
                                              historyProfiles: [:], ledgerPresent: false, appearancePresent: false)
        try backup.write(ArcImportFiles.encoder().encode(manifest), to: "manifest.json")
        let work = location.importDirectory.appendingPathComponent(".restore-\(backupID)")
        try FileManager.default.moveItem(at: work.appendingPathComponent("previous/session.json"), to: location.sessionFile)
        try FileManager.default.removeItem(at: work.appendingPathComponent("staged/session.json"))
        try Data("{".utf8).write(to: ArcImportRestore.journalFile(location))
        for _ in 0..<5 {
            #expect(throws: ArcImportError.restoreJournalUnreadable) {
                try ArcImportBackups.recoverRestore(at: location, usage: NeverRunningProbe())
            }
            #expect(ArcImportBackups.hasInterruptedRestore(at: location))
            #expect(try Data(contentsOf: location.sessionFile) == original)
        }
    }


    @Test("Truncated backup sidecars are rejected before the current files are parked", arguments: ["ledger.json", "space-appearance.json"])
    func corruptBackupSidecar(_ damagedName: String) throws {
        let root = try OrbitFixture.temporaryDirectory("orbit-r5-sidecar")
        defer { try? FileManager.default.removeItem(at: root) }
        let location = ArcImportDataLocation(sessionFile: root.appendingPathComponent("session.json"))
        let imports = try OrbitSecureDirectory.open(location.importDirectory, create: true)
        let backup = try imports.directory("Backups/" + backupID, create: true)
        let session = try BrowserSessionDocument(profiles: [], spaces: [], windows: [], tabs: []).encoded()
        let ledger = try ArcImportFiles.encoder().encode(BrowserImportLedger())
        let appearance = try ArcImportFiles.encoder().encode(BrowserSpaceAppearanceDocument())
        try ArcImportFiles.writePrivate(session, to: location.sessionFile)
        try imports.write(ledger, to: "arc-import-ledger.json")
        try imports.write(appearance, to: "space-appearance.json")
        try backup.write(session, to: "session.json")
        try backup.write(ledger, to: "ledger.json")
        try backup.write(appearance, to: "space-appearance.json")
        try backup.write(Data("{".utf8), to: damagedName)
        let manifest = ArcImportBackupManifest(id: backupID, createdAt: Date(), sessionPresent: true,
                                              historyProfiles: [:], ledgerPresent: true, appearancePresent: true)
        try backup.write(ArcImportFiles.encoder().encode(manifest), to: "manifest.json")
        #expect(throws: ArcImportError.backupInvalid) {
            try ArcImportBackups.restore(backupID, at: location, usage: NeverRunningProbe())
        }
        #expect(try Data(contentsOf: location.sessionFile) == session)
        #expect(try Data(contentsOf: location.ledgerFile) == ledger)
        #expect(try Data(contentsOf: location.appearanceFile) == appearance)
        #expect(!ArcImportBackups.hasInterruptedRestore(at: location))
        #expect(!imports.exists(".restore-" + backupID))
    }

}
