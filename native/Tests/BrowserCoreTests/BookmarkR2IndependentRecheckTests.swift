import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("Independent bookmark R2 authority recheck", .serialized)
struct BookmarkR2IndependentRecheckTests {
    private let document = BrowserBookmarkDocument(entries: [
        .link(title: "Synthetic", url: URL(string: "https://independent-bookmark.test/saved")!)
    ])

    private func root(mode: mode_t = 0o700) throws -> URL {
        // Deliberately use the trusted sticky system ancestor, rather than the
        // private per-user temporary directory, to test both confidentiality routes.
        let result = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("orbit-bookmark-r2-recheck-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        #expect(chmod(result.path, mode) == 0)
        return result
    }

    private func setACL(_ url: URL, entries: String) throws {
        let acl = try #require(("!#acl 1\n" + entries).withCString { acl_from_text($0) })
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        #expect(acl_valid(acl) == 0)
        #expect(acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0)
    }

    private func entry(_ disposition: String, _ permission: String) -> String {
        "group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:\(disposition):\(permission)\n"
    }

    @Test("Raw confidentiality comes from file mode or a private ancestor, while shared defaults remain usable")
    func confidentialityAndStandardDefaults() throws {
        let directory = try root(mode: 0o755)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.html")
        let bytes = try BrowserBookmarkHTML.encode(document)
        try bytes.write(to: file)
        for mode: mode_t in [0o400, 0o600] {
            #expect(chmod(file.path, mode) == 0)
            #expect(try BrowserBookmarkFile.read(at: file) == document)
        }
        #expect(chmod(file.path, 0o644) == 0)
        #expect(throws: BrowserPermissionFile.Failure.unsafeFile) { try BrowserBookmarkFile.read(at: file) }
        #expect(throws: BrowserPermissionFile.Failure.unsafeFile) { try BrowserBookmarkFile.write(document, to: file) }
        #expect(try BrowserPermissionFile.load(file) == bytes)
        try BrowserPermissionFile.save(bytes, to: file)
        #expect(chmod(file.path, 0o644) == 0 && chmod(directory.path, 0o700) == 0)
        #expect(try BrowserBookmarkFile.read(at: file) == document)
        try BrowserBookmarkFile.write(document, to: file)
        var info = stat()
        #expect(lstat(file.path, &info) == 0 && info.st_mode & 0o7777 == 0o600)
    }

    @Test("Writable descendants and file special bits refuse even below a private ancestor")
    func specialAndWritableModes() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let child = directory.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let file = child.appendingPathComponent("synthetic.html")
        let bytes = try BrowserBookmarkHTML.encode(document)
        try bytes.write(to: file)
        // /private/tmp inherits a system group. Set our fixture's group to the
        // operator's effective group so Darwin actually retains requested setgid.
        #expect(chown(child.path, geteuid(), getegid()) == 0)
        #expect(chown(file.path, geteuid(), getegid()) == 0)
        #expect(chmod(file.path, 0o600) == 0)
        for mode: mode_t in [0o770, 0o707, 0o1700, 0o2700, 0o4700] {
            #expect(chmod(child.path, mode) == 0)
            var info = stat()
            #expect(lstat(child.path, &info) == 0 && info.st_mode & 0o7777 == mode)
            #expect(throws: BrowserPermissionFile.Failure.unsafeFile) { try BrowserBookmarkFile.read(at: file) }
            #expect(throws: BrowserPermissionFile.Failure.unsafeFile) { try BrowserBookmarkFile.write(document, to: file) }
            #expect(try Data(contentsOf: file) == bytes)
        }
        #expect(chmod(child.path, 0o700) == 0)
        for mode: mode_t in [0o620, 0o602, 0o1600, 0o2600, 0o4600] {
            #expect(chmod(file.path, mode) == 0)
            var info = stat()
            #expect(lstat(file.path, &info) == 0 && info.st_mode & 0o7777 == mode)
            #expect(throws: BrowserPermissionFile.Failure.unsafeFile) { try BrowserBookmarkFile.read(at: file) }
            #expect(throws: BrowserPermissionFile.Failure.unsafeFile) { try BrowserBookmarkFile.write(document, to: file) }
        }
        #expect(chmod(file.path, 0o600) == 0)
        #expect(try BrowserBookmarkFile.read(at: file) == document)
    }

    @Test("A trusted root-owned sticky directory may be traversed but cannot be the raw final parent")
    func operatorOwnedFinalParent() throws {
        let file = URL(fileURLWithPath: "/private/tmp/orbit-bookmark-r2-final-parent-\(UUID()).html")
        defer { try? FileManager.default.removeItem(at: file) }
        try BrowserBookmarkHTML.encode(document).write(to: file)
        #expect(chmod(file.path, 0o600) == 0)
        #expect(throws: BrowserPermissionFile.Failure.unsafeFile) { try BrowserBookmarkFile.read(at: file) }
        #expect(throws: BrowserPermissionFile.Failure.unsafeFile) { try BrowserBookmarkFile.write(document, to: file) }
        #expect(try BrowserBookmarkFile.read(selection: .init(explicitPanelURL: file, forExport: false)) == document)
    }

    @Test("Darwin empty/deny/mixed ACL iteration is qualified and selected atomic replacement removes ACLs")
    func actualACLIterationAndReplacement() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.html")
        try BrowserBookmarkFile.write(document, to: file)
        let empty = try #require(acl_init(0))
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        #expect(acl_valid(empty) == 0)
        var first: acl_entry_t?
        errno = 0
        #expect(acl_get_entry(empty, ACL_FIRST_ENTRY.rawValue, &first) == -1)
        #expect(errno == EINVAL)
        try setACL(file, entries: entry("deny", "write"))
        #expect(try BrowserBookmarkFile.read(at: file) == document)
        try setACL(file, entries: entry("deny", "write") + entry("allow", "read"))
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        let acl = try #require(acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var item: acl_entry_t?
        #expect(acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &item) == 0)
        #expect(acl_get_entry(acl, ACL_NEXT_ENTRY.rawValue, &item) == 0)
        errno = 0
        #expect(acl_get_entry(acl, ACL_NEXT_ENTRY.rawValue, &item) == -1 && errno == EINVAL)
        #expect(throws: BrowserPermissionFile.Failure.unsafeFile) { try BrowserBookmarkFile.read(at: file) }
        #expect(throws: BrowserPermissionFile.Failure.unsafeFile) { try BrowserBookmarkFile.write(document, to: file) }
        try BrowserBookmarkFile.write(document, selection: .init(explicitPanelURL: file, forExport: true))
        #expect(try BrowserBookmarkFile.read(at: file) == document)
        let replacement = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(replacement >= 0)
        defer { close(replacement) }
        errno = 0
        if let replacementACL = acl_get_fd_np(replacement, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(replacementACL)) }
            errno = 0
            #expect(acl_get_entry(replacementACL, ACL_FIRST_ENTRY.rawValue, &item) == -1 && errno == EINVAL)
        } else {
            // Darwin also represents an absent on-disk extended ACL as ENOENT.
            #expect(errno == ENOENT)
        }
    }

    @Test("Rejected directory descriptors and repeated successful I/O leave no fixture descriptors open")
    func descriptorCleanup() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.html")
        try BrowserBookmarkFile.write(document, to: file)
        var directoryInfo = stat()
        try #require(lstat(directory.path, &directoryInfo) == 0)
        var fileInfo = stat()
        try #require(lstat(file.path, &fileInfo) == 0)
        var fixtureInodes: Set<ino_t> = [directoryInfo.st_ino, fileInfo.st_ino]
        func fixtureDescriptors() -> Int {
            (0..<512).reduce(0) { count, descriptor in
                var info = stat()
                return count + (fstat(Int32(descriptor), &info) == 0 && info.st_dev == directoryInfo.st_dev && fixtureInodes.contains(info.st_ino) ? 1 : 0)
            }
        }
        #expect(fixtureDescriptors() == 0)
        for _ in 0..<32 {
            #expect(chmod(directory.path, 0o777) == 0)
            #expect(throws: BrowserPermissionFile.Failure.unsafeFile) { try BrowserBookmarkFile.read(at: file) }
            #expect(throws: BrowserPermissionFile.Failure.unsafeFile) { try BrowserBookmarkFile.write(document, to: file) }
            #expect(chmod(directory.path, 0o700) == 0)
            #expect(try BrowserBookmarkFile.read(at: file) == document)
            try BrowserBookmarkFile.write(document, to: file)
            try #require(lstat(file.path, &fileInfo) == 0)
            fixtureInodes.insert(fileInfo.st_ino)
        }
        #expect(fixtureDescriptors() == 0)
    }

    @Test("Malformed authority is refused before both grants and shared-helper I/O")
    func authoritiesAcrossEntryPoints() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.html")
        try BrowserBookmarkFile.write(document, to: file)
        let before = try Data(contentsOf: file)
        for authority in ["synthetic@", ":synthetic@", "synthetic:synthetic@", ":0", ":80", "@", "localhost", "foreign.test"] {
            let url = try #require(URL(string: "file://\(authority)\(file.path)"))
            for exporting in [false, true] {
                #expect(throws: (any Error).self) { try BrowserBookmarkFile.Selection(explicitPanelURL: url, forExport: exporting) }
                #expect(throws: (any Error).self) { try BrowserBookmarkFile.canonicalSelection(url, forExport: exporting) }
            }
            #expect(throws: (any Error).self) { try BrowserPermissionFile.load(url) }
            #expect(throws: (any Error).self) { try BrowserPermissionFile.save(before, to: url) }
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("Typed selections do not resolve a changed alias or bypass FIFO/type/size limits")
    func selectionDoesNotResolveAgain() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("original.html")
        let other = directory.appendingPathComponent("other.html")
        try BrowserBookmarkFile.write(document, to: file)
        try BrowserBookmarkFile.write(.init(entries: []), to: other)
        let alias = directory.appendingPathComponent("chosen.html")
        #expect(symlink(file.path, alias.path) == 0)
        let canonical = try BrowserBookmarkFile.canonicalSelection(alias, forExport: false)
        #expect(unlink(alias.path) == 0 && symlink(other.path, alias.path) == 0)
        #expect(try BrowserBookmarkFile.read(selection: .init(explicitPanelURL: canonical, forExport: false)) == document)
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(selection: .init(explicitPanelURL: alias, forExport: false)) }
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.write(document, selection: .init(explicitPanelURL: alias, forExport: true)) }
        #expect(try BrowserBookmarkFile.read(at: other).entries.isEmpty)
        let fifo = directory.appendingPathComponent("pipe.html")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let nonfile = directory.appendingPathComponent("folder.html")
        try FileManager.default.createDirectory(at: nonfile, withIntermediateDirectories: false)
        for invalid in [fifo, nonfile] {
            #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(selection: .init(explicitPanelURL: invalid, forExport: false)) }
            #expect(throws: (any Error).self) { try BrowserBookmarkFile.write(document, selection: .init(explicitPanelURL: invalid, forExport: true)) }
        }
        let fd = open(file.path, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(ftruncate(fd, off_t(BrowserBookmarkHTML.maximumBytes + 1)) == 0)
        #expect(throws: BrowserPermissionFile.Failure.tooLarge) { try BrowserBookmarkFile.read(selection: .init(explicitPanelURL: file, forExport: false)) }
    }

    @Test("UTF8 token bounds retain quoted delimiters and combining text at the exact byte boundary")
    func unicodeByteBoundary() throws {
        let prefix = "A HREF='https://independent-bookmark.test/' EXTRA='"
        let fixed = prefix + ">\u{0301}'\u{0301}"
        let exact = prefix + String(repeating: "a", count: 65_536 - fixed.utf8.count) + ">\u{0301}'\u{0301}"
        #expect(exact.utf8.count == 65_536)
        let decoded = try BrowserBookmarkHTML.decode(Data("<DL><\(exact)>\u{0301}Saved</A></DL>".utf8))
        #expect(decoded.entries == [.link(title: "\u{0301}Saved", url: URL(string: "https://independent-bookmark.test/")!)])
        #expect(throws: BrowserBookmarkTransferError.oversized) {
            try BrowserBookmarkHTML.decode(Data("<DL><\(exact) >Saved</A></DL>".utf8))
        }
    }

    @Test("Retrimming preserves control normalization and localized fallback in a dormant undoable tree")
    func boundedTitleVariants() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let before = await store.sessionDocument()
        let title = String(repeating: "A", count: 1_023) + "\u{00a0}B"
        let url = URL(string: "https://independent-bookmark.test/saved")!
        let input = BrowserBookmarkDocument(entries: [.folder(title: title, children: [
            .link(title: title, url: url), .link(title: "\n\t\u{0000}", url: url),
            .link(title: "\n Left\u{0000}Right \t", url: url)
        ])])
        let labels = BrowserBookmarkLabels(untitled: "Synthetic localized fallback")
        _ = try await store.importBookmarks(input, folderTitle: "Imported", from: store.captureContext(in: window), labels: labels)
        let imported = await store.sessionDocument()
        #expect(imported.organization.tabs.compactMap(\.customTitle).sorted() == [
            String(repeating: "A", count: 1_023), "Synthetic localized fallback", "Left Right"
        ].sorted())
        #expect(imported.organization.folders.contains { $0.title == String(repeating: "A", count: 1_023) })
        #expect(imported.tabs == before.tabs && imported.windows == before.windows)
        _ = try await store.undoOrganization(from: store.captureContext(in: window))
        #expect(await store.sessionDocument().organization == before.organization)
        _ = try await store.redoOrganization(from: store.captureContext(in: window))
        #expect(await store.sessionDocument().organization == imported.organization)
    }
}
