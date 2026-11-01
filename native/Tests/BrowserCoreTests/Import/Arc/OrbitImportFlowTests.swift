@testable import BrowserCore
import Darwin
import Foundation
import Testing

/// End-to-end dry run → confirmation → apply on synthetic Arc data and a synthetic session file.
@Suite("source browser import flow", .serialized)
struct OrbitImportFlowTests {
    private typealias Fixture = OrbitImportTestFixture

    private func snapshotDirectories(_ fixture: Fixture) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: fixture.snapshots.path)) ?? [])
            .filter { $0.hasPrefix(ArcSourceSnapshot.directoryPrefix) }
    }

    @Test("Dry run reports counts only from a private snapshot; apply imports organization and history")
    func dryRunThenApply() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let existing = try await fixture.seedExistingSession()
        let before = try Data(contentsOf: fixture.sessionFile)
        let target = try fixture.target()
        let preparation = try await fixture.importer().prepare(for: target)
        // The snapshot is private and holds only the documents the importer reads.
        let snapshot = preparation.snapshot.directory
        var info = stat()
        #expect(stat(snapshot.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        #expect(stat(preparation.snapshot.sidebar.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        let copied = FileManager.default.enumerator(atPath: snapshot.path)?.compactMap { $0 as? String } ?? []
        #expect(!copied.contains { $0.contains("Cookies") })
        #expect(try Data(contentsOf: fixture.sessionFile) == before, "a dry run writes nothing")

        let report = preparation.report
        #expect(report.source.spaces == 3 && report.source.favorites == 3 && report.source.pinnedTabs == 5)
        #expect(report.source.pinnedFolders == 2 && report.source.todayTabs == 3 && report.source.archivedTabs == 2)
        #expect(report.target.spacesAdded == 3 && report.target.profilesPresent == 1 && report.target.profilesAdded == 2)
        #expect(report.history.importable == 60 && report.historyProfiles == 3 && report.historyProfilesWithoutDatabase == 1)
        #expect(report.skipped.unattributedArchives == 1)
        #expect(!report.interruptedImport)
        #expect(!report.notImported.contains("passwords") && report.notImported.contains("extensions"))

        let outcome = try await fixture.importer().apply(preparation, to: target)
        await target.close()
        #expect(snapshotDirectories(fixture).isEmpty, "the snapshot is deleted afterwards")
        #expect(outcome.merge == report.target)
        #expect(outcome.historyInserted == 60 && outcome.historyAlreadyPresent == 0)
        let document = try BrowserSessionFileStore().load(from: fixture.sessionFile)
        #expect(document.spaces.count == 4 && document.profiles.count == 3)
        #expect(document.profiles[0].id == existing, "Arc's Default profile merged into the existing profile")
        #expect(try await fixture.historyCount(existing) == 31)
        #expect(try await fixture.historyCount(ArcImportIdentity().profile(.directory("Profile 1"))) == 30)
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        #expect(ArcImportFiles.read(ArcImportJournal.self, from: location.journalFile)?.state == .complete)
        let appearance = try #require(ArcImportFiles.read(BrowserSpaceAppearanceDocument.self, from: location.appearanceFile))
        #expect(appearance.entries.count == 3 && appearance.entries.allSatisfy { $0.appearance.colorHex == "#336699" })
        #expect(ArcImportBackups.manifests(at: location).first?.id == outcome.backupID)
    }

    @Test("A re-run finds everything present, keeps the confirmation code stable and adds nothing")
    func rerunIsIdempotent() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var target = try fixture.target()
        _ = try await fixture.importer().apply(try await fixture.importer().prepare(for: target), to: target)
        await target.close()
        let saved = try Data(contentsOf: fixture.sessionFile)
        target = try fixture.target()
        let first = try await fixture.importer().prepare(for: target)
        let second = try await fixture.importer().prepare(for: target)
        #expect(first.report.confirmationCode == second.report.confirmationCode)
        second.discard()
        #expect(first.report.target.addedItems == 0 && first.report.target.spacesAdded == 0)
        let outcome = try await fixture.importer().apply(first, to: target)
        await target.close()
        #expect(outcome.merge.addedItems == 0 && outcome.historyInserted == 0 && outcome.historyAlreadyPresent == 60)
        let document = try BrowserSessionFileStore().load(from: fixture.sessionFile)
        #expect(try BrowserSessionDocument.decode(saved) == document)
    }

    @Test("A crash after the first history chunk is detected and completed by a re-run, without duplicates")
    func crashMidHistoryRecovery() async throws {
        let fixture = try Fixture(history: OrbitFixture.historyRows(count: 40)); defer { fixture.remove() }
        var target = try fixture.target()
        let crashing = fixture.importer(chunk: 10) { point in
            if point == .afterHistoryChunk(1) { throw ArcImportError.snapshotFailed }
        }
        await #expect(throws: ArcImportError.snapshotFailed) {
            try await crashing.apply(try await crashing.prepare(for: target), to: target)
        }
        await target.close()
        let profile = ArcImportIdentity().profile(.directory("Default"))
        #expect(try await fixture.historyCount(profile) == 10)
        #expect(snapshotDirectories(fixture).isEmpty)

        // Next launch: a fresh target from disk.
        target = try fixture.target()
        let preparation = try await fixture.importer(chunk: 10).prepare(for: target)
        #expect(preparation.report.interruptedImport)
        #expect(preparation.report.target.addedItems == 0, "organization was saved before history")
        let outcome = try await fixture.importer(chunk: 10).apply(preparation, to: target)
        await target.close()
        #expect(outcome.historyInserted == 70 && outcome.historyAlreadyPresent == 10)
        #expect(try await fixture.historyCount(profile) == 40)
        #expect(try await fixture.historyCount(ArcImportIdentity().profile(.directory("Profile 1"))) == 40)
        let document = try BrowserSessionFileStore().load(from: fixture.sessionFile)
        #expect(Set(document.organization.tabs.map(\.id)).count == document.organization.tabs.count)
        #expect(document.organization.tabs.count == 11)
    }

    @Test("A crash before the session is saved leaves the previous session; the re-run imports everything")
    func crashBeforeSave() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try await fixture.seedExistingSession()
        let before = try BrowserSessionFileStore().load(from: fixture.sessionFile)
        var target = try fixture.target()
        let crashing = fixture.importer { point in if point == .afterApply { throw ArcImportError.backupFailed } }
        await #expect(throws: ArcImportError.backupFailed) {
            try await crashing.apply(try await crashing.prepare(for: target), to: target)
        }
        await target.close()
        #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile) == before)
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        #expect(!FileManager.default.fileExists(atPath: location.ledgerFile.path), "no ledger entry for unsaved objects")
        target = try fixture.target()
        let preparation = try await fixture.importer().prepare(for: target)
        #expect(preparation.report.interruptedImport && preparation.report.target.spacesAdded == 3)
        _ = try await fixture.importer().apply(preparation, to: target)
        await target.close()
        #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile).spaces.count == 4)
    }

    @Test("Restoring the backup returns the session and history exactly as before the import")
    func restoreBackup() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let existing = try await fixture.seedExistingSession()
        let before = try BrowserSessionFileStore().load(from: fixture.sessionFile)
        let target = try fixture.target()
        let outcome = try await fixture.importer().apply(try await fixture.importer().prepare(for: target), to: target)
        await target.close()
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        #expect(throws: ArcImportError.targetInUse) {
            try ArcImportBackups.restore(outcome.backupID, at: location, usage: AlwaysRunningProbe())
        }
        try ArcImportBackups.restore(outcome.backupID, at: location, usage: NeverRunningProbe())
        #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile) == before)
        #expect(try await fixture.historyCount(existing) == 1)
        let work = ArcImportIdentity().profile(.directory("Profile 1"))
        #expect(!FileManager.default.fileExists(atPath: location.historyDatabase(for: work).deletingLastPathComponent().path))
        #expect(!FileManager.default.fileExists(atPath: location.ledgerFile.path))
        #expect(ArcImportFiles.read(ArcImportJournal.self, from: location.journalFile)?.state == .restored)
        #expect(throws: ArcImportError.backupNotFound) {
            try ArcImportBackups.restore("../escape", at: location, usage: NeverRunningProbe())
        }
    }

    @Test("A running source browser is refused before any copy, and source browser is never touched")
    func runningArcRefused() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var importer = fixture.importer()
        importer.probe = AlwaysRunningProbe()
        let target = try fixture.target()
        await #expect(throws: ArcImportError.arcIsRunning) { try await importer.prepare(for: target) }
        #expect(snapshotDirectories(fixture).isEmpty)
        // The lock may create the empty data directory; nothing is written into it.
        let written = (try? FileManager.default.contentsOfDirectory(atPath: fixture.sessionFile.deletingLastPathComponent().path)) ?? []
        #expect(written.isEmpty)
        #expect(fixture.log.events.contains(.failed(.arcIsRunning)))
    }

    @Test("A source file changing during the copy discards the snapshot")
    func changedDuringCopy() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let sidebar = fixture.source.appendingPathComponent("StorableSidebar.json")
        #expect(throws: ArcImportError.sourceChangedDuringCopy) {
            try ArcSourceSnapshot.capture(source: fixture.source, includeHistory: true, parent: fixture.snapshots,
                                          probe: NeverRunningProbe(), afterCopy: {
                try? Data("{\"version\":1,\"sidebar\":{\"containers\":[]}}".utf8).write(to: sidebar)
            })
        }
        #expect(snapshotDirectories(fixture).isEmpty)
        let link = fixture.source.appendingPathComponent("User Data/Profile 1/History")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        // A symbolic link is never followed: that profile simply has no History to copy.
        let snapshot = try ArcSourceSnapshot.capture(source: fixture.source, parent: fixture.snapshots, probe: NeverRunningProbe())
        #expect(snapshot.historyDatabases.keys.sorted() == ["Default"])
        snapshot.remove()
        #expect(throws: ArcImportError.sourceNotFound) {
            try ArcSourceSnapshot.capture(source: fixture.root.appendingPathComponent("Missing"), parent: fixture.snapshots,
                                          probe: NeverRunningProbe())
        }
    }

    @Test("Offline targets refuse a session used by a running Orbit")
    func targetInUse() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        #expect(throws: ArcImportError.targetInUse) {
            try ArcOfflineImportTarget(sessionFile: fixture.sessionFile, usage: AlwaysRunningProbe())
        }
    }

    @Test("Logs, progress and reports never contain URLs, titles or names")
    func privacy() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let progress = ProgressRecorder()
        let target = try fixture.target()
        let importer = fixture.importer()
        let preparation = try await importer.prepare(for: target, progress: progress.record)
        let outcome = try await importer.apply(preparation, to: target, progress: progress.record)
        await target.close()
        let failing = ArcImporter(source: fixture.root.appendingPathComponent("Missing"), probe: NeverRunningProbe(),
                                  logger: fixture.log, snapshotParent: fixture.snapshots)
        await #expect(throws: ArcImportError.sourceNotFound) { try await failing.prepare(for: try fixture.target()) }
        var texts = fixture.log.messages
        texts.append(String(decoding: try ArcImportFiles.encoder().encode(preparation.report), as: UTF8.self))
        texts.append(String(decoding: try ArcImportFiles.encoder().encode(outcome), as: UTF8.self))
        texts += progress.values.map { "\($0)" }
        texts += [ArcImportError.sourceNotFound, .arcIsRunning, .historyDatabaseUnreadable].map { "\($0) \(String(describing: $0))" }
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        for file in [location.journalFile, location.ledgerFile] { texts.append(try String(contentsOf: file, encoding: .utf8)) }
        let manifest = location.backupsDirectory.appendingPathComponent(outcome.backupID).appendingPathComponent("manifest.json")
        texts.append(try String(contentsOf: manifest, encoding: .utf8))
        #expect(fixture.log.messages.count >= 8)
        for text in texts {
            for sensitive in OrbitFixture.sensitiveStrings + [fixture.root.path, "example.test"] {
                #expect(!text.contains(sensitive), "redaction failed for a synthetic value")
            }
        }
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ArcImportProgress] = []
    var values: [ArcImportProgress] { lock.withLock { storage } }
    var record: @Sendable (ArcImportProgress) -> Void {
        { [self] value in lock.withLock { storage.append(value) } }
    }
}
