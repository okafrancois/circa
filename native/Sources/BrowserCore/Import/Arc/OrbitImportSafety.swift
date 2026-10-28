import Darwin
import Foundation

/// Path rules shared by the source snapshot and every write of an import (IMPORT-R2 review):
/// no symbolic link in any component, and source and destination never overlap.
public enum ArcImportPaths {
    /// Refuses a symbolic link (or a non-directory ancestor) in every existing component of `url`,
    /// from `/` down. Missing trailing components are allowed: the importer creates them itself.
    public static func validateNoSymbolicLinks(_ url: URL) throws {
        var path = ""
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            guard component != "..", component != "." else { throw ArcImportError.symbolicLinkInPath }
            path += "/" + component
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno == ENOENT { return }
                throw ArcImportError.symbolicLinkInPath
            }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK { throw ArcImportError.symbolicLinkInPath }
            if index < components.count - 1, kind != S_IFDIR { throw ArcImportError.symbolicLinkInPath }
        }
    }

    /// Resolved path of the deepest existing ancestor, with the missing tail appended.
    static func resolved(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let base = realpath(existing.path, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? existing.path
        return ([base] + tail).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }

    /// Device and inode of the existing ancestors of `url`, itself included.
    static func identities(_ url: URL) -> Set<[UInt64]> {
        var result: Set<[UInt64]> = []
        var current = URL(fileURLWithPath: resolved(url))
        while true {
            var info = stat()
            if stat(current.path, &info) == 0 { result.insert([UInt64(bitPattern: Int64(info.st_dev)), info.st_ino]) }
            guard current.path != "/" else { break }
            current.deleteLastPathComponent()
        }
        return result
    }

    static func identity(_ url: URL) -> [UInt64]? {
        var info = stat()
        guard stat(resolved(url), &info) == 0 else { return nil }
        return [UInt64(bitPattern: Int64(info.st_dev)), info.st_ino]
    }

    /// Case-insensitive containment of resolved paths (APFS default) plus an inode walk, so a
    /// differently cased or hard-linked path cannot hide an overlap.
    public static func validateSeparated(source: URL, destination: URL) throws {
        let a = resolved(source).lowercased(), b = resolved(destination).lowercased()
        func contains(_ parent: String, _ child: String) -> Bool { child == parent || child.hasPrefix(parent + "/") }
        guard !contains(a, b), !contains(b, a) else { throw ArcImportError.sourceOverlapsTarget }
        if let sourceID = identity(source), identities(destination).contains(sourceID) { throw ArcImportError.sourceOverlapsTarget }
        if let destinationID = identity(destination), identities(source).contains(destinationID) {
            throw ArcImportError.sourceOverlapsTarget
        }
    }
}

/// Free space on the volume holding a path.
public protocol OrbitDiskSpaceProbe: Sendable {
    func availableBytes(at url: URL) -> Int64?
}

public struct OrbitSystemDiskSpaceProbe: OrbitDiskSpaceProbe {
    public init() {}

    public func availableBytes(at url: URL) -> Int64? {
        var existing = url
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
        let values = try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}

enum OrbitDiskSpace {
    /// Proportional margin on every estimate (30 %) plus a small floor (IMPORT-R3 #3).
    static let floor: Int64 = 16 * 1024 * 1024

    static func required(for bytes: Int64) -> Int64 { bytes + bytes / 10 * 3 + floor }

    static func require(_ bytes: Int64, at url: URL, probe: any OrbitDiskSpaceProbe) throws {
        guard let available = probe.availableBytes(at: url) else { return }
        let required = required(for: bytes)
        guard available >= required else { throw ArcImportError.insufficientDiskSpace(requiredBytes: required, availableBytes: available) }
    }
}

/// Inter-process exclusion on a data directory (`flock` on the directory itself, so no file is
/// added to it). Orbit holds it shared while a persistent session is open; offline imports and
/// restores hold it exclusively from loading the session to their end. Released on `release()`
/// or deinit; the kernel releases it if the process dies.
public final class OrbitDataDirectoryLock: @unchecked Sendable {
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { release() }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    /// Creates the directory (0700) when missing. Throws `targetInUse` when the lock is held.
    /// `validatingPath: false` is for the app's session, whose file store enforces its own rules.
    public static func acquire(_ directory: URL, exclusive: Bool, validatingPath: Bool = true) throws -> OrbitDataDirectoryLock {
        let descriptor: Int32
        if validatingPath {
            // Opened component by component without following links (IMPORT-R3 #2).
            let verified = try OrbitSecureDirectory.open(directory, create: true)
            descriptor = dup(verified.descriptor)
        } else {
            if !FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                } catch { throw ArcImportError.targetUnreadable }
            }
            descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ArcImportError.targetUnreadable }
        guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw ArcImportError.targetInUse
        }
        return OrbitDataDirectoryLock(descriptor: descriptor)
    }
}
