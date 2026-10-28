@testable import BrowserCore
import Darwin
import Foundation
import SQLite3
import Testing

/// Regressions of the second cross-review of IMPORT (2 HIGH, 2 MEDIUM), synthetic data only.
@Suite("source browser import R3 regressions", .serialized)
struct OrbitImportR3Tests {
    private typealias Fixture = OrbitImportTestFixture

    private func listing(_ root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []).sorted()
    }

    private func importOnce(_ fixture: Fixture) async throws -> ArcImportOutcome {
        let target = try fixture.target()
        let outcome = try await fixture.importer().apply(try await fixture.importer().prepare(for: target), to: target)
        await target.close()
        return outcome
    }

    private func sqlite(_ path: String, _ statements: [String]) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else { throw ArcImportError.historyDatabaseUnreadable }
        defer { sqlite3_close(handle) }
        for statement in statements {
            guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else { throw ArcImportError.historyDatabaseUnreadable }
        }
    }

    // MARK: HIGH 1 — recovery before the session is loaded

    @Test("R3-1 A restore interrupted after its first rename is rolled back before the target loads; stale codes are refused")
    func recoveryBeforeLoad() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var target = try fixture.target()
        let empty = try await fixture.importer().prepare(for: target)
        empty.discard()
        await target.close()
        let outcome = try await importOnce(fixture)
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        // Crash right after the first rename: the session file is parked, no replacement yet.
        try ArcImportRestore(id: outcome.backupID, location: location).run(diskSpace: FixedDiskSpace(nil), interruption: 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionFile.path))
        target = try fixture.target()
        #expect(!ArcImportBackups.hasInterruptedRestore(at: location))
        let loaded = await target.sessionDocument()
        #expect(loaded.spaces.count == 3 && loaded.profiles.count == 3, "the store sees the rolled-back session")
        let fresh = try await fixture.importer().prepare(for: target)
        #expect(fresh.report.target.addedItems == 0 && fresh.report.target.spacesPresent == 3)
        #expect(fresh.report.target.projectedSessionBytes > 1_000)
        // The reviewer's replay: a code computed on the empty state can never authorize this apply.
        #expect(fresh.report.confirmationCode != empty.report.confirmationCode)
        #expect(fresh.report.targetStateDigest != empty.report.targetStateDigest)
        _ = try await fixture.importer().apply(fresh, to: target)
        await target.close()
        #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile).spaces.count == 3)
    }

    @Test("R3-1 The confirmation code changes with the target state even when every count is equal")
    func codeTracksTargetState() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try await importOnce(fixture)
        var target = try fixture.target()
        let first = try await fixture.importer().prepare(for: target)
        let again = try await fixture.importer().prepare(for: target)
        first.discard(); again.discard()
        #expect(first.report.confirmationCode == again.report.confirmationCode)
        await target.close()
        let document = try BrowserSessionFileStore().load(from: fixture.sessionFile)
        let store = try BrowserStore(restoring: document)
        try await store.renameSpace(document.spaces[0].id, name: "Space z") // same length: same counts and size
        try BrowserSessionFileStore().save(await store.sessionDocument(), to: fixture.sessionFile)
        target = try fixture.target()
        let changed = try await fixture.importer().prepare(for: target)
        changed.discard()
        await target.close()
        #expect(changed.report.target == first.report.target)
        #expect(changed.report.confirmationCode != first.report.confirmationCode)
    }

    @Test("R3-1 A restore journal appearing after the load refuses the dry run and the apply")
    func journalAfterLoad() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let target = try fixture.target()
        let preparation = try await fixture.importer().prepare(for: target)
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        let journal = ArcImportRestore.Journal(backupID: "20261025T000000Z-00000000", phase: .swapping, moves: [])
        try ArcImportFiles.write(journal, to: ArcImportRestore.journalFile(location))
        await #expect(throws: ArcImportError.restoreInterrupted) { try await fixture.importer().prepare(for: target) }
        // An unreadable journal is never "absent" (IMPORT-R4 #C).
        try ArcImportFiles.writePrivate(Data("{}".utf8), to: ArcImportRestore.journalFile(location))
        await #expect(throws: ArcImportError.restoreJournalUnreadable) { try await fixture.importer().apply(preparation, to: target) }
        await target.close()
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionFile.path))
    }

    // MARK: HIGH 2 — descriptor-relative writes, no link anywhere below the data directory

    @Test("R3-2 A History/<profile> link into the source is refused and nothing is created in the source")
    func linkedProfileHistory() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try await importOnce(fixture)
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        let profile = ArcImportIdentity().profile(.directory("Profile 1"))
        let folder = location.historyDatabase(for: profile).deletingLastPathComponent()
        let injected = fixture.source.appendingPathComponent("Injected", isDirectory: true)
        try FileManager.default.createDirectory(at: injected, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: injected)
        let before = listing(fixture.source)
        let target = try fixture.target()
        await #expect(throws: ArcImportError.symbolicLinkInPath) { try await fixture.importer().prepare(for: target) }
        await target.close()
        #expect(listing(fixture.source) == before)
        #expect(listing(injected).isEmpty)
        // The history store itself refuses a linked profile folder, so no other path writes there.
        #expect(throws: BrowserHistoryError.self) {
            try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: location.historyDirectory)
        }
        #expect(listing(injected).isEmpty)
    }

    @Test("R3-2 Writes follow the verified descriptor, and a component swapped for a link is detected")
    func swappedComponent() throws {
        let root = try OrbitFixture.temporaryDirectory("orbit-secure-directory"); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try OrbitSecureDirectory.open(root.appendingPathComponent("A/B"), create: true)
        _ = try directory.verifiedPath("history.sqlite")
        // Another process replaces `A` with a link after the check.
        try FileManager.default.moveItem(at: root.appendingPathComponent("A"), to: root.appendingPathComponent("Moved"))
        let elsewhere = root.appendingPathComponent("Elsewhere/B", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("A"), withDestinationURL: root.appendingPathComponent("Elsewhere"))
        #expect(throws: ArcImportError.symbolicLinkInPath) { try directory.verifiedPath("history.sqlite") }
        try directory.write(Data("x".utf8), to: "probe.json")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Moved/B/probe.json").path))
        #expect(listing(elsewhere).isEmpty)
        #expect(throws: ArcImportError.symbolicLinkInPath) { try OrbitSecureDirectory.open(root.appendingPathComponent("A/B"), create: false) }
        // A link as the last component of a database companion is refused too.
        let fresh = try OrbitSecureDirectory.open(root.appendingPathComponent("C"), create: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("C/history.sqlite-wal"),
                                                   withDestinationURL: root.appendingPathComponent("Elsewhere/wal"))
        #expect(throws: ArcImportError.symbolicLinkInPath) { try fresh.verifiedPath("history.sqlite") }
    }

    @Test("R3-2 A restore never writes through a link planted under History")
    func restoreWithPlantedLink() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try await fixture.seedExistingSession()
        let outcome = try await importOnce(fixture)
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        let profile = ArcImportIdentity().profile(.directory("Profile 1"))
        let folder = location.historyDatabase(for: profile).deletingLastPathComponent()
        let injected = fixture.source.appendingPathComponent("Injected", isDirectory: true)
        try FileManager.default.createDirectory(at: injected, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: injected)
        let before = listing(fixture.source)
        try ArcImportBackups.restore(outcome.backupID, at: location, usage: NeverRunningProbe())
        #expect(listing(fixture.source) == before, "the planted link is moved aside, never followed")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: MEDIUM 3 — disk estimate covers WAL content and long text

    @Test("R3-3 The backup estimate includes uncheckpointed WAL content")
    func walIncludedInEstimate() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let existing = try await fixture.seedExistingSession()
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        let database = location.historyDatabase(for: existing)
        // A writer keeps 12 MB in the WAL (no checkpoint) while the import runs.
        var handle: OpaquePointer?
        #expect(sqlite3_open(database.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        for statement in ["PRAGMA wal_autocheckpoint=0", "CREATE TABLE synthetic_padding(data BLOB)",
                          "INSERT INTO synthetic_padding VALUES(zeroblob(12582912))"] {
            #expect(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK)
        }
        let main = try FileManager.default.attributesOfItem(atPath: database.path)[.size] as! Int64
        let wal = try FileManager.default.attributesOfItem(atPath: database.path + "-wal")[.size] as! Int64
        #expect(wal > 12_000_000 && main < wal)
        let estimate = ArcImportBackups.estimatedBytes(at: location, historyProfiles: [existing])
        let target = try fixture.target()
        let preparation = try await fixture.importer().prepare(for: target)
        let outcome = try await fixture.importer().apply(preparation, to: target)
        await target.close()
        let backup = location.backupsDirectory.appendingPathComponent(outcome.backupID)
            .appendingPathComponent("History/\(existing.rawValue.uuidString)/history.sqlite")
        let actual = try FileManager.default.attributesOfItem(atPath: backup.path)[.size] as! Int64
        #expect(actual > 12_000_000)
        #expect(estimate >= actual, "page_count × page_size counts the WAL content VACUUM INTO copies")
        #expect(preparation.report.diskEstimateBytes >= actual)
        #expect(OrbitDiskSpace.required(for: 1 << 30) >= (1 << 30) + (1 << 30) / 10 * 3, "proportional margin")
    }

    @Test("R3-3 The history estimate scales with URL and title length")
    func longTextEstimate() async throws {
        let rows = (0..<150).map { index in
            OrbitFixture.HistoryRow(url: "https://long.example.test/\(index)/" + String(repeating: "a", count: 3_980),
                                  title: "Synthetic " + String(repeating: "x", count: 1_000),
                                  time: OrbitFixture.chromeTime(Date(timeIntervalSince1970: 1_750_000_000)) - Int64(index) * 1_000_000)
        }
        let fixture = try Fixture(history: rows); defer { fixture.remove() }
        let target = try fixture.target()
        let preparation = try await fixture.importer().prepare(for: target)
        _ = try await fixture.importer().apply(preparation, to: target)
        await target.close()
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        let actual = try [ArcImportIdentity().profile(.directory("Default")), ArcImportIdentity().profile(.directory("Profile 1"))]
            .reduce(Int64(0)) { total, profile in
                let path = location.historyDatabase(for: profile).path
                let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int64
                let wal = (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? Int64) ?? 0
                return total + size + wal
            }
        let history = preparation.report.history
        #expect(history.importableTextBytes > 150 * 2 * 4_900)
        let estimate = ArcImporter.estimatedHistoryBytes(visits: history.importable, textBytes: history.importableTextBytes)
        #expect(estimate >= actual)
        #expect(estimate < actual * 4, "an upper bound, not an arbitrary reserve")
    }

    // MARK: MEDIUM 4 — backup databases must belong to their profile

    private func importTwice(_ fixture: Fixture) async throws -> (backupID: String, location: ArcImportDataLocation) {
        _ = try await importOnce(fixture)
        // The second backup holds the databases of both imported profiles.
        let second = try await importOnce(fixture)
        return (second.backupID, ArcImportDataLocation(sessionFile: fixture.sessionFile))
    }

    private func expectHistoryIntact(_ fixture: Fixture) async throws {
        for directory in ["Default", "Profile 1"] {
            let profile = ArcImportIdentity().profile(.directory(directory))
            #expect(try await fixture.historyCount(profile) == 30)
            let store = try HistoryDatabase(url: ArcImportDataLocation(sessionFile: fixture.sessionFile).historyDatabase(for: profile),
                                            profileID: profile)
            try store.close()
        }
        #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile).spaces.count == 3)
    }

    @Test("R3-4 Swapped backup databases, a foreign schema or version are refused before any swap")
    func backupIdentity() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let (backupID, location) = try await importTwice(fixture)
        let history = location.backupsDirectory.appendingPathComponent(backupID).appendingPathComponent("History")
        let first = history.appendingPathComponent(ArcImportIdentity().profile(.directory("Default")).rawValue.uuidString + "/history.sqlite")
        let second = history.appendingPathComponent(ArcImportIdentity().profile(.directory("Profile 1")).rawValue.uuidString + "/history.sqlite")
        let one = try Data(contentsOf: first), two = try Data(contentsOf: second)
        // Both copies are intact SQLite files: only their owning profile is wrong.
        try two.write(to: first); try one.write(to: second)
        #expect(throws: ArcImportError.backupInvalid) {
            try ArcImportBackups.restore(backupID, at: location, usage: NeverRunningProbe())
        }
        try await expectHistoryIntact(fixture)
        try one.write(to: first); try two.write(to: second)
        for damage in [["DROP TABLE titleWords"], ["PRAGMA user_version=9"], ["UPDATE identity SET version=3"],
                       ["INSERT INTO identity VALUES('00000000-0000-0000-0000-000000000000', 5)"]] {
            try sqlite(first.path, damage)
            #expect(throws: ArcImportError.backupInvalid) {
                try ArcImportBackups.restore(backupID, at: location, usage: NeverRunningProbe())
            }
            try await expectHistoryIntact(fixture)
            try one.write(to: first)
        }
        // The intact backup restores into the right profiles.
        try ArcImportBackups.restore(backupID, at: location, usage: NeverRunningProbe())
        for directory in ["Default", "Profile 1"] {
            let profile = ArcImportIdentity().profile(.directory(directory))
            let folder = try OrbitSecureDirectory.open(location.historyDatabase(for: profile).deletingLastPathComponent(), create: false)
            #expect(BrowserHistoryStore.isValidBackup(in: folder, profileID: profile, writable: true))
        }
    }

    @Test("R3 The confirmation code of a dry run matches its apply whatever the import time")
    func codeIndependentOfTime() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let target = try fixture.target()
        var codes: Set<String> = []
        for offset in [0.0, 0.123456, 0.5, 1.987654321, 3_600.25] {
            var importer = fixture.importer()
            importer.clock = { Date(timeIntervalSince1970: 1_760_000_000 + offset) }
            let preparation = try await importer.prepare(for: target)
            preparation.discard()
            codes.insert(preparation.report.confirmationCode)
        }
        await target.close()
        #expect(codes.count == 1)
    }
}
