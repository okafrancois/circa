import Darwin
import Foundation

public enum BrowserSessionFileError: Error, Equatable, Sendable, LocalizedError {
    public enum Operation: String, Sendable {
        case openDirectory, createDirectory, synchronizeCreatedDirectory, inspectEntry, openFile, readFile
        case createTemporaryFile, setPermissions, clearAccessControl
        case writeTemporaryFile, synchronizeFile, fullySynchronizeFile, closeTemporaryFile, replaceFile
    }

    case invalidDestination
    case symbolicLink
    case notDirectory
    case notRegularFile
    case notFound
    case destinationChanged
    case corruptDocument
    case encodingFailed
    case io(operation: Operation, code: Int32)
    /// The rename already succeeded; retrying must not assume the previous file remains.
    case replacedButDirectorySyncFailed(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidDestination: return "A local absolute file URL without traversal, query or fragment is required."
        case .symbolicLink: return "Session file paths must not contain symbolic links."
        case .notDirectory: return "A session file ancestor is not a directory."
        case .notRegularFile: return "The session destination is not a regular file."
        case .notFound: return "The session file or an ancestor does not exist."
        case .destinationChanged: return "The session destination changed before replacement."
        case .corruptDocument: return "The session file is not a decodable session document."
        case .encodingFailed: return "The session document could not be encoded."
        case let .io(operation, code): return "Session file operation \(operation.rawValue) failed (errno \(code))."
        case let .replacedButDirectorySyncFailed(code):
            return "The session file was replaced, but directory synchronization failed (errno \(code)); durability is uncertain."
        }
    }
}

/// Explicit, synchronous model-document persistence. Callers must exclude private sessions
/// before supplying a document and schedule disk work away from the UI thread.
public struct BrowserSessionFileStore: Sendable {
    public struct SaveResult: Equatable, Sendable {
        /// False means fsync succeeded but the filesystem does not support F_FULLFSYNC.
        public let usedFullFileSync: Bool
        /// Covers the immediate parent and any directory links created by this save.
        /// False means at least one filesystem does not support directory fsync.
        public let didSyncDirectory: Bool
    }

    private let operations: BrowserSessionFileOperations

    public init() { operations = BrowserSessionFileOperations() }

    // Internal syscall seam allows deterministic short-write and pre/post-commit failure tests.
    init(operations: BrowserSessionFileOperations) { self.operations = operations }

    /// Immutable bytes admitted only through document validation and canonical encoding.
    public struct EncodedDocument: Sendable {
        public let data: Data
        public init(_ document: BrowserSessionDocument) throws {
            do { data = try document.encoded() }
            catch let error as BrowserSessionError { throw error }
            catch { throw BrowserSessionFileError.encodingFailed }
        }
    }

    @discardableResult
    public func save(_ document: BrowserSessionDocument, to destination: URL) throws -> SaveResult {
        _ = try Self.components(of: destination)
        return try save(EncodedDocument(document), to: destination)
    }

    @discardableResult
    public func save(_ document: EncodedDocument, to destination: URL) throws -> SaveResult {
        let path = try Self.components(of: destination)
        let data = document.data
        let parent = try Self.openParent(of: path, create: true, syncDirectory: operations.syncDirectory)
        let directory = parent.handle
        let name = path.last!
        let original = try Self.regularEntry(directory: directory.value, name: name)
        let temporaryName = ".browser-session-\(UUID().uuidString).tmp"
        let rawFile = openat(directory.value, temporaryName,
                             O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard rawFile >= 0 else { throw Self.io(.createTemporaryFile) }
        let file = SessionFileDescriptor(rawFile)
        var committed = false
        defer {
            if !committed { _ = unlinkat(directory.value, temporaryName, 0) }
        }
        try Self.makePrivate(file.value, mode: 0o600)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = operations.write(file.value, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Self.io(.writeTemporaryFile)
                }
                guard count > 0, count <= bytes.count - offset else {
                    throw BrowserSessionFileError.io(operation: .writeTemporaryFile, code: EIO)
                }
                offset += count
            }
        }
        guard Self.retryInterrupted({ operations.syncFile(file.value) }) == 0 else {
            throw Self.io(.synchronizeFile)
        }
        let fullSync = Self.retryInterrupted { operations.fullSyncFile(file.value) }
        let usedFullSync = fullSync == 0
        if !usedFullSync, !Self.isUnsupported(errno) { throw Self.io(.fullySynchronizeFile) }
        try file.closeBeforeReplacement()

        // Recheck type and identity after writing. No pathname is ever followed by renameat.
        let current = try Self.regularEntry(directory: directory.value, name: name)
        guard original == current else { throw BrowserSessionFileError.destinationChanged }
        guard operations.replace(directory.value, temporaryName, name) == 0 else { throw Self.io(.replaceFile) }
        committed = true
        let directorySync = Self.retryInterrupted { operations.syncDirectory(directory.value) }
        if directorySync != 0, !Self.isUnsupported(errno) {
            throw BrowserSessionFileError.replacedButDirectorySyncFailed(code: errno)
        }
        return SaveResult(usedFullFileSync: usedFullSync,
                          didSyncDirectory: directorySync == 0 && parent.didSyncCreatedDirectories)
    }

    public func load(
        from destination: URL,
        maximumBytes: Int = BrowserSessionDocument.defaultMaximumInputBytes
    ) throws -> BrowserSessionDocument {
        try loadWithRawBytes(from: destination, maximumBytes: maximumBytes).document
    }

    /// Returns the exact verified input alongside its decoded (possibly migrated) document.
    func loadWithRawBytes(
        from destination: URL,
        maximumBytes: Int = BrowserSessionDocument.defaultMaximumInputBytes
    ) throws -> (document: BrowserSessionDocument, data: Data) {
        guard maximumBytes >= 0 else { throw BrowserSessionError.limitExceeded }
        let path = try Self.components(of: destination)
        let directory = try Self.openParent(of: path, create: false).handle
        let name = path.last!
        guard try Self.regularEntry(directory: directory.value, name: name) != nil else {
            throw BrowserSessionFileError.notFound
        }
        // NONBLOCK prevents a raced-in FIFO from hanging before the descriptor type check.
        let rawFile = openat(directory.value, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard rawFile >= 0 else {
            if errno == ELOOP { throw BrowserSessionFileError.symbolicLink }
            if errno == ENOENT { throw BrowserSessionFileError.notFound }
            throw Self.io(.openFile)
        }
        let file = SessionFileDescriptor(rawFile)
        var metadata = stat()
        guard fstat(file.value, &metadata) == 0 else { throw Self.io(.inspectEntry) }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw BrowserSessionFileError.notRegularFile }
        guard metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
            throw BrowserSessionError.limitExceeded
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = maximumBytes - data.count
            // Probe one extra byte at the limit, including when the input budget is zero.
            let count = buffer.withUnsafeMutableBytes {
                operations.read(file.value, $0.baseAddress!, remaining == 0 ? 1 : min(remaining, $0.count))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.io(.readFile)
            }
            if count == 0 { break }
            guard count <= remaining else { throw BrowserSessionError.limitExceeded }
            data.append(contentsOf: buffer.prefix(count))
        }
        do { return (try BrowserSessionDocument.decode(data, maximumBytes: maximumBytes), data) }
        catch let error as BrowserSessionError { throw error }
        catch { throw BrowserSessionFileError.corruptDocument }
    }

    private static func components(of url: URL) throws -> [String] {
        guard url.isFileURL, url.baseURL == nil, (url.host ?? "").isEmpty,
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, !url.hasDirectoryPath else {
            throw BrowserSessionFileError.invalidDestination
        }
        // Do not standardize or resolve symlinks: that could hide a rejected ancestor.
        let path = url.path(percentEncoded: false)
        let components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !path.contains("\0"), !components.isEmpty,
              !components.contains("."), !components.contains("..") else {
            throw BrowserSessionFileError.invalidDestination
        }
        return components
    }

    private struct ParentDirectory {
        let handle: SessionFileDescriptor
        let didSyncCreatedDirectories: Bool
    }

    private static func openParent(
        of path: [String], create: Bool,
        syncDirectory: (Int32) -> Int32 = { Darwin.fsync($0) }
    ) throws -> ParentDirectory {
        let root = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw io(.openDirectory) }
        var directory = SessionFileDescriptor(root)
        var didSyncCreatedDirectories = true
        for name in path.dropLast() {
            var metadata = try entry(directory: directory.value, name: name)
            var created = false
            if metadata == nil, create {
                if mkdirat(directory.value, name, 0o700) == 0 { created = true }
                else if errno != EEXIST { throw io(.createDirectory) }
                metadata = try entry(directory: directory.value, name: name)
            }
            guard let metadata else { throw BrowserSessionFileError.notFound }
            if metadata.st_mode & S_IFMT == S_IFLNK { throw BrowserSessionFileError.symbolicLink }
            guard metadata.st_mode & S_IFMT == S_IFDIR else { throw BrowserSessionFileError.notDirectory }
            let rawChild = openat(directory.value, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rawChild >= 0 else {
                if errno == ELOOP { throw BrowserSessionFileError.symbolicLink }
                if errno == ENOTDIR { throw BrowserSessionFileError.notDirectory }
                throw io(.openDirectory)
            }
            let child = SessionFileDescriptor(rawChild)
            var opened = stat()
            guard fstat(child.value, &opened) == 0 else { throw io(.inspectEntry) }
            guard opened.st_dev == metadata.st_dev, opened.st_ino == metadata.st_ino else {
                throw BrowserSessionFileError.destinationChanged
            }
            if created {
                try makePrivate(child.value, mode: 0o700)
                // Persist both the new directory's attributes and its link in its parent.
                for descriptor in [child.value, directory.value] {
                    if retryInterrupted({ syncDirectory(descriptor) }) != 0 {
                        guard isUnsupported(errno) else { throw io(.synchronizeCreatedDirectory) }
                        didSyncCreatedDirectories = false
                    }
                }
            }
            directory = child
        }
        return ParentDirectory(handle: directory, didSyncCreatedDirectories: didSyncCreatedDirectories)
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static func regularEntry(directory: Int32, name: String) throws -> Identity? {
        guard let metadata = try entry(directory: directory, name: name) else { return nil }
        if metadata.st_mode & S_IFMT == S_IFLNK { throw BrowserSessionFileError.symbolicLink }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw BrowserSessionFileError.notRegularFile }
        return Identity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private static func entry(directory: Int32, name: String) throws -> stat? {
        var metadata = stat()
        if fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { return metadata }
        if errno == ENOENT { return nil }
        throw io(.inspectEntry)
    }

    private static func makePrivate(_ file: Int32, mode: mode_t) throws {
        // Strip inherited ACL grants before writing any document bytes.
        guard let acl = acl_init(0) else { throw io(.clearAccessControl) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        if acl_set_fd(file, acl) != 0, errno != ENOTSUP, errno != EOPNOTSUPP {
            throw io(.clearAccessControl)
        }
        guard fchmod(file, mode) == 0 else { throw io(.setPermissions) }
    }

    private static func retryInterrupted(_ operation: () -> Int32) -> Int32 {
        while true {
            let result = operation()
            if result != -1 || errno != EINTR { return result }
        }
    }

    private static func isUnsupported(_ code: Int32) -> Bool {
        code == EINVAL || code == ENOTSUP || code == EOPNOTSUPP || code == ENOSYS
    }

    private static func io(_ operation: BrowserSessionFileError.Operation) -> BrowserSessionFileError {
        .io(operation: operation, code: errno)
    }
}

private final class SessionFileDescriptor {
    private(set) var value: Int32

    init(_ value: Int32) { self.value = value }
    deinit { if value >= 0 { _ = Darwin.close(value) } }

    func closeBeforeReplacement() throws {
        let descriptor = value
        value = -1 // Never retry close: its descriptor may already have been released.
        guard Darwin.close(descriptor) == 0 else {
            throw BrowserSessionFileError.io(operation: .closeTemporaryFile, code: errno)
        }
    }
}

struct BrowserSessionFileOperations: Sendable {
    var write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    var read: @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int = { Darwin.read($0, $1, $2) }
    var syncFile: @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }
    var fullSyncFile: @Sendable (Int32) -> Int32 = { Darwin.fcntl($0, F_FULLFSYNC) }
    var replace: @Sendable (Int32, String, String) -> Int32 = { Darwin.renameat($0, $1, $0, $2) }
    var syncDirectory: @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }
}
