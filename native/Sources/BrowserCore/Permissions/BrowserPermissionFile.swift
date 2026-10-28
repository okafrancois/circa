import Darwin
import Foundation

/// Private atomic data file. All path components are opened without following symlinks;
/// this service never logs a path or any persisted origin. Calls run on the store actor.
enum BrowserPermissionFile {
    enum Failure: Error { case invalidPath, unsafeFile, tooLarge, io, committedButNotDurable }
    enum Access { case standard, privateBookmark }
    static func load(_ url: URL, maximumBytes: Int = 4 * 1024 * 1024, access: Access = .standard) throws -> Data? {
        guard maximumBytes > 0 else { throw Failure.tooLarge }
        let (parent, name, privateDirectory) = try openParent(url, create: false, access: access)
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        let file = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw Failure.unsafeFile }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeFile }
        if access == .privateBookmark { try validatePrivateFile(file, info: info, privateDirectory: privateDirectory) }
        guard info.st_size <= maximumBytes else { throw Failure.tooLarge }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(file, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failure.io }
            if count == 0 { return result }
            guard result.count + count <= maximumBytes else { throw Failure.tooLarge }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func save(_ data: Data, to url: URL, maximumBytes: Int = 4 * 1024 * 1024, access: Access = .standard,
                     beforeReplace: () throws -> Void = {}) throws {
        guard maximumBytes > 0 else { throw Failure.tooLarge }
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let (parent, name, privateDirectory) = try openParent(url, create: true, access: access)
        defer { close(parent) }
        if access == .privateBookmark {
            let existing = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if existing >= 0 {
                defer { close(existing) }
                var info = stat()
                guard fstat(existing, &info) == 0 else { throw Failure.unsafeFile }
                try validatePrivateFile(existing, info: info, privateDirectory: privateDirectory)
            } else if errno != ENOENT { throw Failure.unsafeFile }
        }
        let original = try identity(parent: parent, name: name)
        let temporary = ".site-permissions-\(UUID().uuidString).tmp"
        let file = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Failure.io }
        defer { close(file); unlinkat(parent, temporary, 0) }
        // Strip inherited ACLs as well as broad POSIX modes before writing any site metadata.
        let emptyACL = acl_init(0)
        guard let emptyACL else { throw Failure.io }
        defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard fchmod(file, 0o600) == 0, acl_set_fd_np(file, emptyACL, ACL_TYPE_EXTENDED) == 0 else { throw Failure.io }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw Failure.io }
        if fcntl(file, F_FULLFSYNC) != 0, ![EINVAL, ENOTSUP, ENOTTY].contains(errno) { throw Failure.io }
        guard try identity(parent: parent, name: name) == original else { throw Failure.unsafeFile }
        try beforeReplace()
        guard renameat(parent, temporary, parent, name) == 0 else { throw Failure.io }
        if fsync(parent) != 0, ![EINVAL, ENOTSUP, ENOTTY].contains(errno) { throw Failure.committedButNotDurable }
    }

    private struct Identity: Equatable { let device: dev_t; let inode: ino_t }
    private static func identity(parent: Int32, name: String) throws -> Identity? {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw Failure.io
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafeFile }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    static func validateFileURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "", url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil,
              url.path.hasPrefix("/"), !url.hasDirectoryPath else { throw Failure.invalidPath }
    }

    private static func refuseAllowACL(_ file: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(file, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw Failure.unsafeFile }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw Failure.unsafeFile }
        var entry: acl_entry_t?
        var next = ACL_FIRST_ENTRY
        while true {
            errno = 0
            let result = acl_get_entry(acl, next.rawValue, &entry)
            // Darwin returns zero for an entry and EINVAL at the end of a
            // valid ACL, unlike the POSIX/Linux one/zero iteration convention.
            if result == -1, errno == EINVAL { return }
            guard result == 0 else { throw Failure.unsafeFile }
            var tag = ACL_UNDEFINED_TAG
            guard let entry, acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else { throw Failure.unsafeFile }
            next = ACL_NEXT_ENTRY
        }
    }

    private static func validatePrivateFile(_ file: Int32, info: stat, privateDirectory: Bool) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o7022 == 0,
              privateDirectory || info.st_mode & 0o077 == 0 else { throw Failure.unsafeFile }
        try refuseAllowACL(file)
    }

    private static func inspectDirectory(_ file: Int32, privateDirectory: inout Bool) throws {
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeFile }
        // Trusted system ancestors include the root-owned sticky temporary directory.
        // User-owned descendants may not grant another principal write authority.
        if info.st_uid == 0 {
            guard info.st_mode & 0o022 == 0 || (!privateDirectory && info.st_mode & S_ISVTX != 0) else { throw Failure.unsafeFile }
        } else {
            guard info.st_uid == geteuid(), info.st_mode & 0o7022 == 0 else { throw Failure.unsafeFile }
            if info.st_mode & 0o077 == 0 { privateDirectory = true }
        }
        try refuseAllowACL(file)
    }

    private static func openParent(_ url: URL, create: Bool, access: Access) throws -> (Int32, String, Bool) {
        try validateFileURL(url)
        let components = url.path.split(separator: "/").map(String.init)
        guard let name = components.last, components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw Failure.invalidPath }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.io }
        var privateDirectory = false
        do {
            if access == .privateBookmark { try inspectDirectory(directory, privateDirectory: &privateDirectory) }
            for component in components.dropLast() {
                var next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT {
                    if !create { close(directory); return (-1, name, false) }
                    guard mkdirat(directory, component, 0o700) == 0 else { throw Failure.io }
                    guard fsync(directory) == 0 || [EINVAL, ENOTSUP, ENOTTY].contains(errno) else { throw Failure.io }
                    next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw Failure.unsafeFile }
                close(directory)
                directory = next
                if access == .privateBookmark { try inspectDirectory(directory, privateDirectory: &privateDirectory) }
            }
            if access == .privateBookmark {
                var info = stat()
                guard fstat(directory, &info) == 0, info.st_uid == geteuid() else { throw Failure.unsafeFile }
            }
            return (directory, name, privateDirectory)
        } catch {
            close(directory)
            throw error
        }
    }
}
