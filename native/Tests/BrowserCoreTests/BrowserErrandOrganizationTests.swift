import Foundation
import Testing
@testable import BrowserCore

struct BrowserErrandOrganizationTests {
    @Test func revokedStartAndOpenCannotMutateOrganization() async throws {
        let f = try await OrganizationFixture.make()
        let selected = try await f.open("task"), unrelated = try await f.open("unrelated")
        let context = try await f.context()
        let current = try await f.organization().selectedTab!.id
        let admission = BrowserSidebarSelectionAdmission(); admission.revoke()
        await #expect(throws: BrowserStoreError.staleContext) {
            try await f.store.createErrandFolder(title: "Task", tab: current, from: context, admission: admission)
        }
        #expect(await f.store.sessionDocument().organization.folders.isEmpty)
        let allowed = BrowserSidebarSelectionAdmission()
        let (folder, _) = try await f.store.createErrandFolder(title: "Task", tab: current, from: f.context(), admission: allowed)
        let grouped = try await f.organization()
        guard case .folder(let item)? = grouped.item(for: .folder(folder)) else { Issue.record("No task folder"); return }
        #expect(item.children.map(\.node) == [.tab(current)])
        let other = current == selected ? unrelated : selected
        #expect(grouped.tab(other)?.section == .today(grouped.spaceID))
        let before = await f.store.sessionDocument()
        await #expect(throws: BrowserStoreError.staleContext) {
            try await f.store.openErrandTab(url: URL(string: "https://example.test/new")!, folder: folder, expectedTabs: [current], from: f.context(), admission: admission)
        }
        #expect(await f.store.sessionDocument() == before)
        let (created, _) = try await f.store.openErrandTab(url: URL(string: "https://example.test/new")!, folder: folder, expectedTabs: [current], from: f.context(), admission: allowed)
        let after = try await f.organization()
        guard case .folder(let updated)? = after.item(for: .folder(folder)) else { Issue.record("No task folder"); return }
        #expect(Set(updated.children.compactMap { $0.node.tabID }) == [current, created.id])
        #expect(after.tab(other)?.section == .today(after.spaceID))
    }
}
