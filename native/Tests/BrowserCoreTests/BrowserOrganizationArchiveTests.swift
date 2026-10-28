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
    @Test("Every supported inactivity delay uses the injected clock at its exact boundary",
          arguments: [BrowserAutoArchiveThreshold.twelveHours, .oneDay, .sevenDays, .thirtyDays])
    func supportedThresholdBoundaries(_ threshold: BrowserAutoArchiveThreshold) async throws {
        let f = try await OrganizationFixture.make()
        let old = try await f.open("boundary")
        _ = try await f.open("visible")
        try await f.store.setAutoArchiveThreshold(threshold, forProfile: f.personal)
        f.clock.advance(by: try #require(threshold.interval) - 1)
        #expect(await f.store.archiveExpiredTabs().isEmpty)
        f.clock.advance(by: 1)
        #expect(await f.store.archiveExpiredTabs().map(\.id) == [old])
    }

    @Test("Pinned folders and nested splits remain exempt while Today splits archive together")
    func folderAndSplitRules() async throws {
        let f = try await OrganizationFixture.make()
        let pinned = try await f.open("folder-tab")
        let pa = try await f.open("folder-split-a"), pb = try await f.open("folder-split-b")
        _ = try await f.store.pinTabs([pinned, pa, pb], from: f.context())
        let (pinnedSplit, _) = try await f.store.createSplit([pa, pb], from: f.context())
        let (folder, _) = try await f.store.createFolder(title: "Synthetic folder", at: .init(.pinned(f.home)),
            containing: [.tab(pinned), .split(pinnedSplit)], from: f.context())
        let folderChildren = try #require(try await f.organization().folder(folder)?.childNodes)
        let a = try await f.open("today-split-a"), b = try await f.open("today-split-b")
        _ = try await f.store.createSplit([a, b], from: f.context())
        f.clock.advance(by: 12 * 3600)
        #expect(await f.store.archiveExpiredTabs().isEmpty) // Both visible panes are protected.
        _ = try await f.open("visible")
        f.clock.advance(by: 12 * 3600)
        #expect(await f.store.archiveExpiredTabs(protecting: [a]).isEmpty)
        #expect(Set(await f.store.archiveExpiredTabs().map(\.id)) == [a, b])
        #expect(try await f.organization().folder(folder)?.childNodes == folderChildren)
        try await f.validate()
    }

    @Test("Settings are profile scoped across Spaces, and applying to all replaces every override")
    func allProfilesSetting() async throws {
        let f = try await OrganizationFixture.make()
        #expect(await f.store.archivePolicy().defaultThreshold == .twelveHours)
        try await f.store.setAutoArchiveThreshold(.oneDay, forProfile: f.personal)
        #expect(try await f.organization().autoArchiveThreshold == .oneDay)
        try await f.activate(f.leisure)
        #expect(try await f.organization().autoArchiveThreshold == .oneDay)
        try await f.activate(f.lab)
        #expect(try await f.organization().autoArchiveThreshold == .twelveHours)
        try await f.store.setAutoArchiveThreshold(.sevenDays, forProfile: f.work)
        try await f.store.setAutoArchiveThresholdForAllProfiles(.thirtyDays, fromProfile: f.personal)
        let policy = await f.store.archivePolicy()
        #expect(policy.profileThresholds.isEmpty)
        #expect(policy.threshold(for: f.personal) == .thirtyDays && policy.threshold(for: f.work) == .thirtyDays)
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(await f.store.sessionDocument().encoded()))
        #expect(await restored.archivePolicy() == policy)
        await #expect(throws: BrowserStoreError.profileMissing) {
            try await f.store.setAutoArchiveThresholdForAllProfiles(.oneDay, fromProfile: ProfileID())
        }
        #expect(await f.store.archivePolicy() == policy)
        try await f.validate()
    }

    @Test("Background navigation and title changes do not count as viewing a tab")
    func backgroundMetadataDoesNotResetIdle() async throws {
        let f = try await OrganizationFixture.make()
        let id = try await f.open("metadata")
        let occurrence = try #require(await f.occurrences(of: id).first)
        _ = try await f.open("visible")
        f.clock.advance(by: 12 * 3600 - 1)
        let authority = try await f.store.captureOccurrenceAuthority(for: occurrence.occurrenceID, from: f.context())
        _ = try await f.store.updateDestination(to: organizationURL("redirected"), from: authority)
        _ = try await f.store.updatePageTitle("Synthetic title", from: authority)
        _ = try await f.store.renameTab(id, to: "Synthetic custom title", from: f.context())
        f.clock.advance(by: 1)
        let record = try #require(await f.store.archiveExpiredTabs().first)
        #expect(record.id == id && record.tab.url == organizationURL("redirected"))
        #expect(record.tab.pageTitle == "Synthetic title" && record.tab.customTitle == "Synthetic custom title")
        #expect(record.spaceID == f.home && record.profileID == f.personal && record.archivedAt == f.clock.now)
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(await f.store.sessionDocument().encoded()))
        #expect(await restored.sessionDocument().organization.archive == [record])
    }

}
