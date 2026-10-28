import BrowserCore
import BrowserShell
import Foundation
import Testing

@MainActor
private final class SpacesSurface: BrowserSurface {
    let profileID: ProfileID
    let initialURL: URL
    var currentURL: URL?
    var formValue = ""
    var scrollOffset = 0
    var actions = 0
    var disposalCount = 0
    var onDispose: (() -> Void)?

    init(profileID: ProfileID, url: URL) {
        self.profileID = profileID
        initialURL = url
        currentURL = url
    }

    func dispose() {
        disposalCount += 1
        onDispose?()
    }
}

@MainActor
private final class SpacesRecorder {
    var surfaces: [SpacesSurface] = []
    var errors: [any Error] = []
    var onMake: ((SpacesSurface) -> Void)?

    func session(_ fixture: SpacesFixture, windowID: WindowID? = nil) -> BrowserWindowSession<SpacesSurface> {
        let session = BrowserWindowSession(store: fixture.store, restoringWindowID: windowID ?? fixture.windowID) { profile, url in
            let surface = SpacesSurface(profileID: profile, url: url)
            self.surfaces.append(surface)
            self.onMake?(surface)
            return surface
        }
        session.onError = { self.errors.append($0) }
        return session
    }
}

private struct SpacesFixture: Sendable {
    let store: BrowserStore
    let personal: ProfileID
    let work: ProfileID
    let home: SpaceID
    let office: SpaceID
    let leisure: SpaceID
    let empty: SpaceID
    let windowID: WindowID
    let otherWindowID: WindowID
    let homeTabs: [TabOccurrenceID]
    let officeTabs: [TabOccurrenceID]
    let leisureTab: TabOccurrenceID
}

private func spacesFixture() async throws -> SpacesFixture {
    let original = BrowserStore()
    let personal = await original.createProfile(name: "Synthetic Personal")
    let work = await original.createProfile(name: "Synthetic Work")
    let home = try await original.createSpace(name: "Home", profileID: personal)
    let office = try await original.createSpace(name: "Office", profileID: work)
    let leisure = try await original.createSpace(name: "Leisure", profileID: personal)
    let empty = try await original.createSpace(name: "Empty", profileID: work)
    let window = try await original.createWindow(activeSpaceID: home)
    let other = try await original.createWindow(activeSpaceID: home)
    var homeTabs: [TabOccurrenceID] = []
    var officeTabs: [TabOccurrenceID] = []
    for index in 0..<2 {
        homeTabs.append(try await original.openTab(url: URL(string: "https://spaces.test/home/\(index)")!,
            from: original.captureContext(in: window), activate: true))
    }
    try await original.activateSpace(office, in: window)
    for index in 0..<2 {
        officeTabs.append(try await original.openTab(url: URL(string: "https://spaces.test/office/\(index)")!,
            from: original.captureContext(in: window), activate: index == 0))
    }
    try await original.activateSpace(leisure, in: window)
    let leisureTab = try await original.openTab(url: URL(string: "https://spaces.test/leisure/background")!,
        from: original.captureContext(in: window), activate: false)
    try await original.activateSpace(home, in: window)
    _ = try await original.openTab(url: URL(string: "https://spaces.test/other-window")!,
        from: original.captureContext(in: other), activate: true)
    let store = try BrowserStore(restoring: BrowserSessionDocument.decode(await original.sessionDocument().encoded()))
    return SpacesFixture(store: store, personal: personal, work: work, home: home, office: office,
        leisure: leisure, empty: empty, windowID: window, otherWindowID: other,
        homeTabs: homeTabs, officeTabs: officeTabs, leisureTab: leisureTab)
}

@Suite("Space profile surface replacement")
@MainActor
struct SpaceProfileSessionTests {
    @Test("Every open moved page is disposed and reloaded in the target profile, including inactive Spaces")
    func replacesAllSurfaces() async throws {
        let f = try await spacesFixture(), recorder = SpacesRecorder()
        let session = recorder.session(f)
        let second = recorder.session(f, windowID: f.otherWindowID)
        await session.waitForPendingCommands()
        await second.waitForPendingCommands()
        let old = session.ownedSurfaces + second.ownedSurfaces
        let selected = try #require(session.selectedSurface)
        selected.formValue = "synthetic old account"
        session.activateSpace(f.office)
        await session.waitForPendingCommands()
        let unaffected = try #require(session.selectedSurface)
        try await f.store.moveSpaceToProfile(f.home, to: f.work, expectedProfileID: f.personal)
        session.refreshAfterSpaceProfileMove()
        second.refreshAfterSpaceProfileMove()
        await session.waitForPendingCommands()
        await second.waitForPendingCommands()
        #expect(old.allSatisfy { $0.disposalCount == 1 })
        #expect(session.selectedSurface === unaffected)
        #expect(second.selectedSurface?.profileID == f.work)
        session.activateSpace(f.home)
        await session.waitForPendingCommands()
        let replacement = try #require(session.selectedSurface)
        #expect(replacement !== selected && replacement.profileID == f.work && replacement.formValue.isEmpty)
        #expect(session.snapshot?.tabs.count == 2)
        // Neither shell observes the intermediate move back. IDs must still revoke the B pages.
        try await f.store.moveSpaceToProfile(f.home, to: f.personal, expectedProfileID: f.work)
        try await f.store.moveSpaceToProfile(f.home, to: f.work, expectedProfileID: f.personal)
        session.refreshAfterSpaceProfileMove()
        await session.waitForPendingCommands()
        #expect(replacement.disposalCount == 1)
        #expect(session.selectedSurface !== replacement)
        #expect(recorder.errors.isEmpty)
        session.close(); second.close()
        await session.waitForPendingCommands()
        await second.waitForPendingCommands()
    }
}

@Test("Spaces retain exact live instances and form analogues, restore selection, and lazily materialize inactive profiles")
@MainActor
func spacesSessionKeepsLiveIdentityAndRestoresLazily() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let initial = try #require(session.snapshot)
    let selected = try #require(session.selectedSurface)
    selected.formValue = "unsent synthetic draft"
    selected.scrollOffset = 481
    #expect(session.catalog == (await fixture.store.catalogSnapshot()))
    #expect(recorder.surfaces.count == 2)
    #expect(session.surface(for: fixture.officeTabs[0]) == nil)
    session.activateSpace(fixture.office)
    await session.waitForPendingCommands()
    let work = try #require(session.selectedSurface)
    #expect(session.snapshot?.tabs.map(\.occurrenceID) == fixture.officeTabs)
    #expect(session.snapshot?.selectedOccurrenceID == fixture.officeTabs[0])
    #expect(work.profileID == fixture.work)
    #expect(session.ownedSurfaces.count == 4)
    #expect(session.surface(for: fixture.homeTabs[1]) === selected)
    #expect(session.occurrenceID(for: selected) == fixture.homeTabs[1])
    session.activateSpace(fixture.home)
    await session.waitForPendingCommands()
    #expect(session.snapshot?.tabs == initial.tabs)
    #expect(session.selectedSurface === selected)
    #expect(selected.formValue == "unsent synthetic draft" && selected.scrollOffset == 481)
    session.activateSpace(fixture.empty)
    await session.waitForPendingCommands()
    #expect(session.snapshot?.tabs.isEmpty == true)
    #expect(session.snapshot?.selectedOccurrenceID == nil && session.selectedSurface == nil)
    #expect(session.ownedSurfaces.count == 4 && recorder.surfaces.count == 4)
    session.activateSpace(fixture.leisure)
    await session.waitForPendingCommands()
    #expect(session.snapshot?.tabs.map(\.occurrenceID) == [fixture.leisureTab])
    #expect(session.selectedSurface == nil)
    #expect(session.surface(for: fixture.leisureTab)?.profileID == fixture.personal)
    session.activateSpace(fixture.office)
    session.activateSpace(fixture.office)
    await session.waitForPendingCommands()
    #expect(session.selectedSurface === work)
    #expect(recorder.surfaces.map(\.profileID) == [fixture.personal, fixture.personal, fixture.work, fixture.work, fixture.personal])
    #expect(recorder.surfaces.allSatisfy { $0.disposalCount == 0 })
    #expect(recorder.errors.isEmpty)
    session.close()
    await session.waitForPendingCommands()
    #expect(recorder.surfaces.allSatisfy { $0.disposalCount == 1 })
}

@Test("Owned inactive-profile callbacks update only their occurrence and preserve active selection and revision")
@MainActor
func spacesSessionPersistsInactiveMetadata() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let inactive = try #require(session.selectedSurface)
    let destination = URL(string: "https://spaces.test/home/redirected")!
    session.activateSpace(fixture.office)
    await session.waitForPendingCommands()
    let before = try #require(session.snapshot)
    let active = try #require(session.selectedSurface)
    let context = try await fixture.store.captureContext(in: fixture.windowID)
    var publications = 0
    session.onChange = { publications += 1 }
    inactive.currentURL = destination
    session.updateDestination(for: inactive, to: destination)
    session.performOnSelectedSurface { $0.actions += 1 }
    await session.waitForPendingCommands()
    #expect(session.snapshot == before)
    #expect(session.selectedSurface === active)
    #expect(active.actions == 1 && inactive.actions == 0)
    #expect(await fixture.store.isCurrent(context))
    #expect(publications == 1)
    #expect(await fixture.store.sessionDocument().tabs.first { $0.occurrenceID == fixture.homeTabs[1] }?.url == destination)
    session.updateDestination(for: inactive, to: destination)
    await session.waitForPendingCommands()
    #expect(publications == 1)
    session.activateSpace(fixture.home)
    await session.waitForPendingCommands()
    #expect(session.selectedSurface === inactive)
    #expect(session.snapshot?.tabs.last?.url == destination)
    #expect(recorder.errors.isEmpty)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Archive reopen spans Spaces in one profile and returns to the original destination")
@MainActor
func spacesSessionReopenHistoryNeverCrossesProfiles() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let homeURL = URL(string: "https://spaces.test/home/latest")!
    let homeSurface = try #require(session.selectedSurface)
    homeSurface.currentURL = homeURL
    session.updateDestination(for: homeSurface, to: homeURL)
    session.closeSelectedTab()
    session.activateSpace(fixture.office)
    session.reopenClosedTab()
    await session.waitForPendingCommands()
    #expect(!session.canReopenClosedTab)
    #expect(session.snapshot?.tabs.map(\.occurrenceID) == fixture.officeTabs)
    let officeURL = try #require(session.selectedSurface?.currentURL)
    session.closeSelectedTab()
    session.activateSpace(fixture.leisure)
    let leisureURL = URL(string: "https://spaces.test/leisure/closed")!
    session.openTab(url: leisureURL)
    session.closeSelectedTab()
    session.activateSpace(fixture.home)
    session.reopenClosedTab()
    await session.waitForPendingCommands()
    #expect(session.snapshot?.activeSpaceID == fixture.leisure)
    #expect(session.selectedSurface?.initialURL == leisureURL)
    #expect(session.canReopenClosedTab)
    session.reopenClosedTab()
    await session.waitForPendingCommands()
    #expect(session.snapshot?.activeSpaceID == fixture.home)
    #expect(session.selectedSurface?.initialURL == homeURL)
    #expect(session.selectedSurface?.profileID == fixture.personal)
    #expect(!session.canReopenClosedTab)
    session.activateSpace(fixture.office)
    session.reopenClosedTab()
    await session.waitForPendingCommands()
    #expect(session.selectedSurface?.initialURL == officeURL)
    #expect(session.selectedSurface?.profileID == fixture.work)
    #expect(!session.canReopenClosedTab)
    #expect(recorder.errors.isEmpty)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Rapid switch, open, duplicate, select and close commands use their destination profile in queue order")
@MainActor
func spacesSessionRapidCommandsStayOrdered() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let homeSelected = try #require(session.selectedSurface)
    let workURL = URL(string: "https://spaces.test/work/new")!
    let homeURL = URL(string: "https://spaces.test/home/new")!
    session.activateSpace(fixture.office)
    session.openTab(url: workURL)
    session.duplicateSelectedTab()
    session.closeSelectedTab()
    session.selectOccurrence(fixture.officeTabs[1])
    session.performOnSelectedSurface { $0.actions += 1 }
    session.activateSpace(fixture.home)
    session.openTab(url: homeURL, activate: false)
    session.duplicateSelectedTab()
    session.closeSelectedTab()
    await session.waitForPendingCommands()
    #expect(session.selectedSurface?.initialURL == homeURL)
    #expect(session.surface(for: fixture.homeTabs[1]) === homeSelected)
    #expect(session.snapshot?.tabs.count == 3)
    #expect(session.surface(for: fixture.officeTabs[1])?.actions == 1)
    let workSurfaces = recorder.surfaces.filter { $0.initialURL == workURL }
    #expect(workSurfaces.count == 2 && workSurfaces.allSatisfy { $0.profileID == fixture.work })
    #expect(workSurfaces.map(\.disposalCount) == [0, 1])
    #expect(recorder.surfaces.filter { $0.initialURL == homeURL }.allSatisfy { $0.profileID == fixture.personal })
    session.activateSpace(fixture.office)
    await session.waitForPendingCommands()
    #expect(session.snapshot?.selectedOccurrenceID == fixture.officeTabs[1])
    #expect(session.snapshot?.tabs.count == 3)
    #expect(recorder.errors.isEmpty)
    session.close()
    await session.waitForPendingCommands()
    #expect(recorder.surfaces.allSatisfy { $0.disposalCount == 1 })
}

@Test("Exact background row closure preserves selection and a stale row cannot close the new Space's selected tab")
@MainActor
func spacesSessionExactRowClosureCannotRetargetSelection() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let selected = try #require(session.selectedSurface)
    let context = try await fixture.store.captureContext(in: fixture.windowID)
    session.closeOccurrence(fixture.homeTabs[0])
    await session.waitForPendingCommands()
    #expect(session.snapshot?.selectedOccurrenceID == fixture.homeTabs[1])
    #expect(session.selectedSurface === selected)
    #expect(await fixture.store.isCurrent(context))
    session.activateSpace(fixture.office)
    session.selectOccurrence(fixture.homeTabs[1])
    session.closeOccurrence(fixture.homeTabs[1])
    await session.waitForPendingCommands()
    #expect(recorder.errors.count == 2)
    #expect(recorder.errors.allSatisfy { ($0 as? BrowserStoreError) == .occurrenceOwnedByAnotherWindow })
    #expect(session.snapshot?.tabs.map(\.occurrenceID) == fixture.officeTabs)
    #expect(session.snapshot?.selectedOccurrenceID == fixture.officeTabs[0])
    #expect(selected.disposalCount == 0)
    session.activateSpace(fixture.home)
    session.closeOccurrence(fixture.homeTabs[1])
    await session.waitForPendingCommands()
    #expect(session.snapshot?.tabs.isEmpty == true && session.selectedSurface == nil)
    #expect(selected.disposalCount == 1)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Queued catalog edits create and activate an empty explicit-profile Space before a following open")
@MainActor
func spacesSessionCatalogMutationsAreOrderedAndPublished() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    var publications = 0
    var publishedTabCounts: [Int] = []
    session.onChange = {
        publications += 1
        publishedTabCounts.append(session.snapshot?.tabs.count ?? -1)
        #expect(session.catalog?.spaces.contains { $0.id == session.snapshot?.activeSpaceID } == true)
    }
    session.refreshCatalog()
    await session.waitForPendingCommands()
    #expect(publications == 0)
    session.renameSpace(fixture.office, name: " Renamed Office ")
    session.moveSpace(fixture.empty, before: fixture.home)
    session.createSpace(name: "Created Work Space", profileID: fixture.work)
    session.openTab(url: URL(string: "https://spaces.test/created-work")!)
    await session.waitForPendingCommands()
    let created = try #require(session.catalog?.spaces.last)
    #expect(created.name == "Created Work Space" && created.profileID == fixture.work)
    #expect(session.snapshot?.activeSpaceID == created.id)
    #expect(session.snapshot?.tabs.count == 1)
    #expect(session.selectedSurface?.profileID == fixture.work)
    #expect(session.catalog?.spaces.first?.id == fixture.empty)
    #expect(session.catalog?.spaces.first { $0.id == fixture.office }?.name == "Renamed Office")
    #expect(publications == 4)
    #expect(publishedTabCounts == [2, 2, 0, 1])
    session.refreshCatalog()
    await session.waitForPendingCommands()
    #expect(publications == 4)
    #expect(recorder.errors.isEmpty)
    let restored = try BrowserStore(restoring: await fixture.store.sessionDocument())
    #expect(await restored.catalogSnapshot() == session.catalog)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Rapid relative switches and opens resolve against preceding commands and current catalog order")
@MainActor
func spacesSessionRelativeSwitchesResolveInQueueOrder() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let leisureURL = URL(string: "https://spaces.test/relative/leisure")!
    let workURL = URL(string: "https://spaces.test/relative/work")!
    session.activateAdjacentSpace(offset: 1)
    session.activateAdjacentSpace(offset: 1)
    session.openTab(url: leisureURL)
    session.activateAdjacentSpace(offset: 1)
    session.activateAdjacentSpace(offset: 1)
    session.openTab(url: workURL)
    session.activateAdjacentSpace(offset: -1)
    session.performOnSelectedSurface { $0.actions += 1 }
    session.moveSpace(fixture.empty, before: fixture.home)
    session.activateAdjacentSpace(offset: -1)
    await session.waitForPendingCommands()
    #expect(session.snapshot?.activeSpaceID == fixture.office)
    #expect(recorder.surfaces.first { $0.initialURL == leisureURL }?.profileID == fixture.personal)
    #expect(recorder.surfaces.first { $0.initialURL == leisureURL }?.actions == 1)
    #expect(recorder.surfaces.first { $0.initialURL == workURL }?.profileID == fixture.work)
    session.activateAdjacentSpace(offset: Int.min)
    await session.waitForPendingCommands()
    #expect(session.snapshot?.activeSpaceID == fixture.empty)
    #expect(session.selectedSurface?.initialURL == workURL)
    #expect(recorder.errors.isEmpty)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Two windows keep independent active Spaces, catalogs, selections, live state and retirement")
@MainActor
func spacesSessionWindowsRemainIndependent() async throws {
    let fixture = try await spacesFixture()
    let firstRecorder = SpacesRecorder()
    let secondRecorder = SpacesRecorder()
    let first = firstRecorder.session(fixture)
    let second = secondRecorder.session(fixture, windowID: fixture.otherWindowID)
    await first.waitForPendingCommands()
    await second.waitForPendingCommands()
    let other = try #require(second.selectedSurface)
    other.formValue = "other window draft"
    let otherSnapshot = second.snapshot
    first.activateSpace(fixture.office)
    first.renameSpace(fixture.home, name: "Shared Name")
    await first.waitForPendingCommands()
    #expect(second.snapshot == otherSnapshot)
    #expect(second.selectedSurface === other && other.formValue == "other window draft")
    var publications = 0
    second.onChange = { publications += 1 }
    second.refreshCatalog()
    second.refreshCatalog()
    await second.waitForPendingCommands()
    #expect(publications == 1)
    #expect(second.catalog == first.catalog)
    #expect(second.snapshot == otherSnapshot)
    first.updateDestination(for: other, to: URL(string: "https://spaces.test/foreign")!)
    await first.waitForPendingCommands()
    #expect(firstRecorder.errors.last as? BrowserWindowSessionError == .surfaceNotOwned)
    first.close()
    await first.waitForPendingCommands()
    #expect(firstRecorder.surfaces.allSatisfy { $0.disposalCount == 1 })
    #expect(other.disposalCount == 0)
    #expect(try await fixture.store.snapshot(of: fixture.otherWindowID) == otherSnapshot)
    second.close()
    await second.waitForPendingCommands()
}

@Test("Closing or terminating disposes active and inactive surfaces once and revokes every callback", arguments: [false, true])
@MainActor
func spacesSessionRetiresAllOwnedSurfaces(preserveModel: Bool) async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    session.activateSpace(fixture.office)
    await session.waitForPendingCommands()
    let owned = session.ownedSurfaces
    let document = await fixture.store.sessionDocument()
    if preserveModel { session.retireForApplicationTermination() }
    else { session.close() }
    session.close()
    for surface in owned {
        session.updateDestination(for: surface, to: URL(string: "https://spaces.test/retired")!)
        #expect(session.occurrenceID(for: surface) == nil)
    }
    session.activateSpace(fixture.home)
    session.createSpace(name: "Rejected", profileID: fixture.personal)
    session.openTab()
    await session.waitForPendingCommands()
    #expect(session.isClosed && !session.hasPendingCommands)
    #expect(session.ownedSurfaces.isEmpty && session.snapshot == nil && session.catalog == nil)
    #expect(owned.count == 4 && owned.allSatisfy { $0.disposalCount == 1 })
    #expect(recorder.errors.isEmpty)
    if preserveModel {
        #expect(await fixture.store.sessionDocument() == document)
    } else {
        #expect(await fixture.store.sessionDocument().tabs.allSatisfy { $0.windowID == fixture.otherWindowID })
        await #expect(throws: BrowserStoreError.windowMissing) { try await fixture.store.snapshot(of: fixture.windowID) }
    }
}

@Test("Reentrant close from a newly activated Space's factory disposes previously owned and just returned surfaces", arguments: [false, true])
@MainActor
func spacesSessionSwitchFactoryCanClose(preserveModel: Bool) async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    recorder.onMake = { _ in
        if preserveModel { session.retireForApplicationTermination() }
        else { session.close() }
        session.openTab()
    }
    var publications = 0
    session.onChange = { publications += 1 }
    session.activateSpace(fixture.office)
    await session.waitForPendingCommands()
    #expect(session.isClosed && !session.hasPendingCommands)
    #expect(recorder.surfaces.count == 3)
    #expect(recorder.surfaces.allSatisfy { $0.disposalCount == 1 })
    #expect(publications == 0 && session.ownedSurfaces.isEmpty)
    if preserveModel {
        #expect(try await fixture.store.snapshot(of: fixture.windowID).tabs.map(\.occurrenceID) == fixture.officeTabs)
    } else {
        await #expect(throws: BrowserStoreError.windowMissing) { try await fixture.store.snapshot(of: fixture.windowID) }
    }
}

@Test("A new factory can enqueue a Space change, its own inactive callback and an open without losing authority")
@MainActor
func spacesSessionFactoryCanQueueCommandsAndCallbacks() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let redirected = URL(string: "https://spaces.test/factory/redirected")!
    let added = URL(string: "https://spaces.test/factory/home-open")!
    recorder.onMake = { surface in
        guard recorder.surfaces.count == 3 else { return }
        surface.currentURL = redirected
        session.activateSpace(fixture.home)
        session.updateDestination(for: surface, to: redirected)
        session.openTab(url: added)
    }
    session.activateSpace(fixture.office)
    await session.waitForPendingCommands()
    #expect(session.snapshot?.activeSpaceID == fixture.home)
    #expect(session.selectedSurface?.initialURL == added)
    #expect(session.selectedSurface?.profileID == fixture.personal)
    #expect(await fixture.store.sessionDocument().tabs.first { $0.occurrenceID == fixture.officeTabs[0] }?.url == redirected)
    #expect(recorder.surfaces.count == 5)
    #expect(recorder.errors.isEmpty)
    #expect(!session.hasPendingCommands)
    session.close()
    await session.waitForPendingCommands()
    #expect(recorder.surfaces.allSatisfy { $0.disposalCount == 1 })
}

@Test("Reentrant close from row disposal retires every active and inactive surface exactly once")
@MainActor
func spacesSessionDisposalCanClose() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let surface = try #require(session.selectedSurface)
    session.activateSpace(fixture.office)
    session.activateSpace(fixture.home)
    await session.waitForPendingCommands()
    surface.onDispose = {
        session.close()
        session.activateSpace(fixture.office)
        session.openTab()
    }
    session.closeSelectedTab()
    await session.waitForPendingCommands()
    #expect(session.isClosed && !session.hasPendingCommands)
    #expect(recorder.surfaces.count == 4 && recorder.surfaces.allSatisfy { $0.disposalCount == 1 })
    #expect(await fixture.store.sessionDocument().tabs.allSatisfy { $0.windowID == fixture.otherWindowID })
}

@Test("Catalog refresh and queued switching cannot adopt authority after external Space changes")
@MainActor
func spacesSessionRejectsExternalSwitchesAndRoundTrips() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let before = session.snapshot
    let surface = try #require(session.selectedSurface)
    try await fixture.store.activateSpace(fixture.office, in: fixture.windowID)
    let document = await fixture.store.sessionDocument()
    session.activateSpace(fixture.home)
    session.closeOccurrence(fixture.homeTabs[0])
    session.refreshCatalog()
    session.updateDestination(for: surface, to: URL(string: "https://spaces.test/external")!)
    await session.waitForPendingCommands()
    #expect(recorder.errors.count == 4)
    #expect(recorder.errors.allSatisfy { ($0 as? BrowserWindowSessionError) == .contextChangeRequiresNewSession })
    #expect(await fixture.store.sessionDocument() == document)
    #expect(session.snapshot == before && recorder.surfaces.count == 2)
    try await fixture.store.activateSpace(fixture.home, in: fixture.windowID)
    session.activateAdjacentSpace(offset: 1)
    await session.waitForPendingCommands()
    #expect(recorder.errors.last as? BrowserStoreError == .staleContext)
    #expect(session.snapshot == before)
    session.close()
    await session.waitForPendingCommands()
}

private final class SpacesStoreGate: @unchecked Sendable {
    let entered = AsyncStream<Void>.makeStream()
    private let signal = DispatchSemaphore(value: 0)
    func hold() {
        entered.continuation.yield(())
        entered.continuation.finish()
        #expect(signal.wait(timeout: .now() + 10) == .success)
    }
    func release() { signal.signal() }
    func waitUntilEntered() async { for await _ in entered.stream { return } }
}

private extension BrowserStore {
    func holdSpacesTestExecutor(_ gate: SpacesStoreGate) { gate.hold() }
}

@Test("Retirement across a switch's context actor hop cannot create inactive surfaces or leak a window", arguments: [false, true])
@MainActor
func spacesSessionSwitchCloseDuringActorHop(preserveModel: Bool) async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let document = await fixture.store.sessionDocument()
    let gate = SpacesStoreGate()
    let blocker = Task.detached { await fixture.store.holdSpacesTestExecutor(gate) }
    await gate.waitUntilEntered()
    defer { gate.release() }
    session.activateSpace(fixture.office)
    await Task { @MainActor in
        if preserveModel { session.retireForApplicationTermination() }
        else { session.close() }
    }.value
    gate.release()
    await blocker.value
    await session.waitForPendingCommands()
    #expect(recorder.surfaces.count == 2 && recorder.surfaces.allSatisfy { $0.disposalCount == 1 })
    #expect(session.isClosed && !session.hasPendingCommands)
    #expect(recorder.errors.isEmpty)
    if preserveModel { #expect(await fixture.store.sessionDocument() == document) }
    else {
        await #expect(throws: BrowserStoreError.windowMissing) { try await fixture.store.snapshot(of: fixture.windowID) }
    }
}

@Test("Removed and previous-store live surfaces cannot update or recreate saved occurrences")
@MainActor
func spacesSessionRemovedAndPreviousStoreCallbacksAreRejected() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let removed = try #require(session.surface(for: fixture.homeTabs[0]))
    let selected = try #require(session.selectedSurface)
    let context = try await fixture.store.captureContext(in: fixture.windowID)
    try await fixture.store.closeOccurrence(fixture.homeTabs[0], from: context)
    let document = await fixture.store.sessionDocument()
    session.updateDestination(for: removed, to: URL(string: "https://spaces.test/removed")!)
    await session.waitForPendingCommands()
    #expect(recorder.errors.last as? BrowserStoreError == .tabMissing)
    #expect(await fixture.store.sessionDocument() == document)
    session.retireForApplicationTermination()
    await session.waitForPendingCommands()
    let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(document.encoded()))
    let nextRecorder = SpacesRecorder()
    let next = BrowserWindowSession(store: restored, restoringWindowID: fixture.windowID) { profile, url in
        let surface = SpacesSurface(profileID: profile, url: url)
        nextRecorder.surfaces.append(surface)
        return surface
    }
    next.onError = { nextRecorder.errors.append($0) }
    await next.waitForPendingCommands()
    next.updateDestination(for: selected, to: URL(string: "https://spaces.test/previous-store")!)
    session.updateDestination(for: selected, to: URL(string: "https://spaces.test/retired-store")!)
    await next.waitForPendingCommands()
    await session.waitForPendingCommands()
    #expect(nextRecorder.errors.last as? BrowserWindowSessionError == .surfaceNotOwned)
    #expect(await restored.sessionDocument() == document)
    #expect(await fixture.store.sessionDocument() == document)
    #expect(next.selectedSurface !== selected)
    #expect(recorder.surfaces.allSatisfy { $0.disposalCount == 1 })
    next.close()
    await next.waitForPendingCommands()
}

@Test("Failed catalog commands preserve active authority and do not discard following valid commands")
@MainActor
func spacesSessionCatalogFailuresDoNotBreakQueue() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let catalog = session.catalog
    session.createSpace(name: " ", profileID: fixture.work)
    session.createSpace(name: "Missing Profile", profileID: ProfileID())
    session.renameSpace(fixture.home, name: " ")
    session.moveSpace(fixture.home, before: SpaceID())
    session.activateSpace(SpaceID())
    session.activateSpace(fixture.office)
    session.openTab(url: URL(string: "https://spaces.test/after-rejection")!)
    await session.waitForPendingCommands()
    #expect(recorder.errors.count == 5)
    #expect(recorder.errors[0] as? BrowserStoreError == .invalidSpaceName)
    #expect(recorder.errors[1] as? BrowserStoreError == .profileMissing)
    #expect(recorder.errors[2] as? BrowserStoreError == .invalidSpaceName)
    #expect(recorder.errors[3] as? BrowserStoreError == .spaceMissing)
    #expect(recorder.errors[4] as? BrowserStoreError == .spaceMissing)
    #expect(session.catalog == catalog)
    #expect(session.snapshot?.activeSpaceID == fixture.office)
    #expect(session.snapshot?.tabs.count == 3)
    #expect(session.selectedSurface?.profileID == fixture.work)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Closing after an external background removal uses atomic membership and permits a later open", arguments: [false, true])
@MainActor
func spacesSessionCloseAfterExternalBackgroundChange(insertBackground: Bool) async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let removed = try #require(session.surface(for: fixture.homeTabs[0]))
    let selected = try #require(session.selectedSurface)
    session.activateSpace(fixture.office)
    await session.waitForPendingCommands()
    let inactive = try #require(session.selectedSurface)
    inactive.formValue = "preserved inactive profile draft"
    session.activateSpace(fixture.home)
    await session.waitForPendingCommands()
    let context = try await fixture.store.captureContext(in: fixture.windowID)
    try await fixture.store.closeOccurrence(fixture.homeTabs[0], from: context)
    var background: TabOccurrenceID?
    if insertBackground {
        background = try await fixture.store.openTab(url: URL(string: "https://spaces.test/external/background")!,
            from: context, activate: false)
    }
    #expect(await fixture.store.isCurrent(context))
    session.closeSelectedTab()
    await session.waitForPendingCommands()
    #expect(recorder.errors.isEmpty)
    #expect(session.snapshot == (try await fixture.store.snapshot(of: fixture.windowID)))
    #expect(session.snapshot?.tabs.map(\.occurrenceID) == background.map { [$0] } ?? [])
    #expect(session.snapshot?.selectedOccurrenceID == background)
    #expect(removed.disposalCount == 1 && selected.disposalCount == 1)
    #expect(session.surface(for: fixture.homeTabs[0]) == nil && session.surface(for: fixture.homeTabs[1]) == nil)
    #expect(session.occurrenceID(for: removed) == nil && session.occurrenceID(for: selected) == nil)
    #expect(session.surface(for: fixture.officeTabs[0]) === inactive)
    #expect(inactive.disposalCount == 0)
    let openedURL = URL(string: "https://spaces.test/after-external-close")!
    session.openTab(url: openedURL)
    await session.waitForPendingCommands()
    #expect(session.selectedSurface?.initialURL == openedURL)
    #expect(session.selectedSurface?.profileID == fixture.personal)
    #expect(recorder.errors.isEmpty)
    session.activateSpace(fixture.office)
    await session.waitForPendingCommands()
    #expect(session.selectedSurface === inactive)
    #expect(inactive.formValue == "preserved inactive profile draft")
    session.close()
    await session.waitForPendingCommands()
    #expect(recorder.surfaces.allSatisfy { $0.disposalCount == 1 })
}

@Test("Same-Space refresh revokes removed surfaces across Spaces while retaining valid inactive instances and permitting opens")
@MainActor
func spacesSessionRefreshReconcilesRemovedLeases() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let removedHome = try #require(session.surface(for: fixture.homeTabs[0]))
    let selectedHome = try #require(session.selectedSurface)
    session.activateSpace(fixture.office)
    await session.waitForPendingCommands()
    let keptWork = try #require(session.selectedSurface)
    let removedWork = try #require(session.surface(for: fixture.officeTabs[1]))
    keptWork.formValue = "work draft"
    try await fixture.store.closeOccurrence(fixture.officeTabs[1],
        from: fixture.store.captureContext(in: fixture.windowID))
    removedWork.onDispose = {
        #expect(session.surface(for: fixture.officeTabs[1]) == nil)
        #expect(session.occurrenceID(for: removedWork) == nil)
        #expect(!session.ownedSurfaces.contains { $0 === removedWork })
    }
    session.activateSpace(fixture.home)
    await session.waitForPendingCommands()
    #expect(removedWork.disposalCount == 1)
    #expect(session.surface(for: fixture.officeTabs[0]) === keptWork)
    #expect(keptWork.disposalCount == 0)
    let context = try await fixture.store.captureContext(in: fixture.windowID)
    try await fixture.store.closeOccurrence(fixture.homeTabs[0], from: context)
    removedHome.onDispose = {
        #expect(session.surface(for: fixture.homeTabs[0]) == nil)
        #expect(session.occurrenceID(for: removedHome) == nil)
        #expect(!session.ownedSurfaces.contains { $0 === removedHome })
        #expect(session.surface(for: fixture.officeTabs[0]) === keptWork)
    }
    session.activateSpace(fixture.home)
    await session.waitForPendingCommands()
    #expect(removedHome.disposalCount == 1)
    #expect(session.snapshot?.tabs.map(\.occurrenceID) == [fixture.homeTabs[1]])
    #expect(session.selectedSurface === selectedHome)
    #expect(session.ownedSurfaces.count == 2)
    #expect(recorder.errors.isEmpty)
    let external = try await fixture.store.openTab(url: URL(string: "https://spaces.test/refreshed-background")!,
        from: fixture.store.captureContext(in: fixture.windowID), activate: false)
    session.refreshCatalog()
    await session.waitForPendingCommands()
    #expect(session.surface(for: external)?.profileID == fixture.personal)
    #expect(session.selectedSurface === selectedHome)
    session.updateDestination(for: removedHome, to: URL(string: "https://spaces.test/revoked-callback")!)
    session.openTab(url: URL(string: "https://spaces.test/after-refresh")!)
    await session.waitForPendingCommands()
    #expect(recorder.errors.count == 1)
    #expect(recorder.errors[0] as? BrowserWindowSessionError == .surfaceNotOwned)
    #expect(session.selectedSurface?.initialURL == URL(string: "https://spaces.test/after-refresh"))
    #expect(session.surface(for: fixture.officeTabs[0]) === keptWork)
    #expect(keptWork.formValue == "work draft" && keptWork.disposalCount == 0)
    session.close()
    await session.waitForPendingCommands()
    #expect(recorder.surfaces.allSatisfy { $0.disposalCount == 1 })
}

@Test("Reconciliation revokes an entire removed batch before reentrant close and disposes every detached surface", arguments: [false, true])
@MainActor
func spacesSessionReconciliationCanCloseReentrantly(preserveModel: Bool) async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    let first = try #require(session.surface(for: fixture.homeTabs[0]))
    let second = try #require(session.selectedSurface)
    session.activateSpace(fixture.office)
    session.activateSpace(fixture.home)
    await session.waitForPendingCommands()
    try await fixture.store.closeOccurrence(fixture.homeTabs[0],
        from: fixture.store.captureContext(in: fixture.windowID))
    var publications = 0
    session.onChange = { publications += 1 }
    first.onDispose = {
        #expect(session.surface(for: fixture.homeTabs[0]) == nil)
        #expect(session.surface(for: fixture.homeTabs[1]) == nil)
        #expect(session.occurrenceID(for: first) == nil && session.occurrenceID(for: second) == nil)
        if preserveModel { session.retireForApplicationTermination() }
        else { session.close() }
        session.openTab()
        session.activateSpace(fixture.office)
    }
    session.closeSelectedTab()
    await session.waitForPendingCommands()
    #expect(session.isClosed && !session.hasPendingCommands)
    #expect(session.snapshot == nil && session.ownedSurfaces.isEmpty)
    #expect(publications == 0 && recorder.errors.isEmpty)
    #expect(recorder.surfaces.count == 4 && recorder.surfaces.allSatisfy { $0.disposalCount == 1 })
    if preserveModel {
        let saved = try await fixture.store.snapshot(of: fixture.windowID)
        #expect(saved.tabs.isEmpty && saved.selectedOccurrenceID == nil)
        #expect(await fixture.store.sessionDocument().tabs.contains { $0.occurrenceID == fixture.officeTabs[0] })
    } else {
        await #expect(throws: BrowserStoreError.windowMissing) { try await fixture.store.snapshot(of: fixture.windowID) }
    }
}

@Test("A synchronous context boundary captures the preceding Space before later queued switches and opens")
@MainActor
func spacesSessionContextBoundarySeparatesCommands() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    session.activateSpace(fixture.office)
    let boundary = session.captureContextInCommandOrder()
    #expect(session.hasPendingCommands)
    session.activateSpace(fixture.leisure)
    session.openTab(url: URL(string: "https://spaces.test/after-context-boundary")!)
    let captured = try #require(await boundary.value)
    await session.waitForPendingCommands()
    #expect(captured.windowID == fixture.windowID)
    #expect(captured.spaceID == fixture.office && captured.profileID == fixture.work)
    #expect(captured.selectedOccurrenceID == fixture.officeTabs[0])
    #expect(session.snapshot?.activeSpaceID == fixture.leisure)
    #expect(session.selectedSurface?.profileID == fixture.personal)
    #expect(session.selectedSurface?.initialURL == URL(string: "https://spaces.test/after-context-boundary"))
    #expect(!(await fixture.store.isCurrent(captured)))
    #expect(!session.hasPendingCommands && recorder.errors.isEmpty)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Closing before a queued context boundary executes resolves nil and permits retirement to drain")
@MainActor
func spacesSessionContextBoundaryResolvesOnEarlyClose() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    session.activateSpace(fixture.office)
    let boundary = session.captureContextInCommandOrder()
    session.close()
    #expect(await boundary.value == nil)
    await session.waitForPendingCommands()
    #expect(await session.captureContextInCommandOrder().value == nil)
    #expect(!session.hasPendingCommands && session.isClosed)
    #expect(recorder.surfaces.count == 2 && recorder.surfaces.allSatisfy { $0.disposalCount == 1 })
    #expect(recorder.errors.isEmpty)
    await #expect(throws: BrowserStoreError.windowMissing) { try await fixture.store.snapshot(of: fixture.windowID) }
}

@Test("A context boundary rejects stale authority without obstructing later retirement")
@MainActor
func spacesSessionContextBoundaryRejectsStaleAuthority() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    try await fixture.store.activateSpace(fixture.office, in: fixture.windowID)
    let boundary = session.captureContextInCommandOrder()
    #expect(await boundary.value == nil)
    await session.waitForPendingCommands()
    #expect(recorder.errors.count == 1)
    #expect(recorder.errors[0] as? BrowserWindowSessionError == .contextChangeRequiresNewSession)
    #expect(session.snapshot?.activeSpaceID == fixture.home)
    #expect(!session.hasPendingCommands)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Native window actions follow queued Space changes without requiring or creating a surface")
@MainActor
func spacesSessionWindowActionsFollowEmptyAndLiveSwitches() async throws {
    let fixture = try await spacesFixture()
    let recorder = SpacesRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    var observed: [SpaceID] = []
    session.activateSpace(fixture.empty)
    session.performWindowAction {
        #expect(session.selectedSurface == nil)
        #expect(session.snapshot?.tabs.isEmpty == true)
        if let space = session.snapshot?.activeSpaceID { observed.append(space) }
    }
    session.activateSpace(fixture.office)
    session.performWindowAction {
        #expect(session.selectedSurface?.profileID == fixture.work)
        if let space = session.snapshot?.activeSpaceID { observed.append(space) }
    }
    await session.waitForPendingCommands()
    #expect(observed == [fixture.empty, fixture.office])
    #expect(recorder.surfaces.count == 4 && recorder.errors.isEmpty)
    session.performWindowAction { observed.removeAll() }
    session.close()
    await session.waitForPendingCommands()
    #expect(observed == [fixture.empty, fixture.office])
}
