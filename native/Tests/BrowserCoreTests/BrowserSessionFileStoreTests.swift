import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("Explicit local session file persistence")
struct BrowserSessionFileStoreTests {
    @Test("Round trips preserve the complete multi-profile model and empty windows")
    func roundTrip() async throws {
        let directory = try SessionFileTestDirectory()
        let document = try await sessionFileFixture()
        let store = BrowserSessionFileStore()
        let result = try store.save(document, to: directory.file)
        #expect(result.didSyncDirectory)
        #expect(try store.load(from: directory.file) == document)
        let restored = try BrowserStore(restoring: store.load(from: directory.file))
        #expect(await restored.sessionDocument() == document)
        #expect(try directory.contents() == ["session.json"])
    }

    @Test("Replacement publishes a new private inode and leaves an existing reader on the old document")
    func replacementIsAtomic() async throws {
        let directory = try SessionFileTestDirectory()
        let original = try await sessionFileFixture()
        let replacement = emptySessionFileDocument()
        let store = BrowserSessionFileStore()
        try store.save(original, to: directory.file)
        let oldReader = try FileHandle(forReadingFrom: directory.file)
        defer { try? oldReader.close() }
        let oldInode = try sessionFileStat(directory.file).st_ino
        try store.save(replacement, to: directory.file)
        #expect(try store.load(from: directory.file) == replacement)
        #expect(try BrowserSessionDocument.decode(oldReader.readToEnd()!) == original)
        #expect(try sessionFileStat(directory.file).st_ino != oldInode)
        #expect(try directory.contents() == ["session.json"])
    }

    @Test("Invalid graphs and unsupported output versions leave prior bytes and inode unchanged")
    func validationFailurePreservesOldFile() async throws {
        let directory = try SessionFileTestDirectory()
        let original = try await sessionFileFixture()
        let store = BrowserSessionFileStore()
        try store.save(original, to: directory.file)
        let bytes = try Data(contentsOf: directory.file)
        let inode = try sessionFileStat(directory.file).st_ino
        let invalid = BrowserSessionDocument(profiles: [], spaces: original.spaces,
                                            windows: original.windows, tabs: original.tabs)
        #expect(throws: BrowserSessionError.profileMissing) { try store.save(invalid, to: directory.file) }
        #expect(throws: BrowserSessionError.unsupportedVersion) {
            try store.save(emptySessionFileDocument(version: BrowserSessionDocument.currentVersion + 1), to: directory.file)
        }
        #expect(try Data(contentsOf: directory.file) == bytes)
        #expect(try sessionFileStat(directory.file).st_ino == inode)
        #expect(try directory.contents() == ["session.json"])
        let newDestination = directory.root.appendingPathComponent("uncreated/session.json")
        #expect(throws: BrowserSessionError.profileMissing) { try store.save(invalid, to: newDestination) }
        #expect(!FileManager.default.fileExists(atPath: newDestination.deletingLastPathComponent().path))
    }

    @Test("Corrupt JSON, unsupported versions and invalid reference graphs are rejected on load")
    func rejectsInvalidInput() async throws {
        let directory = try SessionFileTestDirectory()
        let store = BrowserSessionFileStore()
        for bytes in [Data("{truncated".utf8), Data("{}".utf8), Data()] {
            try bytes.write(to: directory.file)
            #expect(throws: BrowserSessionFileError.corruptDocument) { try store.load(from: directory.file) }
            #expect(try Data(contentsOf: directory.file) == bytes)
        }
        try JSONEncoder().encode(emptySessionFileDocument(version: BrowserSessionDocument.currentVersion + 1)).write(to: directory.file)
        #expect(throws: BrowserSessionError.unsupportedVersion) { try store.load(from: directory.file) }
        let valid = try await sessionFileFixture()
        let invalid = BrowserSessionDocument(profiles: valid.profiles, spaces: valid.spaces,
                                            windows: [], tabs: valid.tabs)
        try JSONEncoder().encode(invalid).write(to: directory.file)
        #expect(throws: BrowserSessionError.orphanedOccurrence) { try store.load(from: directory.file) }
    }

    @Test("Input budgets reject oversized files before reading and accept an exact-size document")
    func boundedLoad() throws {
        let directory = try SessionFileTestDirectory()
        let store = BrowserSessionFileStore()
        let document = emptySessionFileDocument()
        try store.save(document, to: directory.file)
        let size = try Data(contentsOf: directory.file).count
        #expect(try store.load(from: directory.file, maximumBytes: size) == document)
        for limit in [-1, 0, size - 1] {
            #expect(throws: BrowserSessionError.limitExceeded) {
                try store.load(from: directory.file, maximumBytes: limit)
            }
        }
        let file = try FileHandle(forWritingTo: directory.file)
        try file.truncate(atOffset: UInt64(BrowserSessionDocument.defaultMaximumInputBytes + 1))
        try file.close()
        let unread = BrowserSessionFileStore(operations: .init(read: { _, _, _ in
            Issue.record("An oversized file must be refused before read")
            return 0
        }))
        #expect(throws: BrowserSessionError.limitExceeded) { try unread.load(from: directory.file) }
    }

    @Test("A file growing after fstat still cannot exceed the input budget")
    func boundsGrowingFile() throws {
        let directory = try SessionFileTestDirectory()
        let document = emptySessionFileDocument()
        try BrowserSessionFileStore().save(document, to: directory.file)
        let bytes = try document.encoded()
        let firstRead = SessionFileTestLock(true)
        let store = BrowserSessionFileStore(operations: .init(read: { descriptor, buffer, count in
            let append = firstRead.withLock { first in
                let wasFirst = first
                first = false
                return wasFirst
            }
            if append {
                let writer = open(directory.file.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
                guard writer >= 0 else { errno = EIO; return -1 }
                _ = Darwin.write(writer, " ", 1)
                _ = Darwin.close(writer)
            }
            return Darwin.read(descriptor, buffer, count)
        }))
        #expect(throws: BrowserSessionError.limitExceeded) {
            try store.load(from: directory.file, maximumBytes: bytes.count)
        }
    }

    @Test("Missing input does not create directories or a default session")
    func missingInputIsExplicit() throws {
        let directory = try SessionFileTestDirectory()
        let store = BrowserSessionFileStore()
        #expect(throws: BrowserSessionFileError.notFound) { try store.load(from: directory.file) }
        let nested = directory.root.appendingPathComponent("missing/session.json")
        #expect(throws: BrowserSessionFileError.notFound) { try store.load(from: nested) }
        #expect(try directory.contents().isEmpty)
    }

    @Test("Remote URLs, traversal, NUL, query, fragment and directory URLs are refused")
    func invalidDestinations() throws {
        let directory = try SessionFileTestDirectory()
        let base = directory.root.absoluteString
        let invalid = [
            URL(string: "https://session.test/session.json")!,
            URL(string: "file://remote.invalid/session.json")!,
            URL(string: base + "../session.json")!,
            URL(string: base + "./session.json")!,
            URL(string: base + "nul%00session.json")!,
            URL(string: directory.file.absoluteString + "?query")!,
            URL(string: directory.file.absoluteString + "#fragment")!,
            directory.root,
            URL(fileURLWithPath: "/", isDirectory: true)
        ]
        let store = BrowserSessionFileStore()
        for destination in invalid {
            #expect(throws: BrowserSessionFileError.invalidDestination) {
                try store.save(emptySessionFileDocument(), to: destination)
            }
            #expect(throws: BrowserSessionFileError.invalidDestination) { try store.load(from: destination) }
        }
        #expect(try directory.contents().isEmpty)
    }

    @Test("File symlinks, including dangling links, preserve the link and its target")
    func rejectsFileSymlinks() throws {
        let directory = try SessionFileTestDirectory()
        let target = directory.root.appendingPathComponent("target.json")
        let bytes = try emptySessionFileDocument().encoded()
        try bytes.write(to: target)
        let store = BrowserSessionFileStore()
        for targetPath in [target.path, directory.root.appendingPathComponent("absent.json").path] {
            try FileManager.default.createSymbolicLink(atPath: directory.file.path, withDestinationPath: targetPath)
            #expect(throws: BrowserSessionFileError.symbolicLink) {
                try store.save(emptySessionFileDocument(), to: directory.file)
            }
            #expect(throws: BrowserSessionFileError.symbolicLink) { try store.load(from: directory.file) }
            #expect(try sessionFileStat(directory.file).st_mode & S_IFMT == S_IFLNK)
            #expect(try Data(contentsOf: target) == bytes)
            try FileManager.default.removeItem(at: directory.file)
        }
    }

    @Test("Symlinks in both immediate and distant directory ancestors are refused")
    func rejectsAncestorSymlinks() throws {
        let directory = try SessionFileTestDirectory()
        let real = directory.root.appendingPathComponent("real/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let realFile = real.appendingPathComponent("session.json")
        let store = BrowserSessionFileStore()
        try store.save(emptySessionFileDocument(), to: realFile)
        let bytes = try Data(contentsOf: realFile)
        let link = directory.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.deletingLastPathComponent())
        let immediate = directory.root.appendingPathComponent("immediate")
        try FileManager.default.createSymbolicLink(at: immediate, withDestinationURL: real)
        for destination in [link.appendingPathComponent("deeper/session.json"),
                            immediate.appendingPathComponent("session.json"),
                            link.appendingPathComponent("uncreated/session.json")] {
            #expect(throws: BrowserSessionFileError.symbolicLink) {
                try store.save(emptySessionFileDocument(), to: destination)
            }
            #expect(throws: BrowserSessionFileError.symbolicLink) { try store.load(from: destination) }
        }
        #expect(try Data(contentsOf: realFile) == bytes)
        #expect(!FileManager.default.fileExists(atPath: real.deletingLastPathComponent().appendingPathComponent("uncreated").path))
    }

    @Test("Directories and FIFOs are rejected as destinations without blocking or replacing them")
    func rejectsNonRegularDestinations() throws {
        let directory = try SessionFileTestDirectory()
        let store = BrowserSessionFileStore()
        try FileManager.default.createDirectory(at: directory.file, withIntermediateDirectories: false)
        #expect(throws: BrowserSessionFileError.notRegularFile) {
            try store.save(emptySessionFileDocument(), to: directory.file)
        }
        #expect(throws: BrowserSessionFileError.notRegularFile) { try store.load(from: directory.file) }
        try FileManager.default.removeItem(at: directory.file)
        #expect(mkfifo(directory.file.path, 0o600) == 0)
        #expect(throws: BrowserSessionFileError.notRegularFile) {
            try store.save(emptySessionFileDocument(), to: directory.file)
        }
        #expect(throws: BrowserSessionFileError.notRegularFile) { try store.load(from: directory.file) }
        #expect(try sessionFileStat(directory.file).st_mode & S_IFMT == S_IFIFO)
    }

    @Test("A regular file cannot be traversed as a directory")
    func rejectsNonDirectoryAncestor() throws {
        let directory = try SessionFileTestDirectory()
        try Data("sentinel".utf8).write(to: directory.file)
        let nested = directory.file.appendingPathComponent("session.json")
        let store = BrowserSessionFileStore()
        #expect(throws: BrowserSessionFileError.notDirectory) { try store.save(emptySessionFileDocument(), to: nested) }
        #expect(throws: BrowserSessionFileError.notDirectory) { try store.load(from: nested) }
        #expect(try Data(contentsOf: directory.file) == Data("sentinel".utf8))
    }

    @Test("New directories are 0700, files are 0600, and existing ancestor modes remain unchanged")
    func privatePermissions() throws {
        let directory = try SessionFileTestDirectory()
        #expect(chmod(directory.root.path, 0o750) == 0)
        try addInheritedReadACL(to: directory.root)
        let nested = directory.root.appendingPathComponent("one/two/session.json")
        let store = BrowserSessionFileStore()
        try store.save(emptySessionFileDocument(), to: nested)
        for folder in [nested.deletingLastPathComponent(), nested.deletingLastPathComponent().deletingLastPathComponent()] {
            #expect(try sessionFileStat(folder).st_mode & 0o777 == 0o700)
            try expectNoExtendedACL(folder)
        }
        #expect(try sessionFileStat(directory.root).st_mode & 0o777 == 0o750)
        #expect(try sessionFileStat(nested).st_mode & 0o777 == 0o600)
        try expectNoExtendedACL(nested)
        #expect(chmod(nested.path, 0o644) == 0)
        try store.save(emptySessionFileDocument(), to: nested)
        #expect(try sessionFileStat(nested).st_mode & 0o777 == 0o600)
        try store.save(emptySessionFileDocument(), to: directory.file)
        try expectNoExtendedACL(directory.file)
    }

    @Test("A new directory synchronization failure never publishes a session file")
    func newDirectorySyncFailureIsPrecommit() throws {
        let directory = try SessionFileTestDirectory()
        let nested = directory.root.appendingPathComponent("new/session.json")
        let store = BrowserSessionFileStore(operations: .init(syncDirectory: { _ in errno = EIO; return -1 }))
        #expect(throws: BrowserSessionFileError.io(operation: .synchronizeCreatedDirectory, code: EIO)) {
            try store.save(emptySessionFileDocument(), to: nested)
        }
        #expect(!FileManager.default.fileExists(atPath: nested.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: nested.deletingLastPathComponent().path).isEmpty)
    }

    @Test("Short writes and interrupted IO are retried without dropping bytes")
    func retriesPartialIO() async throws {
        let directory = try SessionFileTestDirectory()
        let document = try await sessionFileFixture()
        let writeCalls = SessionFileTestLock(0)
        let readCalls = SessionFileTestLock(0)
        let store = BrowserSessionFileStore(operations: .init(write: { descriptor, bytes, count in
            let interrupted = writeCalls.withLock { calls in calls += 1; return calls == 1 }
            if interrupted { errno = EINTR; return -1 }
            return Darwin.write(descriptor, bytes, min(count, 11))
        }, read: { descriptor, bytes, count in
            let interrupted = readCalls.withLock { calls in calls += 1; return calls == 1 }
            if interrupted { errno = EINTR; return -1 }
            return Darwin.read(descriptor, bytes, min(count, 7))
        }))
        try store.save(document, to: directory.file)
        #expect(try store.load(from: directory.file) == document)
        #expect(writeCalls.withLock { $0 } > 2)
        #expect(readCalls.withLock { $0 } > 2)
    }

    @Test("A real partial write followed by ENOSPC preserves the prior file and cleans staging")
    func partialWriteFailurePreservesOldFile() async throws {
        let directory = try SessionFileTestDirectory()
        let original = try await sessionFileFixture()
        try BrowserSessionFileStore().save(original, to: directory.file)
        let bytes = try Data(contentsOf: directory.file)
        let inode = try sessionFileStat(directory.file).st_ino
        let written = SessionFileTestLock(0)
        let store = BrowserSessionFileStore(operations: .init(write: { descriptor, buffer, count in
            written.withLock { total in
                if total > 0 { errno = ENOSPC; return -1 }
                let result = Darwin.write(descriptor, buffer, min(count, 9))
                total += max(0, result)
                return result
            }
        }))
        #expect(throws: BrowserSessionFileError.io(operation: .writeTemporaryFile, code: ENOSPC)) {
            try store.save(emptySessionFileDocument(), to: directory.file)
        }
        #expect(written.withLock { $0 } == 9)
        #expect(try Data(contentsOf: directory.file) == bytes)
        #expect(try sessionFileStat(directory.file).st_ino == inode)
        #expect(try directory.contents() == ["session.json"])
    }

    @Test("Zero progress, flush failures and rename failures preserve the prior inode and bytes")
    func precommitFailuresPreserveOldFile() throws {
        let directory = try SessionFileTestDirectory()
        try BrowserSessionFileStore().save(emptySessionFileDocument(), to: directory.file)
        let bytes = try Data(contentsOf: directory.file)
        let inode = try sessionFileStat(directory.file).st_ino
        let failures: [(BrowserSessionFileOperations, BrowserSessionFileError)] = [
            (.init(write: { _, _, _ in 0 }), .io(operation: .writeTemporaryFile, code: EIO)),
            (.init(syncFile: { _ in errno = EIO; return -1 }), .io(operation: .synchronizeFile, code: EIO)),
            (.init(fullSyncFile: { _ in errno = EIO; return -1 }), .io(operation: .fullySynchronizeFile, code: EIO)),
            (.init(replace: { _, _, _ in errno = EACCES; return -1 }), .io(operation: .replaceFile, code: EACCES))
        ]
        for (operations, error) in failures {
            #expect(throws: error) {
                try BrowserSessionFileStore(operations: operations).save(emptySessionFileDocument(), to: directory.file)
            }
            #expect(try Data(contentsOf: directory.file) == bytes)
            #expect(try sessionFileStat(directory.file).st_ino == inode)
            #expect(try directory.contents() == ["session.json"])
        }
    }

    @Test("A destination swapped to a symlink during a write is rejected before commit")
    func rejectsDestinationSwappedToSymlink() throws {
        let directory = try SessionFileTestDirectory()
        let store = BrowserSessionFileStore()
        try store.save(emptySessionFileDocument(), to: directory.file)
        let retained = directory.root.appendingPathComponent("retained.json")
        let oldBytes = try Data(contentsOf: directory.file)
        let racing = BrowserSessionFileStore(operations: .init(syncFile: { descriptor in
            guard Darwin.rename(directory.file.path, retained.path) == 0,
                  symlink(retained.path, directory.file.path) == 0 else { errno = EIO; return -1 }
            return Darwin.fsync(descriptor)
        }))
        #expect(throws: BrowserSessionFileError.symbolicLink) {
            try racing.save(emptySessionFileDocument(), to: directory.file)
        }
        #expect(try Data(contentsOf: retained) == oldBytes)
        #expect(try sessionFileStat(directory.file).st_mode & S_IFMT == S_IFLNK)
        #expect(try directory.contents() == ["retained.json", "session.json"])
    }

    @Test("Unsupported flush capabilities are reported without claiming full durability")
    func unsupportedSynchronization() throws {
        let directory = try SessionFileTestDirectory()
        for code in [ENOTSUP, EOPNOTSUPP, EINVAL, ENOSYS] {
            let store = BrowserSessionFileStore(operations: .init(
                fullSyncFile: { _ in errno = code; return -1 },
                syncDirectory: { _ in errno = code; return -1 }
            ))
            let result = try store.save(emptySessionFileDocument(), to: directory.file)
            #expect(!result.usedFullFileSync)
            #expect(!result.didSyncDirectory)
            #expect(try store.load(from: directory.file) == emptySessionFileDocument())
        }
    }

    @Test("Directory sync failure explicitly reports that the replacement has already committed")
    func directorySyncFailureIsPostcommit() async throws {
        let directory = try SessionFileTestDirectory()
        try BrowserSessionFileStore().save(await sessionFileFixture(), to: directory.file)
        let replacement = emptySessionFileDocument()
        let store = BrowserSessionFileStore(operations: .init(syncDirectory: { _ in errno = EIO; return -1 }))
        #expect(throws: BrowserSessionFileError.replacedButDirectorySyncFailed(code: EIO)) {
            try store.save(replacement, to: directory.file)
        }
        #expect(try BrowserSessionFileStore().load(from: directory.file) == replacement)
        #expect(try directory.contents() == ["session.json"])
    }
}

private final class SessionFileTestDirectory: @unchecked Sendable {
    let root: URL
    var file: URL { root.appendingPathComponent("session.json", isDirectory: false) }

    init() throws {
        // The system temporary alias may itself be a symlink. Canonicalize only this
        // synthetic test root, never a caller-supplied path in the production store.
        guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
        defer { free(canonical) }
        root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("browser-session-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }
}

private final class SessionFileTestLock<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private func emptySessionFileDocument(version: Int = BrowserSessionDocument.currentVersion) -> BrowserSessionDocument {
    BrowserSessionDocument(version: version, profiles: [], spaces: [], windows: [], tabs: [])
}

private func sessionFileFixture() async throws -> BrowserSessionDocument {
    let store = BrowserStore()
    let firstProfile = await store.createProfile(name: "Synthetic One")
    let secondProfile = await store.createProfile(name: "Synthetic Two")
    let firstSpace = try await store.createSpace(name: "One", profileID: firstProfile)
    let secondSpace = try await store.createSpace(name: "Two", profileID: secondProfile)
    let firstWindow = try await store.createWindow(activeSpaceID: firstSpace)
    let secondWindow = try await store.createWindow(activeSpaceID: secondSpace)
    _ = try await store.createWindow(activeSpaceID: firstSpace)
    for (index, window) in [firstWindow, firstWindow, secondWindow].enumerated() {
        _ = try await store.openTab(url: URL(string: "https://session.test/\(index)")!,
                                   from: store.captureContext(in: window), activate: index == 0)
    }
    return await store.sessionDocument()
}

private func sessionFileStat(_ url: URL) throws -> stat {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    return metadata
}

private func expectNoExtendedACL(_ url: URL) throws {
    guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
        if errno == ENOENT { return } // Darwin also represents an absent extended ACL as ENOENT.
        throw POSIXError(POSIXErrorCode(rawValue: errno)!)
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    #expect(acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1)
    #expect(errno == EINVAL)
}

private func addInheritedReadACL(to url: URL) throws {
    // This modifies only the synthetic fixture and proves that chmod alone is insufficient.
    let command = Process()
    command.executableURL = URL(fileURLWithPath: "/bin/chmod")
    command.arguments = ["+a", "everyone allow read,readattr,readextattr,readsecurity,file_inherit,directory_inherit", url.path]
    command.standardOutput = FileHandle.nullDevice
    command.standardError = FileHandle.nullDevice
    try command.run()
    command.waitUntilExit()
    guard command.terminationStatus == 0 else { throw POSIXError(.EIO) }
}
