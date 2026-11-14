import CryptoKit
import Darwin
import Foundation

/// Private snapshot of the engine state that an update can invalidate, taken before the first
/// launch of a different build: Local State, then for every profile its Secure Preferences
/// (extension records and their authenticators), Preferences (pinned extensions) and cookie
/// database. The caller holds the exclusive data root lock and the engine is not running, so
/// the copies are consistent.
///
/// Snapshots stay inside the data root (directory 0700, files 0600), are never logged or
/// uploaded, and are never restored automatically. `restore` is a deliberate action on a
/// stopped browser; it first snapshots the current files so the restore itself can be undone.
public enum BrowserEngineMigrationBackup {
    public static let directoryName = "EngineMigrationBackups"
    static let markerName = ".orbit-last-launched-build"
    public static let retainedSnapshots = 3
    /// Copies of deleted cookies or removed profiles must not outlive this window.
    public static let maximumAge: TimeInterval = 30 * 24 * 3600
    static let engineFiles = ["Local State"]
    static let profileFiles = ["Secure Preferences", "Preferences", "Network/Cookies", "Network/Cookies-journal",
                               "Network/Cookies-wal", "Cookies", "Cookies-journal", "Cookies-wal"]

    public struct Entry: Codable, Equatable, Sendable {
        /// Relative to the engine root, e.g. "profile-<uuid>/Secure Preferences".
        public var path: String
        public var size: Int
        public var sha256: String
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public var id: String
        public var fromBuild: String?
        public var toBuild: String
        public var reason: String
        public var created: Date
        public var files: [Entry]
    }

    public enum Failure: Error, Equatable { case unsafePath, missingSnapshot, damagedSnapshot }

    /// Snapshots the engine state when `build` differs from the last launched build, then
    /// records `build`. Returns the snapshot, or nil when the build is unchanged or the engine
    /// root has no profile yet. On failure nothing is recorded, so the next launch retries.
    @discardableResult
    public static func prepareLaunch(dataRoot: URL, engineRoot: URL, build: String, now: Date = Date()) throws -> Manifest? {
        let marker = dataRoot.appendingPathComponent(markerName)
        let previous = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        prune(dataRoot.appendingPathComponent(directoryName, isDirectory: true), now: now)
        guard previous != build else { return nil }
        var manifest: Manifest?
        if !profiles(in: engineRoot).isEmpty {
            manifest = try snapshot(dataRoot: dataRoot, engineRoot: engineRoot, from: previous, to: build,
                                    reason: "build-change", now: now)
        }
        try Data((build + "\n").utf8).write(to: marker, options: .atomic)
        return manifest
    }

    /// Profile directories directly under the engine root (Default, profile-<uuid>, ...).
    static func profiles(in engineRoot: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: engineRoot.path)) ?? []
        return names.filter { name in
            var info = stat()
            let path = engineRoot.appendingPathComponent(name).path
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
            return isRegularFile(engineRoot.appendingPathComponent(name).appendingPathComponent("Secure Preferences"))
                || isRegularFile(engineRoot.appendingPathComponent(name).appendingPathComponent("Preferences"))
        }.sorted()
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    static func candidates(in engineRoot: URL) -> [String] {
        var paths = engineFiles.filter { isRegularFile(engineRoot.appendingPathComponent($0)) }
        for profile in profiles(in: engineRoot) {
            paths += profileFiles.map { profile + "/" + $0 }.filter { isRegularFile(engineRoot.appendingPathComponent($0)) }
        }
        return paths
    }

    static func digest(_ url: URL) throws -> (Int, String) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return (data.count, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(url.path, 0o700) == 0 else { throw Failure.unsafePath }
    }

    /// Copies the candidates into a new snapshot, published atomically once complete.
    static func snapshot(dataRoot: URL, engineRoot: URL, from: String?, to: String, reason: String, now: Date) throws -> Manifest {
        let directory = dataRoot.appendingPathComponent(directoryName, isDirectory: true)
        try makePrivateDirectory(directory)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now)
        let id = stamp + "-" + UUID().uuidString.prefix(8).lowercased()
        let partial = directory.appendingPathComponent(".partial-" + id, isDirectory: true)
        try makePrivateDirectory(partial)
        do {
            var entries: [Entry] = []
            for relative in candidates(in: engineRoot) {
                let source = engineRoot.appendingPathComponent(relative)
                let target = partial.appendingPathComponent("Chromium").appendingPathComponent(relative)
                try makePrivateDirectory(target.deletingLastPathComponent())
                try FileManager.default.copyItem(at: source, to: target)
                guard chmod(target.path, 0o600) == 0 else { throw Failure.unsafePath }
                let (size, hash) = try digest(target)
                entries.append(Entry(path: relative, size: size, sha256: hash))
            }
            let manifest = Manifest(id: id, fromBuild: from, toBuild: to, reason: reason, created: now, files: entries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let file = partial.appendingPathComponent("manifest.json")
            try encoder.encode(manifest).write(to: file, options: .atomic)
            guard chmod(file.path, 0o600) == 0 else { throw Failure.unsafePath }
            try FileManager.default.moveItem(at: partial, to: directory.appendingPathComponent(id, isDirectory: true))
            prune(directory, now: now)
            return manifest
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Keeps the most recent build-change snapshots and removes every snapshot (restore safety
    /// copies included) older than `maximumAge`.
    static func prune(_ directory: URL, now: Date) {
        let all = snapshots(in: directory)
        let expired = all.filter { now.timeIntervalSince($0.created) > maximumAge }
        let changes = all.filter { $0.reason == "build-change" }
        for old in Set(changes.dropLast(retainedSnapshots).map(\.id) + expired.map(\.id)) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old, isDirectory: true))
        }
        for orphan in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where orphan.hasPrefix(".partial-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(orphan))
        }
    }

    static func snapshots(in directory: URL) -> [Manifest] {
        let decoder = JSONDecoder()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name).appendingPathComponent("manifest.json")),
                  let manifest = try? decoder.decode(Manifest.self, from: data), manifest.id == name else { return nil }
            return manifest
        }.sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }
    }

    /// Snapshots in creation order (oldest first).
    public static func snapshots(dataRoot: URL) -> [Manifest] {
        snapshots(in: dataRoot.appendingPathComponent(directoryName, isDirectory: true))
    }

    /// Puts a verified snapshot back. The browser must be stopped and the caller must hold the
    /// data root lock. The current files are snapshotted first (reason "before-restore"); files
    /// the snapshot does not contain are moved into that safety copy, never deleted.
    @discardableResult
    public static func restore(id: String, dataRoot: URL, engineRoot: URL, now: Date = Date()) throws -> Manifest {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { throw Failure.unsafePath }
        let directory = dataRoot.appendingPathComponent(directoryName, isDirectory: true)
        guard let manifest = snapshots(in: directory).first(where: { $0.id == id }) else { throw Failure.missingSnapshot }
        let source = directory.appendingPathComponent(id).appendingPathComponent("Chromium")
        for entry in manifest.files {
            guard !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains("..") else { throw Failure.unsafePath }
            let (size, hash) = try digest(source.appendingPathComponent(entry.path))
            guard size == entry.size, hash == entry.sha256 else { throw Failure.damagedSnapshot }
        }
        let safety = try snapshot(dataRoot: dataRoot, engineRoot: engineRoot, from: nil, to: "before-restore-" + id,
                                  reason: "before-restore", now: now)
        let restored = Set(manifest.files.map(\.path))
        // A journal or WAL without its database version would mix states: set it aside.
        let databases = Set(manifest.files.map(\.path).filter { $0.hasSuffix("Cookies") })
        for database in databases {
            for suffix in ["-journal", "-wal"] where !restored.contains(database + suffix) {
                let stray = engineRoot.appendingPathComponent(database + suffix)
                guard isRegularFile(stray) else { continue }
                let kept = directory.appendingPathComponent(safety.id).appendingPathComponent("Unrestored")
                    .appendingPathComponent(database + suffix)
                try makePrivateDirectory(kept.deletingLastPathComponent())
                try FileManager.default.moveItem(at: stray, to: kept)
            }
        }
        for entry in manifest.files {
            let target = engineRoot.appendingPathComponent(entry.path)
            try makePrivateDirectory(target.deletingLastPathComponent())
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".restore-" + UUID().uuidString)
            try FileManager.default.copyItem(at: source.appendingPathComponent(entry.path), to: temporary)
            guard chmod(temporary.path, 0o600) == 0, rename(temporary.path, target.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                throw Failure.unsafePath
            }
        }
        return manifest
    }
}
