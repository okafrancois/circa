import Foundation
import Testing
@testable import BrowserCore

@Suite("Archive and auto-archive")
struct BrowserOrganizationArchiveTests {
    @Test("Auto-archive uses time since last view, exact thresholds, and exempts Favorites, Pinned and visible tabs")
    func autoArchiveThresholds() async throws {
        let fixture = try await OrganizationFixture.make()
        let old = try await fixture.open("old")
        let pinned = try await fixture.open("pinned")
        let favorite = try await fixture.open("favorite")
        let visible = try await fixture.open("visible")
        _ = try await fixture.store.pinTabs([pinned], from: fixture.context())
        _ = try await fixture.store.addToFavorites([favorite], from: fixture.context())
        fixture.clock.advance(by: 12 * 3600 - 1)
        #expect(await fixture.store.archiveExpiredTabs().isEmpty)
        fixture.clock.advance(by: 1)
        let archived = await fixture.store.archiveExpiredTabs()
        #expect(archived.map(\.id) == [old])
        #expect(archived.first?.reason == .automatic && archived.first?.archivedAt == fixture.clock.now)
        fixture.clock.advance(by: 30 * 24 * 3600)
        #expect(await fixture.store.archiveExpiredTabs().isEmpty)
        let snapshot = try await fixture.organization()
        #expect(snapshot.todayIDs == [visible] && snapshot.pinnedNodes == [.tab(pinned)])
        #expect(snapshot.favoriteIDs == [favorite])
        try await fixture.validate()
    }

    @Test("Viewing a tab restarts its inactivity clock when it stops being visible")
    func viewingRestartsClock() async throws {
        let fixture = try await OrganizationFixture.make()
        let first = try await fixture.open("first")
        fixture.clock.advance(by: 11 * 3600)
        _ = try await fixture.store.selectTab(first, from: fixture.context())
        fixture.clock.advance(by: 3600)
        _ = try await fixture.open("second")
        fixture.clock.advance(by: 11 * 3600)
        #expect(await fixture.store.archiveExpiredTabs().isEmpty)
        fixture.clock.advance(by: 3600)
        #expect(await fixture.store.archiveExpiredTabs().map(\.id) == [first])
    }

    @Test("Profile overrides, the global default, never, and shell protection are honored")
    func archivePolicies() async throws {
        let fixture = try await OrganizationFixture.make()
        let home = try await fixture.open("home")
        let media = try await fixture.open("media")
        try await fixture.activate(fixture.lab, in: fixture.other)
        let lab = try await fixture.open("lab", in: fixture.other)
        _ = try await fixture.open("lab-visible", in: fixture.other)
        _ = try await fixture.open("home-visible")
        let minute = try BrowserAutoArchiveThreshold.after(60)
        try await fixture.store.setAutoArchiveThreshold(.never, forProfile: fixture.work)
        try await fixture.store.setDefaultAutoArchiveThreshold(minute)
        fixture.clock.advance(by: 60)
        #expect(await fixture.store.archiveExpiredTabs(protecting: [media]).map(\.id) == [home])
        try await fixture.store.setAutoArchiveThreshold(nil, forProfile: fixture.work)
        #expect(await fixture.store.archiveExpiredTabs(protecting: [media]).map(\.id) == [lab])
        #expect(await fixture.store.archivePolicy().threshold(for: fixture.work) == minute)
        #expect(throws: BrowserOrganizationError.invalidThreshold) { try BrowserAutoArchiveThreshold.after(0) }
        #expect(throws: BrowserOrganizationError.invalidThreshold) { try BrowserAutoArchiveThreshold.after(.infinity) }
        await #expect(throws: BrowserStoreError.profileMissing) {
            try await fixture.store.setAutoArchiveThreshold(.oneDay, forProfile: ProfileID())
        }
        try await fixture.validate()
    }

    @Test("Inactivity persists across relaunch and a sweep after relaunch archives overdue tabs")
    func archiveAfterRelaunch() async throws {
        let fixture = try await OrganizationFixture.make()
        let stale = try await fixture.open("stale")
        _ = try await fixture.open("visible")
        let encoded = try await fixture.store.sessionDocument().encoded()
        let clock = ManualClock(fixture.clock.now.addingTimeInterval(13 * 3600))
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(encoded), clock: { clock.now })
        #expect(await restored.archiveExpiredTabs().map(\.id) == [stale])
    }

    @Test("Restoration returns the exact tab to the top of Today in its Space, and can activate it")
    func restoreToOriginalSpace() async throws {
        let fixture = try await OrganizationFixture.make()
        let keep = try await fixture.open("keep")
        let tab = try await fixture.open("restore")
        _ = try await fixture.store.renameTab(tab, to: "Named", from: fixture.context())
        let occurrence = try #require(await fixture.occurrences(of: tab).first)
        try await fixture.store.updateDestination(for: occurrence.occurrenceID, to: organizationURL("restore/page"),
                                                  from: fixture.context())
        _ = try await fixture.store.closeTabs([tab], from: fixture.context())
        try await fixture.activate(fixture.leisure)
        var state = try await fixture.store.restoreArchivedTab(tab, activate: false, from: fixture.context())
        #expect(state.organization.today.isEmpty)
        try await fixture.activate(fixture.home)
        var snapshot = try await fixture.organization()
        #expect(snapshot.todayIDs == [tab, keep])
        #expect(snapshot.tab(tab)?.customTitle == "Named" && snapshot.tab(tab)?.url == organizationURL("restore/page"))
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).isEmpty)

        _ = try await fixture.store.archiveTabs([tab], from: fixture.context())
        try await fixture.activate(fixture.leisure)
        state = try await fixture.store.restoreArchivedTab(tab, activate: true, from: fixture.context())
        #expect(state.context.spaceID == fixture.home)
        snapshot = state.organization
        #expect(snapshot.selectedTab?.id == tab && snapshot.selectedTab?.url == organizationURL("restore/page"))
        try await fixture.validate()
    }

    @Test("Archive listing, search, restoration and deletion never cross profiles")
    func archiveProfileBoundary() async throws {
        let fixture = try await OrganizationFixture.make()
        let personal = try await fixture.open("personal-recipe")
        _ = try await fixture.store.renameTab(personal, to: "Crème brûlée", from: fixture.context())
        _ = try await fixture.store.closeTabs([personal], from: fixture.context())
        try await fixture.activate(fixture.lab, in: fixture.other)
        let work = try await fixture.open("work-report", in: fixture.other)
        _ = try await fixture.store.closeTabs([work], from: fixture.context(fixture.other))
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).map(\.id) == [personal])
        #expect(try await fixture.store.archivedTabs(from: fixture.context(fixture.other)).map(\.id) == [work])
        #expect(try await fixture.store.archivedTabs(from: fixture.context(), matching: "CREME").map(\.id) == [personal])
        #expect(try await fixture.store.archivedTabs(from: fixture.context(), matching: "report").isEmpty)
        #expect(try await fixture.organization().archivedTabCount == 1)
        await #expect(throws: BrowserOrganizationError.notVisibleInContext) {
            try await fixture.store.restoreArchivedTab(work, activate: true, from: fixture.context())
        }
        await #expect(throws: BrowserOrganizationError.notVisibleInContext) {
            try await fixture.store.deleteArchivedTabs([work], from: fixture.context())
        }
        _ = try await fixture.store.clearArchive(from: fixture.context())
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).isEmpty)
        #expect(try await fixture.store.archivedTabs(from: fixture.context(fixture.other)).map(\.id) == [work])
        await #expect(throws: BrowserOrganizationError.archivedTabMissing) {
            try await fixture.store.restoreArchivedTab(personal, activate: false, from: fixture.context())
        }
    }

    @Test("Clear Today archives every unprotected Today tab of the Space only")
    func clearTodayRespectsProtection() async throws {
        let fixture = try await OrganizationFixture.make()
        let a = try await fixture.open("a")
        let media = try await fixture.open("media")
        let pinned = try await fixture.open("pinned")
        _ = try await fixture.store.pinTabs([pinned], from: fixture.context())
        try await fixture.activate(fixture.leisure, in: fixture.other)
        let elsewhere = try await fixture.open("elsewhere", in: fixture.other)
        let state = try await fixture.store.clearTodayTabs(protecting: [media], from: fixture.context())
        #expect(state.organization.todayIDs == [media] && state.organization.pinnedNodes == [.tab(pinned)])
        let archived = try await fixture.store.archivedTabs(from: fixture.context())
        #expect(archived.map(\.id) == [a] && archived[0].reason == .cleared)
        #expect(try await fixture.organization(fixture.other).todayIDs == [elsewhere])
    }

    @Test("Restore Last Closed Tab uses the newest manual archive and skips automatic ones")
    func restoreMostRecent() async throws {
        let fixture = try await OrganizationFixture.make()
        let closed = try await fixture.open("closed")
        let automatic = try await fixture.open("automatic")
        _ = try await fixture.open("visible")
        _ = try await fixture.store.closeTabs([closed], from: fixture.context())
        fixture.clock.advance(by: 13 * 3600)
        #expect(await fixture.store.archiveExpiredTabs().map(\.id) == [automatic])
        let state = try await fixture.store.restoreMostRecentArchivedTab(from: fixture.context())
        #expect(state.organization.selectedTab?.id == closed)
        await #expect(throws: BrowserOrganizationError.archivedTabMissing) {
            try await fixture.store.restoreMostRecentArchivedTab(from: fixture.context())
        }
    }

    @Test("The archive is capped, oldest first, and lowering the cap purges immediately")
    func archiveCap() async throws {
        let fixture = try await OrganizationFixture.make()
        try await fixture.store.setMaximumArchivedTabs(2)
        var ids: [TabID] = []
        for index in 0..<3 {
            let id = try await fixture.open("capped\(index)")
            fixture.clock.advance(by: 1)
            _ = try await fixture.store.closeTabs([id], from: fixture.context())
            ids.append(id)
        }
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).map(\.id) == [ids[2], ids[1]])
        try await fixture.store.setMaximumArchivedTabs(1)
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).map(\.id) == [ids[2]])
        try await fixture.validate()
    }
}
