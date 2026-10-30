import Foundation
import Testing
@testable import BrowserCore

struct SpaceFolderConversionTests {
    private func roundTrip(_ fixture: OrganizationFixture) async throws {
        let document = await fixture.store.sessionDocument()
        let decoded = try JSONDecoder().decode(BrowserSessionDocument.self, from: JSONEncoder().encode(document))
        try decoded.validate()
        let restored = try BrowserStore(restoring: decoded)
        let saved = await restored.sessionDocument()
        #expect(saved.organization == document.organization)
        #expect(saved.spaces == document.spaces)
        let projection = try BrowserSyncMapping.project(session: document, settings: .init())
        let restoredProjection = try BrowserSyncMapping.project(session: saved, settings: .init())
        #expect(projection == restoredProjection)
        // A fresh replica must reconstruct the same structural content through the sync authority.
        var replica = BrowserSyncReplica(device: "conversion-test")
        try replica.capture(projection)
        let materialized = try BrowserSyncMapping.materialize(replica.visible, local: document, settings: .init())
        #expect(materialized.spaces == document.spaces)
        #expect(Set(materialized.organization.folders.map(\.id)) == Set(document.organization.folders.map(\.id)))
        #expect(materialized.organization.tabs.count == document.organization.tabs.count)
        for section in document.organization.spaces {
            #expect(materialized.organization.spaces.first { $0.spaceID == section.spaceID }?.pinned == section.pinned)
        }
        for folder in document.organization.folders {
            #expect(materialized.organization.folders.first { $0.id == folder.id }?.children == folder.children)
        }
    }

    @Test("Export preserves nested pinned and Today content in a collapsed folder and retires the source atomically")
    func exportAndReplay() async throws {
        let f = try await OrganizationFixture.make()
        let pinned = try await f.open("pinned")
        _ = try await f.store.renameTab(pinned, to: "Known title", from: f.context())
        _ = try await f.store.changeTabIcon(pinned, to: .grapheme("★"), from: f.context())
        let (nested, _) = try await f.store.createFolder(title: "Nested", at: .init(.pinned(f.home)), containing: [.tab(pinned)], from: f.context())
        let today = try await f.open("today")
        let selected = try await f.occurrences(of: today).first?.occurrenceID
        try await f.activate(f.leisure)
        let existing = try await f.open("existing")
        try await f.activate(f.home)
        let before = await f.store.sessionDocument()
        let state = try await f.store.exportSpace(f.home, to: f.leisure, from: f.context())
        #expect(state.organization.spaceID == f.leisure)
        #expect(!state.catalog.spaces.contains { $0.id == f.home })
        let folder = try #require(state.organization.pinned.first?.node.folderID.flatMap { state.organization.folder($0) })
        #expect(folder.title == "Home" && folder.isCollapsed)
        #expect(folder.childNodes == [.folder(nested), .tab(today)])
        #expect(state.organization.todayIDs == [existing])
        let shared = try BrowserSyncMapping.project(session: await f.store.sessionDocument(), settings: .init())
        #expect(shared.entries[BrowserSyncMapping.id("space", f.home.rawValue)] == nil)
        #expect(shared.lists[BrowserSyncMapping.id("folder", folder.id.rawValue)] == [BrowserSyncMapping.id("folder", nested.rawValue), BrowserSyncMapping.id("tab", today.rawValue)])
        #expect(shared.entries[BrowserSyncMapping.id("tab", existing.rawValue)] == nil)
        #expect(state.organization.selectedTab?.id == today)
        #expect(state.organization.selectedTab?.occurrenceID == selected)
        #expect(state.organization.tab(pinned)?.customTitle == "Known title")
        #expect(state.organization.tab(pinned)?.customIcon == .grapheme("★"))
        #expect(try await f.store.archivedTabs(from: f.context()).isEmpty)
        try await roundTrip(f)
        let undo = try await f.store.undoOrganization(from: f.context())
        #expect(undo.organization.spaceID == f.home && undo.organization.todayIDs == [today])
        #expect(undo.organization.pinnedNodes == [.folder(nested)])
        #expect(undo.catalog.spaces == before.spaces)
        #expect(undo.organization.selectedTab?.id == today)
        try await roundTrip(f)
        let redo = try await f.store.redoOrganization(from: f.context())
        #expect(redo.organization.pinned.first?.node == .folder(folder.id))
        #expect(redo.organization.selectedTab?.occurrenceID == selected)
        #expect(redo.organization.todayIDs == [existing])
        try await f.validate()
    }

    @Test("Folder promotion retains children, leaves source Today and Favorites, and supports atomic undo and redo")
    func conversionAndReplay() async throws {
        let f = try await OrganizationFixture.make()
        let tab = try await f.open("child")
        let (child, _) = try await f.store.createFolder(title: "Child", at: .init(.pinned(f.home)), containing: [.tab(tab)], from: f.context())
        _ = try await f.store.setFolderCollapsed(child, true, from: f.context())
        let (outer, _) = try await f.store.createFolder(title: "Project", at: .init(.pinned(f.home)), containing: [.folder(child)], from: f.context())
        let today = try await f.open("today")
        let favorite = try await f.open("favorite")
        _ = try await f.store.addToFavorites([favorite], from: f.context())
        let before = await f.store.sessionDocument()
        let converted = try await f.store.convertFolderToSpace(outer, from: f.context())
        let newID = converted.organization.spaceID
        #expect(newID != f.home && converted.catalog.spaces.last?.id == newID)
        #expect(converted.catalog.spaces.last?.name == "Project")
        #expect(converted.organization.pinnedNodes == [.folder(child)])
        #expect(converted.organization.folder(outer) == nil)
        #expect(converted.organization.folder(child)?.isCollapsed == true)
        #expect(converted.organization.today.isEmpty && converted.organization.selectedTab == nil)
        #expect(converted.organization.favoriteIDs == [favorite])
        let source = try #require(await f.store.sessionDocument().organization.spaces.first { $0.spaceID == f.home })
        #expect(source.pinned.isEmpty && source.today == [.tab(today)])
        try await roundTrip(f)
        let undone = try await f.store.undoOrganization(from: f.context())
        #expect(undone.catalog.spaces == before.spaces)
        #expect(undone.organization.spaceID == f.home && undone.organization.pinnedNodes == [.folder(outer)])
        #expect(undone.organization.folder(outer)?.childNodes == [.folder(child)])
        try await roundTrip(f)
        let redone = try await f.store.redoOrganization(from: f.context())
        #expect(redone.organization.spaceID == newID && redone.organization.pinnedNodes == [.folder(child)])
        try await f.validate()
    }

    @Test("Stale contexts and foreign destinations leave the entire document untouched")
    func invalidTargets() async throws {
        let f = try await OrganizationFixture.make()
        let context = try await f.context()
        let before = await f.store.sessionDocument()
        await #expect(throws: BrowserOrganizationError.invalidDestination) { try await f.store.exportSpace(f.home, to: f.lab, from: context) }
        #expect(await f.store.sessionDocument() == before)
        try await f.activate(f.leisure)
        await #expect(throws: BrowserStoreError.staleContext) { try await f.store.convertFolderToSpace(FolderID(), from: context) }
    }

    @Test("Undo refuses to retire a promoted Space after another window adds content")
    func concurrentAddition() async throws {
        let f = try await OrganizationFixture.make()
        let (folder, _) = try await f.store.createFolder(title: "Project", at: .init(.pinned(f.home)), from: f.context())
        let promoted = try await f.store.convertFolderToSpace(folder, from: f.context())
        try await f.activate(promoted.organization.spaceID, in: f.other)
        let added = try await f.open("concurrent", in: f.other)
        let state = try await f.organization()
        #expect(state.undoAction != .convertFolderToSpace)
        #expect(state.todayIDs.contains(added))
        try await f.validate()
    }
}
