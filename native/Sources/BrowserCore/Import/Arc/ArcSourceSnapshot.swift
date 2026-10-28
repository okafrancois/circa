import Darwin
import Foundation

/// Copy-on-read of the few Arc files the importer needs, in a private directory (mode 0700, files
/// 0600) that is deleted when the import ends. Cookies, passwords, extensions and site storage are
/// never copied. Every source file is fingerprinted before and after the copy; a change, or Arc
/// running before or after, discards the copy. Arc is never quit by the importer.
public final class ArcSourceSnapshot: @unchecked Sendable {
    public static let directoryPrefix = "orbit-arc-import-"
    static let maximumDocumentBytes: Int64 = 150 * 1024 * 1024
    static let maximumLocalStateBytes: Int64 = 16 * 1024 * 1024
    /// The WAL index (`-shm`) is rebuilt by SQLite and never copied.
    static let historySidecars = ["-journal", "-wal"]

    public let directory: URL
    public let sidebar: URL
    public let archive: URL?
    public let localState: URL?
    /// Arc profile directory name → private copy of its `History` database.
    public let historyDatabases: [String: URL]
    private let lock = NSLock()
    private var removed = false

    private init(directory: URL, sidebar: URL, archive: URL?, localState: URL?, historyDatabases: [String: URL]) {
        self.directory = directory
        self.sidebar = sidebar
        self.archive = archive
        self.localState = localState
        self.historyDatabases = historyDatabases
    }

    deinit { remove() }

    public func remove() {
        let shouldRemove = lock.withLock { () -> Bool in
            defer { removed = true }
            return !removed
        }
        if shouldRemove { try? FileManager.default.removeItem(at: directory) }
    }

    /// The default Arc data directory (observed location).
    public static var defaultSourceRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arc", isDirectory: true)
    }

    public static func capture(source root: URL, includeHistory: Bool = true,
                               parent: URL = FileManager.default.temporaryDirectory,
                               probe: any ArcRunningProbe,
                               diskSpace: any OrbitDiskSpaceProbe = OrbitSystemDiskSpaceProbe()) throws -> ArcSourceSnapshot {
        try capture(source: root, includeHistory: includeHistory, parent: parent, probe: probe, diskSpace: diskSpace, afterCopy: {})
    }

    /// `afterCopy` runs between the copy and the second fingerprint pass (tests simulate Arc writing).
    static func capture(source root: URL, includeHistory: Bool, parent: URL, probe: any ArcRunningProbe,
                        diskSpace: any OrbitDiskSpaceProbe = OrbitSystemDiskSpaceProbe(), afterCopy: () -> Void) throws -> ArcSourceSnapshot {
        // The temporary directory is system-chosen (`/var` → `/private/var`): resolve it once.
        let parent = URL(fileURLWithPath: ArcImportPaths.resolved(parent), isDirectory: true)
        // Every source file is reached through descriptors opened from `/` without following any
        // link (IMPORT-R3 #2): no check-then-use race on the source side either.
        let source: OrbitSecureDirectory
        do { source = try OrbitSecureDirectory.open(root, create: false) }
        catch ArcImportError.backupNotFound { throw ArcImportError.sourceNotFound }
        guard source.kind("StorableSidebar.json") == S_IFREG else {
            if source.kind("StorableSidebar.json") != nil { throw ArcImportError.unsupportedSourceFile }
            throw ArcImportError.sourceNotFound
        }
        try ArcImportPaths.validateSeparated(source: root, destination: parent)
        guard !probe.isArcRunning(sourceRoot: root) else { throw ArcImportError.arcIsRunning }
        removeStaleSnapshots(in: parent)

        var plan: [(relative: String, limit: Int64?, required: Bool)] = [
            ("StorableSidebar.json", maximumDocumentBytes, true),
            ("StorableArchiveItems.json", maximumDocumentBytes, false),
            ("User Data/Local State", maximumLocalStateBytes, false),
        ]
        var historyDirectories: [String] = []
        switch source.kind("User Data") {
        case nil, S_IFDIR?: break
        default: throw ArcImportError.symbolicLinkInPath
        }
        if includeHistory, let userData = try? source.directory("User Data", create: false) {
            for name in userData.entries().sorted() where ArcSidebarParser.isProfileDirectory(name) && userData.kind(name) == S_IFDIR {
                guard let profile = try? userData.directory(name, create: false), profile.kind("History") == S_IFREG else { continue }
                let history = "User Data/\(name)/History"
                historyDirectories.append(name)
                plan.append((history, nil, true))
                for suffix in historySidecars { plan.append((history + suffix, nil, false)) }
            }
        }

        func locate(_ relative: String) throws -> (OrbitSecureDirectory, String)? {
            let components = relative.split(separator: "/").map(String.init)
            let folder = components.dropLast().joined(separator: "/")
            guard let directory = folder.isEmpty ? source : try? source.directory(folder, create: false) else { return nil }
            return (directory, components.last!)
        }
        func fingerprint(_ relative: String) throws -> Fingerprint? {
            guard let (directory, name) = try locate(relative), let kind = directory.kind(name) else { return nil }
            guard kind == S_IFREG else { throw ArcImportError.unsupportedSourceFile }
            var info = stat()
            guard fstatat(directory.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            return Fingerprint(size: info.st_size, modified: info.st_mtimespec, changed: info.st_ctimespec,
                               inode: info.st_ino, device: info.st_dev)
        }

        var sourceBytes: Int64 = 0
        for entry in plan { sourceBytes += (try? fingerprint(entry.relative))??.size ?? 0 }
        // Worst case without APFS cloning: a full copy.
        try OrbitDiskSpace.require(sourceBytes, at: parent, probe: diskSpace)

        var template = Array(parent.appendingPathComponent(directoryPrefix + "XXXXXX").path.utf8CString)
        guard let created = mkdtemp(&template) else { throw ArcImportError.snapshotFailed }
        let directory = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        do {
            let snapshot = try OrbitSecureDirectory.open(directory, create: false)
            var fingerprints: [String: Fingerprint?] = [:]
            for entry in plan {
                let before = try fingerprint(entry.relative)
                fingerprints[entry.relative] = before
                guard let before, let (from, name) = try locate(entry.relative) else {
                    if entry.required { throw ArcImportError.sourceChangedDuringCopy }
                    continue
                }
                if let limit = entry.limit, before.size > limit { throw ArcImportError.unsupportedSourceFile }
                let folder = entry.relative.split(separator: "/").dropLast().joined(separator: "/")
                let destination = folder.isEmpty ? snapshot : try snapshot.directory(folder, create: true)
                try destination.copy(name, from: from, name)
            }
            afterCopy()
            // Arc writing a file, or starting meanwhile, invalidates the copy.
            for entry in plan where try fingerprint(entry.relative) != fingerprints[entry.relative] ?? nil {
                throw ArcImportError.sourceChangedDuringCopy
            }
            guard !probe.isArcRunning(sourceRoot: root) else { throw ArcImportError.arcIsRunning }
            func copied(_ relative: String) -> URL? {
                let url = directory.appendingPathComponent(relative)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            var histories: [String: URL] = [:]
            for name in historyDirectories { histories[name] = copied("User Data/\(name)/History") }
            return ArcSourceSnapshot(directory: directory, sidebar: directory.appendingPathComponent("StorableSidebar.json"),
                                     archive: copied("StorableArchiveItems.json"), localState: copied("User Data/Local State"),
                                     historyDatabases: histories)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if let error = error as? ArcImportError { throw error }
            throw ArcImportError.snapshotFailed
        }
    }

    /// Leftovers of an interrupted process; recent ones may belong to a concurrent import.
    static func removeStaleSnapshots(in parent: URL, olderThan age: TimeInterval = 6 * 3600) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(directoryPrefix) {
            let url = parent.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
            if let modified, Date().timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: url) }
        }
    }

    struct Fingerprint: Equatable {
        let size: Int64
        let modified: timespec
        let changed: timespec
        let inode: UInt64
        let device: Int32

        static func == (lhs: Fingerprint, rhs: Fingerprint) -> Bool {
            lhs.size == rhs.size && lhs.inode == rhs.inode && lhs.device == rhs.device
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    /// Nil when absent. Symbolic links and non-regular files are refused.
    static func fingerprint(_ url: URL) throws -> Fingerprint? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ArcImportError.snapshotFailed
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ArcImportError.unsupportedSourceFile }
        return Fingerprint(size: info.st_size, modified: info.st_mtimespec, changed: info.st_ctimespec,
                           inode: info.st_ino, device: info.st_dev)
    }

    static func regularFileSize(_ url: URL) -> Int64? {
        (try? fingerprint(url))??.size
    }

    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func createPrivateDirectory(_ url: URL, below root: URL) throws {
        guard url.path != root.path else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// APFS clone when possible (cheap for large History files), otherwise a data copy; 0600.
    static func copy(_ source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) != 0 {
            guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_NOFOLLOW)) == 0 else {
                throw ArcImportError.snapshotFailed
            }
        }
        guard chmod(destination.path, 0o600) == 0 else { throw ArcImportError.snapshotFailed }
    }
}
