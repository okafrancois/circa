import Foundation
import Testing
@testable import BrowserCore

@Suite("Bookmarks in the existing organization")
struct BrowserBookmarkStoreTests {
    private var document: BrowserBookmarkDocument {
        .init(entries: [.folder(title: "Research", children: [
            .link(title: "Reference", url: URL(string: "https://bookmark.test/reference")!),
            .folder(title: "Empty", children: [])
        ]), .link(title: "Second", url: URL(string: "https://bookmark.test/second")!)])
    }

    @Test("Import creates dormant pinned links atomically without changing selection, other Spaces or profiles")
    func atomicImport() async throws {
        let fixture = try await OrganizationFixture.make()
        let active = try await fixture.open("unchanged")
        try await fixture.activate(fixture.leisure, in: fixture.other)
        _ = try await fixture.store.createFolder(title: "Existing leisure folder", at: .init(.pinned(fixture.leisure)),
                                                from: fixture.context(fixture.other))
        try await fixture.activate(fixture.lab, in: fixture.other)
        _ = try await fixture.store.createFolder(title: "Existing foreign folder", at: .init(.pinned(fixture.lab)),
                                                from: fixture.context(fixture.other))
        let before = await fixture.store.sessionDocument()
        let (folder, _) = try await fixture.store.importBookmarks(document, folderTitle: "Imported", from: fixture.context())
        let after = await fixture.store.sessionDocument()
        let snapshot = try await fixture.organization()
        #expect(after.tabs == before.tabs)
        #expect(after.windows == before.windows)
        #expect(snapshot.tab(active)?.isSelected == true)
        #expect(snapshot.undoAction == .importBookmarks)
        #expect(after.organization.folders.contains { $0.id == folder && $0.title == "Imported" })
        #expect(after.organization.tabs.filter { $0.pinnedURL?.host == "bookmark.test" }.count == 2)
        #expect(after.organization.spaces.first { $0.spaceID == fixture.leisure } ==
                before.organization.spaces.first { $0.spaceID == fixture.leisure })
        #expect(after.organization.spaces.first { $0.spaceID == fixture.lab } ==
                before.organization.spaces.first { $0.spaceID == fixture.lab })
        try await fixture.validate()
    }

    @Test("One undo removes the whole imported hierarchy; redo and restart preserve order and home URLs")
    func undoRedoAndRestart() async throws {
        let fixture = try await OrganizationFixture.make()
        _ = try await fixture.store.importBookmarks(document, folderTitle: "Imported", from: fixture.context())
        let saved = await fixture.store.sessionDocument()
        _ = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(try await fixture.organization().pinned.isEmpty)
        _ = try await fixture.store.redoOrganization(from: fixture.context())
        let redone = await fixture.store.sessionDocument()
        #expect(redone.organization == saved.organization)
        let restored = try BrowserStore(restoring: redone)
        let newContext = try await restored.captureContext(in: fixture.window)
        let exported = try await restored.exportBookmarks(from: newContext)
        #expect(exported.linkCount == 2)
        #expect(exported.entries == [.folder(title: "Home", children: [.folder(title: "Imported", children: document.entries)])])
    }

    @Test("Export uses saved home URLs and custom titles, includes same-profile Spaces, excludes Today and foreign profiles")
    func exportIsolationAndHomeURL() async throws {
        let fixture = try await OrganizationFixture.make()
        let pinned = try await fixture.open("saved")
        _ = try await fixture.store.pinTabs([pinned], from: fixture.context())
        _ = try await fixture.store.renameTab(pinned, to: "Kept custom title", from: fixture.context())
        let snapshot = try await fixture.organization()
        let occurrence = try #require(snapshot.tab(pinned)?.occurrenceID)
        try await fixture.store.updateDestination(for: occurrence, to: organizationURL("away"), from: fixture.context())
        _ = try await fixture.open("today-only")
        try await fixture.activate(fixture.lab, in: fixture.other)
        let foreign = try await fixture.open("foreign", in: fixture.other)
        _ = try await fixture.store.pinTabs([foreign], from: fixture.context(fixture.other))
        let exported = try await fixture.store.exportBookmarks(from: fixture.context())
        #expect(exported.entries == [.folder(title: "Home", children: [.link(title: "Kept custom title",
                                                                               url: organizationURL("saved"))])])
        #expect(exported.linkCount == 1 && exported.skippedLinkCount == 0)
    }

    @Test("A stale context and an invalid portable document refuse without changing any organization bytes")
    func staleAndInvalidRefuse() async throws {
        let fixture = try await OrganizationFixture.make()
        let stale = try await fixture.context()
        try await fixture.activate(fixture.leisure)
        let before = await fixture.store.sessionDocument()
        await #expect(throws: BrowserStoreError.staleContext) {
            try await fixture.store.importBookmarks(document, folderTitle: "Wrong target", from: stale)
        }
        await #expect(throws: BrowserStoreError.staleContext) { try await fixture.store.exportBookmarks(from: stale) }
        let unsafe = BrowserBookmarkDocument(entries: [.link(title: "Refused", url: URL(string: "javascript:alert(1)")!)])
        await #expect(throws: BrowserBookmarkTransferError.invalidURL) {
            try await fixture.store.importBookmarks(unsafe, folderTitle: "Refused", from: fixture.context())
        }
        #expect(await fixture.store.sessionDocument() == before)
    }
}
