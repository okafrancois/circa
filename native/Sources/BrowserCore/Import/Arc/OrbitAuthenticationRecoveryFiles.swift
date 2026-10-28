import CryptoKit
import Darwin
import Foundation

/// Errors deliberately contain no paths, filenames, payloads or provider errors.
public enum OrbitRecoveryFailure: Error, Equatable { case unsafeFilesystem, busy, io, invalidEvidence, keyUnavailable, restrictedVerification, expired, injected }

/// Stable root and lock descriptors; neither entry is ever renamed by recovery.
public final class OrbitRecoveryRootLock {
    let root: RecoveryDirectory
    private let lock: Int32
    public init(root url: URL) throws {
        root = try RecoveryDirectory(url: url)
        lock = try root.openFile(".orbit-instance.lock", create: true)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw OrbitRecoveryFailure.busy }
        try root.sync()
    }
    func validate() throws { try root.validate(); try root.validateFile(".orbit-instance.lock", fd: lock) }
    deinit { flock(lock, LOCK_UN); close(lock) }
}

/// Descriptor-relative, nofollow access. Hostile concurrent same-UID writers are outside the
/// threat model; replacement is nevertheless checked at each publication/mutation boundary.
final class RecoveryDirectory {
    let fd: Int32
    let device: UInt64
    let inode: UInt64
    private let parent: RecoveryDirectory?
    private let name: String?
    private let url: URL?
    init(url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw OrbitRecoveryFailure.unsafeFilesystem }
        // Foundation rewrites /private/var differently depending on whether the leaf exists.
        // Walk physical components instead; only macOS's fixed /var system alias is admitted.
        var parts = url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        if parts.first == "var" {
            var link = stat()
            if lstat("/var", &link) == 0, link.st_mode & S_IFMT == S_IFLNK {
                var bytes = [UInt8](repeating: 0, count: 128)
                let count = readlink("/var", &bytes, bytes.count)
                guard count > 0, ["private/var", "/private/var"].contains(String(decoding: bytes.prefix(count), as: UTF8.self)) else { throw OrbitRecoveryFailure.unsafeFilesystem }
                parts = ["private", "var"] + parts.dropFirst()
            }
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw OrbitRecoveryFailure.unsafeFilesystem }
        do {
            for part in parts {
                try Self.component(part)
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw OrbitRecoveryFailure.unsafeFilesystem }
                close(current); current = next
            }
        } catch { close(current); throw error }
        fd = current
        guard fd >= 0 else { throw OrbitRecoveryFailure.unsafeFilesystem }
        parent = nil; name = nil; self.url = url
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == getuid(), s.st_mode & 0o022 == 0 else { close(fd); throw OrbitRecoveryFailure.unsafeFilesystem }
        device = UInt64(truncatingIfNeeded: s.st_dev); inode = UInt64(s.st_ino)
    }
    init(parent: RecoveryDirectory, name: String, create: Bool = false) throws {
        try Self.component(name); try parent.validate()
        if create { guard mkdirat(parent.fd, name, 0o700) == 0 else { throw OrbitRecoveryFailure.io }; try parent.sync() }
        fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OrbitRecoveryFailure.unsafeFilesystem }
        self.parent = parent; self.name = name; url = nil
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_uid == getuid(), s.st_flags == 0, UInt64(truncatingIfNeeded: s.st_dev) == parent.device, s.st_mode & 0o7777 == 0o700 else { close(fd); throw OrbitRecoveryFailure.unsafeFilesystem }
        device = UInt64(truncatingIfNeeded: s.st_dev); inode = UInt64(s.st_ino)
        try Self.rejectExtendedMetadata(fd)
    }
    deinit { close(fd) }
    static func component(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 200 else { throw OrbitRecoveryFailure.unsafeFilesystem }
    }
    func validate() throws {
        var s = stat()
        if let parent, let name { try parent.validate(); guard fstatat(parent.fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw OrbitRecoveryFailure.unsafeFilesystem } }
        else { guard let url, lstat(url.path, &s) == 0 else { throw OrbitRecoveryFailure.unsafeFilesystem } }
        guard UInt64(truncatingIfNeeded: s.st_dev) == device, UInt64(s.st_ino) == inode,
              s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid(),
              (parent == nil ? s.st_mode & 0o022 == 0 : s.st_mode & 0o7777 == 0o700 && s.st_flags == 0) else { throw OrbitRecoveryFailure.unsafeFilesystem }
    }
    /// Registration roots are stricter than compatible, untouched product roots. Reopen
    /// the full nofollow chain and compare the kernel's physical path to the supplied path.
    /// Moving a root or inserting an ancestor alias cannot preserve its recovery authority.
    func registrationLocation() throws -> Data {
        try validate()
        guard let url else { throw OrbitRecoveryFailure.unsafeFilesystem }
        let reopened = try RecoveryDirectory(url: url)
        var info = stat()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        // Foundation may spell the fixed system /var alias differently before/after a leaf
        // exists. RecoveryDirectory's nofollow walk already admits only this system alias.
        let expected = url.path.hasPrefix("/var/") ? "/private" + url.path : url.path
        guard reopened.device == device, reopened.inode == inode,
              fstat(fd, &info) == 0, info.st_mode & 0o7777 == 0o700, info.st_flags == 0,
              fcntl(fd, F_GETPATH, &path) == 0,
              String(cString: path) == expected,
              try Self.registrationMetadata(fd) else { throw OrbitRecoveryFailure.unsafeFilesystem }
        try Self.rejectExtendedMetadata(fd)
        return Data(SHA256.hash(data: Data(expected.utf8)))
    }
    /// The product session has this fixed name under the already-owned root.
    func sessionLocation() throws -> ArcImportDataLocation {
        try validate()
        guard parent == nil else { throw OrbitRecoveryFailure.unsafeFilesystem }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &path) == 0 else { throw OrbitRecoveryFailure.io }
        let location = ArcImportDataLocation(sessionFile:
            URL(fileURLWithPath: String(cString: path) + "/session.json"))
        let reopened = try RecoveryDirectory(url: location.dataDirectory)
        guard reopened.device == device, reopened.inode == inode else { throw OrbitRecoveryFailure.unsafeFilesystem }
        return location
    }
    static func registrationMetadata(_ file: Int32) throws -> Bool {
        // macOS attaches provenance to newly created files/directories. It is not recovery
        // authority. Other extended metadata is unsupported rather than stripped or repaired.
        Set(try attributes(file).keys).isSubset(of: ["com.apple.provenance"])
    }
    func info(_ name: String) throws -> stat? {
        try Self.component(name); try validate(); var s = stat()
        if fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw OrbitRecoveryFailure.io
        }
        return s
    }
    func openFile(_ name: String, create: Bool = false, exclusive: Bool = false) throws -> Int32 {
        try Self.component(name); try validate()
        let result = openat(fd, name, (create ? O_RDWR | O_CREAT : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (exclusive ? O_EXCL : 0), 0o600)
        guard result >= 0 else { throw OrbitRecoveryFailure.io }
        do { try validateFile(name, fd: result); return result } catch { close(result); throw error }
    }
    static func rejectExtendedMetadata(_ file: Int32) throws {
        errno = 0
        if let acl = acl_get_fd_np(file, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl))
            // Extended ACLs (including an explicit empty ACL) are unsupported, not dropped.
            throw OrbitRecoveryFailure.unsafeFilesystem
        }
        guard errno == ENOENT else { throw OrbitRecoveryFailure.unsafeFilesystem }
    }
    static func attributes(_ file: Int32) throws -> [String: Data] {
        let size = flistxattr(file, nil, 0, 0)
        guard size >= 0, size <= 4096 else { throw OrbitRecoveryFailure.unsafeFilesystem }
        if size == 0 { return [:] }
        var names = [CChar](repeating: 0, count: size)
        guard flistxattr(file, &names, size, 0) == size else { throw OrbitRecoveryFailure.io }
        let bytes = names.map { UInt8(bitPattern: $0) }
        var result: [String: Data] = [:]; var total = 0
        for slice in bytes.split(separator: 0) {
            guard result.count < 16, let name = String(bytes: slice, encoding: .utf8), !name.isEmpty, name.utf8.count <= 255 else { throw OrbitRecoveryFailure.unsafeFilesystem }
            let count = fgetxattr(file, name, nil, 0, 0, 0)
            guard count >= 0, count <= 65_536, total + count <= 65_536 else { throw OrbitRecoveryFailure.unsafeFilesystem }
            var value = Data(count: count)
            let read = value.withUnsafeMutableBytes { fgetxattr(file, name, $0.baseAddress, count, 0, 0) }
            guard read == count else { throw OrbitRecoveryFailure.io }
            result[name] = value; total += count
        }
        return result
    }
    static func restoreAttributes(_ attributes: [String: Data], file: Int32) throws {
        for name in try Self.attributes(file).keys where attributes[name] == nil {
            guard fremovexattr(file, name, 0) == 0 else { throw OrbitRecoveryFailure.io }
        }
        for (name, value) in attributes {
            let result = value.withUnsafeBytes { fsetxattr(file, name, $0.baseAddress, value.count, 0, 0) }
            guard result == 0 else { throw OrbitRecoveryFailure.io }
        }
        guard try Self.attributes(file) == attributes else { throw OrbitRecoveryFailure.io }
    }
    func validateFile(_ name: String, fd file: Int32) throws {
        try validate(); var s = stat()
        guard fstat(file, &s) == 0, let named = try info(name), s.st_dev == named.st_dev, s.st_ino == named.st_ino,
              s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1, s.st_uid == getuid(), s.st_mode & 0o7777 == 0o600,
              s.st_flags == 0 else { throw OrbitRecoveryFailure.unsafeFilesystem }
        try Self.rejectExtendedMetadata(file)
    }
    func names() throws -> [String] {
        try validate()
        // A fresh open description avoids sharing readdir offsets with the anchor.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw OrbitRecoveryFailure.io }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let value = withUnsafePointer(to: &entry.pointee.d_name) { p in
                p.withMemoryRebound(to: CChar.self, capacity: 1024) { String(validatingCString: $0) }
            }
            guard let value else { throw OrbitRecoveryFailure.unsafeFilesystem }
            if value == "." || value == ".." { continue }
            try Self.component(value); result.append(value)
            guard result.count <= 4096 else { throw OrbitRecoveryFailure.invalidEvidence }
            errno = 0
        }
        guard errno == 0 else { throw OrbitRecoveryFailure.io }
        return result.sorted()
    }
    func sync() throws { guard fsync(fd) == 0 else { throw OrbitRecoveryFailure.io } }
    func read(_ name: String, limit: Int) throws -> Data {
        let file = try openFile(name); defer { close(file) }
        var s = stat(); guard fstat(file, &s) == 0, s.st_size >= 0, s.st_size <= limit else { throw OrbitRecoveryFailure.invalidEvidence }
        let result = try Self.read(file, count: Int(s.st_size))
        var byte: UInt8 = 0
        guard Darwin.read(file, &byte, 1) == 0 else { throw OrbitRecoveryFailure.invalidEvidence }
        try validateFile(name, fd: file); return result
    }
    static func read(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                guard n > 0 else { throw OrbitRecoveryFailure.io }; offset += n
            }
        }
        return data
    }
    static func write(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                guard n > 0 else { throw OrbitRecoveryFailure.io }; offset += n
            }
        }
    }
    /// Leaves partial evidence on any failure; no error cleanup deletes recovery material.
    func publish(_ data: Data, as name: String, replace: Bool = false, beforeRename: () throws -> Void = {}) throws {
        try validate()
        let temporary = name + ".writing"
        let file = try openFile(temporary, create: true, exclusive: true); defer { close(file) }
        try Self.write(data, fd: file)
        guard fsync(file) == 0, fcntl(file, F_FULLFSYNC) == 0 else { throw OrbitRecoveryFailure.io }
        try beforeRename(); try validateFile(temporary, fd: file)
        if replace { _ = try read(name, limit: 1_048_576) }
        else { guard try info(name) == nil else { throw OrbitRecoveryFailure.invalidEvidence } }
        let flags = replace ? UInt32(0) : UInt32(RENAME_EXCL)
        guard renameatx_np(fd, temporary, fd, name, flags) == 0 else { throw OrbitRecoveryFailure.io }
        try sync()
    }
    func removeTreeEntry(_ name: String) throws {
        guard let s = try info(name) else { return }
        if s.st_mode & S_IFMT == S_IFDIR {
            let directory = try RecoveryDirectory(parent: self, name: name)
            for child in try directory.names() { try directory.removeTreeEntry(child) }
            try directory.validate()
            guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw OrbitRecoveryFailure.io }
        } else {
            let file = try openFile(name); defer { close(file) }; try validateFile(name, fd: file)
            guard unlinkat(fd, name, 0) == 0 else { throw OrbitRecoveryFailure.io }
        }
        try sync()
    }
}

/// Same directory-inode lock used by OrbitDataDirectoryLock (the offline structural importer).
/// Acquired after the product instance-file lock, before creating/opening recovery material.
final class RecoveryImportLock {
    private let descriptor: Int32
    init(root: RecoveryDirectory) throws {
        try root.validate()
        descriptor = openat(root.fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw OrbitRecoveryFailure.io }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw OrbitRecoveryFailure.busy }
    }
    /// All recovery writes finish first. Admission is checked again after conversion;
    /// flock conversion is not assumed atomic with respect to competing writers.
    func allowSessionReaders() throws {
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { throw OrbitRecoveryFailure.busy }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
