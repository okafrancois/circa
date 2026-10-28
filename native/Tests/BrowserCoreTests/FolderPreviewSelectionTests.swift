import Testing
@testable import BrowserCore

@Suite("Folder preview atomic activation")
struct FolderPreviewSelectionTests {
    @Test("Exact organization admission rejects moves, removal, wrong profile and A-B-A without mutation")
    func staleSelection() async throws {
        let fixture = try await OrganizationFixture.make()
        let target = try await fixture.open("target"), active = try await fixture.open("active")
        let expected = try await fixture.organization()
        let unchanged = await fixture.store.sessionDocument()
        let revoked = BrowserSidebarSelectionAdmission()
        revoked.revoke()
        _ = try await fixture.store.selectTab(target, from: fixture.context(), expecting: expected, admission: revoked)
        #expect(await fixture.store.sessionDocument() == unchanged)
        // Reading preview projections never changes selection, occurrences or persistent graph.
        _ = try await fixture.organization()
        #expect(await fixture.store.sessionDocument() == unchanged)
        _ = try await fixture.store.pinTabs([target], from: fixture.context())
        _ = try await fixture.store.unpinTabs([target], from: fixture.context())
        let afterRoundtrip = await fixture.store.sessionDocument()
        await #expect(throws: BrowserOrganizationError.notVisibleInContext) {
            try await fixture.store.selectTab(target, from: fixture.context(), expecting: expected)
        }
        #expect(await fixture.store.sessionDocument() == afterRoundtrip)
        #expect(try await fixture.organization().selectedTab?.id == active)
        let fresh = try await fixture.organization()
        _ = try await fixture.store.selectTab(target, from: fixture.context(), expecting: fresh)
        #expect(try await fixture.organization().selectedTab?.id == target)
        #expect(try await fixture.organization().tab(target)?.lastActiveAt == fixture.clock.now)
        let beforeRemoval = try await fixture.organization()
        _ = try await fixture.store.archiveTabs([target], from: fixture.context())
        let afterRemoval = await fixture.store.sessionDocument()
        await #expect(throws: BrowserOrganizationError.notVisibleInContext) {
            try await fixture.store.selectTab(target, from: fixture.context(), expecting: beforeRemoval)
        }
        #expect(await fixture.store.sessionDocument() == afterRemoval)
        try await fixture.activate(fixture.lab)
        let wrongProfile = await fixture.store.sessionDocument()
        await #expect(throws: BrowserOrganizationError.notVisibleInContext) {
            try await fixture.store.selectTab(target, from: fixture.context(), expecting: fresh)
        }
        #expect(await fixture.store.sessionDocument() == wrongProfile)
    }
}
