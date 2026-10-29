import CryptoKit
import Darwin
import Foundation
import Testing
import zlib
@testable import BrowserCore

@Suite(.serialized)
struct SafariImportTests {
    static let html = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1><META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE><H1>Bookmarks</H1><DL><p>
    <DT><H3 ADD_DATE="1700000000" PERSONAL_TOOLBAR_FOLDER="true">Favorites</H3><DL><p>
    <DT><H3>Nested 日本語</H3><DL><p>
    <DT><A HREF="https://bookmark.example.test/?a=1&amp;b=2" ADD_DATE="1700000001">Café &amp; &#x1F680;</A>
    <DT><A HREF="https://bookmark.example.test/?a=1&amp;b=2">Duplicate</A>
    </DL><p></DL><p>
    <DT><H3 ID="com.apple.ReadingList">Reading List</H3><DL><p>
    <DT><A HREF="https://reading.example.test/">Read later</A>
    <DT><A HREF="https://user:secret@blocked.example.test/">Filtered</A>
    </DL><p></DL><p>
    """
    static let csv = "\u{feff}Title,URL,Username,Password,Notes,OTPAuth\r\n\"Synthetic, title\",https://password.example.test/login,synthetic,\"quoted,\"\"secret\"\"\",\"line one\r\nline two\",otpauth://totp?secret=SYNTHETIC\r\n"
    static func json(_ type: String, rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["metadata": ["browser_name": "Safari", "browser_version": "27.0", "schema_version": 1,
            "data_type": type, "export_time_usec": 1_793_000_000_000_000 as Int64], type: rows], options: [.sortedKeys])
    }
    static func entries(visits: Int = 7) throws -> [(String, Data)] {
        var rows = (0..<visits).map { ["url": "https://history.example.test/\($0)", "title": "History 日本語 \($0)", "time_usec": Int64(Date().timeIntervalSince1970 * 1_000_000) - Int64($0 * 1_000_000), "visits_count": 100] as [String: Any] }
        for url in ["file:///synthetic", "https://user:secret@credential.example.test/", "https://" + String(repeating: "x", count: 4200) + ".test/"] {
            rows.append(["url": url, "time_usec": 1_793_000_000_000_000 as Int64, "visits_count": 1])
        }
        rows.append(["url": "https://invalid-time.example.test/", "time_usec": 0, "visits_count": 1])
        return [("Bookmarks.html", Data(html.utf8)), ("Passwords.csv", Data(csv.utf8)), ("History.json", try json("history", rows: rows)),
            ("PaymentCards.json", try json("payment_cards", rows: [["card_number": "SYNTHETIC-UNSUPPORTED"]])),
            ("Extensions.json", try json("extensions", rows: [["identifier": "synthetic.extension"]])), ("Unknown.bin", Data("ignored".utf8))]
    }
    static func little(_ value: Int, _ width: Int) -> Data { Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func zip(_ entries: [(String, Data)], mode: Int = 0o100600, deflated: Bool = false) -> Data {
        var local = Data(), central = Data()
        for (name, bytes) in entries {
            let path = Data(name.utf8), offset = local.count
            let crc = Int(bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)) })
            var payload = bytes
            if deflated {
                var compressed = Data(count: Int(compressBound(uLong(bytes.count)))), size = uLong(compressBound(uLong(bytes.count)))
                let status = bytes.withUnsafeBytes { source in
                    compressed.withUnsafeMutableBytes { target in
                        compress2(target.bindMemory(to: Bytef.self).baseAddress, &size, source.bindMemory(to: Bytef.self).baseAddress, uLong(bytes.count), Z_BEST_COMPRESSION)
                    }
                }
                precondition(status == Z_OK)
                payload = Data(compressed.prefix(Int(size)).dropFirst(2).dropLast(4))
            }
            let fields = little(0x0800, 2) + little(deflated ? 8 : 0, 2) + Data(repeating: 0, count: 4) + little(crc, 4) + little(payload.count, 4) + little(bytes.count, 4)
            local += little(67324752, 4) + little(20, 2) + fields + little(path.count, 2) + little(0, 2) + path + payload
            central += little(33639248, 4) + little(0x0314, 2) + little(20, 2) + fields + little(path.count, 2) + Data(repeating: 0, count: 8) + little(mode << 16, 4) + little(offset, 4) + path
        }
        return local + central + little(101010256, 4) + Data(repeating: 0, count: 4) + little(entries.count, 2) + little(entries.count, 2) + little(central.count, 4) + little(local.count, 4) + little(0, 2)
    }
    static func export(to file: URL) throws { try zip(entries()).write(to: file) }
    struct Fixture {
        let base: OrbitImportTestFixture
        let source: URL
        init(entries: [(String, Data)]? = nil) throws {
            base = try .init()
            let directory = base.root.appendingPathComponent("SafariExport")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            source = directory.appendingPathComponent("Export.zip")
            try SafariImportTests.zip(entries ?? SafariImportTests.entries()).write(to: source)
        }
        func adapter(shared: Bool = true, directory: String = "History") -> SafariBrowserImportAdapter {
            .init(installationID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, profile: .init(directory: directory, name: "Synthetic"),
                  placement: .init(importedSpace: "Imported from Safari — Synthetic", bookmarkFolder: "Imported Bookmarks", windowName: "Imported Window"), includeSharedData: shared)
        }
        func importer(_ adapter: SafariBrowserImportAdapter? = nil) -> BrowserImportOrchestrator {
            var result = base.importer(); result.source = source; result.adapter = adapter ?? self.adapter(); result.options.historyChunkSize = 2; return result
        }
        func snapshot() throws -> ArcSourceSnapshot { try adapter().snapshot(source: source, parent: base.snapshots, probe: NeverRunningProbe(), diskSpace: OrbitSystemDiskSpaceProbe()) }
    }
    @Test func productFixtureRestore() throws {
        guard let path = ProcessInfo.processInfo.environment["ORBIT_SAFARI_RESTORE_ROOT"] else { return }
        let root = URL(fileURLWithPath: path)
        let run = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: BrowserImportRecoveryTests.key)
        try run.restore(confirmDeletingLaterChanges: true, usage: NeverRunningProbe())
        #expect(run.status.phase == .restored)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Chromium/profile-" + run.status.profileID.rawValue.uuidString.lowercased()).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("History/" + run.status.profileID.rawValue.uuidString).path))
    }
    @Test func officialExportRoundTripAndUndo() async throws {
        let f = try Fixture(); defer { f.base.remove() }
        _ = try await f.base.seedExistingSession()
        let before = try Data(contentsOf: f.base.sessionFile), target = try f.base.target()
        let importer = f.importer(), preparation = try await importer.prepare(for: target)
        #expect(preparation.plan.counts.favorites == 0)
        #expect(preparation.plan.counts.pinnedTabs == 3)
        #expect(preparation.plan.counts.pinnedFolders == 4)
        #expect(preparation.report.history.importable == 7)
        #expect(preparation.report.history.credentialURLs == 1)
        #expect(preparation.report.history.nonWebURLs == 1)
        #expect(preparation.report.history.oversizedURLs == 1)
        #expect(preparation.report.history.invalidTimes == 1)
        #expect(preparation.report.sourceCounts?["aggregateVisitsWithoutTimestamps"] == 693)
        #expect(preparation.report.sourceCounts?["payment_cards"] == 1)
        #expect(preparation.report.sourceCounts?["extensions"] == 1)
        #expect(preparation.report.sourceCounts?["notes"] == 1)
        #expect(preparation.report.sourceCounts?["otp"] == 1)
        let read = try f.adapter().passwords(snapshot: preparation.snapshot)
        #expect(read.passwords.count == 1 && read.passwords[0].password == "quoted,\"secret\"")
        #expect(read.unrepresentedNotes == 1 && read.unrepresentedOTP == 1)
        let root = preparation.snapshot.directory
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("PaymentCards.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Export.zip").path))
        let outcome = try await importer.apply(preparation, to: target)
        #expect(outcome.historyInserted == 7)
        let doc = await target.sessionDocument()
        #expect(doc.organization.tabs.contains { $0.pageTitle == "Café & 🚀" && $0.createdAt == Date(timeIntervalSince1970: 1_700_000_001) })
        #expect(doc.organization.folders.contains { $0.title == "Reading List" })
        await target.close()
        try ArcImportBackups.restore(outcome.backupID, at: target.location, usage: NeverRunningProbe())
        #expect(try Data(contentsOf: f.base.sessionFile) == before)
    }
    @Test func passwordRunIsSealedAndRestorable() async throws {
        let f = try Fixture(); defer { f.base.remove() }
        _ = try await f.base.seedExistingSession()
        let before = try Data(contentsOf: f.base.sessionFile), target = try f.base.target(), importer = f.importer()
        let prep = try await importer.prepare(for: target)
        let key = SymmetricKey(data: Data(repeating: 33, count: 32))
        await #expect(throws: BrowserAuthenticationImportError.consentRequired) {
            try await BrowserAuthenticationRun.applySafariExport(preparation: prep, importer: importer, target: target, adapter: f.adapter(), consent: false, recoveryKey: key)
        }
        let run = try await BrowserAuthenticationRun.applySafariExport(preparation: prep, importer: importer, target: target, adapter: f.adapter(), consent: true, recoveryKey: key)
        await target.close()
        let reopened = try BrowserAuthenticationRun.open(dataRoot: target.location.dataDirectory, recoveryKey: key)
        #expect(reopened.status.phase == .passwordsPending)
        #expect(try reopened.passwordsForRuntime().count == 1)
        let bytes = try Data(contentsOf: target.location.dataDirectory.appendingPathComponent("AuthenticationImport/run.sealed"))
        #expect(bytes.range(of: Data("quoted".utf8)) == nil)
        try reopened.beginPasswordApplication(); try reopened.markVerified()
        #expect(run.status.profileID == reopened.status.profileID)
        try reopened.restore(confirmDeletingLaterChanges: true, usage: NeverRunningProbe())
        #expect(try Data(contentsOf: f.base.sessionFile) == before)
    }
    @Test func sharedDataAssignedOnlyOnceAndLocalizedNames() async throws {
        var entries = try Self.entries()
        entries.append(("Historique - Travail.json", try Self.json("history", rows: [])))
        entries[0].0 = "Signets.html"; entries[1].0 = "Mots de passe.csv"
        let f = try Fixture(entries: entries); defer { f.base.remove() }
        let snapshot = try f.snapshot(); defer { snapshot.remove() }
        let profiles = try f.adapter().discoverProfiles(metadata: SafariBrowserImportAdapter.inventoryData(snapshot: snapshot))
        #expect(profiles.count == 2)
        let adapter = f.adapter(shared: false, directory: "Historique - Travail")
        let result = try adapter.makePlan(snapshot: snapshot, ledger: .init(), defaultProfile: nil, importedAt: Date())
        #expect(result.plan.counts.pinnedTabs == 0)
        #expect(try adapter.passwords(snapshot: snapshot).passwords.isEmpty)
        #expect(result.plan.historySources.count == 1)
    }
    @Test func manyHistoryRowsAreStreamed() async throws {
        let f = try Fixture(entries: Self.entries(visits: 10_000)); defer { f.base.remove() }
        let target = try f.base.target()
        let preparation = try await f.importer().prepare(for: target)
        #expect(preparation.report.history.importable == 10_000)
        preparation.discard(); await target.close()
    }
    @Test(arguments: ["../escape", "/absolute", "a/../../escape", "a\\escape", "a//b", "a/./b", "C:drive", "a\u{0}b"])
    func rejectsUnsafePaths(_ path: String) throws {
        let f = try Fixture(entries: [(path, Data("x".utf8))]); defer { f.base.remove() }
        #expect(throws: (any Error).self) { try f.snapshot() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.base.snapshots.path).isEmpty)
    }
    @Test func rejectsLinksDuplicatesPartialAndCorruption() throws {
        let f = try Fixture(); defer { f.base.remove() }
        var corrupt = Self.zip(try Self.entries()); corrupt[45] ^= 1
        let cases = [Self.zip([("Bookmarks.html", Data(Self.html.utf8))], mode: 0o120777),
                     Self.zip([("Bookmarks.html", Data(Self.html.utf8)), ("BOOKMARKS.HTML", Data(Self.html.utf8))]),
                     Data(Self.zip(try Self.entries()).dropLast(22)), corrupt, Data("not zip".utf8)]
        for data in cases {
            try data.write(to: f.source)
            #expect(throws: (any Error).self) { try f.snapshot() }
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.base.snapshots.path).isEmpty)
        }
    }
    @Test func deflatedExportLimitsAndSnapshotPermissions() throws {
        let f = try Fixture(); defer { f.base.remove() }
        try Self.zip(Self.entries(), deflated: true).write(to: f.source)
        let snapshot = try f.snapshot()
        #expect((try FileManager.default.attributesOfItem(atPath: snapshot.directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        for name in try FileManager.default.contentsOfDirectory(atPath: snapshot.directory.path) {
            #expect((try FileManager.default.attributesOfItem(atPath: snapshot.directory.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        snapshot.remove()
        try Self.zip((0..<129).map { ("\($0).bin", Data()) }).write(to: f.source)
        #expect(throws: (any Error).self) { try f.snapshot() }
        let original = f.source.deletingLastPathComponent().appendingPathComponent("Original.zip")
        try FileManager.default.moveItem(at: f.source, to: original)
        try FileManager.default.createSymbolicLink(at: f.source, withDestinationURL: original)
        #expect(throws: (any Error).self) { try f.snapshot() }
    }
    @Test func largeToolbarStaysInPinnedFolderAndHistoryIdentitySurvivesReordering() throws {
        let bookmarks = "<DL><H3>Favorites</H3><DL>" + (0..<200).map { "<A HREF=\"https://saved.example.test/\($0)\">Saved</A>" }.joined() + "</DL></DL>"
        let rows: [[String: Any]] = (0..<5).map { ["url": "https://history.example.test/\($0)", "time_usec": 1_793_000_000_000_000 as Int64, "visits_count": 50] }
        let f = try Fixture(entries: [("Bookmarks.html", Data(bookmarks.utf8)), ("History.json", try Self.json("history", rows: rows))])
        defer { f.base.remove() }
        let first = try f.snapshot(); defer { first.remove() }
        let plan = try f.adapter().makePlan(snapshot: first, ledger: .init(), defaultProfile: nil, importedAt: Date()).plan
        #expect(plan.counts.favorites == 0 && plan.counts.pinnedTabs == 200 && plan.counts.pinnedFolders == 2)
        let reader = try f.adapter().historyReader(file: first.historyDatabases["History"]!, directory: "History")
        let ids = try reader.nextChunk(size: 10)!.map(\.id)
        try Self.zip([("History.json", try Self.json("history", rows: rows.reversed()))]).write(to: f.source)
        let second = try f.snapshot(); defer { second.remove() }
        let reversed = try f.adapter().historyReader(file: second.historyDatabases["History"]!, directory: "History")
        #expect(try reversed.nextChunk(size: 10)!.map(\.id) == ids)
    }
    @Test func rejectsMalformedFormatsAndOversizedEntry() throws {
        let f = try Fixture(); defer { f.base.remove() }
        let cases: [(String, Data)] = [("Bookmarks.html", Data("<DL><H3>Unclosed".utf8)), ("History.json", Data("{\"history\":[".utf8)),
            ("Passwords.csv", Data("Title,URL,Username,Password\nBad,https://synthetic.test/,x,\"unclosed".utf8)),
            ("History.json", try Self.json("history", rows: [["url": "https://synthetic.test/", "visits_count": -1, "time_usec": 1]]))]
        for entry in cases {
            try Self.zip([entry]).write(to: f.source)
            #expect(throws: (any Error).self) { try f.snapshot() }
        }
        var oversized = Self.zip([("Unknown.bin", Data())])
        // Central uncompressed length alone is sufficient to reject before allocation.
        let central = 30 + "Unknown.bin".utf8.count
        oversized.replaceSubrange((central + 24)..<(central + 28), with: Self.little(SafariExportArchive.maximumEntryBytes + 1, 4))
        try oversized.write(to: f.source)
        #expect(throws: (any Error).self) { try f.snapshot() }
    }
}
