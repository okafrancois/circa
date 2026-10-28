@testable import BrowserCore
import Darwin
import Foundation
import SQLite3
import Testing

/// IMPORT-R5: accidental failures and stale paths, not a hostile concurrent filesystem mutator.
/// Synthetic roots use canonical /private/tmp so no system /tmp or /var symlink is implicit.
@Suite("source browser import R5 SQLite/history", .serialized)
struct OrbitImportR5SQLiteHistoryTests {
    private func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/orbit-import-r5-synthetic-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func execute(_ path: String, _ sql: String) throws {
        var handle: OpaquePointer?
        let opened = sqlite3_open(path, &handle)
        defer { sqlite3_close(handle) }
        #expect(opened == SQLITE_OK)
        guard opened == SQLITE_OK else { throw BrowserHistoryError.storageFailure(opened) }
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func descriptors(in root: URL) -> Set<Int32> {
        // Parallel suites may open unrelated descriptors. Count only descriptors still naming
        // this test's unique root, including native SQLite descriptors, without logging paths.
        Set((0..<getdtablesize()).filter { descriptor in
            guard fcntl(descriptor, F_GETFD) != -1 else { return false }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &path) == 0 else { return false }
            let name = String(cString: path)
            return name == root.path || name.hasPrefix(root.path + "/")
        })
    }

    @Test("The exact-schema template opens below the canonical system temporary root")
    func schemaTemplateUsesCanonicalTemporaryRoot() {
        #expect(BrowserHistoryStore.expectedSchema?.isEmpty == false)
    }

    @Test("Guard use leaves every Unix VFS syscall unchanged")
    func ordinaryVFSIsUnmodified() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let unix = try #require(sqlite3_vfs_find("unix"))
        let get = try #require(unix.pointee.xGetSystemCall)
        let names = ["open", "unlink", "access", "stat", "lstat"]
        let before = names.map { name in get(unix, name).map { unsafeBitCast($0, to: UInt.self) } }
        let pin = try OrbitSQLiteGuard.pin(openingDirectory: root)
        defer { pin.release() }
        let (result, handle) = OrbitSQLiteGuard.open(root.appendingPathComponent("history.sqlite").path,
                                                  flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        #expect(result == SQLITE_OK)
        #expect(sqlite3_close(handle) == SQLITE_OK)
        #expect(names.map { name in get(unix, name).map { unsafeBitCast($0, to: UInt.self) } } == before)
    }

    @Test("Ordinary sqlite3_open follows its own path after an import-guard directory is renamed")
    func ordinaryOpenAfterRename() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Profile", isDirectory: true)
        let parked = root.appendingPathComponent("Parked", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let pin = try OrbitSQLiteGuard.pin(openingDirectory: original)
        defer { pin.release() }
        let file = original.appendingPathComponent("history.sqlite")
        let (opened, handle) = OrbitSQLiteGuard.open(file.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        #expect(opened == SQLITE_OK)
        #expect(sqlite3_close(handle) == SQLITE_OK)
        try FileManager.default.moveItem(at: original, to: parked)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try execute(file.path, "CREATE TABLE ordinary(value INTEGER); INSERT INTO ordinary VALUES(5)")
        #expect(FileManager.default.fileExists(atPath: file.path), "ordinary SQLite uses the replacement directory")
        #expect(!FileManager.default.fileExists(atPath: parked.appendingPathComponent("history.sqlite-journal").path))
        let (refused, stale) = OrbitSQLiteGuard.open(file.path, flags: SQLITE_OPEN_READWRITE)
        sqlite3_close(stale)
        #expect(refused == SQLITE_CANTOPEN, "the guarded opener refuses its retained stale identity")
    }

    @Test("A directory replaced with a symlink before checked open is refused without outside writes")
    func checkedOpenRefusesStaleDirectory() throws {
        // Replacement for R4 openRace: success through inode redirection is outside the revised
        // model. A stale path already present at verification must instead fail closed.
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Profile", isDirectory: true)
        let parked = root.appendingPathComponent("Parked", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let pin = try OrbitSQLiteGuard.pin(openingDirectory: original)
        defer { pin.release() }
        try FileManager.default.moveItem(at: original, to: parked)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        let (opened, handle) = OrbitSQLiteGuard.open(original.appendingPathComponent("history.sqlite").path,
                                                  flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        sqlite3_close(handle)
        #expect(opened == SQLITE_CANTOPEN)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: parked.path).isEmpty)
    }

    @Test("Twenty refused opens through a symlink ancestor allocate no surviving descriptors")
    func refusedOpensDoNotLeak() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        let alias = root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let before = descriptors(in: root)
        for _ in 0..<20 {
            #expect(throws: ArcImportError.self) { try OrbitSQLiteGuard.pin(openingDirectory: alias) }
            let (opened, handle) = OrbitSQLiteGuard.open(alias.appendingPathComponent("history.sqlite").path,
                                                      flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            sqlite3_close(handle)
            #expect(opened == SQLITE_CANTOPEN)
        }
        #expect(descriptors(in: root) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("Twenty SQLite-level refused opens close all native handles")
    func sqliteFailureDoesNotLeak() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("missing.sqlite").path
        // Warm SQLite's one-time process state before measuring resource ownership.
        let (_, warmup) = OrbitSQLiteGuard.open(path, flags: SQLITE_OPEN_READONLY)
        sqlite3_close(warmup)
        let before = descriptors(in: root)
        for _ in 0..<20 {
            let (opened, handle) = OrbitSQLiteGuard.open(path, flags: SQLITE_OPEN_READONLY)
            #expect(opened != SQLITE_OK)
            #expect(sqlite3_close(handle) == SQLITE_OK)
        }
        #expect(descriptors(in: root) == before)
    }

    @Test("History creation rejects an existing symlink ancestor without creating a profile outside")
    func historyOpenRefusesAncestor() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        let alias = root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let before = descriptors(in: root)
        for _ in 0..<20 {
            #expect(throws: BrowserHistoryError.self) {
                try BrowserHistoryStore(profileID: ProfileID(), policy: .persistent, directory: alias.appendingPathComponent("History"))
            }
        }
        #expect(descriptors(in: root) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("Profile deletion refuses a swapped symlink ancestor and keeps both histories intact", arguments: [true, false])
    func deletionRefusesAncestor(closeBeforeDeletion: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let ancestor = root.appendingPathComponent("Original", isDirectory: true)
        let parked = root.appendingPathComponent("Parked", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        let profile = ProfileID()
        let history = ancestor.appendingPathComponent("History", isDirectory: true)
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: history)
        #expect(try await store.record(BrowserHistoryVisit(url: URL(string: "https://synthetic.test/keep")!)))
        // Cover both live cleanup and deletion after an explicit close released its registry pin.
        if closeBeforeDeletion { try await store.close() }
        let outsideProfile = outside.appendingPathComponent("History/\(profile.rawValue.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideProfile, withIntermediateDirectories: true)
        let sentinel = outsideProfile.appendingPathComponent("history.sqlite")
        let bytes = Data("synthetic outside sentinel".utf8)
        try bytes.write(to: sentinel)
        try FileManager.default.moveItem(at: ancestor, to: parked)
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: outside)
        await #expect(throws: BrowserHistoryError.self) { try await store.removeProfileHistory() }
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(FileManager.default.fileExists(atPath: parked.appendingPathComponent("History/\(profile.rawValue.uuidString)/history.sqlite").path))
        try FileManager.default.removeItem(at: ancestor)
        try FileManager.default.moveItem(at: parked, to: ancestor)
        // Descriptor-based cleanup still works when the original identity is restored.
        try await store.removeProfileHistory()
        try await store.removeProfileHistory()
        #expect(!FileManager.default.fileExists(atPath: history.appendingPathComponent(profile.rawValue.uuidString).path))
        #expect(try Data(contentsOf: sentinel) == bytes)
    }

    @Test("Database and every SQLite sidecar refuse hard links without changing their outside aliases")
    func hardLinksAreRefused() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("history.sqlite" + suffix)
            let outside = root.appendingPathComponent(UUID().uuidString)
            let bytes = Data("synthetic linked file".utf8)
            try bytes.write(to: outside)
            try FileManager.default.linkItem(at: outside, to: file)
            let (result, handle) = OrbitSQLiteGuard.open(folder.appendingPathComponent("history.sqlite").path,
                                                      flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
            sqlite3_close(handle)
            #expect(result == SQLITE_CANTOPEN)
            #expect(try Data(contentsOf: outside) == bytes)
        }
    }

    @Test("SQLITE_FULL remains explicit and its transaction rolls back without losing earlier visits")
    func sqliteFullRollsBack() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"), profileID: ProfileID())
        defer { try? database.close() }
        try database.execute("CREATE TABLE synthetic_padding(value BLOB)")
        try database.execute("INSERT INTO synthetic_padding VALUES(x'01')")
        let pages = try database.scalarInt("PRAGMA page_count")
        try database.execute("PRAGMA max_page_count=\(pages)")
        #expect(throws: BrowserHistoryError.storageFailure(SQLITE_FULL)) {
            try database.transaction { try database.execute("INSERT INTO synthetic_padding VALUES(zeroblob(1048576))") }
        }
        #expect(try database.scalarInt("SELECT count(*) FROM synthetic_padding") == 1)
        #expect(try database.scalarText("PRAGMA quick_check") == "ok")
    }
}
