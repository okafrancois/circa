import Darwin
import Foundation

/// A directory reached from `/` one component at a time with `openat(O_DIRECTORY | O_NOFOLLOW)`
/// (IMPORT-R3 #2): no symbolic link anywhere, and no path re-resolution between the check and the
/// use. Every importer write goes through an instance (`*at` system calls on its descriptor).
/// SQLite opens by path, so `verifiedPath(_:)` re-checks that the path still designates exactly
/// these directories (device and inode of every component) right before and after SQLite uses it.
final class OrbitSecureDirectory {
    let descriptor: Int32
    let path: String
    /// Device and inode of every directory from `/` to this one.
    private let chain: [Identity]

    struct Identity: Equatable { let device: Int32; let inode: UInt64 }

    private init(descriptor: Int32, path: String, chain: [Identity]) {
        self.descriptor = descriptor
        self.path = path
        self.chain = chain
    }

    deinit { Darwin.close(descriptor) }

    static func identity(of descriptor: Int32) throws -> Identity {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ArcImportError.symbolicLinkInPath }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    /// Opens (and with `create`, makes with mode 0700) every component of an absolute path.
    static func open(_ url: URL, create: Bool,
                     inspect: (Int32) throws -> Identity = OrbitSecureDirectory.identity) throws -> OrbitSecureDirectory {
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw ArcImportError.symbolicLinkInPath }
        let rootIdentity: Identity
        do { rootIdentity = try inspect(root) }
        catch { Darwin.close(root); throw error }
        let top = OrbitSecureDirectory(descriptor: root, path: "", chain: [rootIdentity])
        let relative = url.path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        return relative.isEmpty ? top : try top.directory(relative, create: create, inspect: inspect)
    }

    static func validName(_ name: some StringProtocol) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    /// Opens a descendant given as a relative path, creating missing directories when asked.
    func directory(_ relative: String, create: Bool,
                   inspect: (Int32) throws -> Identity = OrbitSecureDirectory.identity) throws -> OrbitSecureDirectory {
        var current = self
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            guard Self.validName(component) else { throw ArcImportError.symbolicLinkInPath }
            let name = String(component)
            if create {
                if mkdirat(current.descriptor, name, 0o700) == 0 { try current.synchronize() }
                else if errno != EEXIST { throw ArcImportError.backupFailed }
            }
            let child = openat(current.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else {
                if errno == ENOENT { throw ArcImportError.backupNotFound }
                throw ArcImportError.symbolicLinkInPath
            }
            let childIdentity: Identity
            do { childIdentity = try inspect(child) }
            catch { Darwin.close(child); throw error }
            current = OrbitSecureDirectory(descriptor: child, path: current.path + "/" + name,
                                         chain: current.chain + [childIdentity])
        }
        return current
    }

    var url: URL { URL(fileURLWithPath: path.isEmpty ? "/" : path, isDirectory: true) }

    /// File type of an entry without following it; nil when absent.
    func kind(_ name: String) -> mode_t? { try? checkedKind(name) }

    /// Absence means ENOENT only. Permission and I/O failures must block recovery.
    func checkedKind(_ name: String) throws -> mode_t? {
        guard Self.validName(name) else { throw ArcImportError.symbolicLinkInPath }
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw ArcImportError.restoreFailed
        }
        return info.st_mode & S_IFMT
    }

    func exists(_ name: String) -> Bool { kind(name) != nil }

    func linkCount(_ name: String) -> UInt16? {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return info.st_nlink
    }

    func size(_ name: String) -> Int64 {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return 0 }
        return info.st_size
    }

    /// Opens a regular file without following a link.
    func openFile(_ name: String, flags: Int32 = O_RDONLY, mode: mode_t = 0o600) throws -> Int32 {
        guard Self.validName(name) else { throw ArcImportError.symbolicLinkInPath }
        let file = openat(descriptor, name, flags | O_NOFOLLOW | O_CLOEXEC, mode)
        guard file >= 0 else {
            if errno == ENOENT { throw ArcImportError.backupNotFound }
            throw ArcImportError.symbolicLinkInPath
        }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(file)
            throw ArcImportError.symbolicLinkInPath
        }
        // A second link would make this file also live elsewhere (IMPORT-R4 #B).
        guard info.st_nlink == 1 else {
            Darwin.close(file)
            throw ArcImportError.hardLinkedFile
        }
        return file
    }

    func read(_ name: String, limit: Int = 64 * 1024 * 1024) -> Data? {
        guard let file = try? openFile(name) else { return nil }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size <= limit else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, Int(info.st_size)) }
        return count == Int(info.st_size) ? data : nil
    }

    /// Temporary file (O_EXCL | O_NOFOLLOW, 0600), fsync, `renameat`, directory fsync.
    func write(_ data: Data, to name: String) throws {
        guard Self.validName(name) else { throw ArcImportError.symbolicLinkInPath }
        let temporary = ".\(name).\(UUID().uuidString).tmp"
        let file = try openFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        var failed = false
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(file, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { if errno == EINTR { continue }; failed = true; return }
                offset += written
            }
        }
        if fsync(file) != 0 { failed = true }
        Darwin.close(file)
        guard !failed, renameat(descriptor, temporary, descriptor, name) == 0 else {
            unlinkat(descriptor, temporary, 0)
            throw ArcImportError.backupFailed
        }
        try synchronize()
    }

    /// Clone, else data copy, of a regular file from another verified directory (0600, O_EXCL).
    func copy(_ name: String, from source: OrbitSecureDirectory, _ sourceName: String) throws {
        let input = try source.openFile(sourceName)
        defer { Darwin.close(input) }
        guard Self.validName(name) else { throw ArcImportError.symbolicLinkInPath }
        if fclonefileat(input, descriptor, name, 0) == 0 {
            let output = try openFile(name, flags: O_WRONLY)
            defer { Darwin.close(output) }
            guard fchmod(output, 0o600) == 0, fsync(output) == 0 else { throw ArcImportError.snapshotFailed }
            try synchronize()
            return
        }
        let output = try openFile(name, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { Darwin.close(output) }
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0, fsync(output) == 0 else {
            unlinkat(descriptor, name, 0)
            throw ArcImportError.snapshotFailed
        }
        try synchronize()
    }

    func rename(_ name: String, to destination: OrbitSecureDirectory, _ destinationName: String) throws {
        guard Self.validName(name), Self.validName(destinationName),
              renameat(descriptor, name, destination.descriptor, destinationName) == 0 else {
            throw ArcImportError.restoreFailed
        }
        try synchronize()
        try destination.synchronize()
    }

    func synchronize() throws {
        guard fsync(descriptor) == 0 else { throw ArcImportError.restoreFailed }
    }

    /// Removes a file or a whole directory tree below this directory, never following a link.
    func remove(_ name: String) { try? removeChecked(name) }

    /// Cleanup must complete before its recovery marker can be removed.
    func removeChecked(_ name: String) throws {
        guard let kind = try checkedKind(name) else { return }
        if kind == S_IFDIR {
            let child = try directory(name, create: false)
            for entry in try child.checkedEntries() { try child.removeChecked(entry) }
            guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw ArcImportError.restoreFailed }
        } else {
            guard unlinkat(descriptor, name, 0) == 0 else { throw ArcImportError.restoreFailed }
        }
        try synchronize()
    }

    func entries() -> [String] { (try? checkedEntries()) ?? [] }

    func checkedEntries() throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw ArcImportError.restoreFailed }
        guard let stream = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw ArcImportError.restoreFailed
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ArcImportError.restoreFailed }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// The path SQLite may open for `name` (and its `-wal`, `-shm`, `-journal` companions): every
    /// directory of the path is re-checked against this chain and every companion that exists must
    /// be a regular file. Call again after SQLite closed to detect a swap during its use.
    func verifiedPath(_ name: String) throws -> String {
        guard Self.validName(name) else { throw ArcImportError.symbolicLinkInPath }
        var current = ""
        var walked: [Identity] = []
        var info = stat()
        guard stat("/", &info) == 0 else { throw ArcImportError.symbolicLinkInPath }
        walked.append(Identity(device: info.st_dev, inode: info.st_ino))
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            guard lstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ArcImportError.symbolicLinkInPath }
            walked.append(Identity(device: info.st_dev, inode: info.st_ino))
        }
        guard walked == chain, try Self.identity(of: descriptor) == chain.last else { throw ArcImportError.symbolicLinkInPath }
        for companion in [name, name + "-wal", name + "-shm", name + "-journal"] {
            var entry = stat()
            guard fstatat(descriptor, companion, &entry, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw ArcImportError.symbolicLinkInPath
            }
            guard entry.st_mode & S_IFMT == S_IFREG else { throw ArcImportError.symbolicLinkInPath }
            guard entry.st_nlink == 1 else { throw ArcImportError.hardLinkedFile }
        }
        return path + "/" + name
    }
}
