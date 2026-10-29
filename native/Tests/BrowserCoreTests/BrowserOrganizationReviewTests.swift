import Foundation
import Testing
@testable import BrowserCore

/// Regression tests for the ORG-R2 cross-review findings. Every scenario uses synthetic data.
@Suite("Organization review fixes (ORG-R2)")
struct BrowserOrganizationReviewTests {
    @Test("Automatic archive fallback stays reversible until another window explicitly selects it",
          arguments: [false, true])
    func fallbackSelectionAndReplayOwnership(claimFallback: Bool) async throws {
        let fixture = try await OrganizationFixture.make()
        let restored = try await fixture.open("restored")
        _ = try await fixture.store.archiveTabs([restored], from: fixture.context())
        _ = try await fixture.store.restoreArchivedTab(restored, activate: false, from: fixture.context())
        let temporary = try await fixture.open("temporary", in: fixture.other)
        _ = try await fixture.store.closeTabs([temporary], from: fixture.context(fixture.other))
        #expect(try await fixture.organization(fixture.other).selectedTab?.id == restored)
        if claimFallback {
            // Selecting the already visible fallback is an explicit claim too.
            _ = try await fixture.store.selectTab(restored, from: fixture.context(fixture.other))
            #expect(try await fixture.organization().undoAction == nil)
        } else {
            for _ in 0..<2 {
                _ = try await fixture.store.undoOrganization(from: fixture.context())
                #expect(try await fixture.organization().allTabs.isEmpty)
                #expect(try await fixture.organization(fixture.other).allTabs.isEmpty)
                _ = try await fixture.store.redoOrganization(from: fixture.context())
                #expect(try await fixture.organization().selectedTab?.id == restored)
                #expect(try await fixture.organization(fixture.other).selectedTab?.id == restored)
            }
        }
        try await fixture.validate()
    }

    // MARK: Finding 1 — archive cap during undo

    @Test("Undoing a close with a full archive brings back the record it evicted, whatever the hash order")
    func undoRestoresEvictedArchiveRecord() async throws {
        // Dictionary order depends on random identities; 40 fresh fixtures cover both orders.
        for _ in 0..<40 {
            let fixture = try await OrganizationFixture.make()
            try await fixture.store.setMaximumArchivedTabs(1)
            let a = try await fixture.open("a")
            let b = try await fixture.open("b")
            _ = try await fixture.store.closeTabs([a], from: fixture.context())
            fixture.clock.advance(by: 1)
            _ = try await fixture.store.closeTabs([b], from: fixture.context())
            #expect(try await fixture.store.archivedTabs(from: fixture.context()).map(\.id) == [b])
            _ = try await fixture.store.undoOrganization(from: fixture.context())
            #expect(try await fixture.store.archivedTabs(from: fixture.context()).map(\.id) == [a])
            #expect(try await fixture.organization().todayIDs == [b])
            _ = try await fixture.store.redoOrganization(from: fixture.context())
            #expect(try await fixture.store.archivedTabs(from: fixture.context()).map(\.id) == [b])
            try await fixture.validate()
        }
    }

    // MARK: Scope addition (a) — per-profile cap, undo consistent with eviction

    @Test("The archive cap applies per profile: one profile's archiving never evicts another's records")
    func archiveCapPerProfile() async throws {
        let fixture = try await OrganizationFixture.make()
        try await fixture.store.setMaximumArchivedTabs(2)
        let first = try await fixture.open("personal-1")
        let second = try await fixture.open("personal-2")
        _ = try await fixture.store.closeTabs([first, second], from: fixture.context())
        let personal = try await fixture.store.archivedTabs(from: fixture.context()).map(\.id)
        #expect(personal == [second, first])
        try await fixture.activate(fixture.lab)
        var work: [TabID] = []
        for index in 0..<4 { work.append(try await fixture.open("work-\(index)")) }
        fixture.clock.advance(by: 1)
        _ = try await fixture.store.clearTodayTabs(from: fixture.context())
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).count == 2)
        try await fixture.activate(fixture.home)
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).map(\.id) == personal)
        try await fixture.store.setMaximumArchivedTabs(1)
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).map(\.id) == [second])
        try await fixture.validate()
    }

    @Test("A replay that makes the cap evict another record records it, so the opposite replay brings it back")
    func replayEvictionIsReversible() async throws {
        let fixture = try await OrganizationFixture.make()
        try await fixture.store.setMaximumArchivedTabs(2)
        let older = try await fixture.open("older", in: fixture.other)
        _ = try await fixture.store.closeTabs([older], from: fixture.context(fixture.other))
        fixture.clock.advance(by: 1)
        let tab = try await fixture.open("restored")
        _ = try await fixture.store.closeTabs([tab], from: fixture.context())
        _ = try await fixture.store.restoreArchivedTab(tab, activate: false, from: fixture.context())
        fixture.clock.advance(by: 1)
        let newer = try await fixture.open("newer", in: fixture.other)
        _ = try await fixture.store.closeTabs([newer], from: fixture.context(fixture.other))
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).map(\.id) == [newer, older])
        for _ in 0..<2 {
            _ = try await fixture.store.undoOrganization(from: fixture.context())
            #expect(try await fixture.store.archivedTabs(from: fixture.context()).map(\.id) == [newer, tab])
            _ = try await fixture.store.redoOrganization(from: fixture.context())
            #expect(try await fixture.store.archivedTabs(from: fixture.context()).map(\.id) == [newer, older])
            #expect(try await fixture.organization().todayIDs.contains(tab))
        }
        try await fixture.validate()
    }

    @Test("A replay whose own archive record the cap would evict at once is refused instead of deleting the tab")
    func replayNeverEvictsItsOwnRecord() async throws {
        let fixture = try await OrganizationFixture.make()
        try await fixture.store.setMaximumArchivedTabs(1)
        let tab = try await fixture.open("restored")
        _ = try await fixture.store.closeTabs([tab], from: fixture.context())
        _ = try await fixture.store.restoreArchivedTab(tab, activate: false, from: fixture.context())
        fixture.clock.advance(by: 1)
        let newer = try await fixture.open("newer", in: fixture.other)
        _ = try await fixture.store.closeTabs([newer], from: fixture.context(fixture.other))
        let before = try await fixture.store.sessionDocument().encoded()
        await #expect(throws: BrowserOrganizationError.undoConflict) {
            try await fixture.store.undoOrganization(from: fixture.context())
        }
        #expect(try await fixture.store.sessionDocument().encoded() == before)
        #expect(try await fixture.organization().todayIDs.contains(tab))
        try await fixture.validate()
    }

    // MARK: Finding 2 — undo never destroys another window's change

    @Test("Undoing a restore is unavailable once another window selected or renamed the tab")
    func undoRestoreRespectsOtherWindow() async throws {
        for variant in ["select", "rename", "both"] {
            let fixture = try await OrganizationFixture.make()
            let tab = try await fixture.open("shared")
            _ = try await fixture.open("anchor")
            _ = try await fixture.store.closeTabs([tab], from: fixture.context())
            _ = try await fixture.store.restoreArchivedTab(tab, activate: false, from: fixture.context())
            #expect(try await fixture.organization().undoAction == .restoreArchivedTab)
            if variant != "rename" { _ = try await fixture.store.selectTab(tab, from: fixture.context(fixture.other)) }
            if variant != "select" {
                _ = try await fixture.store.renameTab(tab, to: "Edited elsewhere", from: fixture.context(fixture.other))
            }
            // The restore is not offered; the older close cannot be undone either (the tab exists).
            #expect(try await fixture.organization().undoAction == nil)
            let before = try await fixture.store.sessionDocument().encoded()
            await #expect(throws: BrowserOrganizationError.undoConflict) {
                try await fixture.store.undoOrganization(from: fixture.context())
            }
            #expect(try await fixture.store.sessionDocument().encoded() == before)
            let shared = try #require(try await fixture.organization(fixture.other).tab(tab))
            if variant != "select" { #expect(shared.customTitle == "Edited elsewhere") }
            if variant != "rename" { #expect(shared.isSelected) }
            try await fixture.validate()
        }
    }

    @Test("Undo reverts only the keys its command touched: another window's rename survives an unpin")
    func undoKeepsUntouchedFields() async throws {
        let fixture = try await OrganizationFixture.make()
        let tab = try await fixture.open("tab")
        _ = try await fixture.store.pinTabs([tab], from: fixture.context())
        _ = try await fixture.store.renameTab(tab, to: "Renamed elsewhere", from: fixture.context(fixture.other))
        let state = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(state.organization.todayIDs == [tab] && state.organization.pinned.isEmpty)
        #expect(state.organization.tab(tab)?.customTitle == "Renamed elsewhere")
        #expect(state.organization.tab(tab)?.pinnedURL == nil)
        try await fixture.validate()
    }

    @Test("A concurrent reorder of the same node blocks its undo; a sibling's reorder does not")
    func placementVersionsDetectReorders() async throws {
        let fixture = try await OrganizationFixture.make()
        let x = try await fixture.open("x")
        let y = try await fixture.open("y")
        let t = try await fixture.open("t")
        _ = try await fixture.store.pinTabs([x, y], from: fixture.context())
        _ = try await fixture.store.pinTabs([t], from: fixture.context())
        // Pinning keeps sidebar order; Today lists the newest tab first.
        #expect(try await fixture.organization().pinnedNodes == [.tab(y), .tab(x), .tab(t)])
        _ = try await fixture.store.moveItems([.tab(t)], to: .init(.pinned(fixture.home), position: .before(.tab(x))),
                                              from: fixture.context(fixture.other))
        // Pinning t is skipped (t was moved since); pinning x and y is still exact and runs.
        #expect(try await fixture.organization().undoAction == .pinTabs)
        let state = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(state.organization.pinnedNodes == [.tab(t)])
        #expect(Set(state.organization.todayIDs) == [x, y])

        let sibling = try await OrganizationFixture.make()
        let a = try await sibling.open("a")
        let b = try await sibling.open("b")
        _ = try await sibling.store.pinTabs([a], from: sibling.context())
        _ = try await sibling.store.pinTabs([b], from: sibling.context(sibling.other))
        _ = try await sibling.store.moveItems([.tab(b)], to: .init(.pinned(sibling.home), position: .start),
                                              from: sibling.context(sibling.other))
        let undone = try await sibling.store.undoOrganization(from: sibling.context())
        #expect(undone.organization.pinnedNodes == [.tab(b)] && undone.organization.todayIDs == [a])
        try await fixture.validate()
        try await sibling.validate()
    }

    @Test("The undo label names the record that will run: conflicting newer records are skipped and discarded")
    func undoLabelSkipsConflicts() async throws {
        let fixture = try await OrganizationFixture.make()
        let a = try await fixture.open("a")
        let y = try await fixture.open("y")
        let z = try await fixture.open("z")
        _ = try await fixture.store.renameTab(a, to: "Mine", from: fixture.context())
        _ = try await fixture.store.pinTabs([y], from: fixture.context())
        #expect(try await fixture.organization().undoAction == .pinTabs)
        _ = try await fixture.store.pinTabs([z], from: fixture.context(fixture.other))
        _ = try await fixture.store.moveItems([.tab(y)], to: .init(.pinned(fixture.home), position: .after(.tab(z))),
                                              from: fixture.context(fixture.other))
        #expect(try await fixture.organization().undoAction == .renameTab)
        let state = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(state.organization.tab(a)?.customTitle == nil)
        #expect(state.organization.pinnedNodes == [.tab(z), .tab(y)])
        #expect(state.organization.redoAction == .renameTab && state.organization.undoAction == nil)
        try await fixture.validate()
    }

    @Test("An expected replay candidate mismatch performs no writes, for undo and redo")
    func replayCandidateMismatchIsReadOnly() async throws {
        let fixture = try await OrganizationFixture.make()
        let x = try await fixture.open("x")
        let y = try await fixture.open("y")
        _ = try await fixture.store.pinTabs([x], from: fixture.context())
        let pinID = try #require(try await fixture.organization().undoRecordID)
        _ = try await fixture.store.renameTab(y, to: "Local", from: fixture.context())
        let renameID = try #require(try await fixture.organization().undoRecordID)
        let originalContext = try await fixture.context()
        _ = try await fixture.store.renameTab(y, to: "Remote", from: fixture.context(fixture.other))
        #expect(try await fixture.context() == originalContext)
        for undoing in [true, false] {
            let before = await fixture.store.sessionDocument()
            let snapshot = try await fixture.organization()
            let revision = await fixture.store.currentOrganizationRevision()
            let journal = await fixture.store.organizationJournals[fixture.window]
            let rejected = try await undoing
                ? fixture.store.undoOrganization(from: fixture.context(), expectedRecordID: renameID)
                : fixture.store.redoOrganization(from: fixture.context(), expectedRecordID: renameID)
            #expect(rejected == nil)
            #expect(await fixture.store.sessionDocument() == before)
            #expect(try await fixture.organization() == snapshot)
            #expect(await fixture.store.currentOrganizationRevision() == revision)
            let after = await fixture.store.organizationJournals[fixture.window]
            #expect(after?.undo.map(\.id) == journal?.undo.map(\.id))
            #expect(after?.redo.map(\.id) == journal?.redo.map(\.id))
            #expect(after?.recordedCount == journal?.recordedCount)
            let accepted = try await undoing
                ? fixture.store.undoOrganization(from: fixture.context(), expectedRecordID: pinID)
                : fixture.store.redoOrganization(from: fixture.context(), expectedRecordID: pinID)
            #expect(accepted != nil)
            #expect(try await fixture.organization().tab(y)?.customTitle == "Remote")
        }
        #expect(try await fixture.organization().pinnedNodes == [.tab(x)])
        try await fixture.validate()
    }

    @Test("Undo never takes another window's visible tab out of that window's Space")
    func undoKeepsOtherWindowsVisibleTab() async throws {
        let fixture = try await OrganizationFixture.make()
        let tab = try await fixture.open("moved")
        _ = try await fixture.open("stay")
        _ = try await fixture.store.moveItems([.tab(tab)], to: .init(.today(fixture.leisure)), from: fixture.context())
        try await fixture.activate(fixture.leisure, in: fixture.other)
        _ = try await fixture.store.selectTab(tab, from: fixture.context(fixture.other))
        #expect(try await fixture.organization().undoAction == nil)
        await #expect(throws: BrowserOrganizationError.undoConflict) {
            try await fixture.store.undoOrganization(from: fixture.context())
        }
        #expect(try await fixture.organization(fixture.other).selectedTab?.id == tab)
        try await fixture.validate()
    }

    // MARK: Finding 4 — undoing a folder move restores the displaced selection

    @Test("Undoing a folder move to another Space selects the tab inside it again")
    func undoFolderMoveRestoresSelection() async throws {
        let fixture = try await OrganizationFixture.make()
        let other = try await fixture.open("other")
        let inside = try await fixture.open("inside")
        let (folder, _) = try await fixture.store.createFolder(title: "Group", at: .init(.pinned(fixture.home)),
            containing: [.tab(inside)], from: fixture.context())
        #expect(try await fixture.organization().selectedTab?.id == inside)
        let moved = try await fixture.store.moveItems([.folder(folder)], to: .init(.pinned(fixture.leisure)),
                                                      from: fixture.context())
        #expect(moved.organization.selectedTab?.id == other)
        let state = try await fixture.store.undoOrganization(from: fixture.context())
        #expect(state.organization.pinnedNodes == [.folder(folder)])
        #expect(state.organization.selectedTab?.id == inside)
        try await fixture.validate()
    }

    // MARK: Finding 3 — version 1 identities are reserved before deriving

    @Test("Migration never merges independent tabs when a derived identity equals an existing one")
    func migrationReservesIdentities() throws {
        let profile = BrowserProfile(id: ProfileID(), name: "Synthetic")
        let one = BrowserSpace(id: SpaceID(), profileID: profile.id, name: "One")
        let two = BrowserSpace(id: SpaceID(), profileID: profile.id, name: "Two")
        let window = WindowID()
        let shared = TabID()
        let first = TabOccurrenceID(), duplicate = TabOccurrenceID(), independent = TabOccurrenceID()
        // The third tab's identity is exactly what the duplicate occurrence would derive.
        let colliding = BrowserSessionDocument.derivedTabID(shared, duplicate)
        let tabs = [
            BrowserTab(id: shared, occurrenceID: first, windowID: window, spaceID: one.id, url: URL(string: "https://migration.test/a")!),
            BrowserTab(id: shared, occurrenceID: duplicate, windowID: window, spaceID: two.id, url: URL(string: "https://migration.test/b")!),
            BrowserTab(id: colliding, occurrenceID: independent, windowID: window, spaceID: two.id, url: URL(string: "https://migration.test/c")!)
        ]
        for order in [[duplicate, independent], [independent, duplicate]] {
            let windows = [BrowserSessionDocument.Window(id: window, activeSpaceID: one.id, spaces: [
                .init(spaceID: one.id, occurrenceIDs: [first], selectedOccurrenceID: first),
                .init(spaceID: two.id, occurrenceIDs: order, selectedOccurrenceID: order[0])
            ])]
            let document = BrowserSessionDocument(profiles: [profile], spaces: [one, two], windows: windows, tabs: tabs)
            try document.validate()
            #expect(document.organization.tabs.count == 3)
            #expect(Set(document.tabs.map(\.id)).count == 3)
            let byOccurrence = Dictionary(uniqueKeysWithValues: document.tabs.map { ($0.occurrenceID, $0.id) })
            #expect(byOccurrence[first] == shared && byOccurrence[independent] == colliding)
            #expect(byOccurrence[duplicate] != shared && byOccurrence[duplicate] != colliding)
            // Deterministic: the same input migrates to the same identities.
            let again = BrowserSessionDocument(profiles: [profile], spaces: [one, two], windows: windows, tabs: tabs)
            #expect(again.tabs == document.tabs)
        }
    }

    // MARK: Scope additions (b) and (c)

    @Test("Snapshots carry an archive revision instead of the records; it follows only the profile's archive")
    func archiveRevisionInSnapshot() async throws {
        let fixture = try await OrganizationFixture.make()
        let initial = try await fixture.organization().archiveRevision
        let tab = try await fixture.open("archived")
        _ = try await fixture.store.closeTabs([tab], from: fixture.context())
        let afterClose = try await fixture.organization()
        #expect(afterClose.archiveRevision != initial && afterClose.archivedTabCount == 1)
        try await fixture.activate(fixture.lab, in: fixture.other)
        let work = try await fixture.organization(fixture.other).archiveRevision
        let other = try await fixture.open("work", in: fixture.other)
        _ = try await fixture.store.closeTabs([other], from: fixture.context(fixture.other))
        #expect(try await fixture.organization().archiveRevision == afterClose.archiveRevision)
        #expect(try await fixture.organization(fixture.other).archiveRevision != work)
        let saved = try await fixture.store.sessionDocument().encoded()
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(saved))
        let snapshot = try await restored.organizationSnapshot(from: restored.captureContext(in: fixture.window))
        #expect(snapshot.archiveRevision == afterClose.archiveRevision)
    }

    @Test("Removing a profile purges its Favorites, sections, threshold override, archive and undo records")
    func profileRemovalPurgesOrganization() async throws {
        let fixture = try await OrganizationFixture.make()
        let kept = try await fixture.open("personal")
        try await fixture.activate(fixture.lab)
        let favorite = try await fixture.open("work-favorite")
        let archived = try await fixture.open("work-archived")
        _ = try await fixture.open("work-today")
        _ = try await fixture.store.addToFavorites([favorite], from: fixture.context())
        _ = try await fixture.store.closeTabs([archived], from: fixture.context())
        try await fixture.store.setAutoArchiveThreshold(.oneDay, forProfile: fixture.work)
        try await fixture.store.setAutoArchiveThreshold(.sevenDays, forProfile: fixture.personal)
        await fixture.store.organizationWillRemoveProfile(fixture.work)
        let document = await fixture.store.sessionDocument()
        #expect(document.organization.tabs.map(\.id) == [kept])
        #expect(document.organization.favorites.isEmpty)
        #expect(document.organization.archive.isEmpty)
        #expect(document.organization.archivePolicy.profileThresholds == [fixture.personal: .sevenDays])
        #expect(document.tabs.allSatisfy { $0.spaceID != fixture.lab })
        #expect(try await fixture.organization().undoAction == nil)
        try document.validate()
    }

    // MARK: Finding 5 — batch moves are O(n log n)

    @Test("Pinning thousands of Today tabs next to 50 folders stays linear-ish, and its undo too")
    func batchPinPerformance() async throws {
        var timings: [Int: (pin: Duration, undo: Duration)] = [:]
        for count in [500, 1_000, 2_000] {
            var best: (pin: Duration, undo: Duration) = (.seconds(60), .seconds(60))
            for _ in 0..<5 {
                let (store, window, tabIDs) = try largeOrganization(tabs: count, folders: 50)
                let clock = ContinuousClock()
                let pin = try await clock.measure {
                    _ = try await store.pinTabs(tabIDs, from: store.captureContext(in: window))
                }
                let snapshot = try await store.organizationSnapshot(from: store.captureContext(in: window))
                #expect(snapshot.pinned.count == 50 + count && snapshot.today.isEmpty)
                let undo = try await clock.measure {
                    _ = try await store.undoOrganization(from: store.captureContext(in: window))
                }
                let undone = try await store.organizationSnapshot(from: store.captureContext(in: window))
                #expect(undone.todayIDs == tabIDs)
                best = (min(best.pin, pin), min(best.undo, undo))
            }
            timings[count] = best
        }
        let pin2000 = try #require(timings[2_000]).pin, pin500 = try #require(timings[500]).pin
        print("ORG-R2 batch pin (best of 5, includes validation and snapshot):",
              timings.sorted { $0.key < $1.key }.map { "\($0.key): pin \($0.value.pin), undo \($0.value.undo)" })
        // Budget with headroom for Debug builds on a loaded machine (tests also run in parallel);
        // quadratic behaviour (the reviewer measured 762 ms for 2000 tabs, 13.6× the 500-tab time)
        // fails both the budget and the growth bound. Linear growth is 4×.
        #expect(pin2000 < .milliseconds(250))
        #expect(try #require(timings[2_000]).undo < .milliseconds(250))
        #expect(pin2000 < pin500 * 12)
    }
}

/// One profile, one Space and one window without live occurrences: `count` Today tabs and
/// `folders` Pinned folders holding two pinned tabs each.
func largeOrganization(tabs count: Int, folders folderCount: Int) throws -> (BrowserStore, WindowID, [TabID]) {
    let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let profile = BrowserProfile(id: ProfileID(), name: "Synthetic")
    let space = BrowserSpace(id: SpaceID(), profileID: profile.id, name: "Bulk")
    let window = WindowID()
    let today = (0..<count).map { BrowserOrganizedTab(id: TabID(), url: URL(string: "https://bulk.test/\($0)")!,
                                                      createdAt: date, lastActiveAt: date) }
    var pinnedTabs: [BrowserOrganizedTab] = []
    var folders: [BrowserOrganizedFolder] = []
    for index in 0..<folderCount {
        let children = (0..<2).map { child -> BrowserOrganizedTab in
            let url = URL(string: "https://bulk.test/folder\(index)/\(child)")!
            return BrowserOrganizedTab(id: TabID(), url: url, pinnedURL: url, createdAt: date, lastActiveAt: date)
        }
        pinnedTabs += children
        folders.append(BrowserOrganizedFolder(id: FolderID(), title: "Folder \(index)",
                                              children: children.map { .tab($0.id) }, createdAt: date))
    }
    let organization = BrowserOrganizationDocument(
        tabs: today + pinnedTabs, folders: folders, favorites: [],
        spaces: [.init(spaceID: space.id, pinned: folders.map { .folder($0.id) }, today: today.map { .tab($0.id) })],
        archive: [], archivePolicy: BrowserArchivePolicy())
    let document = BrowserSessionDocument(profiles: [profile], spaces: [space], windows: [
        .init(id: window, activeSpaceID: space.id, spaces: [.init(spaceID: space.id, occurrenceIDs: [], selectedOccurrenceID: nil)])
    ], tabs: [], organization: organization)
    return (try BrowserStore(restoring: document), window, today.map(\.id))
}
