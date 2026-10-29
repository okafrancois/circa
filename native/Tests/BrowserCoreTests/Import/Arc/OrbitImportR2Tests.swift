@testable import BrowserCore
import Darwin
import Foundation
import Testing

/// Regressions of the IMPORT cross-review (five HIGH defects), synthetic data only.
@Suite("source browser import R2 regressions", .serialized)
struct OrbitImportR2Tests {
    private typealias Fixture = OrbitImportTestFixture

    private func listing(_ root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []).sorted()
    }

    private func isDiskSpaceError(_ error: any Error) -> Bool {
        if case .insufficientDiskSpace? = error as? ArcImportError { return true }
        return false
    }

    private func isTooLarge(_ error: any Error) -> Bool {
        if case .sessionTooLarge? = error as? ArcImportError { return true }
        return false
    }

    // MARK: #1 — the merged session must stay readable at the next launch

    private func oversizedSidebar() -> [String: Any] { OrbitFixture.oversizedSidebar() }

    @Test("#1 A merged session above the launch read limit is refused before any write; a consented reduction loads back")
    func oversizedSession() async throws {
        let fixture = try Fixture(sidebar: oversizedSidebar()); defer { fixture.remove() }
        let target = try fixture.target()
        let importer = fixture.importer()
        let full = try await importer.prepare(for: target)
        let budget = full.report.sessionBudget
        #expect(budget.limitBytes == BrowserStore.importSessionBudgetBytes)
        #expect(!budget.fits && budget.projectedBytes > BrowserSessionDocument.defaultMaximumInputBytes)
        #expect((budget.withoutArchiveBytes ?? 0) > budget.limitBytes)
        #expect((budget.withoutArchiveAndTodayBytes ?? .max) <= budget.limitBytes)
        #expect(budget.suggestedExclusions == [.archive, .today])
        let tooLarge = await #expect(throws: ArcImportError.self) { try await importer.apply(full, to: target) }
        #expect(tooLarge.map(isTooLarge) == true)
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionFile.path), "nothing saved")
        #expect(!FileManager.default.fileExists(atPath: location.backupsDirectory.path), "refused before the backup")
        #expect(!FileManager.default.fileExists(atPath: location.journalFile.path))

        let again = try await importer.prepare(for: target)
        let reduced = await again.excluding([.archive, .today], for: target)
        #expect(reduced.report.sessionBudget.fits && reduced.report.excluded == ["archive", "today"])
        #expect(reduced.report.source.todayTabs == 0 && reduced.report.source.archivedTabs == 0)
        #expect(reduced.report.confirmationCode != again.report.confirmationCode)
        _ = try await importer.apply(reduced, to: target)
        await target.close()
        // Read back with the launch limit.
        let loaded = try BrowserSessionFileStore().load(from: fixture.sessionFile)
        #expect(loaded.spaces.count == 3)
        let bytes = try FileManager.default.attributesOfItem(atPath: fixture.sessionFile.path)[.size] as! Int
        #expect(bytes <= BrowserStore.importSessionBudgetBytes)
    }

    @Test("#1 The store refuses an over-budget merge without mutating catalog or organization")
    func storeBudget() async throws {
        let store = BrowserStore()
        let plan = ArcImportMapper.plan(try OrbitFixture.graph(), defaultProfileTarget: nil, importedAt: Date())
        let preview = await store.previewImport(plan, ledger: BrowserImportLedger())
        #expect(preview.projectedSessionBytes > 1_000)
        let refused = await #expect(throws: ArcImportError.self) {
            try await store.applyImport(plan, ledger: BrowserImportLedger(), maximumSessionBytes: 1_000)
        }
        #expect(refused.map(isTooLarge) == true)
        #expect(await store.catalogSnapshot().profiles.isEmpty)
        #expect(await store.sessionDocument().organization == .empty)
        let applied = try await store.applyImport(plan, ledger: BrowserImportLedger())
        #expect(applied.counts.projectedSessionBytes == (try await store.sessionDocument().encoded().count))
    }

    // MARK: #2 — one writer per session, across processes

    @Test("#2 A second import cannot load the session while the first holds it, so it never saves over it")
    func concurrentImports() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let first = try fixture.target()
        // The second run used to load its (empty) state here and later save over the first.
        #expect(throws: ArcImportError.targetInUse) { try fixture.target() }
        let importer = fixture.importer()
        _ = try await importer.apply(try await importer.prepare(for: first), to: first)
        await first.close()
        let second = try fixture.target()
        #expect(await second.sessionDocument().spaces.count == 3, "loaded after the first import")
        let outcome = try await importer.apply(try await importer.prepare(for: second), to: second)
        await second.close()
        #expect(outcome.merge.addedItems == 0)
        #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile).spaces.count == 3)
    }

    @Test("#2 A running Orbit (shared lock) excludes offline imports and restores; shared holders coexist")
    func sharedLock() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        let orbit = try OrbitDataDirectoryLock.acquire(location.dataDirectory, exclusive: false)
        let otherWindowOfOrbit = try OrbitDataDirectoryLock.acquire(location.dataDirectory, exclusive: false)
        #expect(throws: ArcImportError.targetInUse) { try fixture.target() }
        #expect(throws: ArcImportError.targetInUse) {
            try ArcImportBackups.restore("20261025T000000Z-00000000", at: location, usage: NeverRunningProbe())
        }
        orbit.release()
        otherWindowOfOrbit.release()
        let target = try fixture.target()
        #expect(throws: ArcImportError.targetInUse) {
            try OrbitDataDirectoryLock.acquire(location.dataDirectory, exclusive: false)
        }
        await target.close()
        _ = try OrbitDataDirectoryLock.acquire(location.dataDirectory, exclusive: false)
    }

    // MARK: #3 — no symbolic link, no overlap

    @Test("#3 A symbolic link in Orbit's import folder is refused and nothing is written into the source")
    func symlinkedImportDirectory() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let data = fixture.sessionFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: data.appendingPathComponent("Import"), withDestinationURL: fixture.source)
        let before = listing(fixture.source)
        // R5 blocks before session loading: an inaccessible recovery-marker location
        // cannot be interpreted as an absent restore journal.
        #expect(throws: ArcImportError.symbolicLinkInPath) { try fixture.target() }
        #expect(listing(fixture.source) == before)
        #expect(throws: ArcImportError.symbolicLinkInPath) {
            try ArcImportFiles.writePrivate(Data("x".utf8), to: data.appendingPathComponent("Import/Backups/probe.json"))
        }
        #expect(listing(fixture.source) == before)
    }

    @Test("#3 Symbolic links inside or above the source are refused")
    func symlinkedSource() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        // `User Data` pointing outside the source.
        let outside = fixture.root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.source.appendingPathComponent("User Data"), to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.source.appendingPathComponent("User Data"), withDestinationURL: outside)
        #expect(throws: ArcImportError.symbolicLinkInPath) {
            try ArcSourceSnapshot.capture(source: fixture.source, parent: fixture.snapshots, probe: NeverRunningProbe())
        }
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("User Data"))
        try FileManager.default.moveItem(at: outside, to: fixture.source.appendingPathComponent("User Data"))
        // The source reached through a symbolic link.
        let alias = fixture.root.appendingPathComponent("OrbitAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
        var importer = fixture.importer()
        importer.source = alias
        let target = try fixture.target()
        await #expect(throws: ArcImportError.symbolicLinkInPath) { try await importer.prepare(for: target) }
        await target.close()
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.snapshots.path))?.isEmpty ?? true)
    }

    @Test("#3 Source and destination may not contain one another, whatever the case of the path")
    func overlap() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let before = listing(fixture.source)
        let insideFile = fixture.source.appendingPathComponent("Orbit/session.json")
        #expect(throws: ArcImportError.sourceOverlapsTarget) {
            try ArcOfflineImportTarget(sessionFile: insideFile, usage: NeverRunningProbe(), separatedFrom: fixture.source)
        }
        #expect(listing(fixture.source) == before, "refused before the lock creates anything in the source")
        // A target opened without that check is still refused by the importer before any copy.
        let inside = try ArcOfflineImportTarget(sessionFile: insideFile, usage: NeverRunningProbe())
        await #expect(throws: ArcImportError.sourceOverlapsTarget) { try await fixture.importer().prepare(for: inside) }
        await inside.close()
        let cased = URL(fileURLWithPath: fixture.source.path.uppercased()).appendingPathComponent("Orbit2/session.json")
        #expect(throws: ArcImportError.sourceOverlapsTarget) {
            try ArcImportPaths.validateSeparated(source: fixture.source, destination: cased.deletingLastPathComponent())
        }
        #expect(throws: ArcImportError.sourceOverlapsTarget) {
            try ArcImportPaths.validateSeparated(source: fixture.root.appendingPathComponent("Orbit/Copy"),
                                                 destination: fixture.root.appendingPathComponent("Orbit"))
        }
        try ArcImportPaths.validateSeparated(source: fixture.source, destination: fixture.root.appendingPathComponent("Orbit"))
    }

    // MARK: #4 — a profile keeps its target across imports

    @Test("#4 source browser's Default stays attached to its first target after the target's first profile changes")
    func profileMappingIsPersisted() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let existing = try await fixture.seedExistingSession()
        var target = try fixture.target()
        _ = try await fixture.importer().apply(try await fixture.importer().prepare(for: target), to: target)
        await target.close()
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        let ledger = try #require(ArcImportFiles.read(BrowserImportLedger.self, from: location.ledgerFile))
        #expect(ledger.profileTargets[.directory("Default")] == existing)
        // The first profile of the session changes.
        let document = try BrowserSessionFileStore().load(from: fixture.sessionFile)
        let reordered = BrowserSessionDocument(profiles: [document.profiles[1], document.profiles[0]] + document.profiles.dropFirst(2),
                                               spaces: document.spaces, windows: document.windows, tabs: document.tabs,
                                               organization: document.organization)
        try BrowserSessionFileStore().save(reordered, to: fixture.sessionFile)
        let work = ArcImportIdentity().profile(.directory("Profile 1"))
        #expect(reordered.profiles.first?.id == work)

        target = try fixture.target()
        let preparation = try await fixture.importer().prepare(for: target)
        #expect(preparation.report.target.conflicts == 0 && preparation.report.target.spacesAdded == 0)
        #expect(preparation.report.target.addedItems == 0)
        let outcome = try await fixture.importer().apply(preparation, to: target)
        await target.close()
        #expect(outcome.historyInserted == 0)
        #expect(try await fixture.historyCount(existing) == 31)
        #expect(try await fixture.historyCount(work) == 30)
    }

    // MARK: #5 — restore never loses the current state

    private struct Imported {
        let existing: ProfileID
        let backupID: String
        let location: ArcImportDataLocation
    }

    private func importForRestore(_ fixture: Fixture) async throws -> Imported {
        let existing = try await fixture.seedExistingSession()
        let target = try fixture.target()
        let outcome = try await fixture.importer().apply(try await fixture.importer().prepare(for: target), to: target)
        await target.close()
        return Imported(existing: existing, backupID: outcome.backupID, location: ArcImportDataLocation(sessionFile: fixture.sessionFile))
    }

    private func expectImportedState(_ fixture: Fixture, _ imported: Imported) async throws {
        #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile).spaces.count == 4)
        #expect(try await fixture.historyCount(imported.existing) == 31)
        #expect(try await fixture.historyCount(ArcImportIdentity().profile(.directory("Profile 1"))) == 30)
        #expect(!FileManager.default.fileExists(atPath: ArcImportRestore.journalFile(imported.location).path))
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: imported.location.importDirectory.path)) ?? [])
            .filter { $0.hasPrefix(".restore-") }
        #expect(leftovers.isEmpty)
    }

    @Test("#5 An incomplete or corrupt backup is refused before the current history or session is touched")
    func invalidBackup() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let imported = try await importForRestore(fixture)
        let backup = imported.location.backupsDirectory.appendingPathComponent(imported.backupID)
        let database = backup.appendingPathComponent("History/\(imported.existing.rawValue.uuidString)/history.sqlite")
        let saved = try Data(contentsOf: database)
        try FileManager.default.removeItem(at: database)
        #expect(throws: ArcImportError.backupInvalid) {
            try ArcImportBackups.restore(imported.backupID, at: imported.location, usage: NeverRunningProbe())
        }
        try await expectImportedState(fixture, imported)
        try saved.write(to: database)
        let session = backup.appendingPathComponent("session.json")
        try Data("{not a session".utf8).write(to: session)
        #expect(throws: ArcImportError.backupInvalid) {
            try ArcImportBackups.restore(imported.backupID, at: imported.location, usage: NeverRunningProbe())
        }
        try await expectImportedState(fixture, imported)
        #expect(throws: ArcImportError.backupNotFound) {
            try ArcImportBackups.restore("20261025T000000Z-00000000", at: imported.location, usage: NeverRunningProbe())
        }
    }

    @Test("#5 Low disk space refuses a restore before anything changes")
    func lowDiskRestore() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let imported = try await importForRestore(fixture)
        let refused = #expect(throws: ArcImportError.self) {
            try ArcImportBackups.restore(imported.backupID, at: imported.location, usage: NeverRunningProbe(),
                                         diskSpace: FixedDiskSpace(1_024))
        }
        #expect(refused.map(isDiskSpaceError) == true)
        try await expectImportedState(fixture, imported)
    }

    @Test("#5 An error during the swap rolls every rename back")
    func failedSwapRollsBack() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let imported = try await importForRestore(fixture)
        let restore = ArcImportRestore(id: imported.backupID, location: imported.location)
        for failure in [1, 3, 5] {
            #expect(throws: ArcImportError.restoreFailed) {
                try restore.run(diskSpace: FixedDiskSpace(nil), interruption: nil, failure: failure)
            }
            try await expectImportedState(fixture, imported)
        }
    }

    @Test("#5 A restore interrupted mid-swap is rolled back by the next operation, then completes")
    func interruptedRestore() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let imported = try await importForRestore(fixture)
        let restore = ArcImportRestore(id: imported.backupID, location: imported.location)
        try restore.run(diskSpace: FixedDiskSpace(nil), interruption: 3)
        #expect(FileManager.default.fileExists(atPath: ArcImportRestore.journalFile(imported.location).path))
        try ArcImportBackups.recoverInterruptedRestore(at: imported.location)
        try await expectImportedState(fixture, imported)
        // A restore after recovery goes through and is exact.
        try ArcImportBackups.restore(imported.backupID, at: imported.location, usage: NeverRunningProbe())
        #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile).spaces.count == 1)
        #expect(try await fixture.historyCount(imported.existing) == 1)
        let work = imported.location.historyDatabase(for: ArcImportIdentity().profile(.directory("Profile 1")))
        #expect(!FileManager.default.fileExists(atPath: work.deletingLastPathComponent().path))
        // The next import also recovers an interrupted restore first.
        try restore.run(diskSpace: FixedDiskSpace(nil), interruption: 2)
        let target = try fixture.target()
        _ = try await fixture.importer().prepare(for: target)
        await target.close()
        #expect(!FileManager.default.fileExists(atPath: ArcImportRestore.journalFile(imported.location).path))
        #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile).spaces.count == 1)
    }

    // MARK: Free disk space

    @Test("Low disk space refuses the copy before any snapshot, and the apply before any backup")
    func lowDiskImport() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let disk = FixedDiskSpace(1_024)
        let importer = fixture.importer(diskSpace: disk)
        let target = try fixture.target()
        let copyRefused = await #expect(throws: ArcImportError.self) { try await importer.prepare(for: target) }
        #expect(copyRefused.map(isDiskSpaceError) == true)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.snapshots.path))?.isEmpty ?? true)
        disk.set(nil)
        let preparation = try await importer.prepare(for: target)
        disk.set(1_024)
        let applyRefused = await #expect(throws: ArcImportError.self) { try await importer.apply(preparation, to: target) }
        #expect(applyRefused.map(isDiskSpaceError) == true)
        await target.close()
        let location = ArcImportDataLocation(sessionFile: fixture.sessionFile)
        #expect(!FileManager.default.fileExists(atPath: location.backupsDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionFile.path))
    }

    // MARK: History v5 — revisits do not re-index the search tables

    @Test("History v5: counter updates of known pages skip FTS work; indexed changes still re-index")
    func conditionalSearchTriggers() async throws {
        let root = try OrbitFixture.temporaryDirectory("orbit-history-v5"); defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        func visits(_ count: Int, pages: Int, prefix: String) -> [BrowserHistoryVisit] {
            (0..<count).map { index in
                BrowserHistoryVisit(id: UUID(), url: URL(string: "https://\(prefix).example.test/page/\(index % pages)")!,
                                    title: "Synthetic \(prefix) \(index % pages)", visitedAt: base.addingTimeInterval(Double(index)))
            }
        }
        func importTime(_ batch: [BrowserHistoryVisit], into store: BrowserHistoryStore, profile: ProfileID) async throws -> Duration {
            let clock = ContinuousClock()
            let start = clock.now
            for chunk in stride(from: 0, to: batch.count, by: 2_000) {
                _ = try await store.importDocument(BrowserHistoryDocument(profileID: profile,
                    visits: Array(batch[chunk..<min(batch.count, chunk + 2_000)])))
            }
            return clock.now - start
        }
        let distinctProfile = ProfileID(), repeatedProfile = ProfileID()
        let distinct = try BrowserHistoryStore(profileID: distinctProfile, policy: .persistent, directory: root)
        let repeated = try BrowserHistoryStore(profileID: repeatedProfile, policy: .persistent, directory: root)
        let inserts = try await importTime(visits(8_000, pages: 8_000, prefix: "distinct"), into: distinct, profile: distinctProfile)
        let updates = try await importTime(visits(8_000, pages: 80, prefix: "repeated"), into: repeated, profile: repeatedProfile)
        // Before v5 each revisit re-tokenized both indexes (about 40x slower than a new page).
        #expect(updates < inserts * 6, "revisits must cost about as much as new pages")
        #expect(try await repeated.suggestions("Synthetic repeated 7").first?.visitCount == 100)
        let visit = try #require(try await repeated.visits(limit: 1).first)
        try await repeated.updateMetadata(visitID: visit.id, title: "Renamed synthetic page")
        #expect(try await repeated.suggestions("renamed").map(\.url) == [visit.url])
        try await distinct.close(); try await repeated.close()
        let inspect = try HistoryDatabase(url: root.appendingPathComponent(repeatedProfile.rawValue.uuidString).appendingPathComponent("history.sqlite"),
                                          profileID: repeatedProfile)
        #expect(try inspect.scalarInt("PRAGMA user_version") == HistoryDatabase.currentVersion)
        try inspect.execute("INSERT INTO search(search,rank) VALUES('integrity-check',1)")
        try inspect.execute("INSERT INTO titleWords(titleWords,rank) VALUES('integrity-check',1)")
        try inspect.close()
    }
}
