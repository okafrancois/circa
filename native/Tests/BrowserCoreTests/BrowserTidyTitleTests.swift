import Foundation
import Testing
@testable import BrowserCore

@Suite("Pinned title compare and apply")
struct BrowserTidyTitleTests {
    @Test func generatedMarkerPersistsAndUndoRestoresIt() async throws {
        let f = try await OrganizationFixture.make()
        let id = try await f.open("synthetic-page")
        _ = try await f.store.pinTabs([id], from: f.context())
        let snapshot = try await f.organization()
        let tab = try #require(snapshot.allTabs.first { $0.id == id })
        _ = try await f.store.tidyPinnedTitle(tab, revision: snapshot.organizationRevision, to: "Notes", from: f.context())
        let document = await f.store.sessionDocument()
        let decoded = try JSONDecoder().decode(BrowserSessionDocument.self, from: JSONEncoder().encode(document))
        #expect(decoded.organization.tabs.first { $0.id == id }?.tidiedTitle == "Notes")
        _ = try await f.store.renameTab(id, to: "Manual", from: f.context())
        #expect(try await f.organization().allTabs.first { $0.id == id }?.tidiedTitle == nil)
        _ = try await f.store.undoOrganization(from: f.context())
        #expect(try await f.organization().allTabs.first { $0.id == id }?.tidiedTitle == "Notes")
        _ = try await f.store.undoOrganization(from: f.context())
        #expect(try await f.organization().allTabs.first { $0.id == id }?.customTitle == nil)
    }
    @Test func titleEditsAndRepinRevokeLease() async throws {
        let f = try await OrganizationFixture.make()
        let id = try await f.open("long-synthetic-title")
        _ = try await f.store.pinTabs([id], from: f.context())
        let snapshot = try await f.organization()
        let tab = try #require(snapshot.allTabs.first { $0.id == id })
        _ = try await f.store.renameTab(id, to: "My title", from: f.context())
        await #expect(throws: BrowserStoreError.staleContext) {
            try await f.store.tidyPinnedTitle(tab, revision: snapshot.organizationRevision, to: "Generated", from: f.context())
        }
        #expect(try await f.organization().allTabs.first { $0.id == id }?.customTitle == "My title")
        let current = try await f.organization()
        let renamed = try #require(current.allTabs.first { $0.id == id })
        _ = try await f.store.tidyPinnedTitle(renamed, revision: current.organizationRevision, to: nil, from: f.context())
        #expect(try await f.organization().allTabs.first { $0.id == id }?.customTitle == nil)
        let before = try await f.organization()
        let candidate = try #require(before.allTabs.first { $0.id == id })
        _ = try await f.store.unpinTabs([id], from: f.context())
        _ = try await f.store.pinTabs([id], from: f.context())
        await #expect(throws: BrowserStoreError.staleContext) {
            try await f.store.tidyPinnedTitle(candidate, revision: before.organizationRevision, to: "Late", from: f.context())
        }
    }
}
