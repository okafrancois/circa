import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("Portable bookmark private files")
struct BrowserBookmarkFileTests {
    private func directory() throws -> URL {
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let url = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("orbit-bookmark-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }
    private var document: BrowserBookmarkDocument {
        .init(entries: [.folder(title: "Synthetic", children: [
            .link(title: "Équipe & research", url: URL(string: "https://bookmarks.test/reference?q=1&x=2")!),
            .folder(title: "Empty", children: [])
        ])])
    }

    @Test("Actual atomic replacement is private, leaves old hard links intact and round-trips structure")
    func privateReplacement() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bookmarks.html")
        let old = Data("synthetic previous bytes".utf8)
        try old.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let alias = root.appendingPathComponent("old-inode")
        #expect(link(url.path, alias.path) == 0)
        try BrowserBookmarkFile.write(document, to: url)
        #expect(try BrowserBookmarkFile.read(at: url) == document)
        #expect(try Data(contentsOf: alias) == old)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["bookmarks.html", "old-inode"])
    }

    @Test("Bookmark files above 4 MiB work while shared permission load and save retain the default limit")
    func separateByteLimits() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let large = BrowserBookmarkDocument(entries: (0..<5000).map { index in
            .link(title: String(repeating: "a", count: 1000), url: URL(string: "https://large.test/\(index)")!)
        })
        let url = root.appendingPathComponent("large.html")
        try BrowserBookmarkFile.write(large, to: url)
        let data = try Data(contentsOf: url)
        #expect(data.count > 4 * 1024 * 1024)
        #expect(try BrowserBookmarkFile.read(at: url) == large)
        #expect(throws: BrowserPermissionFile.Failure.tooLarge) { try BrowserPermissionFile.load(url) }
        #expect(throws: BrowserPermissionFile.Failure.tooLarge) { try BrowserSitePermissionStore(destination: url) }
        #expect(throws: BrowserPermissionFile.Failure.tooLarge) { try BrowserSettingsStore(destination: url) }
        #expect(throws: BrowserPermissionFile.Failure.tooLarge) { try BrowserPermissionFile.save(data, to: url) }
        let smallURL = root.appendingPathComponent("permissions.json")
        let small = Data("{\"version\":1}".utf8)
        try BrowserPermissionFile.save(small, to: smallURL)
        #expect(try BrowserPermissionFile.load(smallURL) == small)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("Final and parent symlinks and FIFO inputs or outputs refuse without modifying the target")
    func unsafeFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.html")
        try BrowserBookmarkFile.write(document, to: target)
        let original = try Data(contentsOf: target)
        let symbolic = root.appendingPathComponent("link.html")
        #expect(symlink(target.path, symbolic.path) == 0)
        let parentLink = root.appendingPathComponent("alias", isDirectory: true)
        #expect(symlink(root.path, parentLink.path) == 0)
        let fifo = root.appendingPathComponent("pipe.html")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        for url in [symbolic, parentLink.appendingPathComponent("target.html"), fifo] {
            #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(at: url) }
            #expect(throws: (any Error).self) { try BrowserBookmarkFile.write(document, to: url) }
        }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test("Explicit panel grants canonicalize existing files and new export parents without weakening direct I/O")
    func canonicalPanelSelection() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("canonical.html")
        try BrowserBookmarkFile.write(document, to: target)
        let alias = root.appendingPathComponent("granted-alias.html")
        #expect(symlink(target.path, alias.path) == 0)
        #expect(throws: BrowserPermissionFile.Failure.unsafeFile) { try BrowserBookmarkFile.read(at: alias) }
        let granted = try BrowserBookmarkFile.canonicalSelection(alias, forExport: false)
        #expect(granted == target)
        #expect(try BrowserBookmarkFile.read(at: granted) == document)
        let parentAlias = root.appendingPathComponent("granted-parent", isDirectory: true)
        #expect(symlink(root.path, parentAlias.path) == 0)
        let selected = parentAlias.appendingPathComponent("new.html")
        #expect(try BrowserBookmarkFile.canonicalSelection(selected, forExport: true) == root.appendingPathComponent("new.html"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("new.html").path))
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.canonicalSelection(selected, forExport: false) }
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.canonicalSelection(URL(string: "https://unsupported.test/")!, forExport: false) }
    }

    @Test("Missing, oversized, malformed and non-UTF8 files fail without creating browser data")
    func invalidFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("input.html")
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(at: url) }
        try Data([0xff]).write(to: url)
        #expect(throws: BrowserBookmarkTransferError.invalidEncoding) { try BrowserBookmarkFile.read(at: url) }
        try Data("<DL><A>unfinished".utf8).write(to: url)
        #expect(throws: BrowserBookmarkTransferError.malformedHTML) { try BrowserBookmarkFile.read(at: url) }
        let descriptor = open(url.path, O_WRONLY | O_TRUNC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(ftruncate(descriptor, off_t(BrowserBookmarkHTML.maximumBytes + 1)) == 0)
        #expect(throws: BrowserPermissionFile.Failure.tooLarge) { try BrowserBookmarkFile.read(at: url) }
    }
}
