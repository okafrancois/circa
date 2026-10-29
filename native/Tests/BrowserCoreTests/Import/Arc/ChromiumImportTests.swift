@testable import BrowserCore
import Foundation
import Testing
import SQLite3

@Suite(.serialized)
struct ChromiumImportTests {
    struct Fixture {
        let base: OrbitImportTestFixture
        let root: URL
        init() throws {
            base = try .init()
            root = base.root.appendingPathComponent("ChromiumSource")
            for directory in ["Default", "Profile 1"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(directory + "/Sessions"), withIntermediateDirectories: true)
                try OrbitFixture.writeHistory(OrbitFixture.historyRows(count: 4), to: root.appendingPathComponent(directory + "/History"))
                try Self.bookmarks().write(to: root.appendingPathComponent(directory + "/Bookmarks"))
                try Self.bookmarks(account: true).write(to: root.appendingPathComponent(directory + "/AccountBookmarks"))
                try ChromiumImportTests.session().write(to: root.appendingPathComponent(directory + "/Sessions/Session_123"))
            }
            try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": [
                "Default": ["name": "Synthetic Personal", "user_name": "ignored@example.test"],
                "Profile 1": ["name": "Synthetic Work"], "Guest Profile": ["name": "Guest"], "../escape": ["name": "Invalid"]
            ]]]).write(to: root.appendingPathComponent("Local State"))
        }
        static func bookmarks(account: Bool = false) throws -> Data {
            func leaf(_ id: String) -> [String: Any] {
                ["type": "url", "id": id, "guid": "00000000-0000-4000-8000-00000000000" + id,
                 "name": "Synthetic saved title", "date_added": "13390000000000000", "url": "https://bookmark.example.test/" + id]
            }
            func folder(_ id: String, _ name: String, _ children: [[String: Any]]) -> [String: Any] {
                ["type": "folder", "id": id, "name": name, "children": children]
            }
            return try JSONSerialization.data(withJSONObject: ["version": 1, "roots": [
                "bookmark_bar": folder("10", "Toolbar", [folder("11", "Nested", [leaf("1"), leaf(account ? "3" : "2")])]),
                "other": folder("12", "Other", []), "synced": folder("13", "Mobile", [])
            ]])
        }
        func adapter(_ id: String = "chrome", directory: String = "Default", installation: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!) -> ChromiumBrowserImportAdapter {
            .init(descriptor: ChromiumImportRegistry.descriptors.first { $0.id == id }!, installationID: installation,
                  profile: .init(directory: directory, name: "Synthetic Personal"),
                  placement: .init(importedSpace: "Imported from \(id) — Synthetic Personal", bookmarkFolder: "Imported Bookmarks", windowName: "Imported Window"))
        }
        func importer(_ adapter: ChromiumBrowserImportAdapter) -> BrowserImportOrchestrator {
            var importer = base.importer()
            importer.source = root; importer.adapter = adapter
            return importer
        }
        func remove() { base.remove() }
    }
    static func i32(_ value: Int) -> Data { var v = Int32(value).littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
    static func command(_ id: UInt8, _ payload: Data) -> Data {
        var size = UInt16(payload.count + 1).littleEndian
        return withUnsafeBytes(of: &size) { Data($0) } + Data([id]) + payload
    }
    static func string(_ text: String, utf16: Bool = false) -> Data {
        let data = text.data(using: utf16 ? .utf16LittleEndian : .utf8)!
        return i32(utf16 ? text.utf16.count : data.count) + data + Data(repeating: 0, count: (4 - data.count % 4) % 4)
    }
    static func navigation(_ tab: Int, _ index: Int = 0) -> Data {
        let body = i32(tab) + i32(index) + string("https://tab.example.test/\(tab)/\(index)") + string("Synthetic tab \(tab)", utf16: true) + string("") + i32(0)
        return command(6, i32(body.count) + body)
    }
    static func session(version: Int = 3) -> Data {
        var data = Data("SNSS".utf8) + i32(version)
        data += command(9, i32(1) + i32(0))
        for tab in 1...4 {
            data += command(0, i32(1) + i32(tab))
            data += command(2, i32(tab) + i32(5 - tab))
            data += navigation(tab)
        }
        data += navigation(2, 1) + command(7, i32(2) + i32(1))
        data += command(12, i32(1) + Data([1, 0, 0, 0]))
        data += command(16, i32(4) + Data(repeating: 0, count: 12))
        data += command(9, i32(2) + i32(0)) + command(0, i32(2) + i32(5)) + navigation(5)
        data += command(17, i32(2) + Data(repeating: 0, count: 12))
        if version == 3 { data += command(255, Data()) }
        return data
    }
    @Test func metadataAndInventory() throws {
        let f = try Fixture(); defer { f.remove() }
        let adapter = f.adapter()
        let profiles = try adapter.discoverProfiles(metadata: Data(contentsOf: f.root.appendingPathComponent("Local State")))
        #expect(profiles.map(\.directory) == ["Default", "Profile 1"])
        #expect(profiles[0].name == "Synthetic Personal")
        #expect(ChromiumImportRegistry.installed { $0 == adapter.descriptor.bundleID ? [URL(fileURLWithPath: "/synthetic/app")] : [] } == [adapter.descriptor])
        #expect(ChromiumImportRegistry.descriptors.count == 7)
        #expect(throws: (any Error).self) { try adapter.discoverProfiles(metadata: Data("{}".utf8)) }
    }
    @Test func allSourcesIsolateAndRollback() async throws {
        let f = try Fixture(); defer { f.remove() }
        _ = try await f.base.seedExistingSession()
        var ids = Set<ProfileID>(), tabIDs = Set<TabID>()
        for source in ["chrome", "brave", "edge", "dia"] {
            let adapter = f.adapter(source), importer = f.importer(f.adapter(source))
            let target = try f.base.target()
            let before = try Data(contentsOf: f.base.sessionFile)
            let prepared = try await importer.prepare(for: target)
            let plan = prepared.plan
            #expect(plan.counts.favorites == 0 && plan.counts.pinnedTabs == 4 && plan.counts.todayTabs == 2)
            #expect(plan.counts.spaces == 2 && plan.profiles[0].isAdopted == false)
            #expect(ids.insert(plan.profiles[0].id).inserted)
            for section in plan.sections {
                for tab in section.today { #expect(tabIDs.insert(tab.id).inserted) }
            }
            let outcome = try await importer.apply(prepared, to: target)
            #expect(outcome.historyInserted == 4)
            let second = try await importer.prepare(for: target)
            #expect(second.report.target.addedItems == 0)
            let repeated = try await importer.apply(second, to: target)
            #expect(repeated.historyInserted == 0 && repeated.historyAlreadyPresent == 4)
            await target.close()
            let ledger = try #require(ArcImportFiles.read(BrowserImportLedger.self, from: target.location.ledgerFile))
            #expect(ledger.profileMappings[adapter.registration.profileKey("Default")] == plan.profiles[0].id.rawValue)
            #expect(ledger.profileTargets[.directory("Default")] == nil)
            // Restoring the second import leaves the first import intact; restoring the first removes it.
            try ArcImportBackups.restore(repeated.backupID, at: target.location, usage: NeverRunningProbe())
            #expect(try BrowserSessionFileStore().load(from: f.base.sessionFile).profiles.contains { $0.id == plan.profiles[0].id })
            try ArcImportBackups.restore(outcome.backupID, at: target.location, usage: NeverRunningProbe())
            #expect(try Data(contentsOf: f.base.sessionFile) == before)
            #expect(!FileManager.default.fileExists(atPath: target.location.historyDatabase(for: plan.profiles[0].id).path))
        }
        #expect(ids.count == 4)
    }
    @Test func namespacesCoexist() async throws {
        let f = try Fixture(); defer { f.remove() }
        let target = try f.base.target()
        for adapter in [f.adapter(), f.adapter("brave"), f.adapter(directory: "Profile 1"), f.adapter(installation: UUID())] {
            let importer = f.importer(adapter)
            _ = try await importer.apply(try await importer.prepare(for: target), to: target)
        }
        let document = await target.sessionDocument()
        #expect(document.profiles.count == 4)
        let ledger = try #require(ArcImportFiles.read(BrowserImportLedger.self, from: target.location.ledgerFile))
        #expect(ledger.profileMappings.count == 4 && ledger.registrations.count == 3)
        await target.close()
    }
    @Test func arcPlansRemainIdentical() async throws {
        let f = try OrbitImportTestFixture(); defer { f.remove() }
        let target = try f.target()
        let before = try await f.importer().prepare(for: target)
        let graph = try OrbitFixture.graph()
        let expected = ArcImportMapper.plan(graph, options: f.importer().options, defaultProfileTarget: await target.defaultProfile(),
                                            importedAt: f.importer().clock())
        #expect(before.plan == expected)
        var explicit = f.importer(); explicit.adapter = ArcBrowserImportAdapter(options: explicit.options)
        let after = try await explicit.prepare(for: target)
        #expect(before.plan == after.plan && before.report == after.report)
        #expect(try ArcImportFiles.encoder().encode(before.report) == ArcImportFiles.encoder().encode(after.report))
        before.discard(); after.discard(); await target.close()
        let encoded = try ArcImportFiles.encoder().encode(BrowserImportLedger())
        #expect((try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["version"] as? Int == 1)
    }
    @Test func sessionsReplayAndReject() throws {
        for version in [1, 3] {
            let windows = try ChromiumSessionReader.read(Self.session(version: version))
            #expect(windows.count == 1 && windows[0].tabs.map(\.id) == [3, 2, 1])
            #expect(windows[0].tabs[1].url.path == "/2/1" && windows[0].tabs[2].pinned)
        }
        #expect(throws: (any Error).self) { try ChromiumSessionReader.read(Self.session().dropLast()) }
        #expect(throws: (any Error).self) { try ChromiumSessionReader.read(Self.session(version: 5)) }
        #expect(throws: (any Error).self) { try ChromiumSessionReader.read(Self.session().dropLast(3)) }
    }
    @Test func encryptedAndCorruptCategories() async throws {
        let f = try Fixture(); defer { f.remove() }
        let root = f.root.appendingPathComponent("Default")
        try Data("encrypted".utf8).write(to: root.appendingPathComponent("EncryptedBookmarks2"))
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("AccountBookmarks"))
        try (Data("SNSS".utf8) + Self.i32(5)).write(to: root.appendingPathComponent("Sessions/Session_124"))
        let target = try f.base.target()
        let prep = try await f.importer(f.adapter()).prepare(for: target)
        #expect(prep.plan.counts.pinnedTabs == 0 && prep.plan.counts.todayTabs == 0)
        #expect(prep.report.capabilities?["tabs"] == .needsExport)
        #expect(prep.report.capabilities?["bookmarks"] != .supported)
        prep.discard(); await target.close()
    }
    @Test func sourceSafetyAndMissingFiles() async throws {
        let f = try Fixture(); defer { f.remove() }
        let target = try f.base.target()
        var importer = f.importer(f.adapter()); importer.probe = AlwaysRunningProbe()
        await #expect(throws: ArcImportError.arcIsRunning) { try await importer.prepare(for: target) }
        importer.probe = NeverRunningProbe()
        let file = f.root.appendingPathComponent("Default/Bookmarks")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: f.root.appendingPathComponent("Default/AccountBookmarks"))
        await #expect(throws: (any Error).self) { try await importer.prepare(for: target) }
        try FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ArcSourceSnapshot.maximumDocumentBytes + 1)); try handle.close()
        await #expect(throws: ArcImportError.unsupportedSourceFile) { try await importer.prepare(for: target) }
        try FileManager.default.removeItem(at: file)
        let prep = try await importer.prepare(for: target)
        #expect(prep.report.source.pinnedTabs > 0) // account store remains available
        prep.discard(); await target.close()
    }
    @Test func historySchemasAndWAL() async throws {
        let f = try Fixture(); defer { f.remove() }
        let path = f.root.appendingPathComponent("Default/History")
        var db: OpaquePointer?
        #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO visits(url,visit_time,transition) SELECT url,visit_time+1,1 FROM visits LIMIT 1;", nil, nil, nil) == SQLITE_OK)
        let target = try f.base.target(), importer = f.importer(f.adapter())
        let prep = try await importer.prepare(for: target)
        #expect(prep.report.history.importable == 5)
        #expect(FileManager.default.fileExists(atPath: prep.snapshot.historyDatabases["Default"]!.path + "-wal"))
        let reader = try f.adapter().historyReader(file: prep.snapshot.historyDatabases["Default"]!, directory: "Default")
        var visits: [BrowserHistoryVisit] = []
        while let chunk = try reader.nextChunk(size: 2) { visits += chunk }
        #expect(visits.contains { $0.typedCount == 1 })
        prep.discard()
        #expect(sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE); ALTER TABLE visits DROP COLUMN transition; ALTER TABLE urls DROP COLUMN hidden;", nil, nil, nil) == SQLITE_OK)
        let optional = try await importer.prepare(for: target)
        #expect(optional.report.history.importable == 5 && optional.report.historyDatabasesUnreadable == 0)
        optional.discard()
        #expect(sqlite3_exec(db, "ALTER TABLE urls DROP COLUMN title;", nil, nil, nil) == SQLITE_OK)
        let missing = try await importer.prepare(for: target)
        #expect(missing.report.historyDatabasesUnreadable == 1)
        missing.discard(); await target.close()
    }
    @Test func hotJournalRecoveryUsesPrivateCopy() async throws {
        let f = try Fixture(); defer { f.remove() }
        let path = f.root.appendingPathComponent("Default/History")
        // Kill a synthetic writer after dirty pages spill, leaving a genuine hot rollback journal.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import sqlite3, os
c = sqlite3.connect(__import__('sys').argv[1])
c.execute('PRAGMA cache_size=1')
c.execute('BEGIN IMMEDIATE')
c.execute('UPDATE urls SET title=?', ('x'*200000,))
os._exit(0)
""", path.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let before = try Data(contentsOf: path), journal = try Data(contentsOf: URL(fileURLWithPath: path.path + "-journal"))
        let target = try f.base.target()
        let prep = try await f.importer(f.adapter()).prepare(for: target)
        #expect(prep.report.history.importable == 4 && prep.report.historyDatabasesUnreadable == 0)
        #expect(try Data(contentsOf: path) == before)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path.path + "-journal")) == journal)
        prep.discard(); await target.close()
    }
    @Test func sourceStartsDuringCopyAndFingerprintChanges() throws {
        final class Starts: ArcRunningProbe, @unchecked Sendable {
            private let lock = NSLock(); private var calls = 0
            func isArcRunning(sourceRoot: URL) -> Bool { lock.withLock { calls += 1; return calls >= 3 } }
        }
        let f = try Fixture(); defer { f.remove() }
        #expect(throws: ArcImportError.arcIsRunning) {
            try f.adapter().snapshot(source: f.root, parent: f.base.snapshots, probe: Starts(), diskSpace: OrbitSystemDiskSpaceProbe())
        }
        #expect(throws: ArcImportError.sourceChangedDuringCopy) {
            try ArcSourceSnapshot.captureManifest(source: f.root,
                plan: [("Local State", 100000, true)], historyDirectories: [], historyPrefix: "",
                parent: f.base.snapshots, probe: NeverRunningProbe(), diskSpace: OrbitSystemDiskSpaceProbe(), afterCopy: {
                    try! Data("changed".utf8).write(to: f.root.appendingPathComponent("Local State"))
                })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.base.snapshots.path).isEmpty)
    }
    @Test func sessionFallbackAndRecentlyClosedIsolation() async throws {
        let f = try Fixture(); defer { f.remove() }
        let root = f.root.appendingPathComponent("Default")
        try Data("broken".utf8).write(to: root.appendingPathComponent("Sessions/Session_124"))
        try Self.session().write(to: root.appendingPathComponent("Current Tabs"))
        let target = try f.base.target(), importer = f.importer(f.adapter())
        let prep = try await importer.prepare(for: target)
        #expect(prep.plan.counts.todayTabs == 2)
        prep.discard()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sessions"))
        let closedOnly = try await importer.prepare(for: target)
        #expect(closedOnly.plan.counts.todayTabs == 0 && closedOnly.plan.counts.archivedTabs == 0)
        closedOnly.discard(); await target.close()
    }
}
