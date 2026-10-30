import Darwin
import Foundation
import SQLite3

/// Keys are supplied by the product's Keychain provider, or by a fixture. No fallback key.
public protocol ArcSiteSessionKeyProviding {
    func sourcePassword() throws -> Data
    func targetPassword() throws -> Data
}

public struct ArcSiteSessionProfile: Codable, Sendable, Equatable {
    public let sourceDirectory: String
    public let targetID: ProfileID
    public init(sourceDirectory: String, targetID: ProfileID) {
        self.sourceDirectory = sourceDirectory
        self.targetID = targetID
    }
    public var targetDirectory: String { "profile-" + targetID.rawValue.uuidString.lowercased() }
}

public struct ArcSiteSessionRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case importSessions, restore }
    public var action: Action
    public var sourceRoot: URL
    public var profiles: [ArcSiteSessionProfile]
    public init(action: Action = .importSessions, sourceRoot: URL, profiles: [ArcSiteSessionProfile]) {
        self.action = action; self.sourceRoot = sourceRoot; self.profiles = profiles
    }
}

public struct ArcSiteSessionResult: Codable, Sendable, Equatable {
    public var profiles = 0
    public var cookies = 0
    public var failedProfiles = 0
    public var restored = false
    public init() {}
}

/// Offline only. The caller owns Orbit's data-root lock and has not initialized CEF.
/// Backups contain private profile data and stay below the product's private data root.
public struct ArcSiteSessionImport {
    public enum Failure: Error { case invalidProfile, unsafePath, database, schema, backupUnavailable }
    public let dataRoot: URL
    public init(dataRoot: URL) { self.dataRoot = dataRoot }
    public var directory: URL { dataRoot.appendingPathComponent("SessionImport", isDirectory: true) }
    public var pendingFile: URL { directory.appendingPathComponent("pending.json") }
    private var backups: URL { directory.appendingPathComponent("Backups", isDirectory: true) }
    private let manager = FileManager.default
    private static let entries = ["Cookies", "Cookies-journal", "Cookies-wal", "Cookies-shm",
                                  "Local Storage", "IndexedDB", "WebStorage"]
    private struct SavedProfile: Codable {
        var profile: ArcSiteSessionProfile
        var existing: [String]
        var state: State
        enum State: String, Codable { case prepared, committed, restored }
    }
    private struct Backup: Codable { var profiles: [SavedProfile] = [] }

    public func schedule(_ request: ArcSiteSessionRequest) throws {
        try validate(request)
        try ArcImportFiles.writePrivate(JSONEncoder().encode(request), to: pendingFile)
    }

    public func cancelPending() throws {
        if manager.fileExists(atPath: pendingFile.path) { try manager.removeItem(at: pendingFile) }
    }

    public var hasBackup: Bool { (try? latestBackup()) != nil }

    /// An interrupted profile is put back before a pending request or CEF can touch it.
    public func recoverInterruptedImport() throws {
        for url in try backupDirectories() {
            var backup = try readBackup(url)
            for index in backup.profiles.indices where backup.profiles[index].state == .prepared {
                try restore(backup.profiles[index], from: url)
                backup.profiles[index].state = .restored
                try writeBackup(backup, at: url)
            }
        }
    }

    public func consumePending(keys: any ArcSiteSessionKeyProviding) throws -> ArcSiteSessionResult? {
        try recoverInterruptedImport()
        guard manager.fileExists(atPath: pendingFile.path) else { return nil }
        try checkTree(pendingFile)
        let data = try Data(contentsOf: pendingFile)
        // Consume before acting: a replay after an interruption would back up already imported
        // data over the undo point, or restore an older backup. Profiles interrupted mid-run
        // stay `.prepared` and are put back by `recoverInterruptedImport()` on the next launch.
        try cancelPending()
        let request = try JSONDecoder().decode(ArcSiteSessionRequest.self, from: data)
        try validate(request)
        return request.action == .restore ? try restoreLatest() : try run(request, keys: keys)
    }

    public func run(_ request: ArcSiteSessionRequest, keys: any ArcSiteSessionKeyProviding,
                    now: Date = Date()) throws -> ArcSiteSessionResult {
        try validate(request)
        var sourceKey = try ArcChromiumCookieCipher.deriveKey(password: keys.sourcePassword())
        defer { sourceKey.resetBytes(in: 0..<sourceKey.count) }
        var targetKey = try ArcChromiumCookieCipher.deriveKey(password: keys.targetPassword())
        defer { targetKey.resetBytes(in: 0..<targetKey.count) }
        let stamp = String(Int(now.timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString
        let backupURL = backups.appendingPathComponent(stamp, isDirectory: true)
        _ = try ArcImportFiles.ensurePrivateDirectory(backupURL)
        var backup = Backup()
        var result = ArcSiteSessionResult()
        for profile in request.profiles {
            let source = request.sourceRoot.appendingPathComponent(profile.sourceDirectory, isDirectory: true)
            let target = targetURL(profile)
            // A backup must be complete and recorded before the first mutation of this profile.
            var saved: SavedProfile?
            do {
                guard manager.fileExists(atPath: source.path) else { throw Failure.invalidProfile }
                try checkTree(source)
                try checkTree(target)
                let savedURL = backupURL.appendingPathComponent(profile.targetDirectory, isDirectory: true)
                _ = try ArcImportFiles.ensurePrivateDirectory(savedURL)
                let existing = Self.entries.filter { manager.fileExists(atPath: target.appendingPathComponent($0).path) }
                for name in existing {
                    try manager.copyItem(at: target.appendingPathComponent(name), to: savedURL.appendingPathComponent(name))
                }
                let item = SavedProfile(profile: profile, existing: existing, state: .prepared)
                backup.profiles.append(item)
                try writeBackup(backup, at: backupURL)
                saved = item
                _ = try ArcImportFiles.ensurePrivateDirectory(target)
                let cookies = try importCookies(from: source, to: target, sourceKey: sourceKey, targetKey: targetKey, now: now)
                for name in ["Local Storage", "IndexedDB", "WebStorage"] {
                    let destination = target.appendingPathComponent(name)
                    if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                    let original = source.appendingPathComponent(name)
                    if manager.fileExists(atPath: original.path) { try manager.copyItem(at: original, to: destination) }
                }
                backup.profiles[backup.profiles.count - 1].state = .committed
                try writeBackup(backup, at: backupURL)
                result.profiles += 1
                result.cookies += cookies
            } catch {
                if let saved {
                    // Failure to restore is fatal: do not start CEF on a partially replaced profile.
                    try restore(saved, from: backupURL)
                    backup.profiles[backup.profiles.count - 1].state = .restored
                    try writeBackup(backup, at: backupURL)
                }
                result.failedProfiles += 1
            }
        }
        return result
    }

    public func restoreLatest() throws -> ArcSiteSessionResult {
        let url = try latestBackup()
        var backup = try readBackup(url)
        var result = ArcSiteSessionResult()
        result.restored = true
        for index in backup.profiles.indices where backup.profiles[index].state != .restored {
            backup.profiles[index].state = .prepared
            try writeBackup(backup, at: url)
            try restore(backup.profiles[index], from: url)
            backup.profiles[index].state = .restored
            try writeBackup(backup, at: url)
            result.profiles += 1
        }
        return result
    }

    private func targetURL(_ profile: ArcSiteSessionProfile) -> URL {
        dataRoot.appendingPathComponent("Chromium", isDirectory: true).appendingPathComponent(profile.targetDirectory, isDirectory: true)
    }

    private func validate(_ request: ArcSiteSessionRequest) throws {
        guard dataRoot.isFileURL, request.sourceRoot.isFileURL else { throw Failure.unsafePath }
        try checkTree(directory)
        var targets = Set<ProfileID>()
        for profile in request.profiles {
            _ = try ArcAuthenticationSourceProfile(registration: UUID(), profile: .directory(profile.sourceDirectory))
            guard targets.insert(profile.targetID).inserted else { throw Failure.invalidProfile }
            let source = request.sourceRoot.appendingPathComponent(profile.sourceDirectory).standardizedFileURL.resolvingSymlinksInPath()
            let target = targetURL(profile).standardizedFileURL.resolvingSymlinksInPath()
            let rootPath = dataRoot.standardizedFileURL.resolvingSymlinksInPath().path
            guard source != target, source.path != rootPath, !source.path.hasPrefix(rootPath + "/"),
                  !rootPath.hasPrefix(source.path + "/") else {
                throw Failure.unsafePath
            }
        }
    }

    private func checkTree(_ url: URL) throws {
        // Do not let a copied storage link make CEF follow data outside the selected profile.
        var path = url
        while path.path != "/" {
            var info = stat()
            if lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { throw Failure.unsafePath }
            path.deleteLastPathComponent()
        }
        guard manager.fileExists(atPath: url.path) else { return }
        if let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) {
            for case let child as URL in enumerator {
                if try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw Failure.unsafePath }
            }
        }
    }

    private func backupDirectories() throws -> [URL] {
        guard manager.fileExists(atPath: backups.path) else { return [] }
        try checkTree(backups)
        return try manager.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && manager.fileExists(atPath: $0.appendingPathComponent("backup.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func latestBackup() throws -> URL {
        for url in try backupDirectories().reversed() {
            if try readBackup(url).profiles.contains(where: { $0.state != .restored }) { return url }
        }
        throw Failure.backupUnavailable
    }
    private func readBackup(_ url: URL) throws -> Backup {
        let backup = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url.appendingPathComponent("backup.json")))
        try validate(.init(action: .restore, sourceRoot: URL(fileURLWithPath: "/"), profiles: backup.profiles.map(\.profile)))
        guard backup.profiles.allSatisfy({ Set($0.existing).isSubset(of: Set(Self.entries)) }) else { throw Failure.unsafePath }
        return backup
    }
    private func writeBackup(_ backup: Backup, at url: URL) throws {
        try ArcImportFiles.writePrivate(JSONEncoder().encode(backup), to: url.appendingPathComponent("backup.json"))
    }
    private func restore(_ saved: SavedProfile, from backup: URL) throws {
        let target = targetURL(saved.profile)
        try checkTree(target)
        _ = try ArcImportFiles.ensurePrivateDirectory(target)
        for name in Self.entries {
            let destination = target.appendingPathComponent(name)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            if saved.existing.contains(name) {
                try manager.copyItem(at: backup.appendingPathComponent(saved.profile.targetDirectory).appendingPathComponent(name), to: destination)
            }
        }
    }

    private func importCookies(from source: URL, to target: URL, sourceKey: Data, targetKey: Data, now: Date) throws -> Int {
        let networkFile = source.appendingPathComponent("Network/Cookies")
        let sourceFile = manager.fileExists(atPath: networkFile.path) ? networkFile : source.appendingPathComponent("Cookies")
        guard manager.fileExists(atPath: sourceFile.path) else { return 0 }
        // SQLite's backup API includes committed WAL pages; read from the resulting copy only.
        let copy = directory.appendingPathComponent("cookies-" + UUID().uuidString + ".sqlite")
        defer { try? manager.removeItem(at: copy) }
        _ = try ArcImportFiles.ensurePrivateDirectory(directory)
        do {
            let original = try SessionSQLite(sourceFile, readOnly: true)
            let snapshot = try SessionSQLite(copy)
            guard let operation = sqlite3_backup_init(snapshot.db, "main", original.db, "main") else { throw Failure.database }
            let status = sqlite3_backup_step(operation, -1)
            let finish = sqlite3_backup_finish(operation)
            guard status == SQLITE_DONE, finish == SQLITE_OK else { throw Failure.database }
        }
        let sourceDB = try SessionSQLite(copy, readOnly: true)
        try sourceDB.validateSchema()
        let targetFile = target.appendingPathComponent("Cookies")
        let fresh = !manager.fileExists(atPath: targetFile.path)
        if fresh { try manager.copyItem(at: copy, to: targetFile) }
        let targetDB = try SessionSQLite(targetFile)
        try targetDB.validateSchema()
        let columns = try sourceDB.columns()
        guard columns == (try targetDB.columns()), let encryptedIndex = columns.firstIndex(of: "encrypted_value"),
              let hostIndex = columns.firstIndex(of: "host_key") else { throw Failure.schema }
        try targetDB.execute("BEGIN IMMEDIATE")
        do {
            if fresh { try targetDB.execute("DELETE FROM cookies") }
            let microseconds = Int64((now.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
            let select = try sourceDB.statement("SELECT * FROM cookies WHERE has_expires = 0 OR expires_utc > \(microseconds)")
            defer { sqlite3_finalize(select) }
            let insert = try targetDB.statement("INSERT OR REPLACE INTO cookies (" + columns.map { "\"" + $0 + "\"" }.joined(separator: ",")
                                               + ") VALUES (" + columns.map { _ in "?" }.joined(separator: ",") + ")")
            defer { sqlite3_finalize(insert) }
            var count = 0
            var step = sqlite3_step(select)
            while step == SQLITE_ROW {
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                for index in columns.indices {
                    let column = Int32(index)
                    let parameter = column + 1
                    if index == encryptedIndex, sqlite3_column_bytes(select, column) > 0 {
                        let encrypted = Data(bytes: sqlite3_column_blob(select, column)!, count: Int(sqlite3_column_bytes(select, column)))
                        guard let host = sqlite3_column_text(select, Int32(hostIndex)) else { throw Failure.schema }
                        let converted = try ArcChromiumCookieCipher.reencrypt(encrypted, host: String(cString: host), sourceKey: sourceKey, targetKey: targetKey)
                        let bound = converted.withUnsafeBytes { sqlite3_bind_blob(insert, parameter, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                        guard bound == SQLITE_OK else { throw Failure.database }
                    } else {
                        guard sqlite3_bind_value(insert, parameter, sqlite3_column_value(select, column)) == SQLITE_OK else { throw Failure.database }
                    }
                }
                guard sqlite3_step(insert) == SQLITE_DONE else { throw Failure.database }
                count += 1
                step = sqlite3_step(select)
            }
            guard step == SQLITE_DONE else { throw Failure.database }
            try targetDB.execute("COMMIT")
            return count
        } catch {
            try? targetDB.execute("ROLLBACK")
            throw error
        }
    }
}

private final class SessionSQLite {
    var db: OpaquePointer?
    init(_ url: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; throw ArcSiteSessionImport.Failure.database
        }
        sqlite3_busy_timeout(db, 2000)
    }
    deinit { sqlite3_close(db) }
    func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ArcSiteSessionImport.Failure.database
        }
        return statement
    }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ArcSiteSessionImport.Failure.database }
    }
    func validateSchema() throws {
        for key in ["version", "last_compatible_version"] {
            let row = try statement("SELECT value FROM meta WHERE key='\(key)'")
            defer { sqlite3_finalize(row) }
            guard sqlite3_step(row) == SQLITE_ROW, sqlite3_column_int(row, 0) == 24 else { throw ArcSiteSessionImport.Failure.schema }
        }
    }
    func columns() throws -> [String] {
        let row = try statement("PRAGMA table_info(cookies)")
        defer { sqlite3_finalize(row) }
        var names: [String] = []
        while sqlite3_step(row) == SQLITE_ROW {
            guard let name = sqlite3_column_text(row, 1) else { throw ArcSiteSessionImport.Failure.schema }
            let value = String(cString: name)
            guard value.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) else { throw ArcSiteSessionImport.Failure.schema }
            names.append(value)
        }
        guard !names.isEmpty else { throw ArcSiteSessionImport.Failure.schema }
        return names
    }
}
