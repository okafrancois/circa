import Darwin
import Foundation
import os
import SQLite3

/// Checked-path SQLite access (IMPORT-R5).
/// The threat model is accidental filesystem failures and stale paths, without an actively
/// malicious concurrent filesystem mutator. Every ancestor must be an existing real directory;
/// database and sidecar files must be regular files with exactly one link. Directory identities
/// are checked before and after SQLite opens a path. Callers using SQLite paths in statements
/// (for example VACUUM INTO) also verify those paths before and after the statement.
/// A Pin retains a verified directory identity until released; it does not redirect SQLite I/O.
/// SQLite owns its native VFS and all its descriptors, including Apple's guarded descriptors.
/// No global VFS callbacks or system calls are replaced. These checks do not claim to prevent
/// a hostile swap between verification and a SQLite syscall, or during a connection's lifetime.
enum OrbitSQLiteGuard {
    // The directory is immutable; its descriptor is only read while this entry retains it.
    private struct Entry: @unchecked Sendable {
        let directory: OrbitSecureDirectory
        let identity: OrbitSecureDirectory.Identity
        var count: Int
    }

    private static let registry = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    final class Pin: @unchecked Sendable {
        let path: String
        private let lock = NSLock()
        private var released = false

        fileprivate init(path: String) { self.path = path }
        deinit { release() }

        func release() {
            let shouldRelease = lock.withLock { () -> Bool in
                defer { released = true }
                return !released
            }
            if shouldRelease { OrbitSQLiteGuard.unpin(path) }
        }
    }

    static func pin(_ directory: OrbitSecureDirectory) throws -> Pin {
        let candidate = Entry(directory: directory, identity: try OrbitSecureDirectory.identity(of: directory.descriptor), count: 1)
        try registry.withLock { entries in
            let path = candidate.directory.path
            if var entry = entries[path] {
                guard entry.identity == candidate.identity else { throw ArcImportError.symbolicLinkInPath }
                entry.count += 1
                entries[path] = entry
            } else {
                entries[path] = candidate
            }
        }
        return Pin(path: directory.path)
    }

    /// Verifies the entire ancestor chain, not just the final directory component.
    static func pin(openingDirectory url: URL) throws -> Pin {
        try pin(OrbitSecureDirectory.open(url, create: false))
    }

    static func pinnedIdentity(_ directory: String) -> OrbitSecureDirectory.Identity? {
        registry.withLock { $0[directory]?.identity }
    }

    private static func unpin(_ path: String) {
        registry.withLock { entries in
            guard var entry = entries[path] else { return }
            entry.count -= 1
            if entry.count > 0 { entries[path] = entry }
            else { entries.removeValue(forKey: path) }
        }
    }

    private static func checkedPath(in directory: OrbitSecureDirectory, name: String) throws -> String {
        let path = try directory.verifiedPath(name)
        // A failed stat is absence only for ENOENT; permission and I/O failures must refuse open.
        for suffix in ["", "-wal", "-shm", "-journal"] {
            var info = stat()
            if fstatat(directory.descriptor, name + suffix, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw ArcImportError.symbolicLinkInPath }
                continue
            }
            guard info.st_mode & S_IFMT == S_IFREG else { throw ArcImportError.symbolicLinkInPath }
            guard info.st_nlink == 1 else { throw ArcImportError.hardLinkedFile }
        }
        return path
    }

    /// Uses SQLite's ordinary VFS. On a failed post-check SQLite closes its own handle; no native
    /// descriptor is intercepted, manually closed, or intentionally leaked.
    static func open(_ path: String, flags: Int32) -> (Int32, OpaquePointer?) {
        let url = URL(fileURLWithPath: path)
        let directory: OrbitSecureDirectory
        do {
            let parent = url.deletingLastPathComponent()
            let pinned = registry.withLock { $0[parent.path] }
            directory = try pinned?.directory ?? OrbitSecureDirectory.open(parent, create: false)
            guard try checkedPath(in: directory, name: url.lastPathComponent) == path else {
                return (SQLITE_CANTOPEN, nil)
            }
        } catch { return (SQLITE_CANTOPEN, nil) }
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        do { _ = try checkedPath(in: directory, name: url.lastPathComponent) }
        catch {
            sqlite3_close(handle)
            return (SQLITE_CANTOPEN, nil)
        }
        return (result, handle)
    }
}
