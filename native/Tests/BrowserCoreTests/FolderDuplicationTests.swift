import Foundation
import Testing
@testable import BrowserCore

struct FolderDuplicationTests {
    @Test("Nested folder duplication preserves order and metadata with fresh identities, persistence and undo")
    func deepCopy() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("first"), b = try await f.open("second"), c = try await f.open("third")
        let (outer, _) = try await f.store.createFolder(title: "Outer", at: .init(.pinned(f.home)), containing: [.tab(a)], from: f.context())
        let (inner, _) = try await f.store.createFolder(title: "Inner", at: .init(.folder(outer)), containing: [.tab(b), .tab(c)], from: f.context())
        _ = try await f.store.renameTab(a, to: "Custom [title] | value", from: f.context())
        _ = try await f.store.setFolderCollapsed(inner, true, from: f.context())
        let (split, _) = try await f.store.createSplit([b, c], from: f.context())
        let before = try await f.organization()
        let (copy, _) = try await f.store.duplicateFolder(outer, from: f.context())
        let after = try await f.organization()
        #expect(after.pinnedNodes == [.folder(outer), .folder(copy)])
        let original = try #require(before.folder(outer)), duplicate = try #require(after.folder(copy))
        #expect(original.title == duplicate.title)
        let copiedInnerID = try #require(duplicate.childNodes.last?.folderID)
        let copiedInner = try #require(after.folder(copiedInnerID))
        #expect(copiedInnerID != inner && copiedInner.isCollapsed)
        let copiedSplit = try #require(copiedInner.childNodes.first?.splitID)
        #expect(copiedSplit != split)
        let newTabs = after.allTabs.filter { !before.allTabs.map(\.id).contains($0.id) }
        #expect(newTabs.count == 3 && Set(newTabs.map(\.id)).count == 3)
        #expect(newTabs.allSatisfy { !$0.isLoadedInThisWindow })
        #expect(newTabs.map(\.url) == before.allTabs.map(\.url))
        #expect(newTabs.first?.title == before.tab(a)?.title)
        let document = await f.store.sessionDocument()
        try document.validate()
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(document.encoded()))
        #expect(try await restored.organizationSnapshot(from: restored.captureContext(in: f.window)).folder(copy)?.childNodes == duplicate.childNodes)
        _ = try await f.store.undoOrganization(from: f.context())
        #expect(try await f.organization().pinnedNodes == before.pinnedNodes)
        #expect(try await f.organization().allTabs.map(\.id) == before.allTabs.map(\.id))
        _ = try await f.store.redoOrganization(from: f.context())
        #expect(try await f.organization().folder(copy)?.childNodes == duplicate.childNodes)
        try await f.validate()
    }
}
