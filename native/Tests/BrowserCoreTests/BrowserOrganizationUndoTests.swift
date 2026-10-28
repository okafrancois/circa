import Foundation
import Testing
@testable import BrowserCore

@Suite("Organization undo and redo")
struct BrowserOrganizationUndoTests {
    @Test("Undo and redo restore exact order, sections and pinned URLs")
    func undoRedoPin() async throws {
        let fixture = try await OrganizationFixture.make()
        let a = try await fixture.open("a")
        let b = try await fixture.open("b")
        let c = try await fixture.open("c")
        let before = try await fixture.organization()
        _ = try await fixture.store.pinTabs([b], from: fixture.context())
        let pinned = try await fixture.organization()
        var state = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(state.organization.today == before.today && state.organization.pinned == before.pinned)
        #expect(state.organization.redoAction == .pinTabs && state.organization.undoAction == nil)
        state = try await fixture.store.redoOrganization(from: fixture.context())
        // folder-preview-implementation-r1-2026-10-26.md: replay publishes a fresh ownership revision.
        #expect(state.organization.organizationRevision > pinned.organizationRevision)
        var replayed = state.organization
        replayed.organizationRevision = pinned.organizationRevision
        #expect(replayed == pinned)
        #expect(state.organization.todayIDs == [c, a] && state.organization.pinnedNodes == [.tab(b)])
        await #expect(throws: BrowserOrganizationError.nothingToRedo) {
            try await fixture.store.redoOrganization(from: fixture.context())
        }
        try await fixture.validate()
    }

    @Test("Undoing a close restores the tab, reopens it in the window and selects it again")
    func undoCloseReopensAndSelects() async throws {
        let fixture = try await OrganizationFixture.make()
        let first = try await fixture.open("first")
        let closed = try await fixture.open("closed")
        _ = try await fixture.open("last", activate: false)
        _ = try await fixture.store.renameTab(closed, to: "Kept name", from: fixture.context())
        let selected = try #require(await fixture.occurrences(of: closed).first)
        try await fixture.store.closeOccurrence(selected.occurrenceID, from: fixture.context())
        #expect(try await fixture.organization().undoAction == .closeTabs)
        let state = try await fixture.store.undoOrganization(from: fixture.context())
        let restored = try #require(state.organization.selectedTab)
        #expect(restored.id == closed && restored.customTitle == "Kept name")
        #expect(restored.url == organizationURL("closed"))
        #expect(state.organization.todayIDs.contains(closed) && state.organization.todayIDs.contains(first))
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).isEmpty)
        let redone = try await fixture.store.redoOrganization(from: fixture.context())
        #expect(!redone.organization.todayIDs.contains(closed))
        #expect(redone.snapshot.tabs.allSatisfy { $0.id != closed })
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).map(\.id) == [closed])
        try await fixture.validate()
    }

    @Test("Undo restores a selection the command displaced and never steals a later one")
    func undoSelectionScope() async throws {
        let fixture = try await OrganizationFixture.make()
        let a = try await fixture.open("a")
        let b = try await fixture.open("b")
        _ = try await fixture.store.moveItems([.tab(b)], to: .init(.today(fixture.leisure)), from: fixture.context())
        #expect(try await fixture.organization().selectedTab?.id == a)
        var state = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(state.organization.selectedTab?.id == b && state.organization.todayIDs == [b, a])

        // Pinning the visible tab does not displace it, so undo leaves a later selection alone.
        _ = try await fixture.store.selectTab(a, from: fixture.context())
        _ = try await fixture.store.pinTabs([a], from: fixture.context())
        _ = try await fixture.store.selectTab(b, from: fixture.context())
        state = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(state.organization.selectedTab?.id == b && state.organization.pinned.isEmpty)
        try await fixture.validate()
    }

    @Test("Undoing a batch move restores parents and order across folders and Spaces")
    func undoBatchMoveAcrossContainers() async throws {
        let fixture = try await OrganizationFixture.make()
        let a = try await fixture.open("a")
        let b = try await fixture.open("b")
        let c = try await fixture.open("c")
        let d = try await fixture.open("d")
        let (folder, _) = try await fixture.store.createFolder(title: "Group", at: .init(.pinned(fixture.home)),
            containing: [.tab(b), .tab(c)], from: fixture.context())
        let before = await fixture.store.sessionDocument().organization
        _ = try await fixture.store.moveItems([.tab(a), .tab(c), .tab(d)], to: .init(.today(fixture.leisure)),
                                              from: fixture.context())
        #expect(try await fixture.organization().folder(folder)?.childNodes == [.tab(b)])
        _ = try await fixture.store.undoOrganization(from: fixture.context())
        let after = await fixture.store.sessionDocument().organization
        #expect(after.spaces == before.spaces && after.folders == before.folders)
        #expect(after.tabs.map(\.pinnedURL) == before.tabs.map(\.pinnedURL))
        #expect(await fixture.occurrences(of: d).first?.spaceID == fixture.home)
        _ = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(try await fixture.organization().todayIDs == [d, c, b, a])
        try await fixture.validate()
    }

    @Test("Undoing folder deletion restores the folder, its nested children and archived contents")
    func undoFolderDeletion() async throws {
        let fixture = try await OrganizationFixture.make()
        let a = try await fixture.open("a")
        let b = try await fixture.open("b")
        let c = try await fixture.open("c")
        let (outer, _) = try await fixture.store.createFolder(title: "Outer", at: .init(.pinned(fixture.home)),
            containing: [.tab(a)], from: fixture.context())
        let (inner, _) = try await fixture.store.createFolder(title: "Inner", at: .init(.folder(outer)),
            containing: [.tab(b), .tab(c)], from: fixture.context())
        let original = try await fixture.organization()
        _ = try await fixture.store.deleteFolder(outer, contents: .keepContents, from: fixture.context())
        #expect(try await fixture.organization().pinnedNodes == [.tab(a), .folder(inner)])
        _ = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(try await fixture.organization().pinned == original.pinned)
        _ = try await fixture.store.deleteFolder(outer, contents: .archiveContents, from: fixture.context())
        #expect(try await fixture.organization().pinned.isEmpty)
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).count == 3)
        _ = try await fixture.store.undoOrganization(from: fixture.context())
        let restored = try await fixture.organization()
        #expect(restored.pinned.map(\.node) == original.pinned.map(\.node))
        #expect(restored.folder(inner)?.childNodes == original.folder(inner)?.childNodes)
        #expect(Set(restored.folder(inner)?.childNodes ?? []) == [.tab(b), .tab(c)])
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).isEmpty)
        try await fixture.validate()
    }

    @Test("Renames of tabs and folders undo to their exact previous titles")
    func undoRenames() async throws {
        let fixture = try await OrganizationFixture.make()
        let tab = try await fixture.open("tab")
        let (folder, _) = try await fixture.store.createFolder(title: "Before", at: .init(.pinned(fixture.home)),
                                                               from: fixture.context())
        _ = try await fixture.store.renameTab(tab, to: "One", from: fixture.context())
        _ = try await fixture.store.renameTab(tab, to: "Two", from: fixture.context())
        _ = try await fixture.store.renameFolder(folder, to: "After", from: fixture.context())
        _ = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(try await fixture.organization().folder(folder)?.title == "Before")
        _ = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(try await fixture.organization().tab(tab)?.customTitle == "One")
        _ = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(try await fixture.organization().tab(tab)?.customTitle == nil)
    }

    @Test("Unrelated concurrent insertions do not block undo; conflicting edits discard the record untouched")
    func undoConflicts() async throws {
        let fixture = try await OrganizationFixture.make()
        let a = try await fixture.open("a")
        let b = try await fixture.open("b")
        _ = try await fixture.store.pinTabs([a], from: fixture.context())
        let popup = try await fixture.open("popup", in: fixture.other)
        _ = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(try await fixture.organization().todayIDs == [popup, b, a])

        _ = try await fixture.store.pinTabs([b], from: fixture.context())
        _ = try await fixture.store.unpinTabs([b], from: fixture.context(fixture.other))
        let before = try await fixture.store.sessionDocument().encoded()
        await #expect(throws: BrowserOrganizationError.undoConflict) {
            try await fixture.store.undoOrganization(from: fixture.context())
        }
        #expect(try await fixture.store.sessionDocument().encoded() == before)
        // The conflicting record was discarded rather than left blocking the journal.
        #expect(try await fixture.organization().undoAction == nil)
        try await fixture.validate()
    }

    @Test("Undo belongs to the issuing window and profile; a new command clears redo")
    func undoScopes() async throws {
        let fixture = try await OrganizationFixture.make()
        let a = try await fixture.open("a")
        let b = try await fixture.open("b")
        _ = try await fixture.store.pinTabs([a], from: fixture.context())
        await #expect(throws: BrowserOrganizationError.nothingToUndo) {
            try await fixture.store.undoOrganization(from: fixture.context(fixture.other))
        }
        #expect(try await fixture.organization(fixture.other).undoAction == nil)
        try await fixture.activate(fixture.lab)
        #expect(try await fixture.organization().undoAction == nil)
        await #expect(throws: BrowserOrganizationError.nothingToUndo) {
            try await fixture.store.undoOrganization(from: fixture.context())
        }
        try await fixture.activate(fixture.leisure)
        #expect(try await fixture.organization().undoAction == .pinTabs)
        try await fixture.activate(fixture.home)
        _ = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(try await fixture.organization().redoAction == .pinTabs)
        _ = try await fixture.store.pinTabs([b], from: fixture.context())
        #expect(try await fixture.organization().redoAction == nil)
        // Saving does not consume the journal.
        _ = try await fixture.store.sessionDocument().encoded()
        #expect(try await fixture.organization().undoAction == .pinTabs)
        // Closing the window drops its journal.
        try await fixture.store.closeWindow(fixture.window)
        let window = try await fixture.store.createWindow(activeSpaceID: fixture.home)
        #expect(try await fixture.store.organizationSnapshot(from: fixture.store.captureContext(in: window)).undoAction == nil)
    }

    @Test("Undo restores a closed Favorite reopened in the Space where it was closed")
    func undoArchiveOfFavorite() async throws {
        let fixture = try await OrganizationFixture.make()
        let mail = try await fixture.open("mail")
        _ = try await fixture.store.addToFavorites([mail], from: fixture.context())
        _ = try await fixture.store.archiveTabs([mail], from: fixture.context())
        let record = try #require(try await fixture.store.archivedTabs(from: fixture.context()).first)
        #expect(record.origin == .favorites && record.reason == .removed)
        let state = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(state.organization.favoriteIDs == [mail])
        #expect(state.organization.selectedTab?.id == mail)
        #expect(state.organization.tab(mail)?.pinnedURL == organizationURL("mail"))
        try await fixture.validate()
    }
}
