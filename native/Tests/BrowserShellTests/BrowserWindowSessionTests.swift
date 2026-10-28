import BrowserCore
import BrowserShell
import Foundation
import Testing

@MainActor
private final class TestSurface: BrowserSurface {
    let profileID: ProfileID
    let initialURL: URL
    var currentURL: URL? { initialURL }
    var disposalCount = 0
    var actions = 0

    init(profileID: ProfileID, url: URL) {
        self.profileID = profileID
        initialURL = url
    }

    func dispose() { disposalCount += 1 }
}

@MainActor
private final class SurfaceRecorder {
    var surfaces: [TestSurface] = []
    var errors: [any Error] = []

    func session(
        store: BrowserStore = BrowserStore(), restoringWindowID: WindowID? = nil
    ) -> BrowserWindowSession<TestSurface> {
        let makeSurface = { (profileID: ProfileID, url: URL) in
            let surface = TestSurface(profileID: profileID, url: url)
            self.surfaces.append(surface)
            return surface
        }
        let session: BrowserWindowSession<TestSurface>
        if let restoringWindowID {
            session = BrowserWindowSession(store: store, restoringWindowID: restoringWindowID, makeSurface: makeSurface)
        } else {
            session = BrowserWindowSession(store: store, makeSurface: makeSurface)
        }
        session.onError = { self.errors.append($0) }
        return session
    }
}

@Test("Rapid open and close commands resolve selection in input order")
@MainActor
func rapidOpenCloseTargetsNewTab() async throws {
    let recorder = SurfaceRecorder()
    let session = recorder.session()
    session.openTab()
    await session.waitForPendingCommands()
    let firstID = try #require(session.snapshot?.selectedOccurrenceID)
    session.openTab(url: URL(string: "https://second.test")!)
    session.closeSelectedTab()
    await session.waitForPendingCommands()
    #expect(session.snapshot?.tabs.map(\.occurrenceID) == [firstID])
    #expect(session.snapshot?.selectedOccurrenceID == firstID)
    #expect(recorder.surfaces.count == 2)
    #expect(recorder.surfaces.map(\.disposalCount) == [0, 1])
    #expect(recorder.errors.isEmpty)
    session.close()
    await session.waitForPendingCommands()
}

@Test("A queued navigation uses the preceding tab selection and keeps surfaces alive")
@MainActor
func navigationFollowsQueuedSelection() async throws {
    let recorder = SurfaceRecorder()
    let session = recorder.session()
    session.openTab()
    session.openTab(activate: false)
    await session.waitForPendingCommands()
    let snapshot = try #require(session.snapshot)
    #expect(snapshot.selectedOccurrenceID == snapshot.tabs[0].occurrenceID)
    session.selectOccurrence(snapshot.tabs[1].occurrenceID)
    session.performOnSelectedSurface { $0.actions += 1 }
    await session.waitForPendingCommands()
    #expect(recorder.surfaces.map(\.actions) == [0, 1])
    #expect(recorder.surfaces.map(\.disposalCount) == [0, 0])
    #expect(recorder.errors.isEmpty)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Window closure revokes queued work and retires only that window's surfaces")
@MainActor
func windowClosurePreventsLateEffects() async throws {
    let store = BrowserStore()
    let firstRecorder = SurfaceRecorder()
    let secondRecorder = SurfaceRecorder()
    let first = firstRecorder.session(store: store)
    let second = secondRecorder.session(store: store)
    first.openTab()
    second.openTab()
    await first.waitForPendingCommands()
    await second.waitForPendingCommands()
    let closedWindowID = try #require(first.snapshot?.id)
    let secondSnapshot = try #require(second.snapshot)
    first.openTab()
    first.performOnSelectedSurface { $0.actions += 1 }
    first.close()
    first.close()
    first.openTab()
    await first.waitForPendingCommands()
    #expect(first.isClosed)
    #expect(first.snapshot == nil)
    #expect(first.selectedSurface == nil)
    #expect(firstRecorder.surfaces.count == 1)
    #expect(firstRecorder.surfaces.map(\.disposalCount) == [1])
    #expect(firstRecorder.surfaces.map(\.actions) == [0])
    await #expect(throws: BrowserStoreError.windowMissing) {
        try await store.captureContext(in: closedWindowID)
    }
    #expect(second.snapshot == secondSnapshot)
    #expect(secondRecorder.surfaces.map(\.disposalCount) == [0])
    #expect(firstRecorder.surfaces[0].profileID != secondRecorder.surfaces[0].profileID)
    #expect(firstRecorder.errors.isEmpty && secondRecorder.errors.isEmpty)
    second.close()
    await second.waitForPendingCommands()
}

@Test("Closing during bootstrap creates no surface or later UI publication")
@MainActor
func closeBeforeInitializationCompletes() async {
    let recorder = SurfaceRecorder()
    let session = recorder.session()
    var publications = 0
    session.onChange = { publications += 1 }
    session.openTab()
    session.close()
    await session.waitForPendingCommands()
    #expect(recorder.surfaces.isEmpty)
    #expect(session.snapshot == nil)
    #expect(publications == 0)
    #expect(recorder.errors.isEmpty)
}

@Test("An invalid tab command fails without discarding later valid commands")
@MainActor
func failedSelectionDoesNotBreakQueue() async throws {
    let recorder = SurfaceRecorder()
    let session = recorder.session()
    session.openTab()
    session.selectOccurrence(TabOccurrenceID())
    session.performOnSelectedSurface { $0.actions += 1 }
    await session.waitForPendingCommands()
    #expect(recorder.errors.count == 1)
    #expect(recorder.errors.first as? BrowserStoreError == .tabMissing)
    #expect(recorder.surfaces.map(\.actions) == [1])
    session.closeSelectedTab()
    await session.waitForPendingCommands()
    #expect(session.snapshot?.tabs.isEmpty == true)
    #expect(session.selectedSurface == nil)
    #expect(!session.isClosed)
    session.performOnSelectedSurface(createIfMissing: true) { $0.actions += 1 }
    await session.waitForPendingCommands()
    #expect(session.snapshot?.tabs.count == 1)
    #expect(recorder.surfaces.map(\.disposalCount) == [1, 0])
    #expect(recorder.surfaces.map(\.actions) == [1, 1])
    session.close()
    await session.waitForPendingCommands()
}

@Test("Duplicate creates a fresh occurrence and recently closed tabs reopen in local reverse order")
@MainActor
func duplicateAndReopenStayWithinWindow() async throws {
    let recorder = SurfaceRecorder()
    let otherRecorder = SurfaceRecorder()
    let session = recorder.session()
    let other = otherRecorder.session()
    let firstURL = URL(string: "https://first.test")!
    let secondURL = URL(string: "https://second.test")!
    session.openTab(url: firstURL)
    session.openTab(url: secondURL)
    await session.waitForPendingCommands()
    let original = try #require(session.snapshot)
    session.duplicateSelectedTab()
    await session.waitForPendingCommands()
    let duplicateID = try #require(session.snapshot?.selectedOccurrenceID)
    #expect(!original.tabs.contains { $0.occurrenceID == duplicateID })
    #expect(session.selectedSurface?.initialURL == secondURL)
    session.closeSelectedTab()
    session.selectOccurrence(original.tabs[0].occurrenceID)
    session.closeSelectedTab()
    await session.waitForPendingCommands()
    #expect(session.canReopenClosedTab)
    session.reopenClosedTab()
    await session.waitForPendingCommands()
    #expect(session.selectedSurface?.initialURL == firstURL)
    session.reopenClosedTab()
    await session.waitForPendingCommands()
    #expect(session.selectedSurface?.initialURL == secondURL)
    #expect(!session.canReopenClosedTab)
    other.reopenClosedTab()
    await other.waitForPendingCommands()
    #expect(other.snapshot?.tabs.isEmpty == true)
    #expect(otherRecorder.surfaces.isEmpty)
    #expect(recorder.errors.isEmpty && otherRecorder.errors.isEmpty)
    session.close()
    other.close()
    await session.waitForPendingCommands()
    await other.waitForPendingCommands()
}

@Test("A menu close cannot be overtaken by a direct tab selection")
@MainActor
func menuClosePrecedesDirectSelection() async throws {
    let recorder = SurfaceRecorder()
    let router = BrowserWindowRouter(create: { _ in recorder.session() }, present: { _, _ in }, dispose: { $0.close() })
    router.newWindow()
    await router.waitForPendingCommands()
    let session = try #require(router.selectedWindow)
    session.openTab()
    session.openTab(activate: false)
    await session.waitForPendingCommands()
    let initial = try #require(session.snapshot)
    router.perform { $0.closeSelectedTab() }
    session.selectOccurrence(initial.tabs[1].occurrenceID)
    await session.waitForPendingCommands()
    #expect(session.snapshot?.tabs.map(\.occurrenceID) == [initial.tabs[1].occurrenceID])
    #expect(recorder.surfaces.map(\.disposalCount) == [1, 0])
    #expect(recorder.errors.isEmpty)
    router.shutdown()
    await session.waitForPendingCommands()
}

@Test("An external Space/profile change is refused instead of using the old profile's surfaces")
@MainActor
func changedProfileCannotReuseSurfaceFactory() async throws {
    let store = BrowserStore()
    let recorder = SurfaceRecorder()
    let session = recorder.session(store: store)
    session.openTab()
    await session.waitForPendingCommands()
    let windowID = try #require(session.snapshot?.id)
    let otherProfile = await store.createProfile(name: "Other")
    let otherSpace = try await store.createSpace(name: "Other", profileID: otherProfile)
    try await store.activateSpace(otherSpace, in: windowID)
    session.openTab()
    session.performOnSelectedSurface { $0.actions += 1 }
    await session.waitForPendingCommands()
    #expect(recorder.errors.count == 2)
    #expect(recorder.errors.allSatisfy { ($0 as? BrowserWindowSessionError) == .contextChangeRequiresNewSession })
    #expect(recorder.surfaces.count == 1)
    #expect(recorder.surfaces[0].actions == 0)
    #expect(try await store.snapshot(of: windowID).tabs.isEmpty)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Duplicate refuses a model selection that has not been published to the shell")
@MainActor
func duplicateRejectsUnpublishedSelection() async throws {
    let store = BrowserStore()
    let recorder = SurfaceRecorder()
    let session = recorder.session(store: store)
    session.openTab(url: URL(string: "https://first.test")!)
    session.openTab(url: URL(string: "https://second.test")!, activate: false)
    await session.waitForPendingCommands()
    let snapshot = try #require(session.snapshot)
    try await store.selectOccurrence(snapshot.tabs[1].occurrenceID, in: snapshot.id)
    session.duplicateSelectedTab()
    await session.waitForPendingCommands()
    #expect(recorder.errors.first as? BrowserStoreError == .staleContext)
    #expect(recorder.surfaces.count == 2)
    #expect(try await store.snapshot(of: snapshot.id).tabs.count == 2)
    session.close()
    await session.waitForPendingCommands()
}

private struct RestoredWindowFixture {
    let store: BrowserStore
    let windowID: WindowID
    let otherWindowID: WindowID
    let personalProfileID: ProfileID
    let workProfileID: ProfileID
    let document: BrowserSessionDocument
}

private func restoredWindowFixture() async throws -> RestoredWindowFixture {
    let original = BrowserStore()
    let personal = await original.createProfile(name: "Synthetic Personal")
    let work = await original.createProfile(name: "Synthetic Work")
    let home = try await original.createSpace(name: "Home", profileID: personal)
    let office = try await original.createSpace(name: "Office", profileID: work)
    let window = try await original.createWindow(activeSpaceID: home)
    let otherWindow = try await original.createWindow(activeSpaceID: office)
    let first = try await original.openTab(url: URL(string: "https://restore.test/first")!,
        from: original.captureContext(in: window), activate: true)
    let second = try await original.openTab(url: URL(string: "https://restore.test/selected")!,
        from: original.captureContext(in: window), activate: false)
    _ = try await original.openTab(url: URL(string: "https://restore.test/background")!,
        from: original.captureContext(in: window), activate: false)
    try await original.selectOccurrence(second, in: window)
    try await original.activateSpace(office, in: window)
    _ = try await original.openTab(url: URL(string: "https://restore.test/inactive-space")!,
        from: original.captureContext(in: window), activate: true)
    try await original.activateSpace(home, in: window)
    #expect(try await original.snapshot(of: window).selectedOccurrenceID != first)
    _ = try await original.openTab(url: URL(string: "https://restore.test/other-window")!,
        from: original.captureContext(in: otherWindow), activate: true)
    let document = try BrowserSessionDocument.decode(await original.sessionDocument().encoded())
    return RestoredWindowFixture(store: try BrowserStore(restoring: document), windowID: window,
        otherWindowID: otherWindow, personalProfileID: personal, workProfileID: work, document: document)
}

@Test("Adoption preserves restored order, exact identities and selection and publishes fully owned surfaces once")
@MainActor
func adoptionReconstructsActiveSpaceOccurrences() async throws {
    let fixture = try await restoredWindowFixture()
    let expected = try await fixture.store.snapshot(of: fixture.windowID)
    let recorder = SurfaceRecorder()
    let session = recorder.session(store: fixture.store, restoringWindowID: fixture.windowID)
    var publications = 0
    session.onChange = {
        publications += 1
        #expect(session.snapshot == expected)
        for tab in expected.tabs {
            #expect(session.surface(for: tab.occurrenceID)?.initialURL == tab.url)
            #expect(session.surface(for: tab.occurrenceID)?.profileID == fixture.personalProfileID)
        }
        #expect(session.selectedSurface === session.surface(for: expected.tabs[1].occurrenceID))
    }
    await session.waitForPendingCommands()
    #expect(publications == 1)
    #expect(session.snapshot == expected)
    #expect(recorder.surfaces.map(\.initialURL) == expected.tabs.map(\.url))
    #expect(recorder.surfaces.count == 3)
    #expect(recorder.errors.isEmpty)
    #expect(await fixture.store.sessionDocument() == fixture.document)
    session.close()
    await session.waitForPendingCommands()
    #expect(recorder.surfaces.map(\.disposalCount) == [1, 1, 1])
}

@Test("Two restored windows recreate each surface with its own profile and saved destination")
@MainActor
func adoptedWindowsKeepProfilesAndSurfacesSeparate() async throws {
    let fixture = try await restoredWindowFixture()
    let firstRecorder = SurfaceRecorder()
    let secondRecorder = SurfaceRecorder()
    let first = firstRecorder.session(store: fixture.store, restoringWindowID: fixture.windowID)
    let second = secondRecorder.session(store: fixture.store, restoringWindowID: fixture.otherWindowID)
    await first.waitForPendingCommands()
    await second.waitForPendingCommands()
    #expect(firstRecorder.surfaces.allSatisfy { $0.profileID == fixture.personalProfileID })
    #expect(secondRecorder.surfaces.map(\.profileID) == [fixture.workProfileID])
    #expect(secondRecorder.surfaces.map(\.initialURL) == second.snapshot?.tabs.map(\.url))
    #expect(await fixture.store.sessionDocument() == fixture.document)
    first.close()
    await first.waitForPendingCommands()
    #expect(firstRecorder.surfaces.map(\.disposalCount) == [1, 1, 1])
    #expect(secondRecorder.surfaces.map(\.disposalCount) == [0])
    #expect(second.snapshot == (try await fixture.store.snapshot(of: fixture.otherWindowID)))
    second.close()
    await second.waitForPendingCommands()
    #expect(await fixture.store.sessionDocument().tabs.isEmpty)
}

@Test("Adoption preserves an empty window or background-only window without selecting or adding a tab", arguments: [false, true])
@MainActor
func adoptionPreservesAbsentSelection(hasBackgroundTab: Bool) async throws {
    let original = BrowserStore()
    let profile = await original.createProfile(name: "Synthetic")
    let space = try await original.createSpace(name: "Home", profileID: profile)
    let window = try await original.createWindow(activeSpaceID: space)
    if hasBackgroundTab {
        _ = try await original.openTab(url: URL(string: "https://restore.test/background-only")!,
            from: original.captureContext(in: window), activate: false)
    }
    let store = try BrowserStore(restoring: await original.sessionDocument())
    let expected = try await store.snapshot(of: window)
    let recorder = SurfaceRecorder()
    let session = recorder.session(store: store, restoringWindowID: window)
    await session.waitForPendingCommands()
    #expect(session.snapshot == expected)
    #expect(session.selectedSurface == nil)
    #expect(session.snapshot?.selectedOccurrenceID == nil)
    #expect(recorder.surfaces.count == (hasBackgroundTab ? 1 : 0))
    #expect(recorder.errors.isEmpty)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Revoking adoption before bootstrap cleans up only its owned window or preserves it for termination", arguments: [false, true])
@MainActor
func adoptionRevokedBeforeBootstrap(preservingModel: Bool) async throws {
    let fixture = try await restoredWindowFixture()
    let recorder = SurfaceRecorder()
    let session = recorder.session(store: fixture.store, restoringWindowID: fixture.windowID)
    var publications = 0
    session.onChange = { publications += 1 }
    session.openTab()
    if preservingModel { session.retireForApplicationTermination() }
    else { session.close() }
    await session.waitForPendingCommands()
    #expect(session.isClosed)
    #expect(!session.hasPendingCommands)
    #expect(session.snapshot == nil)
    #expect(recorder.surfaces.isEmpty)
    #expect(publications == 0)
    #expect(recorder.errors.isEmpty)
    if preservingModel {
        #expect(await fixture.store.sessionDocument() == fixture.document)
    } else {
        await #expect(throws: BrowserStoreError.windowMissing) {
            try await fixture.store.snapshot(of: fixture.windowID)
        }
        #expect(await fixture.store.sessionDocument().tabs.allSatisfy { $0.windowID == fixture.otherWindowID })
    }
    #expect(try await fixture.store.snapshot(of: fixture.otherWindowID).tabs.count == 1)
}

@Test("A factory that closes adoption retires already owned and just returned surfaces without publication")
@MainActor
func adoptionFactoryClosureCannotLeakSurfaces() async throws {
    let fixture = try await restoredWindowFixture()
    var surfaces: [TestSurface] = []
    var session: BrowserWindowSession<TestSurface>!
    session = BrowserWindowSession(store: fixture.store, restoringWindowID: fixture.windowID) { profileID, url in
        let surface = TestSurface(profileID: profileID, url: url)
        surfaces.append(surface)
        if surfaces.count == 2 { session.close() }
        return surface
    }
    var publications = 0
    session.onChange = { publications += 1 }
    await session.waitForPendingCommands()
    #expect(!session.hasPendingCommands)
    #expect(surfaces.count == 2)
    #expect(surfaces.map(\.disposalCount) == [1, 1])
    #expect(publications == 0)
    #expect(session.snapshot == nil)
    await #expect(throws: BrowserStoreError.windowMissing) {
        try await fixture.store.snapshot(of: fixture.windowID)
    }
}

@Test("Termination retirement preserves the model for readoption and revokes disposed surface callbacks")
@MainActor
func terminationRetirementAllowsReadoption() async throws {
    let fixture = try await restoredWindowFixture()
    let recorder = SurfaceRecorder()
    let session = recorder.session(store: fixture.store, restoringWindowID: fixture.windowID)
    await session.waitForPendingCommands()
    let expected = try #require(session.snapshot)
    let surface = try #require(session.selectedSurface)
    session.retireForApplicationTermination()
    session.updateDestination(for: surface, to: URL(string: "https://late.test")!)
    session.openTab()
    session.close()
    await session.waitForPendingCommands()
    #expect(recorder.surfaces.map(\.disposalCount) == [1, 1, 1])
    #expect(await fixture.store.sessionDocument() == fixture.document)
    let next = recorder.session(store: fixture.store, restoringWindowID: fixture.windowID)
    await next.waitForPendingCommands()
    #expect(next.snapshot == expected)
    #expect(recorder.surfaces.count == 6)
    #expect(recorder.errors.isEmpty)
    next.close()
    await next.waitForPendingCommands()
}

@Test("A missing adopted window reports failure without creating a replacement window or blank tab")
@MainActor
func adoptionOfMissingWindowDoesNotCreateState() async throws {
    let store = BrowserStore()
    let recorder = SurfaceRecorder()
    let session = recorder.session(store: store, restoringWindowID: WindowID())
    await session.waitForPendingCommands()
    #expect(session.snapshot == nil)
    #expect(recorder.errors.count == 1)
    #expect(recorder.errors.first as? BrowserStoreError == .windowMissing)
    #expect(recorder.surfaces.isEmpty)
    #expect(await store.sessionDocument().windows.isEmpty)
    #expect(await store.sessionDocument().profiles.isEmpty)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Background navigation updates its saved occurrence without changing selection and unchanged URLs do not publish")
@MainActor
func backgroundDestinationPersistsWithoutRetargetingSelection() async throws {
    let fixture = try await restoredWindowFixture()
    let recorder = SurfaceRecorder()
    let session = recorder.session(store: fixture.store, restoringWindowID: fixture.windowID)
    await session.waitForPendingCommands()
    let before = try #require(session.snapshot)
    let selectedSurface = try #require(session.selectedSurface)
    let background = try #require(session.surface(for: before.tabs[2].occurrenceID))
    let context = try await fixture.store.captureContext(in: fixture.windowID)
    let destination = URL(string: "https://restore.test/redirected-background")!
    var publications = 0
    session.onChange = { publications += 1 }
    session.updateDestination(for: background, to: destination)
    session.performOnSelectedSurface { $0.actions += 1 }
    await session.waitForPendingCommands()
    let after = try #require(session.snapshot)
    #expect(after.tabs[2].url == destination)
    #expect(after.tabs[0] == before.tabs[0])
    #expect(after.tabs[1] == before.tabs[1])
    #expect(after.tabs.map(\.id) == before.tabs.map(\.id))
    #expect(after.tabs.map(\.occurrenceID) == before.tabs.map(\.occurrenceID))
    #expect(after.tabs.map(\.spaceID) == before.tabs.map(\.spaceID))
    #expect(after.selectedOccurrenceID == before.selectedOccurrenceID)
    #expect(after.revision == before.revision)
    #expect(session.selectedSurface === selectedSurface)
    #expect(selectedSurface.actions == 1 && background.actions == 0)
    #expect(await fixture.store.isCurrent(context))
    #expect(publications == 1)
    let encoded = try await fixture.store.sessionDocument().encoded()
    let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(encoded))
    #expect(try await restored.snapshot(of: fixture.windowID).tabs == after.tabs)
    session.updateDestination(for: background, to: destination)
    await session.waitForPendingCommands()
    #expect(publications == 1)
    #expect(try await fixture.store.sessionDocument().encoded() == encoded)
    session.selectOccurrence(before.tabs[0].occurrenceID)
    session.updateDestination(for: background, to: URL(string: "https://restore.test/another-redirect")!)
    await session.waitForPendingCommands()
    #expect(session.snapshot?.selectedOccurrenceID == before.tabs[0].occurrenceID)
    #expect(recorder.errors.isEmpty)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Foreign, disposed and invalid navigation callbacks cannot mutate or recreate occurrences")
@MainActor
func destinationCallbacksRequireLiveOwnedSurface() async throws {
    let store = BrowserStore()
    let firstRecorder = SurfaceRecorder()
    let secondRecorder = SurfaceRecorder()
    let first = firstRecorder.session(store: store)
    let second = secondRecorder.session(store: store)
    first.openTab()
    first.openTab(activate: false)
    second.openTab()
    await first.waitForPendingCommands()
    await second.waitForPendingCommands()
    let selected = try #require(first.selectedSurface)
    let foreign = try #require(second.selectedSurface)
    let before = try await store.sessionDocument().encoded()
    first.updateDestination(for: foreign, to: URL(string: "https://foreign.test")!)
    first.updateDestination(for: selected, to: URL(string: "relative-destination")!)
    await first.waitForPendingCommands()
    #expect(firstRecorder.errors.count == 2)
    #expect(firstRecorder.errors[0] as? BrowserWindowSessionError == .surfaceNotOwned)
    #expect(firstRecorder.errors[1] as? BrowserSessionError == .invalidURL)
    #expect(try await store.sessionDocument().encoded() == before)
    first.closeSelectedTab()
    first.updateDestination(for: selected, to: URL(string: "https://disposed.test")!)
    await first.waitForPendingCommands()
    #expect(firstRecorder.errors.count == 3)
    #expect(firstRecorder.errors[2] as? BrowserWindowSessionError == .surfaceNotOwned)
    #expect(selected.disposalCount == 1)
    #expect(first.snapshot?.tabs.count == 1)
    #expect(first.snapshot?.tabs[0].url == URL(string: "about:blank"))
    first.updateDestination(for: first.selectedSurface!, to: URL(string: "https://closed.test")!)
    first.close()
    await first.waitForPendingCommands()
    #expect(await store.sessionDocument().tabs.count == 1)
    #expect(secondRecorder.surfaces.map(\.disposalCount) == [0])
    second.close()
    await second.waitForPendingCommands()
}

@Test("Background URL callbacks reject unpublished selection and Space round trips instead of gaining new authority")
@MainActor
func destinationCallbackRejectsStaleShellAuthority() async throws {
    let fixture = try await restoredWindowFixture()
    let recorder = SurfaceRecorder()
    let session = recorder.session(store: fixture.store, restoringWindowID: fixture.windowID)
    await session.waitForPendingCommands()
    let before = try #require(session.snapshot)
    let background = try #require(session.surface(for: before.tabs[2].occurrenceID))
    try await fixture.store.selectOccurrence(before.tabs[0].occurrenceID, in: fixture.windowID)
    try await fixture.store.selectOccurrence(before.tabs[1].occurrenceID, in: fixture.windowID)
    let encoded = try await fixture.store.sessionDocument().encoded()
    session.updateDestination(for: background, to: URL(string: "https://stale.test")!)
    await session.waitForPendingCommands()
    #expect(recorder.errors.count == 1)
    #expect(recorder.errors[0] as? BrowserStoreError == .staleContext)
    #expect(try await fixture.store.sessionDocument().encoded() == encoded)
    let otherSpace = try #require(fixture.document.spaces.first { $0.id != before.activeSpaceID })
    try await fixture.store.activateSpace(otherSpace.id, in: fixture.windowID)
    try await fixture.store.activateSpace(before.activeSpaceID, in: fixture.windowID)
    // The round trip itself records viewing time; only the rejected callback must not mutate.
    let afterRoundTrip = try await fixture.store.sessionDocument().encoded()
    session.updateDestination(for: background, to: URL(string: "https://stale-space.test")!)
    await session.waitForPendingCommands()
    #expect(recorder.errors.count == 2)
    #expect(recorder.errors[1] as? BrowserStoreError == .staleContext)
    #expect(try await fixture.store.sessionDocument().encoded() == afterRoundTrip)
    #expect(session.snapshot == before)
    session.close()
    await session.waitForPendingCommands()
}

/// Holds only a synthetic store's executor to exercise UI revocation across suspended actor calls.
private final class SessionStoreGate: @unchecked Sendable {
    let entered = AsyncStream<Void>.makeStream()
    private let releaseSignal = DispatchSemaphore(value: 0)

    func hold() {
        entered.continuation.yield(())
        entered.continuation.finish()
        #expect(releaseSignal.wait(timeout: .now() + 10) == .success)
    }

    func release() { releaseSignal.signal() }

    func waitUntilEntered() async {
        for await _ in entered.stream { return }
    }
}

private extension BrowserStore {
    func holdSessionTestExecutor(_ gate: SessionStoreGate) { gate.hold() }
}

@Test("Closing adoption while its store executor is occupied cannot publish surfaces or leak the model window")
@MainActor
func adoptionCloseDuringStoreHop() async throws {
    let fixture = try await restoredWindowFixture()
    let gate = SessionStoreGate()
    let blocker = Task.detached { await fixture.store.holdSessionTestExecutor(gate) }
    await gate.waitUntilEntered()
    defer { gate.release() }
    let recorder = SurfaceRecorder()
    let session = recorder.session(store: fixture.store, restoringWindowID: fixture.windowID)
    var publications = 0
    session.onChange = { publications += 1 }
    await Task { @MainActor in session.close() }.value
    gate.release()
    await blocker.value
    await session.waitForPendingCommands()
    #expect(session.snapshot == nil)
    #expect(recorder.surfaces.isEmpty)
    #expect(recorder.errors.isEmpty)
    #expect(publications == 0)
    #expect(!session.hasPendingCommands)
    await #expect(throws: BrowserStoreError.windowMissing) {
        try await fixture.store.snapshot(of: fixture.windowID)
    }
    #expect(try await fixture.store.snapshot(of: fixture.otherWindowID).tabs.count == 1)
}

@Test("Retirement across a destination callback's actor hop revokes mutation and all later publication")
@MainActor
func destinationCloseDuringStoreHop() async throws {
    let fixture = try await restoredWindowFixture()
    let recorder = SurfaceRecorder()
    let session = recorder.session(store: fixture.store, restoringWindowID: fixture.windowID)
    await session.waitForPendingCommands()
    let surface = try #require(session.selectedSurface)
    let gate = SessionStoreGate()
    let blocker = Task.detached { await fixture.store.holdSessionTestExecutor(gate) }
    await gate.waitUntilEntered()
    defer { gate.release() }
    var publications = 0
    session.onChange = { publications += 1 }
    session.updateDestination(for: surface, to: URL(string: "https://revoked.test")!)
    await Task { @MainActor in session.retireForApplicationTermination() }.value
    gate.release()
    await blocker.value
    await session.waitForPendingCommands()
    #expect(await fixture.store.sessionDocument() == fixture.document)
    #expect(session.snapshot == nil)
    #expect(recorder.surfaces.map(\.disposalCount) == [1, 1, 1])
    #expect(recorder.errors.isEmpty)
    #expect(publications == 0)
    #expect(!session.hasPendingCommands)
}
