@testable import BrowserCore
import CryptoKit
import Darwin
import Foundation
import SQLite3
import Testing

/// Regressions of the third cross-review of IMPORT (3 HIGH, 1 MEDIUM), synthetic data only.
@Suite("source browser import R4 regressions", .serialized)
struct OrbitImportR4Tests {
    private typealias Fixture = OrbitImportTestFixture

    private func listing(_ root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []).sorted()
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func importOnce(_ fixture: Fixture) async throws -> ArcImportOutcome {
        let target = try fixture.target()
        let outcome = try await fixture.importer().apply(try await fixture.importer().prepare(for: target), to: target)
        await target.close()
        return outcome
    }

    @discardableResult
    private func sqlite(_ path: String, _ statements: [String]) throws -> Int32 {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else { throw ArcImportError.historyDatabaseUnreadable }
        defer { sqlite3_close(handle) }
        for statement in statements {
            let result = sqlite3_exec(handle, statement, nil, nil, nil)
            guard result == SQLITE_OK else { return result }
        }
        return SQLITE_OK
    }

    private func count(_ path: String, _ table: String) -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT count(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: HIGH A — checked paths under the IMPORT-R5 accidental-failure model

    @Test("R4-A A folder replaced by a link before opening is refused without outside writes")
    func openRace() throws {
        let root = try OrbitFixture.temporaryDirectory("orbit-checked-open"); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Profile", isDirectory: true)
        let park = root.appendingPathComponent("Profile.held", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let pin = try OrbitSQLiteGuard.pin(openingDirectory: folder)
        defer { pin.release() }
        // R5 replaces the old active-race/inode-redirection guarantee with checked-path refusal.
        // The swap is complete before verification; no hostile concurrent mutator is modeled.
        try FileManager.default.moveItem(at: folder, to: park)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        let (opened, handle) = OrbitSQLiteGuard.open(folder.appendingPathComponent("history.sqlite").path,
                                                   flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        #expect(opened == SQLITE_CANTOPEN)
        #expect(handle == nil)
        sqlite3_close(handle)
        #expect(listing(outside).isEmpty)
        #expect(listing(park).isEmpty)
    }

    @Test("R4-A History survives a completed directory rename after close and subsequent reopen")
    func storeSwap() async throws {
        let root = try OrbitFixture.temporaryDirectory("orbit-history-rename"); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Original", isDirectory: true)
        let relocated = root.appendingPathComponent("Relocated", isDirectory: true)
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent,
                                             directory: original.appendingPathComponent("History"))
        for index in 0..<15 {
            _ = try await store.record(BrowserHistoryVisit(url: URL(string: "https://rename.example.test/\(index)")!, visitedAt: Date()))
        }
        try await store.close()
        // A user may move a closed synthetic data folder. New opens verify the new ancestor chain;
        // this does not promise safe SQLite writes during an active hostile directory swap.
        try FileManager.default.moveItem(at: original, to: relocated)
        let moved = try BrowserHistoryStore(profileID: profile, policy: .persistent,
                                             directory: relocated.appendingPathComponent("History"))
        #expect(try await moved.visits(limit: 100).count == 15)
        for index in 15..<30 {
            _ = try await moved.record(BrowserHistoryVisit(url: URL(string: "https://rename.example.test/\(index)")!, visitedAt: Date()))
        }
        try await moved.close()
        try FileManager.default.moveItem(at: relocated, to: original)
        let reopened = try BrowserHistoryStore(profileID: profile, policy: .persistent,
                                                directory: original.appendingPathComponent("History"))
        #expect(try await reopened.visits(limit: 100).count == 30)
        try await reopened.close()
    }

    // MARK: HIGH B — hard links

    @Test("R4-B A history database hard-linked into the source is refused; the outside file is untouched")
    func hardLinkedDatabase() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try await importOnce(fixture)
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        let database = location.historyDatabase(for: ArcImportIdentity().profile(.directory("Default")))
        let outside = fixture.source.appendingPathComponent("Injected.sqlite")
        try FileManager.default.linkItem(at: database, to: outside)
        let before = try digest(outside)
        let target = try fixture.target()
        await #expect(throws: ArcImportError.hardLinkedFile) { try await fixture.importer().prepare(for: target) }
        await target.close()
        #expect(try digest(outside) == before)
        // The store and the checked opener refuse it too, so neither modifies the outside file.
        #expect(throws: BrowserHistoryError.self) {
            try BrowserHistoryStore(profileID: ArcImportIdentity().profile(.directory("Default")), policy: .persistent,
                                    directory: location.historyDirectory)
        }
        let folder = try OrbitSecureDirectory.open(database.deletingLastPathComponent(), create: false)
        let pin = try OrbitSQLiteGuard.pin(folder)
        let (opened, handle) = OrbitSQLiteGuard.open(database.path, flags: SQLITE_OPEN_READWRITE)
        sqlite3_close(handle)
        pin.release()
        #expect(opened != SQLITE_OK)
        #expect(try digest(outside) == before)
    }

    @Test("R4-B Hard-linked session, ledger or backup files are refused")
    func hardLinkedStateFiles() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let outcome = try await importOnce(fixture)
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        let elsewhere = fixture.root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        // Session.
        try FileManager.default.linkItem(at: fixture.sessionFile, to: elsewhere.appendingPathComponent("session.json"))
        #expect(throws: ArcImportError.hardLinkedFile) { try fixture.target() }
        try FileManager.default.removeItem(at: elsewhere.appendingPathComponent("session.json"))
        // Ledger.
        try FileManager.default.linkItem(at: location.ledgerFile, to: elsewhere.appendingPathComponent("ledger.json"))
        let target = try fixture.target()
        await #expect(throws: ArcImportError.stateFileUnreadable) { try await fixture.importer().prepare(for: target) }
        await target.close()
        try FileManager.default.removeItem(at: elsewhere.appendingPathComponent("ledger.json"))
        // Backup manifest: the restore refuses it as an unreadable backup.
        let manifest = location.backupsDirectory.appendingPathComponent(outcome.backupID).appendingPathComponent("manifest.json")
        try FileManager.default.linkItem(at: manifest, to: elsewhere.appendingPathComponent("manifest.json"))
        #expect(throws: ArcImportError.backupNotFound) {
            try ArcImportBackups.restore(outcome.backupID, at: location, usage: NeverRunningProbe())
        }
        #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile).spaces.count == 3)
    }

    // MARK: HIGH C — an unreadable restore journal blocks everything

    private func interruptedRestore(_ fixture: Fixture, renames: Int) async throws -> (location: ArcImportDataLocation, backup: String) {
        _ = try await fixture.seedExistingSession()
        let outcome = try await importOnce(fixture)
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        try ArcImportRestore(id: outcome.backupID, location: location).run(diskSpace: FixedDiskSpace(nil), interruption: renames)
        // The journal is then damaged (truncated to its first byte).
        try ArcImportFiles.writePrivate(Data("{".utf8), to: ArcImportRestore.journalFile(location))
        return (location, outcome.backupID)
    }

    @Test("R4-C A truncated journal blocks the target, the dry run, the apply and the restore, and keeps the parked session")
    func corruptJournalBlocks() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let (location, backup) = try await interruptedRestore(fixture, renames: 1)
        let parked = location.importDirectory.appendingPathComponent(".restore-\(backup)/previous/session.json")
        #expect(FileManager.default.fileExists(atPath: parked.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionFile.path))
        #expect(throws: ArcImportError.restoreJournalUnreadable) { try fixture.target() }
        #expect(throws: ArcImportError.restoreJournalUnreadable) {
            try ArcImportBackups.restore(backup, at: location, usage: NeverRunningProbe())
        }
        #expect(throws: ArcImportError.restoreJournalUnreadable) { try ArcImportBackups.recoverInterruptedRestore(at: location) }
        #expect(FileManager.default.fileExists(atPath: ArcImportRestore.journalFile(location).path), "evidence kept")
        #expect(FileManager.default.fileExists(atPath: parked.path), "the parked session is never discarded")
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionFile.path), "nothing wrote a new session")
    }

    @Test("R4-C recover-restore rebuilds the renames from the manifest, even after a partial swap, and keeps the evidence")
    func recoverRestoreCommand() async throws {
        for renames in [1, 2, 4] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let (location, _) = try await interruptedRestore(fixture, renames: renames)
            #expect(throws: ArcImportError.targetInUse) {
                try ArcImportBackups.recoverRestore(at: location, usage: AlwaysRunningProbe())
            }
            let report = try ArcImportBackups.recoverRestore(at: location, usage: NeverRunningProbe())
            #expect(!report.journalReadable && report.rebuiltFromManifest == 1 && report.restoredEntries >= 1)
            #expect(report.entriesLeftAside == 0)
            let evidence = try #require(report.evidenceFolder)
            #expect(FileManager.default.fileExists(atPath: location.dataDirectory.appendingPathComponent(evidence)
                .appendingPathComponent("arc-import-restore.json").path))
            #expect(!ArcImportBackups.hasInterruptedRestore(at: location))
            // Exactly the state before the restore attempt: 4 Spaces, both histories intact.
            #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile).spaces.count == 4)
            #expect(try await fixture.historyCount(ArcImportIdentity().profile(.directory("Profile 1"))) == 30)
            let target = try fixture.target()
            #expect(await target.sessionDocument().spaces.count == 4)
            await target.close()
        }
    }

    @Test("R4-C Without a readable manifest, parked entries go back only where nothing replaced them")
    func recoverWithoutManifest() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let (location, backup) = try await interruptedRestore(fixture, renames: 1)
        try Data("{".utf8).write(to: location.backupsDirectory.appendingPathComponent(backup).appendingPathComponent("manifest.json"))
        let report = try ArcImportBackups.recoverRestore(at: location, usage: NeverRunningProbe())
        #expect(report.rebuiltFromManifest == 0 && report.restoredEntries == 1)
        #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile).spaces.count == 4)
        let readable = try ArcImportBackups.recoverRestore(at: location, usage: NeverRunningProbe())
        #expect(readable.journalReadable && readable.restoredEntries == 0, "nothing left to recover")
    }

    // MARK: MEDIUM D — the exact schema of the version, not only names

    @Test("R4-D A fake FTS table, a missing or extra trigger is refused; an extra plain table is inert")
    func backupSchema() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try await importOnce(fixture)
        let second = try await importOnce(fixture)
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        let profile = ArcImportIdentity().profile(.directory("Default"))
        let folder = location.backupsDirectory.appendingPathComponent(second.backupID)
            .appendingPathComponent("History/\(profile.rawValue.uuidString)")
        let database = folder.appendingPathComponent("history.sqlite")
        let original = try Data(contentsOf: database)
        func valid() throws -> Bool {
            BrowserHistoryStore.isValidBackup(in: try OrbitSecureDirectory.open(folder, create: false), profileID: profile)
        }
        #expect(try valid())
        for damage in [["DROP TABLE titleWords", "CREATE TABLE titleWords(searchTitle TEXT)"],
                       ["DROP TRIGGER titleWords_update"],
                       ["CREATE TRIGGER synthetic_extra AFTER INSERT ON visits BEGIN SELECT 1; END"],
                       ["DROP INDEX visits_time"],
                       ["DROP TABLE search", "CREATE VIRTUAL TABLE search USING fts5(searchURL,searchTitle)"]] {
            #expect(try sqlite(database.path, damage) == SQLITE_OK)
            #expect(try !valid())
            #expect(throws: ArcImportError.backupInvalid) {
                try ArcImportBackups.restore(second.backupID, at: location, usage: NeverRunningProbe())
            }
            try original.write(to: database)
        }
        #expect(try sqlite(database.path, ["CREATE TABLE synthetic_padding(data BLOB)"]) == SQLITE_OK)
        #expect(try valid(), "an extra plain table runs no code")
        try original.write(to: database)
        try ArcImportBackups.restore(second.backupID, at: location, usage: NeverRunningProbe())
    }

    @Test("R4-D A history database still at an older schema is backed up, and that backup restores after migration")
    func olderSchemaBackup() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try await importOnce(fixture)
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        let profile = ArcImportIdentity().profile(.directory("Default"))
        let database = location.historyDatabase(for: profile)
        // Recreate the v4 schema and version markers on a populated database.
        #expect(try sqlite(database.path, [
            "DROP TRIGGER shortSymbols_insert", "DROP TRIGGER shortSymbols_delete", "DROP TRIGGER shortSymbols_update",
            "DROP TABLE shortSymbols", "DROP INDEX pages_weight_last",
            "DROP TABLE historySyncEvents", "DROP TABLE historySyncBatches",
            "DROP TABLE historySyncState", "DROP TABLE historySyncVersions",
            "DROP TRIGGER pages_update", "DROP TRIGGER titleWords_update",
            "CREATE TRIGGER pages_update AFTER UPDATE ON pages BEGIN INSERT INTO search(search,rowid,searchURL,searchTitle) VALUES('delete',old.id,old.searchURL,old.searchTitle); INSERT INTO search(rowid,searchURL,searchTitle) VALUES(new.id,new.searchURL,new.searchTitle); END",
            "CREATE TRIGGER titleWords_update AFTER UPDATE ON pages BEGIN INSERT INTO titleWords(titleWords,rowid,searchTitle) VALUES('delete',old.id,old.searchTitle); INSERT INTO titleWords(rowid,searchTitle) VALUES(new.id,new.searchTitle); END",
            "UPDATE identity SET version=4", "PRAGMA user_version=4"]) == SQLITE_OK)
        let outcome = try await importOnce(fixture)
        let backup = location.backupsDirectory.appendingPathComponent(outcome.backupID)
            .appendingPathComponent("History/\(profile.rawValue.uuidString)/history.sqlite")
        #expect(count(backup.path, "visits") == 30, "the v4 database was backed up as it was")
        try ArcImportBackups.restore(outcome.backupID, at: location, usage: NeverRunningProbe())
        let restored = try OrbitSecureDirectory.open(database.deletingLastPathComponent(), create: false)
        #expect(BrowserHistoryStore.isValidBackup(in: restored, profileID: profile, writable: true), "migrated to the exact current schema")
        #expect(try await fixture.historyCount(profile) == 30)
    }
}
