import Darwin
import Foundation
import SQLite3

/// Where an import writes, derived from the session file exactly like the app derives its
/// history directory. `Import/` holds UUID-only state and backups; it is private (0700).
public struct ArcImportDataLocation: Sendable, Equatable {
    public let sessionFile: URL

    /// Not standardized: Foundation rewrites `/private/var` as `/var`, a symbolic link the session
    /// file store refuses.
    public init(sessionFile: URL) { self.sessionFile = sessionFile.absoluteURL }

    public var dataDirectory: URL { sessionFile.deletingLastPathComponent() }
    public var historyDirectory: URL { dataDirectory.appendingPathComponent("History", isDirectory: true) }
    public var importDirectory: URL { dataDirectory.appendingPathComponent("Import", isDirectory: true) }
    public var journalFile: URL { importDirectory.appendingPathComponent("arc-import-journal.json") }
    public var ledgerFile: URL { importDirectory.appendingPathComponent("arc-import-ledger.json") }
    public var appearanceFile: URL { importDirectory.appendingPathComponent("space-appearance.json") }
    public var offerFile: URL { importDirectory.appendingPathComponent("arc-import-offer.json") }
    public var backupsDirectory: URL { importDirectory.appendingPathComponent("Backups", isDirectory: true) }

    /// The first-run offer record, written through verified descriptors like every import file.
    public func writeOfferRecord(_ data: Data) throws { try ArcImportFiles.writePrivate(data, to: offerFile) }

    public func historyDatabase(for profileID: ProfileID) -> URL {
        historyDirectory.appendingPathComponent(profileID.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }
}

/// Survives a crash in the middle of an apply: `applying` at the next run means the import was
/// interrupted. Re-running completes it (every step is idempotent); restoring the backup undoes it.
public struct ArcImportJournal: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case applying, complete, restored }
    public var version = 1
    public var state: State
    public var backupID: String
    public var startedAt: Date
    public var updatedAt: Date
}

/// Space appearance imported from Arc, keyed by Space. A sidecar of the session document (v2 has no
/// Space theme); consumed by the theme lot. Never overwrites an existing entry.
public struct BrowserSpaceAppearanceDocument: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let spaceID: SpaceID
        public let appearance: ArcSpaceAppearance
    }

    public var version = 1
    public var entries: [Entry] = []

    public init() {}

    public func appearance(for spaceID: SpaceID) -> ArcSpaceAppearance? {
        entries.first { $0.spaceID == spaceID }?.appearance
    }

    mutating func addMissing(_ additions: [Entry]) {
        let known = Set(entries.map(\.spaceID))
        entries += additions.filter { !known.contains($0.spaceID) && !$0.appearance.isEmpty }
        entries.sort { $0.spaceID.rawValue.uuidString < $1.spaceID.rawValue.uuidString }
    }
}

/// What a backup holds. Identities only.
public struct ArcImportBackupManifest: Codable, Equatable, Sendable {
    public var version = 1
    public let id: String
    public let createdAt: Date
    public let sessionPresent: Bool
    /// Profiles whose history database existed before the import (restored) or not (removed).
    public let historyProfiles: [UUID: Bool]
    public let ledgerPresent: Bool
    public let appearancePresent: Bool
}

enum ArcImportFiles {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Creates (0700) through verified descriptors from `/` (IMPORT-R3 #2).
    @discardableResult
    static func ensurePrivateDirectory(_ url: URL) throws -> OrbitSecureDirectory {
        let directory = try OrbitSecureDirectory.open(url, create: true)
        _ = fchmod(directory.descriptor, 0o700)
        return directory
    }

    /// Temporary file, fsync, `renameat`, directory fsync, all relative to a verified descriptor.
    static func writePrivate(_ data: Data, to url: URL) throws {
        try ensurePrivateDirectory(url.deletingLastPathComponent()).write(data, to: url.lastPathComponent)
    }

    static func readData(_ url: URL, limit: Int = 64 * 1024 * 1024) -> Data? {
        (try? OrbitSecureDirectory.open(url.deletingLastPathComponent(), create: false))?.read(url.lastPathComponent, limit: limit)
    }

    static func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = readData(url) else { return nil }
        return try? decoder().decode(type, from: data)
    }

    /// Nil only when the file is absent. A file that exists but is not a single-link regular file
    /// or does not decode is an error, never "absent" (IMPORT-R4 #C).
    static func readExisting<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        let directory: OrbitSecureDirectory
        do { directory = try OrbitSecureDirectory.open(url.deletingLastPathComponent(), create: false) }
        catch ArcImportError.backupNotFound { return nil }
        guard try directory.checkedKind(url.lastPathComponent) != nil else { return nil }
        guard let data = directory.read(url.lastPathComponent), let value = try? decoder().decode(type, from: data) else {
            throw ArcImportError.stateFileUnreadable
        }
        return value
    }

    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try writePrivate(try encoder().encode(value), to: url)
    }

    static func remove(_ url: URL) {
        (try? OrbitSecureDirectory.open(url.deletingLastPathComponent(), create: false))?.remove(url.lastPathComponent)
    }

    static func exists(_ url: URL) -> Bool {
        (try? OrbitSecureDirectory.open(url.deletingLastPathComponent(), create: false))?.exists(url.lastPathComponent) ?? false
    }

    /// The `History/<profile>` directory, created and verified; refuses any symbolic link,
    /// including the profile directory itself and the database companions.
    static func historyDirectory(_ location: ArcImportDataLocation, _ profileID: ProfileID, create: Bool) throws -> OrbitSecureDirectory {
        let directory = try OrbitSecureDirectory.open(location.historyDirectory, create: create)
            .directory(profileID.rawValue.uuidString, create: create)
        _ = try directory.verifiedPath("history.sqlite")
        return directory
    }

    /// Size of the database as SQLite sees it, WAL content included (`page_count × page_size`),
    /// an upper bound of what `VACUUM INTO` writes (IMPORT-R3 #3).
    static func logicalDatabaseBytes(in directory: OrbitSecureDirectory) -> Int64 {
        guard directory.exists("history.sqlite"), let path = try? directory.verifiedPath("history.sqlite"),
              let pin = try? OrbitSQLiteGuard.pin(directory) else { return 0 }
        defer { pin.release() }
        let (opened, handle) = OrbitSQLiteGuard.open(path, flags: SQLITE_OPEN_READWRITE)
        guard opened == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return directory.size("history.sqlite") + directory.size("history.sqlite-wal")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5000)
        func integer(_ sql: String) -> Int64? {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_int64(statement, 0)
        }
        guard let pages = integer("PRAGMA page_count"), let size = integer("PRAGMA page_size") else {
            return directory.size("history.sqlite") + directory.size("history.sqlite-wal")
        }
        return pages * size
    }

    /// A consistent copy of a live WAL database through SQLite (`VACUUM INTO`), never a raw copy.
    /// Both paths are verified against their directories' descriptors before and after SQLite runs.
    static func snapshotDatabase(from source: OrbitSecureDirectory, to destination: OrbitSecureDirectory,
                                 profileID: ProfileID) throws {
        let input = try source.verifiedPath("history.sqlite")
        let output = try destination.verifiedPath("history.sqlite")
        guard !destination.exists("history.sqlite") else { throw ArcImportError.backupFailed }
        // Retain both verified directory identities. SQLite uses its ordinary path-based VFS;
        // verify both paths again after VACUUM under the accidental-failure model (IMPORT-R5).
        let sourcePin = try OrbitSQLiteGuard.pin(source)
        defer { sourcePin.release() }
        let destinationPin = try OrbitSQLiteGuard.pin(destination)
        defer { destinationPin.release() }
        let (opened, handle) = OrbitSQLiteGuard.open(input, flags: SQLITE_OPEN_READWRITE)
        guard opened == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw ArcImportError.backupFailed
        }
        sqlite3_busy_timeout(handle, 5000)
        let quoted = output.replacingOccurrences(of: "'", with: "''")
        let result = sqlite3_exec(handle, "VACUUM INTO '\(quoted)'", nil, nil, nil)
        sqlite3_close(handle)
        guard result == SQLITE_OK else { throw ArcImportError.backupFailed }
        _ = try source.verifiedPath("history.sqlite")
        _ = try destination.verifiedPath("history.sqlite")
        let file = try destination.openFile("history.sqlite", flags: O_RDONLY)
        defer { Darwin.close(file) }
        guard fchmod(file, 0o600) == 0 else { throw ArcImportError.backupFailed }
        // The copy must belong to the profile it is filed under (IMPORT-R3 #4).
        guard BrowserHistoryStore.isValidBackup(in: destination, profileID: profileID, exactSchema: false) else {
            throw ArcImportError.backupFailed
        }
    }
}

/// Backups taken before every apply, restorable while Orbit is closed.
public enum ArcImportBackups {
    /// Reuses the normal restorable backup format for a session-only catalog mutation.
    /// Cookies, storage and history are unchanged by a Space profile move.
    public static func createSessionBackup(at location: ArcImportDataLocation,
                                          document: BrowserSessionDocument) throws -> String {
        try create(at: location, session: document.encoded(), historyProfiles: [], now: Date())
    }

    public static func manifests(at location: ArcImportDataLocation) -> [ArcImportBackupManifest] {
        guard let backups = try? OrbitSecureDirectory.open(location.backupsDirectory, create: false) else { return [] }
        return backups.entries().compactMap { name in
            (try? backups.directory(name, create: false))?.read("manifest.json")
                .flatMap { try? ArcImportFiles.decoder().decode(ArcImportBackupManifest.self, from: $0) }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Bytes a backup of these profiles' databases would take (WAL content included).
    static func estimatedBytes(at location: ArcImportDataLocation, historyProfiles: [ProfileID]) -> Int64 {
        Set(historyProfiles).reduce(Int64(0)) { total, profile in
            guard let directory = try? ArcImportFiles.historyDirectory(location, profile, create: false) else { return total }
            return total + ArcImportFiles.logicalDatabaseBytes(in: directory)
        }
    }

    static func create(at location: ArcImportDataLocation, session: Data?, historyProfiles: [ProfileID],
                       now: Date) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let id = formatter.string(from: now) + "-" + UUID().uuidString.prefix(8).lowercased()
        let backups = try ArcImportFiles.ensurePrivateDirectory(location.backupsDirectory)
        do {
            let directory = try backups.directory(id, create: true)
            if let session { try directory.write(session, to: "session.json") }
            var profiles: [UUID: Bool] = [:]
            for profileID in Set(historyProfiles) {
                let current: OrbitSecureDirectory?
                do { current = try ArcImportFiles.historyDirectory(location, profileID, create: false) }
                catch ArcImportError.backupNotFound { current = nil }
                let exists = try current?.checkedKind("history.sqlite") != nil
                profiles[profileID.rawValue] = exists
                if let current, exists {
                    let destination = try directory.directory("History/" + profileID.rawValue.uuidString, create: true)
                    try ArcImportFiles.snapshotDatabase(from: current, to: destination, profileID: profileID)
                }
            }
            func keep(_ file: URL, as name: String) throws -> Bool {
                let parent: OrbitSecureDirectory
                do { parent = try OrbitSecureDirectory.open(file.deletingLastPathComponent(), create: false) }
                catch ArcImportError.backupNotFound { return false }
                guard try parent.checkedKind(file.lastPathComponent) != nil else { return false }
                guard let data = parent.read(file.lastPathComponent) else { throw ArcImportError.backupFailed }
                try directory.write(data, to: name)
                return true
            }
            let manifest = ArcImportBackupManifest(id: id, createdAt: now, sessionPresent: session != nil,
                historyProfiles: profiles, ledgerPresent: try keep(location.ledgerFile, as: "ledger.json"),
                appearancePresent: try keep(location.appearanceFile, as: "space-appearance.json"))
            try directory.write(try ArcImportFiles.encoder().encode(manifest), to: "manifest.json")
            return id
        } catch {
            backups.remove(id)
            throw ArcImportError.backupFailed
        }
    }

    /// Puts the session, the touched history databases, the ledger and the appearance sidecar back
    /// exactly as they were before the import. Orbit must not be using the session (exclusive lock
    /// and process check). The whole backup is validated and staged first; the current files are
    /// then swapped by journaled renames on the same volume, rolled back on any error, and an
    /// interrupted swap is rolled back right after the lock is taken, before anything is read.
    public static func restore(_ id: String, at location: ArcImportDataLocation, usage: any OrbitTargetUsageProbe,
                               diskSpace: any OrbitDiskSpaceProbe = OrbitSystemDiskSpaceProbe()) throws {
        let lock = try OrbitDataDirectoryLock.acquire(location.dataDirectory, exclusive: true)
        defer { lock.release() }
        guard !usage.isInUse(sessionFile: location.sessionFile) else { throw ArcImportError.targetInUse }
        try recoverInterruptedRestore(at: location, holdingLock: true)
        try ArcImportRestore(id: id, location: location).run(diskSpace: diskSpace, interruption: nil)
    }

    /// True while a restore journal is present: no session state can be trusted until recovery.
    public static func hasInterruptedRestore(at location: ArcImportDataLocation) -> Bool {
        do {
            let imports = try OrbitSecureDirectory.open(location.importDirectory, create: false)
            return try imports.checkedKind(ArcImportRestore.journalName) != nil
        } catch ArcImportError.backupNotFound { return false }
        catch { return true } // An inaccessible marker location must block loading a half-swap.
    }

    /// Rolls back a restore interrupted during its swap (journal `Import/arc-import-restore.json`).
    /// Call right after taking the data directory's exclusive lock and before loading anything, or
    /// let it take the lock. An unreadable journal throws `restoreJournalUnreadable` and is kept:
    /// nothing may proceed on a half-restored session until `recoverRestore` runs.
    public static func recoverInterruptedRestore(at location: ArcImportDataLocation, holdingLock: Bool = false) throws {
        guard hasInterruptedRestore(at: location) else { return }
        let lock = holdingLock ? nil : try OrbitDataDirectoryLock.acquire(location.dataDirectory, exclusive: true)
        defer { lock?.release() }
        try ArcImportRestore.recover(location)
    }

    /// True when a restore journal exists but cannot be read.
    public static func hasUnreadableRestoreJournal(at location: ArcImportDataLocation) -> Bool {
        guard hasInterruptedRestore(at: location) else { return false }
        return (try? ArcImportFiles.readExisting(ArcImportRestore.Journal.self, from: ArcImportRestore.journalFile(location))) == nil
    }

    /// The explicit recovery command (`orbit-import recover-restore`): with the session unused,
    /// rolls an interrupted restore back even when its journal is unreadable, by rebuilding the
    /// planned renames from the backup manifest (or, without one, by putting every parked entry
    /// back where nothing replaced it). Never overwrites a file; the unreadable journal and the
    /// restore's working folders are kept under `Import/Recovered/<time>/`. Counts only.
    public static func recoverRestore(at location: ArcImportDataLocation, usage: any OrbitTargetUsageProbe,
                                      now: Date = Date()) throws -> ArcImportRecoveryReport {
        let lock = try OrbitDataDirectoryLock.acquire(location.dataDirectory, exclusive: true)
        defer { lock.release() }
        guard !usage.isInUse(sessionFile: location.sessionFile) else { throw ArcImportError.targetInUse }
        var report = ArcImportRecoveryReport()
        guard hasInterruptedRestore(at: location) else { return report }
        if !hasUnreadableRestoreJournal(at: location) {
            try ArcImportRestore.recover(location)
            report.journalReadable = true
            return report
        }
        report.journalReadable = false
        try ArcImportRestore.recoverWithoutJournal(location, now: now, report: &report)
        return report
    }
}

/// Outcome of `recoverRestore`, counts only.
public struct ArcImportRecoveryReport: Codable, Equatable, Sendable {
    public var journalReadable = true
    /// Entries put back where they were before the interrupted restore.
    public var restoredEntries = 0
    /// Parked entries left aside because something now occupies their place.
    public var entriesLeftAside = 0
    /// Restores whose renames were rebuilt from their backup manifest.
    public var rebuiltFromManifest = 0
    /// Relative folder holding the unreadable journal and the restore's working folders.
    public var evidenceFolder: String?
    public init() {}
}

/// One restore: validation, staging, swap, cleanup. Every file operation is relative to verified
/// directory descriptors below the data directory (IMPORT-R3 #2).
struct ArcImportRestore {
    struct Move: Codable, Equatable {
        /// Paths relative to the data directory (fixed names and UUIDs only).
        let from: String
        let to: String
    }

    struct Journal: Codable {
        enum Phase: String, Codable { case staging, swapping, cleanup, rollbackCompleted }
        var version = 1
        let backupID: String
        var phase: Phase
        let moves: [Move]
        // Explicit recovery keeps unresolved parked entries and the damaged journal as evidence.
        var evidenceRelativePath: String? = nil
        var evidenceWorks: [String]? = nil
    }

    let id: String
    let location: ArcImportDataLocation

    static func journalFile(_ location: ArcImportDataLocation) -> URL {
        location.importDirectory.appendingPathComponent("arc-import-restore.json")
    }

    static let journalName = "arc-import-restore.json"
    var workName: String { ".restore-\(id)" }
    var workRelative: String { "Import/\(workName)" }

    /// The verified parent directory and leaf name of a path relative to the data directory.
    static func parent(_ relative: String, in root: OrbitSecureDirectory, create: Bool) throws -> (OrbitSecureDirectory, String) {
        let components = relative.split(separator: "/").map(String.init)
        guard let name = components.last, components.allSatisfy(OrbitSecureDirectory.validName) else {
            throw ArcImportError.restoreFailed
        }
        let directory = components.count == 1 ? root : try root.directory(components.dropLast().joined(separator: "/"), create: create)
        return (directory, name)
    }

    static func exists(_ relative: String, in root: OrbitSecureDirectory) throws -> Bool {
        do {
            let (directory, name) = try parent(relative, in: root, create: false)
            return try directory.checkedKind(name) != nil
        } catch ArcImportError.backupNotFound { return false }
    }

    static func move(_ move: Move, in root: OrbitSecureDirectory, reverse: Bool = false) throws {
        let (from, to) = reverse ? (move.to, move.from) : (move.from, move.to)
        let (source, sourceName) = try parent(from, in: root, create: false)
        let (destination, destinationName) = try parent(to, in: root, create: true)
        try source.rename(sourceName, to: destination, destinationName)
    }

    /// Test seams: `interruption` stops after that many renames without rolling back (a crash);
    /// `failure` throws before that rename (an I/O error), which rolls back.
    func run(diskSpace: any OrbitDiskSpaceProbe, interruption: Int?, failure: Int? = nil) throws {
        guard id.wholeMatch(of: /[0-9TZ]{16}-[0-9a-f]{8}/) != nil else { throw ArcImportError.backupNotFound }
        let root = try OrbitSecureDirectory.open(location.dataDirectory, create: false)
        let imports = try root.directory("Import", create: true)
        guard let backup = try? imports.directory("Backups/" + id, create: false),
              let manifestData = backup.read("manifest.json"),
              let manifest = try? ArcImportFiles.decoder().decode(ArcImportBackupManifest.self, from: manifestData),
              manifest.id == id else { throw ArcImportError.backupNotFound }

        // 1. Validate everything the swap will need, before touching anything.
        var stagedBytes: Int64 = 0
        var session: Data?
        if manifest.sessionPresent {
            guard let data = backup.read("session.json", limit: BrowserSessionDocument.defaultMaximumInputBytes),
                  (try? BrowserSessionDocument.decode(data)) != nil else { throw ArcImportError.backupInvalid }
            session = data
            stagedBytes += Int64(data.count)
        }
        var databases: [(profile: UUID, directory: OrbitSecureDirectory)] = []
        for (profile, existed) in manifest.historyProfiles where existed {
            // The database must exist, be intact, belong to this exact profile and have a known schema.
            guard let directory = try? backup.directory("History/" + profile.uuidString, create: false),
                  directory.kind("history.sqlite") == S_IFREG,
                  BrowserHistoryStore.isValidBackup(in: directory, profileID: ProfileID(profile), exactSchema: false) else {
                throw ArcImportError.backupInvalid
            }
            databases.append((profile, directory))
            stagedBytes += directory.size("history.sqlite")
        }
        var sidecars: [(current: String, data: Data?)] = []
        for (present, name, current) in [(manifest.ledgerPresent, "ledger.json", "Import/arc-import-ledger.json"),
                                         (manifest.appearancePresent, "space-appearance.json", "Import/space-appearance.json")] {
            var data: Data?
            if present {
                guard let saved = backup.read(name) else { throw ArcImportError.backupInvalid }
                if name == "ledger.json" {
                    guard (try? ArcImportFiles.decoder().decode(BrowserImportLedger.self, from: saved)) != nil else {
                        throw ArcImportError.backupInvalid
                    }
                } else {
                    guard let appearance = try? ArcImportFiles.decoder().decode(BrowserSpaceAppearanceDocument.self, from: saved),
                          appearance.version == 1 else { throw ArcImportError.backupInvalid }
                }
                data = saved
                stagedBytes += Int64(saved.count)
            }
            sidecars.append((current, data))
        }
        try OrbitDiskSpace.require(stagedBytes, at: location.dataDirectory, probe: diskSpace)

        // 2. Stage replacements next to their destinations (same volume), at the same relative
        //    paths, then plan the renames (rebuildable from the manifest, see `plannedMoves`).
        imports.remove(workName)
        do {
            let staged = try imports.directory("\(workName)/staged", create: true)
            _ = try imports.directory("\(workName)/previous", create: true)
            if let session { try staged.write(session, to: location.sessionFile.lastPathComponent) }
            for (profile, directory) in databases {
                let copy = try staged.directory("History/\(profile.uuidString)", create: true)
                try copy.copy("history.sqlite", from: directory, "history.sqlite")
                // The staged copy is brought to the current version in its verified folder, then
                // must have exactly this build's schema before anything is swapped (IMPORT-R4 #D).
                let path = try copy.verifiedPath("history.sqlite")
                let pin = try OrbitSQLiteGuard.pin(copy)
                defer { pin.release() }
                do { try HistoryDatabase(url: URL(fileURLWithPath: path), profileID: ProfileID(profile)).close() }
                catch { throw ArcImportError.backupInvalid }
                // Now in WAL mode: our own copy is opened read-write so SQLite can map its index.
                guard BrowserHistoryStore.isValidBackup(in: copy, profileID: ProfileID(profile), writable: true) else {
                    throw ArcImportError.backupInvalid
                }
            }
            for sidecar in sidecars {
                if let data = sidecar.data {
                    let components = sidecar.current.split(separator: "/").map(String.init)
                    try staged.directory(components.dropLast().joined(separator: "/"), create: true)
                        .write(data, to: components.last!)
                }
            }
        } catch {
            imports.remove(workName)
            throw (error as? ArcImportError) == .backupInvalid ? ArcImportError.backupInvalid : ArcImportError.restoreFailed
        }
        let moves = try plannedMoves(manifest).filter { move in
            // Parks only for entries that exist now; every staged replacement is installed.
            try move.from.hasPrefix(workRelative + "/staged/") || Self.exists(move.from, in: root)
        }

        // 3. Swap by renames, journaled; any error rolls everything back.
        var journal = Journal(backupID: id, phase: .swapping, moves: moves)
        do { try imports.write(try ArcImportFiles.encoder().encode(journal), to: Self.journalName) }
        catch {
            // Publication may have renamed the journal before its directory fsync failed.
            // Preserve staging even when the caller cannot know whether the marker is durable.
            throw ArcImportError.restoreFailed
        }
        do {
            for (index, move) in moves.enumerated() {
                if let interruption, index == interruption { return }
                if let failure, index == failure { throw ArcImportError.restoreFailed }
                try Self.move(move, in: root)
            }
        } catch {
            // A failed rollback is still a live transaction: preserve every recovery input.
            try Self.rollBack(moves, in: root)
            journal.phase = .rollbackCompleted
            try imports.write(try ArcImportFiles.encoder().encode(journal), to: Self.journalName)
            try imports.removeChecked(workName)
            try imports.removeChecked(Self.journalName)
            throw ArcImportError.restoreFailed
        }

        // 4. Cleanup; the previous files are no longer needed.
        journal.phase = .cleanup
        try imports.write(try ArcImportFiles.encoder().encode(journal), to: Self.journalName)
        try imports.removeChecked(workName)
        try imports.removeChecked(Self.journalName)
        if let data = imports.read("arc-import-journal.json"),
           var importJournal = try? ArcImportFiles.decoder().decode(ArcImportJournal.self, from: data) {
            importJournal.state = .restored
            importJournal.updatedAt = Date()
            try? imports.write(try ArcImportFiles.encoder().encode(importJournal), to: "arc-import-journal.json")
        }
    }

    /// Every rename a restore of this backup performs, in order: per entry, the current file is
    /// parked under `previous/` before its replacement leaves `staged/` (same relative path).
    func plannedMoves(_ manifest: ArcImportBackupManifest) -> [Move] {
        var moves: [Move] = []
        func park(_ relative: String) { moves.append(Move(from: relative, to: "\(workRelative)/previous/\(relative)")) }
        func install(_ relative: String) { moves.append(Move(from: "\(workRelative)/staged/\(relative)", to: relative)) }
        let sessionName = location.sessionFile.lastPathComponent
        park(sessionName)
        if manifest.sessionPresent { install(sessionName) }
        for (profile, existed) in manifest.historyProfiles.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let relative = "History/\(profile.uuidString)"
            if existed {
                for suffix in ["", "-wal", "-shm", "-journal"] { park("\(relative)/history.sqlite\(suffix)") }
                install("\(relative)/history.sqlite")
            } else {
                park(relative)
            }
        }
        for (present, current) in [(manifest.ledgerPresent, "Import/arc-import-ledger.json"),
                                   (manifest.appearancePresent, "Import/space-appearance.json")] {
            park(current)
            if present { install(current) }
        }
        return moves
    }

    /// Undoes applied renames, newest first; idempotent, so it also finishes an interrupted rollback.
    static func rollBack(_ moves: [Move], in root: OrbitSecureDirectory) throws {
        for move in moves.reversed() where try exists(move.to, in: root) && !exists(move.from, in: root) {
            try self.move(move, in: root, reverse: true)
        }
        try synchronizeMoveParents(moves, in: root)
    }

    /// A retry can infer a completed rename from its entries, but not a completed fsync.
    /// Repair both parents before a completed marker makes any staged inputs disposable.
    private static func synchronizeMoveParents(_ moves: [Move], in root: OrbitSecureDirectory) throws {
        for relative in Set(moves.flatMap { [$0.from, $0.to] }) {
            do {
                let (directory, _) = try parent(relative, in: root, create: false)
                try directory.synchronize()
            } catch ArcImportError.backupNotFound { /* No rename reached this absent parent. */ }
        }
    }

    static func recover(_ location: ArcImportDataLocation) throws {
        let root = try OrbitSecureDirectory.open(location.dataDirectory, create: false)
        let imports = try root.directory("Import", create: false)
        // Never treat an unreadable journal as absent: the parked files would be lost (#C).
        guard let data = imports.read(journalName),
              var journal = try? ArcImportFiles.decoder().decode(Journal.self, from: data) else {
            throw ArcImportError.restoreJournalUnreadable
        }
        let restore = ArcImportRestore(id: journal.backupID, location: location)
        if journal.phase == .swapping {
            try rollBack(journal.moves, in: root)
            journal.phase = .rollbackCompleted
            // Persist and sync the completed rollback BEFORE deleting any staged input.
            try imports.write(try ArcImportFiles.encoder().encode(journal), to: journalName)
        }
        // A terminal marker can be visible after its publication fsync failed. Every retry
        // must repair its file and directory durability before discarding rollback inputs.
        let marker = try imports.openFile(journalName)
        defer { Darwin.close(marker) }
        guard fsync(marker) == 0 else { throw ArcImportError.restoreFailed }
        try imports.synchronize()
        if journal.evidenceWorks != nil {
            try finishRecoveryEvidence(journal, in: imports)
        } else {
            try imports.removeChecked(restore.workName)
        }
        try imports.removeChecked(journalName)
    }

    private static func finishRecoveryEvidence(_ journal: Journal, in imports: OrbitSecureDirectory) throws {
        guard let relative = journal.evidenceRelativePath, let works = journal.evidenceWorks,
              relative.hasPrefix("Recovered/"), relative.split(separator: "/").allSatisfy(OrbitSecureDirectory.validName),
              works.allSatisfy({ OrbitSecureDirectory.validName($0) && $0.hasPrefix(".restore-") }) else {
            throw ArcImportError.restoreJournalUnreadable
        }
        let evidence = try imports.directory(relative, create: true)
        for work in works where try imports.checkedKind(work) != nil {
            try imports.rename(work, to: evidence, String(work.dropFirst()))
        }
        try imports.synchronize()
        try evidence.synchronize()
    }

    /// Rollback without the journal: the renames are rebuilt from each restore's backup manifest
    /// (deterministic), else parked entries go back wherever nothing occupies their place.
    static func recoverWithoutJournal(_ location: ArcImportDataLocation, now: Date, report: inout ArcImportRecoveryReport) throws {
        let root = try OrbitSecureDirectory.open(location.dataDirectory, create: false)
        let imports = try root.directory("Import", create: false)
        let works = try imports.checkedEntries().filter { $0.hasPrefix(".restore-") }.sorted()
        for work in works {
            guard try imports.checkedKind(work) == S_IFDIR else { throw ArcImportError.restoreFailed }
        }
        for work in works {
            let restore = ArcImportRestore(id: String(work.dropFirst(".restore-".count)), location: location)
            if let backup = try? imports.directory("Backups/" + restore.id, create: false),
               let data = backup.read("manifest.json"),
               let manifest = try? ArcImportFiles.decoder().decode(ArcImportBackupManifest.self, from: data), manifest.id == restore.id {
                let moves = restore.plannedMoves(manifest)
                // Missing staging alone cannot prove installation: cleanup of an already
                // completed rollback may have removed it before the journal was corrupted.
                // Without a parked original, reversing such an install could remove the live
                // restored session. Refuse the ambiguity before moving anything.
                for move in moves where move.from.hasPrefix(restore.workRelative + "/staged/") {
                    if try !exists(move.from, in: root) && exists(move.to, in: root)
                        && !exists(restore.workRelative + "/previous/" + move.to, in: root) {
                        throw ArcImportError.restoreJournalUnreadable
                    }
                }
                for move in moves.reversed() where try exists(move.to, in: root) && !exists(move.from, in: root) {
                    try self.move(move, in: root, reverse: true)
                    if move.to.hasPrefix(restore.workRelative + "/previous/") { report.restoredEntries += 1 }
                }
                try synchronizeMoveParents(moves, in: root)
                report.rebuiltFromManifest += 1
            }
            // Whatever is still parked goes back only where its place is free.
            do {
                let previous = try imports.directory("\(work)/previous", create: false)
                try putBack(previous, into: root, report: &report)
            } catch ArcImportError.backupNotFound { /* An absent parked tree has nothing to recover. */ }
        }
        // Evidence: the unreadable journal and the working folders, moved aside together.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now) + "-" + UUID().uuidString.prefix(8).lowercased()
        let evidence = try imports.directory("Recovered/" + stamp, create: true)
        // Keep the unreadable journal as evidence, then atomically publish a durable completed
        // marker. A crash during evidence cleanup must never replay the reverse moves.
        guard let damaged = imports.read(journalName) else { throw ArcImportError.restoreJournalUnreadable }
        try evidence.write(damaged, to: journalName)
        let completed = Journal(backupID: works.first.map { String($0.dropFirst(".restore-".count)) } ?? "19700101T000000Z-00000000",
                                phase: .rollbackCompleted, moves: [],
                                evidenceRelativePath: "Recovered/" + stamp, evidenceWorks: works)
        try imports.write(try ArcImportFiles.encoder().encode(completed), to: journalName)
        try finishRecoveryEvidence(completed, in: imports)
        try imports.removeChecked(journalName)
        report.evidenceFolder = "Import/Recovered/" + stamp
    }

    /// Moves each entry of a parked tree back to the same relative place when that place is free;
    /// descends where both are directories; leaves the rest parked.
    private static func putBack(_ parked: OrbitSecureDirectory, into original: OrbitSecureDirectory,
                                report: inout ArcImportRecoveryReport) throws {
        // Repeat these syncs even if an earlier attempt moved the last entry then stopped
        // during fsync: an empty tree alone does not prove the destination is durable.
        try parked.synchronize()
        try original.synchronize()
        for name in try parked.checkedEntries().sorted() {
            if try original.checkedKind(name) == nil {
                try parked.rename(name, to: original, name)
                report.restoredEntries += 1
            } else if try parked.checkedKind(name) == S_IFDIR, try original.checkedKind(name) == S_IFDIR {
                let inner = try parked.directory(name, create: false)
                let target = try original.directory(name, create: false)
                try putBack(inner, into: target, report: &report)
            } else {
                report.entriesLeftAside += 1
            }
        }
    }
}
