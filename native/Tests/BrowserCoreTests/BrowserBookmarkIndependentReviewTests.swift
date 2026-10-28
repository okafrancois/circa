import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("Independent portable bookmark review R1")
struct BrowserBookmarkIndependentReviewTests {
    private let address = URL(string: "https://independent-bookmark.test/saved?a=1&b=2")!

    private func directory() throws -> URL {
        let path = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(path) }
        let root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("orbit-bookmark-independent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test("The exact 64-folder limit round-trips, and one extra folder refuses in both directions")
    func exactDepthBoundary() throws {
        var entry = BrowserBookmarkDocument.Entry.link(title: "Last", url: address)
        for _ in 0..<BrowserBookmarkHTML.maximumDepth { entry = .folder(title: "Level", children: [entry]) }
        let document = BrowserBookmarkDocument(entries: [entry])
        #expect(try BrowserBookmarkHTML.decode(BrowserBookmarkHTML.encode(document)) == document)
        let tooDeep = BrowserBookmarkDocument(entries: [.folder(title: "Extra", children: [entry])])
        #expect(throws: BrowserBookmarkTransferError.excessiveDepth) { try BrowserBookmarkHTML.encode(tooDeep) }
        let html = "<DL>" + String(repeating: "<H3>Level</H3><DL>", count: 65)
            + String(repeating: "</DL>", count: 66)
        #expect(throws: BrowserBookmarkTransferError.excessiveDepth) { try BrowserBookmarkHTML.decode(Data(html.utf8)) }
    }

    @Test("Skipped links consume the entry budget instead of bypassing it")
    func skippedEntryBudget() throws {
        let entry = "<A HREF='javascript:synthetic'>Skipped</A>"
        let accepted = "<DL>" + String(repeating: entry, count: BrowserBookmarkHTML.maximumEntries) + "</DL>"
        let parsed = try BrowserBookmarkHTML.decode(Data(accepted.utf8))
        #expect(parsed.entries.isEmpty && parsed.skippedLinkCount == BrowserBookmarkHTML.maximumEntries)
        let refused = "<DL>" + String(repeating: entry, count: BrowserBookmarkHTML.maximumEntries + 1) + "</DL>"
        #expect(throws: BrowserBookmarkTransferError.excessiveEntries) { try BrowserBookmarkHTML.decode(Data(refused.utf8)) }
    }

    @Test("Entities cannot turn inert encoded text into hierarchy or decode credential URLs past the filter")
    func encodedStructureAndCredentials() throws {
        let html = """
        <DL><A HREF='https://synthetic&#58;credential&#64;independent-bookmark.test/'>Skipped</A>
        <A HREF='https://independent-bookmark.test/'>&lt;/A&gt;&lt;H3&gt;Fake&lt;/H3&gt;&#x26;lt;</A></DL>
        """
        let parsed = try BrowserBookmarkHTML.decode(Data(html.utf8))
        #expect(parsed.skippedLinkCount == 1 && parsed.folderCount == 0)
        #expect(parsed.entries == [.link(title: "</A><H3>Fake</H3>&lt;", url: URL(string: "https://independent-bookmark.test/")!)])
        let supported = BrowserBookmarkDocument(entries: parsed.entries)
        #expect(try BrowserBookmarkHTML.decode(BrowserBookmarkHTML.encode(supported)) == supported)
    }

    @Test("An invalid late child leaves organization, undo and redo journals unchanged")
    func lateInvalidChildRollback() async throws {
        let f = try await OrganizationFixture.make()
        _ = try await f.store.createFolder(title: "Existing", at: .init(.pinned(f.home)), from: f.context())
        _ = try await f.store.undoOrganization(from: f.context())
        let before = await f.store.sessionDocument()
        let snapshot = try await f.organization()
        let invalid = BrowserBookmarkDocument(entries: [.folder(title: "Valid", children: [
            .link(title: "Valid", url: address),
            .link(title: "Invalid", url: URL(string: "file:///synthetic-only")!)
        ])])
        await #expect(throws: BrowserBookmarkTransferError.invalidURL) {
            try await f.store.importBookmarks(invalid, folderTitle: "Refused", from: f.context())
        }
        #expect(await f.store.sessionDocument() == before)
        let after = try await f.organization()
        #expect(after.undoAction == snapshot.undoAction && after.redoAction == snapshot.redoAction)
        _ = try await f.store.redoOrganization(from: f.context())
        #expect(try await f.organization().pinned.count == 1)
    }

    @Test("The combined export counts its grouping folder and refuses without modifying the store")
    func combinedExportBounds() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Scope", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        var entry = BrowserBookmarkDocument.Entry.link(title: "Last", url: address)
        // Import adds one folder and export adds a second one. The full export is too deep.
        for _ in 0..<63 { entry = .folder(title: "Level", children: [entry]) }
        _ = try await store.importBookmarks(.init(entries: [entry]), folderTitle: "Imported",
                                          from: store.captureContext(in: window))
        let before = await store.sessionDocument()
        await #expect(throws: BrowserBookmarkTransferError.excessiveDepth) {
            try await store.exportBookmarks(from: store.captureContext(in: window))
        }
        #expect(await store.sessionDocument() == before)
    }

    @Test("R1-P2-TITLE: truncation must not leave whitespace that makes a supported import fail", .disabled("Historical R1 bug characterization; desired fixed invariants run in BookmarkReviewInvariantTests"))
    func longTitleNormalizationCounterexample() async throws {
        let f = try await OrganizationFixture.make()
        let name = String(repeating: "A", count: 1_023) + " B"
        let input = "<DL><H3>\(name)</H3><DL><A HREF='https://independent-bookmark.test/'>Saved</A></DL></DL>"
        let document = try BrowserBookmarkHTML.decode(Data(input.utf8))
        let before = await f.store.sessionDocument()
        await #expect(throws: BrowserSessionError.organizationInvalidTitle) {
            try await f.store.importBookmarks(document, folderTitle: "Imported", from: f.context())
        }
        #expect(await f.store.sessionDocument() == before)
        // Preserve a failing desired invariant as an explicit known issue, not a passing claim.
        await withKnownIssue("R1-P2-TITLE: normalize after truncation as well as before it") {
            _ = try await f.store.importBookmarks(document, folderTitle: "Imported", from: f.context())
        }
    }

    @Test("R1-P2-TOKEN: a large single grapheme bypasses the advertised bounded HTML token", .disabled("Historical R1 bug characterization; desired fixed invariants run in BookmarkReviewInvariantTests"))
    func tokenByteBoundCounterexample() throws {
        let attribute = "a" + String(repeating: "\u{0301}", count: 100_000)
        let opening = "<A HREF='https://independent-bookmark.test/' EXTRA='\(attribute)'>"
        #expect(opening.count < 65_536 && opening.utf8.count > 65_536)
        let data = Data(("<DL>" + opening + "Saved</A></DL>").utf8)
        #expect(data.count < BrowserBookmarkHTML.maximumBytes)
        #expect(try BrowserBookmarkHTML.decode(data).linkCount == 1)
        withKnownIssue("R1-P2-TOKEN: readTag counts extended graphemes instead of limiting UTF-8 token bytes") {
            #expect(throws: BrowserBookmarkTransferError.oversized) { try BrowserBookmarkHTML.decode(data) }
        }
    }

    @Test("Foreign hosts and malformed file references refuse without touching a private export")
    func invalidFileReferences() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("saved.html")
        let document = BrowserBookmarkDocument(entries: [.link(title: "Saved", url: address)])
        try BrowserBookmarkFile.write(document, to: target)
        let before = try Data(contentsOf: target)
        var foreign = URLComponents(url: target, resolvingAgainstBaseURL: false)!
        foreign.host = "foreign.invalid"
        var query = URLComponents(url: target, resolvingAgainstBaseURL: false)!
        query.query = "synthetic"
        for url in [try #require(foreign.url), try #require(query.url), root] {
            #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(at: url) }
            #expect(throws: (any Error).self) { try BrowserBookmarkFile.write(document, to: url) }
            #expect(throws: (any Error).self) { try BrowserBookmarkFile.canonicalSelection(url, forExport: true) }
        }
        #expect(try Data(contentsOf: target) == before)
    }

    @Test("R1-P2-AUTHORITY: empty-host credential and port authorities must not alias a local file", .disabled("Historical R1 bug characterization; desired fixed invariants run in BookmarkReviewInvariantTests"))
    func emptyHostAuthorityCounterexample() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("saved.html")
        let document = BrowserBookmarkDocument(entries: [.link(title: "Saved", url: address)])
        try BrowserBookmarkFile.write(document, to: target)
        for authority in ["synthetic-user@", ":80", "synthetic-user:synthetic@"] {
            let url = try #require(URL(string: "file://\(authority)\(target.path)"))
            #expect(url.host == "")
            #expect(try BrowserBookmarkFile.read(at: url) == document)
            #expect(try BrowserBookmarkFile.canonicalSelection(url, forExport: false) == target)
            withKnownIssue("R1-P2-AUTHORITY: direct I/O must reject file user/password/port components") {
                #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(at: url) }
            }
        }
    }

    @Test("R1-P2-PRIVATE: raw I/O accepts a writable regular file in a writable directory", .disabled("Historical R1 bug characterization; desired fixed invariants run in BookmarkReviewInvariantTests"))
    func nonprivatePathCounterexample() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("writable", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(chmod(directory.path, 0o777) == 0)
        let target = directory.appendingPathComponent("saved.html")
        let document = BrowserBookmarkDocument(entries: [.link(title: "Saved", url: address)])
        try BrowserBookmarkFile.write(document, to: target)
        #expect(chmod(target.path, 0o666) == 0)
        #expect(try BrowserBookmarkFile.read(at: target) == document)
        withKnownIssue("R1-P2-PRIVATE: raw I/O has no writable-parent/owner/mode authority validation") {
            #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(at: target) }
        }
        // Explicit replacement intentionally repairs the file's mode. Preserve that assertion.
        try BrowserBookmarkFile.write(document, to: target)
        var info = stat()
        #expect(lstat(target.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }
}
