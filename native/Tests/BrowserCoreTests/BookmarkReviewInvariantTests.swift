import Darwin
import Foundation
import Testing
@testable import BrowserCore

/// Baseline-compatible desired invariants for the four Core R1 findings.
@Suite("Bookmark review fixed invariants")
struct BookmarkReviewInvariantTests {
    private let address = URL(string: "https://bookmark-invariants.test/saved")!
    private func directory() throws -> URL {
        let path = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        let result = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("orbit-bookmark-invariants-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return result
    }

    @Test("Supported long link and folder titles import, stay trimmed, and remain one undo batch")
    func boundedTitles() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let before = await store.sessionDocument()
        let title = String(repeating: "A", count: 1_023) + " B"
        let document = try BrowserBookmarkHTML.decode(Data("<DL><H3>\(title)</H3><DL><A HREF='\(address)'>\(title)</A></DL></DL>".utf8))
        _ = try await store.importBookmarks(document, folderTitle: "Imported", from: store.captureContext(in: window))
        let result = await store.sessionDocument().organization
        #expect(result.tabs.count == 1 && result.folders.count == 2)
        #expect(result.tabs.allSatisfy { $0.customTitle == String(repeating: "A", count: 1_023) })
        #expect(result.folders.allSatisfy { $0.title == "Imported" || $0.title == String(repeating: "A", count: 1_023) })
        _ = try await store.undoOrganization(from: store.captureContext(in: window))
        #expect(await store.sessionDocument().organization == before.organization)
    }

    @Test("One oversized grapheme in an ignored attribute cannot bypass the token byte limit")
    func tokenBytes() throws {
        let attribute = "a" + String(repeating: "\u{0301}", count: 100_000)
        let tag = "<A HREF='\(address)' EXTRA='\(attribute)'>"
        #expect(tag.count < 65_536 && tag.utf8.count > 65_536)
        #expect(throws: BrowserBookmarkTransferError.oversized) {
            try BrowserBookmarkHTML.decode(Data(("<DL>" + tag + "Saved</A></DL>").utf8))
        }
        let prefix = "A HREF='\(address)' X='", suffix = "'"
        let exact = prefix + String(repeating: "a", count: 65_536 - prefix.utf8.count - suffix.utf8.count) + suffix
        #expect(try BrowserBookmarkHTML.decode(Data(("<DL><" + exact + ">Saved</A></DL>").utf8)).linkCount == 1)
        #expect(throws: BrowserBookmarkTransferError.oversized) {
            try BrowserBookmarkHTML.decode(Data(("<DL><" + exact + " >Saved</A></DL>").utf8))
        }
        let combining = try BrowserBookmarkHTML.decode(Data("<DL><A HREF='\(address)'>\u{0301}Saved</A></DL>".utf8))
        #expect(combining.entries == [.link(title: "\u{0301}Saved", url: address)])
    }

    @Test("Empty-host file user, password and port authorities refuse read, save and canonicalization")
    func fileAuthorities() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("saved.html")
        let document = BrowserBookmarkDocument(entries: [.link(title: "Saved", url: address)])
        try BrowserBookmarkFile.write(document, to: url)
        let before = try Data(contentsOf: url)
        for authority in ["synthetic-user@", ":80", "synthetic-user:synthetic@"] {
            let invalid = try #require(URL(string: "file://\(authority)\(url.path)"))
            #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(at: invalid) }
            #expect(throws: (any Error).self) { try BrowserBookmarkFile.write(document, to: invalid) }
            #expect(throws: (any Error).self) { try BrowserBookmarkFile.canonicalSelection(invalid, forExport: false) }
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("Ungranted writable paths refuse without touching their file; safe private paths still work")
    func rawPrivateAuthority() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("writable", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(chmod(directory.path, 0o777) == 0)
        let url = directory.appendingPathComponent("saved.html")
        let document = BrowserBookmarkDocument(entries: [.link(title: "Saved", url: address)])
        let bytes = try BrowserBookmarkHTML.encode(document)
        try bytes.write(to: url)
        #expect(chmod(url.path, 0o666) == 0)
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(at: url) }
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.write(document, to: url) }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(chmod(directory.path, 0o700) == 0 && chmod(url.path, 0o644) == 0)
        #expect(try BrowserBookmarkFile.read(at: url) == document)
        try BrowserBookmarkFile.write(document, to: url)
        var info = stat()
        #expect(lstat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }
}
