import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("Explicit bookmark selections and raw private authority")
struct BookmarkSelectionGrantTests {
    private let document = BrowserBookmarkDocument(entries: [.link(title: "Synthetic", url: URL(string: "https://selection.test/")!)])
    private func directory() throws -> URL {
        let p = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(p) }
        let root = URL(fileURLWithPath: String(cString: p), isDirectory: true).appendingPathComponent("orbit-selection-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func setACL(_ url: URL, disposition: String, permission: String) throws {
        // This is the native ACL text for the public everyone group, qualified
        // using an isolated fixture. No personal account identity is consulted.
        let text = "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:\(disposition):\(permission)\n"
        let acl = try #require(text.withCString { acl_from_text($0) })
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(acl_valid(acl) == 0 && acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0)
    }

    @Test("Explicit selections accept ordinary files and replace privately; grant operation cannot change")
    func selectedReadAndReplacement() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        #expect(chmod(selected.path, 0o777) == 0)
        let file = selected.appendingPathComponent("selected.html")
        try BrowserBookmarkHTML.encode(document).write(to: file)
        #expect(chmod(file.path, 0o644) == 0)
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(at: file) }
        let input = try BrowserBookmarkFile.Selection(explicitPanelURL: file, forExport: false)
        let output = try BrowserBookmarkFile.Selection(explicitPanelURL: file, forExport: true)
        #expect(try BrowserBookmarkFile.read(selection: input) == document)
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.write(document, selection: input) }
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(selection: output) }
        try BrowserBookmarkFile.write(document, selection: output)
        var info = stat()
        #expect(lstat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        let alias = selected.appendingPathComponent("alias.html")
        #expect(symlink(file.path, alias.path) == 0)
        let uncanonical = try BrowserBookmarkFile.Selection(explicitPanelURL: alias, forExport: false)
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(selection: uncanonical) }
        let canonical = try BrowserBookmarkFile.canonicalSelection(alias, forExport: false)
        #expect(try BrowserBookmarkFile.read(selection: .init(explicitPanelURL: canonical, forExport: false)) == document)
    }

    @Test("Raw descriptors reject ACL allows on files or parents while deny-only ACLs remain usable")
    func accessControlLists() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("selected.html")
        try BrowserBookmarkFile.write(document, to: file)
        try setACL(file, disposition: "allow", permission: "read")
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(at: file) }
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.write(document, to: file) }
        #expect(try BrowserBookmarkFile.read(selection: .init(explicitPanelURL: file, forExport: false)) == document)
        try setACL(file, disposition: "deny", permission: "write")
        #expect(try BrowserBookmarkFile.read(at: file) == document)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let inside = child.appendingPathComponent("inside.html")
        try BrowserBookmarkFile.write(document, to: inside)
        try setACL(child, disposition: "allow", permission: "write")
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(at: inside) }
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.write(document, to: inside) }
    }
}
