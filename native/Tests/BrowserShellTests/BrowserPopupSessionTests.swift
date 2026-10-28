import BrowserCore
import BrowserShell
import Foundation
import Testing

@MainActor
private class PopupSurface: BrowserSurface {
    let profileID: ProfileID
    var nativeHistory: [URL]
    var submittedBody = Data("synthetic-post-body".utf8)
    var opener: PopupSurface?
    var navigationCount = 0
    var disposalCount = 0
    var onDispose: (() -> Void)?
    var currentURL: URL? { nativeHistory.last }

    init(profileID: ProfileID, url: URL) {
        self.profileID = profileID
        nativeHistory = [url]
    }

    func navigate(to url: URL) {
        navigationCount += 1
        nativeHistory.append(url)
    }

    func dispose() {
        disposalCount += 1
        onDispose?()
    }
}

@MainActor
private final class SpecializedPopupSurface: PopupSurface {}

@MainActor
private final class PopupRecorder {
    var generated: [PopupSurface] = []
    var errors: [any Error] = []
    var onMake: ((PopupSurface) -> Void)?

    func session(_ fixture: PopupFixture, windowID: WindowID? = nil) -> BrowserWindowSession<PopupSurface> {
        let session = BrowserWindowSession(store: fixture.store, restoringWindowID: windowID ?? fixture.windowID) { profile, url in
            let surface = PopupSurface(profileID: profile, url: url)
            self.generated.append(surface)
            self.onMake?(surface)
            return surface
        }
        session.onError = { self.errors.append($0) }
        return session
    }
}

private struct PopupFixture: Sendable {
    let store: BrowserStore
    let profileID: ProfileID
    let otherProfileID: ProfileID
    let home: SpaceID
    let sameProfileSpace: SpaceID
    let otherProfileSpace: SpaceID
    let windowID: WindowID
    let selectedID: TabOccurrenceID
    let backgroundID: TabOccurrenceID
}

private func popupFixture() async throws -> PopupFixture {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic Popup Profile")
    let otherProfile = await store.createProfile(name: "Synthetic Other Profile")
    let home = try await store.createSpace(name: "Popup Home", profileID: profile)
    let sameProfileSpace = try await store.createSpace(name: "Popup Same Profile", profileID: profile)
    let otherProfileSpace = try await store.createSpace(name: "Popup Other Profile", profileID: otherProfile)
    let window = try await store.createWindow(activeSpaceID: home)
    let selected = try await store.openTab(url: URL(string: "https://popup.test/opener")!,
        from: store.captureContext(in: window), activate: true)
    let background = try await store.openTab(url: URL(string: "https://popup.test/background")!,
        from: store.captureContext(in: window), activate: false)
    return PopupFixture(store: store, profileID: profile, otherProfileID: otherProfile, home: home,
        sameProfileSpace: sameProfileSpace, otherProfileSpace: otherProfileSpace, windowID: window,
        selectedID: selected, backgroundID: background)
}

@MainActor
private struct PopupHarness {
    let fixture: PopupFixture
    let recorder: PopupRecorder
    let session: BrowserWindowSession<PopupSurface>

    func providedSurface(from opener: PopupSurface) -> PopupSurface {
        let surface = PopupSurface(profileID: fixture.profileID, url: URL(string: "https://popup.test/native-response")!)
        surface.opener = opener
        return surface
    }

    func close() async {
        session.close()
        await session.waitForPendingCommands()
        #expect(!session.hasPendingCommands)
        #expect(recorder.generated.allSatisfy { $0.disposalCount == 1 })
    }
}

@MainActor
private func popupHarness() async throws -> PopupHarness {
    let fixture = try await popupFixture()
    let recorder = PopupRecorder()
    let session = recorder.session(fixture)
    await session.waitForPendingCommands()
    return PopupHarness(fixture: fixture, recorder: recorder, session: session)
}

/// Blocks only a synthetic model actor while the UI revokes its authority.
private final class PopupStoreGate: @unchecked Sendable {
    let entered = AsyncStream<Void>.makeStream()
    private let enteredSignal = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)

    func hold() {
        enteredSignal.signal()
        entered.continuation.yield(())
        entered.continuation.finish()
        #expect(releaseSignal.wait(timeout: .now() + 10) == .success)
    }

    func release() { releaseSignal.signal() }
    func waitUntilEntered() async { for await _ in entered.stream { return } }

    /// Starts the store hold after a reentrant command is accepted, before its UI callback returns.
    func waitForSynchronousEntry() -> Bool { enteredSignal.wait(timeout: .now() + 2) == .success }
}

private extension BrowserStore {
    func holdPopupTestExecutor(_ gate: PopupStoreGate) { gate.hold() }
}

@MainActor
private func selectionQueuedBeforeStoreHold(
    _ harness: PopupHarness, context: BrowserContext, intent: BrowserSelectionIntent
) async throws -> (selection: Task<Bool, Never>, gate: PopupStoreGate, blocker: Task<Void, Never>) {
    let gate = PopupStoreGate()
    let store = harness.fixture.store
    var selection: Task<Bool, Never>?
    var blocker: Task<Void, Never>?
    harness.session.performWindowAction {
        selection = harness.session.selectOccurrence(harness.fixture.backgroundID, ifContextMatches: context, while: intent)
        #expect(harness.session.hasPendingCommands)
        blocker = Task.detached { await store.holdPopupTestExecutor(gate) }
        // This callback runs outside all model locks. Its queued selection cannot start until the
        // callback returns, so the store is held strictly after acceptance and before the actor hop.
        #expect(gate.waitForSynchronousEntry())
    }
    await gate.waitUntilEntered()
    await Task { @MainActor in }.value
    return (try #require(selection), gate, try #require(blocker))
}

@Suite("Provided popup surface command ordering")
@MainActor
struct BrowserPopupSessionTests {
    @Test("Background adoption preserves the exact native surface, request state, profile and selection")
    func backgroundAdoptionKeepsNativeIdentity() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let opener = try #require(session.selectedSurface)
        let provided = harness.providedSurface(from: opener)
        let history = [URL(string: "https://popup.test/native-post")!, provided.currentURL!]
        provided.nativeHistory = history
        let context = try await harness.fixture.store.captureContext(in: harness.fixture.windowID)
        let adoption = session.adoptSurface(provided, from: opener, profileID: harness.fixture.profileID,
            url: provided.currentURL!)
        #expect(session.hasPendingCommands)
        let occurrence = try #require(await adoption.value)
        await session.waitForPendingCommands()
        #expect(session.surface(for: occurrence) === provided)
        #expect(session.occurrenceID(for: provided) == occurrence)
        #expect(session.ownedSurfaces.last === provided)
        #expect(provided.profileID == harness.fixture.profileID)
        #expect(provided.nativeHistory == history && provided.navigationCount == 0)
        #expect(provided.submittedBody == Data("synthetic-post-body".utf8) && provided.opener === opener)
        #expect(provided.disposalCount == 0 && opener.disposalCount == 0)
        #expect(harness.recorder.generated.count == 2)
        #expect(session.selectedSurface === opener)
        #expect(try await harness.fixture.store.captureContext(in: harness.fixture.windowID) == context)
        #expect(session.snapshot == (try await harness.fixture.store.snapshot(of: harness.fixture.windowID)))
        #expect(session.snapshot?.tabs.last?.url == provided.currentURL)
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
        #expect(provided.disposalCount == 1)
    }

    @Test("A background source in the active Space can adopt without taking selection")
    func backgroundSourceCanAdopt() async throws {
        let harness = try await popupHarness()
        let source = try #require(harness.session.surface(for: harness.fixture.backgroundID))
        let provided = harness.providedSurface(from: source)
        let before = harness.session.snapshot
        let id = try #require(await harness.session.adoptSurface(provided, from: source,
            profileID: harness.fixture.profileID, url: provided.currentURL!).value)
        #expect(harness.session.surface(for: id) === provided)
        #expect(harness.session.snapshot?.selectedOccurrenceID == before?.selectedOccurrenceID)
        #expect(harness.session.snapshot?.revision == before?.revision)
        #expect(source.disposalCount == 0 && harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("The synchronous context boundary precedes adoption and conditional HTML selection")
    func capturedContextCanForegroundAdoption() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let source = try #require(session.selectedSurface)
        let provided = harness.providedSurface(from: source)
        let boundary = session.captureContextInCommandOrder()
        let adoption = session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
            url: provided.currentURL!)
        let expected = try #require(await boundary.value)
        let id = try #require(await adoption.value)
        #expect(session.snapshot?.selectedOccurrenceID == expected.selectedOccurrenceID)
        #expect(session.snapshot?.revision == expected.revision)
        let selected = session.selectOccurrence(id, ifContextMatches: expected)
        #expect(session.hasPendingCommands)
        #expect(await selected.value)
        await session.waitForPendingCommands()
        #expect(session.selectedSurface === provided)
        #expect(session.snapshot?.revision == expected.revision &+ 1)
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("User selection after acceptance preserves the popup but prevents late foregrounding", arguments: [false, true])
    func laterSelectionPreventsForegrounding(roundTrip: Bool) async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let opener = try #require(session.selectedSurface)
        let provided = harness.providedSurface(from: opener)
        let boundary = session.captureContextInCommandOrder()
        let adoption = session.adoptSurface(provided, from: opener, profileID: harness.fixture.profileID,
            url: provided.currentURL!)
        session.selectOccurrence(harness.fixture.backgroundID)
        if roundTrip { session.selectOccurrence(harness.fixture.selectedID) }
        let expected = try #require(await boundary.value)
        let id = try #require(await adoption.value)
        #expect(!(await session.selectOccurrence(id, ifContextMatches: expected).value))
        await session.waitForPendingCommands()
        #expect(session.snapshot?.selectedOccurrenceID == (roundTrip ? harness.fixture.selectedID : harness.fixture.backgroundID))
        #expect(session.surface(for: id) === provided && provided.disposalCount == 0)
        #expect(opener.disposalCount == 0 && provided.navigationCount == 0)
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("A prior queued user selection permits background adoption without retargeting the source")
    func priorSelectionDoesNotRevokeSource() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let source = try #require(session.selectedSurface)
        let provided = harness.providedSurface(from: source)
        session.selectOccurrence(harness.fixture.backgroundID)
        let capture = session.captureContextInCommandOrder()
        let adoption = session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
            url: provided.currentURL!)
        let expected = try #require(await capture.value)
        let id = try #require(await adoption.value)
        #expect(session.surface(for: id) === provided)
        #expect(expected.selectedOccurrenceID == harness.fixture.backgroundID)
        #expect(session.snapshot?.selectedOccurrenceID == expected.selectedOccurrenceID)
        #expect(session.snapshot?.revision == expected.revision)
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("A queued Space switch rejects the immutable old source even with the same profile", arguments: [false, true])
    func queuedSpaceSwitchRejectsOldSource(sameProfile: Bool) async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let source = try #require(session.selectedSurface)
        let provided = harness.providedSurface(from: source)
        let destination = sameProfile ? harness.fixture.sameProfileSpace : harness.fixture.otherProfileSpace
        session.activateSpace(destination)
        let adoption = session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
            url: provided.currentURL!)
        #expect(await adoption.value == nil)
        await session.waitForPendingCommands()
        #expect(provided.disposalCount == 1 && source.disposalCount == 0)
        #expect(session.snapshot?.activeSpaceID == destination && session.snapshot?.tabs.isEmpty == true)
        #expect(await harness.fixture.store.sessionDocument().tabs.count == 2)
        #expect(harness.recorder.generated.count == 2 && harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("An exact supplied profile and an existing owned source are required", arguments: [false, true])
    func invalidSourceOrProfileIsRejected(wrongProfile: Bool) async throws {
        let harness = try await popupHarness()
        let owned = try #require(harness.session.selectedSurface)
        let foreign = PopupSurface(profileID: harness.fixture.profileID, url: URL(string: "https://popup.test/foreign")!)
        let source = wrongProfile ? owned : foreign
        let provided = harness.providedSurface(from: source)
        let before = await harness.fixture.store.sessionDocument()
        #expect(await harness.session.adoptSurface(provided, from: source,
            profileID: wrongProfile ? harness.fixture.otherProfileID : harness.fixture.profileID,
            url: provided.currentURL!).value == nil)
        await harness.session.waitForPendingCommands()
        #expect(provided.disposalCount == 1 && owned.disposalCount == 0 && foreign.disposalCount == 0)
        #expect(await harness.fixture.store.sessionDocument() == before)
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("Atomic inventory rejects an externally removed background source without recreating it")
    func removedBackgroundSourceIsRejected() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let source = try #require(session.surface(for: harness.fixture.backgroundID))
        let provided = harness.providedSurface(from: source)
        let context = try await harness.fixture.store.captureContext(in: harness.fixture.windowID)
        try await harness.fixture.store.closeOccurrence(harness.fixture.backgroundID, from: context)
        #expect(await harness.fixture.store.isCurrent(context))
        let before = await harness.fixture.store.sessionDocument()
        #expect(await session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
            url: provided.currentURL!).value == nil)
        await session.waitForPendingCommands()
        #expect(await harness.fixture.store.sessionDocument() == before)
        #expect(provided.disposalCount == 1 && source.disposalCount == 0)
        #expect(session.snapshot?.selectedOccurrenceID == harness.fixture.selectedID)
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("A queued source close revokes adoption and following ordinary commands still execute")
    func queuedSourceCloseDoesNotBreakDrain() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let source = try #require(session.surface(for: harness.fixture.backgroundID))
        let provided = harness.providedSurface(from: source)
        session.closeOccurrence(harness.fixture.backgroundID)
        let adoption = session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
            url: provided.currentURL!)
        session.openTab(url: URL(string: "https://popup.test/after-rejection")!, activate: false)
        #expect(await adoption.value == nil)
        await session.waitForPendingCommands()
        #expect(source.disposalCount == 1 && provided.disposalCount == 1)
        #expect(session.snapshot?.tabs.count == 2 && session.snapshot?.selectedOccurrenceID == harness.fixture.selectedID)
        #expect(session.snapshot?.tabs.last?.url == URL(string: "https://popup.test/after-rejection"))
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("Out-of-band selection changes reject adoption and conditional selection silently", arguments: [false, true])
    func externalSelectionCannotAuthorizeCallbacks(roundTrip: Bool) async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let source = try #require(session.selectedSurface)
        let expected = try #require(await session.captureContextInCommandOrder().value)
        let provided = harness.providedSurface(from: source)
        try await harness.fixture.store.selectOccurrence(harness.fixture.backgroundID, in: harness.fixture.windowID)
        if roundTrip {
            try await harness.fixture.store.selectOccurrence(harness.fixture.selectedID, in: harness.fixture.windowID)
        }
        let before = await harness.fixture.store.sessionDocument()
        let snapshot = session.snapshot
        #expect(await session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
            url: provided.currentURL!).value == nil)
        #expect(!(await session.selectOccurrence(harness.fixture.backgroundID, ifContextMatches: expected).value))
        await session.waitForPendingCommands()
        #expect(await harness.fixture.store.sessionDocument() == before)
        #expect(session.snapshot == snapshot && provided.disposalCount == 1)
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("Conditional selection requires a live owned target in the current Space")
    func conditionalSelectionRejectsMissingAndInactiveTargets() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let expected = try #require(await session.captureContextInCommandOrder().value)
        #expect(!(await session.selectOccurrence(TabOccurrenceID(), ifContextMatches: expected).value))
        session.activateSpace(harness.fixture.sameProfileSpace)
        let next = try #require(await session.captureContextInCommandOrder().value)
        #expect(!(await session.selectOccurrence(harness.fixture.selectedID, ifContextMatches: next).value))
        #expect(session.snapshot?.activeSpaceID == harness.fixture.sameProfileSpace)
        #expect(session.selectedSurface == nil && harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("Duplicate offers and existing owned instances never dispose or duplicate live surfaces")
    func duplicateOffersRespectOwnership() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let source = try #require(session.selectedSurface)
        let background = try #require(session.surface(for: harness.fixture.backgroundID))
        #expect(await session.adoptSurface(source, from: source, profileID: harness.fixture.profileID,
            url: source.currentURL!).value == nil)
        #expect(await session.adoptSurface(background, from: source, profileID: harness.fixture.profileID,
            url: background.currentURL!).value == nil)
        let provided = harness.providedSurface(from: source)
        let first = session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
            url: provided.currentURL!)
        let duplicate = session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
            url: provided.currentURL!)
        #expect(await duplicate.value == nil)
        let id = try #require(await first.value)
        #expect(await session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
            url: provided.currentURL!).value == nil)
        #expect(session.snapshot?.tabs.count == 3)
        #expect(source.disposalCount == 0 && background.disposalCount == 0 && provided.disposalCount == 0)
        session.closeOccurrence(id)
        await session.waitForPendingCommands()
        #expect(provided.disposalCount == 1)
        #expect(await session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
            url: provided.currentURL!).value == nil)
        #expect(provided.disposalCount == 1 && harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("Foreign-session provided instances remain owned and usable after valid or invalid profile offers", arguments: [false, true])
    func foreignOwnedSurfaceIsNeverAdoptedOrDisposed(wrongProfile: Bool) async throws {
        let harness = try await popupHarness()
        let fixture = harness.fixture
        let source = try #require(harness.session.selectedSurface)
        let otherWindow = try await fixture.store.createWindow(activeSpaceID: fixture.home)
        _ = try await fixture.store.openTab(url: URL(string: "https://popup.test/foreign-owned")!,
            from: fixture.store.captureContext(in: otherWindow), activate: true)
        let otherRecorder = PopupRecorder()
        let other = otherRecorder.session(fixture, windowID: otherWindow)
        await other.waitForPendingCommands()
        let foreign = try #require(other.selectedSurface)
        let before = await fixture.store.sessionDocument()
        #expect(await harness.session.adoptSurface(foreign, from: source,
            profileID: wrongProfile ? fixture.otherProfileID : fixture.profileID,
            url: foreign.currentURL!).value == nil)
        await harness.session.waitForPendingCommands()
        #expect(await fixture.store.sessionDocument() == before)
        #expect(harness.session.occurrenceID(for: foreign) == nil)
        #expect(other.selectedSurface === foreign && foreign.disposalCount == 0)
        other.performOnSelectedSurface { $0.navigate(to: URL(string: "https://popup.test/foreign-still-usable")!) }
        await other.waitForPendingCommands()
        #expect(foreign.navigationCount == 1 && foreign.disposalCount == 0)
        await harness.close()
        #expect(other.selectedSurface === foreign && foreign.disposalCount == 0)
        #expect(otherRecorder.errors.isEmpty && harness.recorder.errors.isEmpty)
        other.close()
        await other.waitForPendingCommands()
        #expect(foreign.disposalCount == 1 && !other.hasPendingCommands)
    }

    @Test("Provenance is shared across generic session specializations")
    func foreignGenericSurfaceIsNeverAdoptedOrDisposed() async throws {
        let harness = try await popupHarness()
        let fixture = harness.fixture
        let source = try #require(harness.session.selectedSurface)
        let otherWindow = try await fixture.store.createWindow(activeSpaceID: fixture.home)
        _ = try await fixture.store.openTab(url: URL(string: "https://popup.test/specialized-owner")!,
            from: fixture.store.captureContext(in: otherWindow), activate: true)
        let other = BrowserWindowSession<SpecializedPopupSurface>(store: fixture.store, restoringWindowID: otherWindow) { profile, url in
            SpecializedPopupSurface(profileID: profile, url: url)
        }
        await other.waitForPendingCommands()
        let foreign = try #require(other.selectedSurface)
        let before = await fixture.store.sessionDocument()
        #expect(await harness.session.adoptSurface(foreign, from: source, profileID: fixture.profileID,
            url: foreign.currentURL!).value == nil)
        #expect(await harness.session.adoptSurface(foreign, from: source, profileID: fixture.otherProfileID,
            url: foreign.currentURL!).value == nil)
        await harness.session.waitForPendingCommands()
        #expect(await fixture.store.sessionDocument() == before)
        #expect(other.selectedSurface === foreign && foreign.disposalCount == 0)
        await harness.close()
        other.performOnSelectedSurface { $0.navigate(to: URL(string: "https://popup.test/specialized-still-usable")!) }
        await other.waitForPendingCommands()
        #expect(foreign.navigationCount == 1 && foreign.disposalCount == 0)
        other.close()
        await other.waitForPendingCommands()
        #expect(foreign.disposalCount == 1 && harness.recorder.errors.isEmpty)
    }

    @Test("An unowned offer is reserved before return across generic session types")
    func earlyReservationPreventsForeignOffersAndDisposal() async throws {
        let harness = try await popupHarness()
        let fixture = harness.fixture
        let source = try #require(harness.session.selectedSurface)
        let otherWindow = try await fixture.store.createWindow(activeSpaceID: fixture.home)
        _ = try await fixture.store.openTab(url: URL(string: "https://popup.test/reservation-competitor")!,
            from: fixture.store.captureContext(in: otherWindow), activate: true)
        let other = BrowserWindowSession<SpecializedPopupSurface>(store: fixture.store, restoringWindowID: otherWindow) { profile, url in
            SpecializedPopupSurface(profileID: profile, url: url)
        }
        await other.waitForPendingCommands()
        let otherSource = try #require(other.selectedSurface)
        let provided = SpecializedPopupSurface(profileID: fixture.profileID, url: URL(string: "https://popup.test/reserved-native-response")!)
        let rightfulAdoption = harness.session.adoptSurface(provided, from: source,
            profileID: fixture.profileID, url: provided.currentURL!)
        let foreignAdoption = other.adoptSurface(provided, from: otherSource,
            profileID: fixture.profileID, url: provided.currentURL!)
        let foreignBadProfile = other.adoptSurface(provided, from: otherSource,
            profileID: fixture.otherProfileID, url: provided.currentURL!)
        #expect(await foreignAdoption.value == nil)
        #expect(await foreignBadProfile.value == nil)
        let id = try #require(await rightfulAdoption.value)
        await harness.session.waitForPendingCommands()
        await other.waitForPendingCommands()
        #expect(harness.session.surface(for: id) === provided)
        #expect(other.occurrenceID(for: provided) == nil && provided.disposalCount == 0)
        await harness.close()
        #expect(provided.disposalCount == 1 && otherSource.disposalCount == 0)
        #expect(await other.adoptSurface(provided, from: otherSource, profileID: fixture.profileID,
            url: provided.currentURL!).value == nil)
        await other.waitForPendingCommands()
        #expect(provided.disposalCount == 1 && other.selectedSurface === otherSource)
        other.close()
        await other.waitForPendingCommands()
        #expect(otherSource.disposalCount == 1 && harness.recorder.errors.isEmpty)
    }

    @Test("A factory cannot claim or dispose another session's live instance")
    func factoryCannotStealForeignOwnership() async throws {
        let harness = try await popupHarness()
        let fixture = harness.fixture
        let foreign = try #require(harness.session.selectedSurface)
        let otherWindow = try await fixture.store.createWindow(activeSpaceID: fixture.home)
        _ = try await fixture.store.openTab(url: URL(string: "https://popup.test/invalid-factory")!,
            from: fixture.store.captureContext(in: otherWindow), activate: true)
        let other = BrowserWindowSession<PopupSurface>(store: fixture.store, restoringWindowID: otherWindow) { _, _ in foreign }
        var errors: [any Error] = []
        other.onError = { errors.append($0) }
        await other.waitForPendingCommands()
        #expect(other.snapshot == nil && other.ownedSurfaces.isEmpty)
        #expect(errors.count == 1 && errors.first as? BrowserWindowSessionError == .surfaceNotOwned)
        #expect(harness.session.selectedSurface === foreign && foreign.disposalCount == 0)
        other.close()
        await other.waitForPendingCommands()
        #expect(foreign.disposalCount == 0 && !other.hasPendingCommands)
        harness.session.performOnSelectedSurface { $0.navigate(to: URL(string: "https://popup.test/owner-after-invalid-factory")!) }
        await harness.session.waitForPendingCommands()
        #expect(foreign.navigationCount == 1 && harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("Every detached surface is revoked before the first disposal can offer a later batch member", arguments: [false, true])
    func detachedBatchCannotBeReadoptedReentrantly(foreignReceiver: Bool) async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let fixture = harness.fixture
        let source = try #require(session.selectedSurface)
        let firstDetached = try #require(session.surface(for: fixture.backgroundID))
        session.openTab(url: URL(string: "https://popup.test/second-detached")!, activate: false)
        await session.waitForPendingCommands()
        let secondDetached = try #require(session.ownedSurfaces.last)
        let secondID = try #require(session.occurrenceID(for: secondDetached))
        let otherWindow = try await fixture.store.createWindow(activeSpaceID: fixture.home)
        _ = try await fixture.store.openTab(url: URL(string: "https://popup.test/batch-other-source")!,
            from: fixture.store.captureContext(in: otherWindow), activate: true)
        let otherRecorder = PopupRecorder()
        let other = otherRecorder.session(fixture, windowID: otherWindow)
        await other.waitForPendingCommands()
        let otherSource = try #require(other.selectedSurface)
        let context = try await fixture.store.captureContext(in: fixture.windowID)
        try await fixture.store.closeOccurrence(fixture.backgroundID, from: context)
        try await fixture.store.closeOccurrence(secondID, from: context)
        let before = await fixture.store.sessionDocument()
        var delayed: Task<TabOccurrenceID?, Never>?
        var callbackCount = 0
        firstDetached.onDispose = {
            callbackCount += 1
            #expect(session.occurrenceID(for: firstDetached) == nil && session.occurrenceID(for: secondDetached) == nil)
            #expect(secondDetached.disposalCount == 0)
            delayed = (foreignReceiver ? other : session).adoptSurface(secondDetached,
                from: foreignReceiver ? otherSource : source, profileID: fixture.profileID,
                url: secondDetached.currentURL!)
        }
        session.refreshCatalog()
        await session.waitForPendingCommands()
        #expect(await delayed?.value == nil)
        await other.waitForPendingCommands()
        #expect(callbackCount == 1 && firstDetached.disposalCount == 1 && secondDetached.disposalCount == 1)
        #expect(session.occurrenceID(for: secondDetached) == nil && other.occurrenceID(for: secondDetached) == nil)
        #expect(await fixture.store.sessionDocument() == before)
        #expect(session.snapshot?.tabs.map(\.occurrenceID) == [fixture.selectedID])
        #expect(session.selectedSurface === source && source.disposalCount == 0)
        other.performOnSelectedSurface { $0.navigate(to: URL(string: "https://popup.test/batch-other-still-usable")!) }
        await other.waitForPendingCommands()
        #expect(otherSource.navigationCount == 1 && otherSource.disposalCount == 0)
        #expect(harness.recorder.errors.isEmpty && otherRecorder.errors.isEmpty)
        await harness.close()
        other.close()
        await other.waitForPendingCommands()
        #expect(firstDetached.disposalCount == 1 && secondDetached.disposalCount == 1 && otherSource.disposalCount == 1)
    }

    @Test("Shared provenance keeps neither a surface nor its session alive")
    func sharedProvenanceUsesWeakIdentities() async throws {
        let fixture = try await popupFixture()
        weak var weakSession: BrowserWindowSession<PopupSurface>?
        weak var weakSurface: PopupSurface?
        var session: BrowserWindowSession<PopupSurface>? = BrowserWindowSession(
            store: fixture.store, restoringWindowID: fixture.windowID
        ) { profile, url in PopupSurface(profileID: profile, url: url) }
        weakSession = session
        await session?.waitForPendingCommands()
        weakSurface = session?.selectedSurface
        #expect(weakSession != nil && weakSurface != nil)
        session?.close()
        await session?.waitForPendingCommands()
        session = nil
        #expect(weakSession == nil && weakSurface == nil)
    }

    @Test("Protected offer rejection waits for earlier commands and participates in pending drains", arguments: ["owned", "reserved", "disposed"])
    func protectedRejectionsFollowCommandOrder(protection: String) async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let fixture = harness.fixture
        let source = try #require(session.selectedSurface)
        let protected = protection == "owned" ? source : harness.providedSurface(from: source)
        if protection == "disposed" {
            let id = try #require(await session.adoptSurface(protected, from: source,
                profileID: fixture.profileID, url: protected.currentURL!).value)
            session.closeOccurrence(id)
            await session.waitForPendingCommands()
        }
        let originalDisposalCount = protected.disposalCount
        let gate = PopupStoreGate()
        let store = fixture.store
        let blocker = Task.detached { await store.holdPopupTestExecutor(gate) }
        await gate.waitUntilEntered()
        defer { gate.release() }
        let priorURL = URL(string: "https://popup.test/before-protected-rejection")!
        session.openTab(url: priorURL, activate: false)
        let rightfulAdoption = protection == "reserved"
            ? session.adoptSurface(protected, from: source, profileID: fixture.profileID, url: protected.currentURL!)
            : nil
        let rejection = session.adoptSurface(protected, from: source, profileID: fixture.profileID, url: protected.currentURL!)
        let started = AsyncStream<Void>.makeStream()
        var resolved = false
        var drained = false
        let observer = Task { @MainActor in
            started.continuation.yield(())
            started.continuation.finish()
            let result = await rejection.value
            resolved = true
            #expect(result == nil)
            #expect(session.snapshot?.tabs.contains { $0.url == priorURL } == true)
        }
        let drain = Task { @MainActor in
            await session.waitForPendingCommands()
            drained = true
        }
        for await _ in started.stream { break }
        await Task { @MainActor in }.value
        #expect(!resolved && !drained && session.hasPendingCommands)
        #expect(protected.disposalCount == originalDisposalCount)
        gate.release()
        await blocker.value
        await observer.value
        await drain.value
        if let rightfulAdoption {
            let id = try #require(await rightfulAdoption.value)
            #expect(session.surface(for: id) === protected)
        }
        #expect(resolved && drained && !session.hasPendingCommands)
        #expect(protected.disposalCount == originalDisposalCount)
        // Even an idle rejection must increment the count before returning its task.
        let idleRejection = session.adoptSurface(protected, from: source, profileID: fixture.profileID, url: protected.currentURL!)
        #expect(session.hasPendingCommands)
        #expect(await idleRejection.value == nil)
        await session.waitForPendingCommands()
        #expect(!session.hasPendingCommands && protected.disposalCount == originalDisposalCount)
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
        #expect(protected.disposalCount == 1)
    }

    @Test("A retiring foreign offer waits behind the receiver's blocked commands without disposing the surface")
    func retiringRejectionFollowsReceiverQueue() async throws {
        let receiver = try await popupHarness()
        let owner = try await popupHarness()
        let source = try #require(receiver.session.selectedSurface)
        let firstRetired = try #require(owner.session.selectedSurface)
        let protected = try #require(owner.session.surface(for: owner.fixture.backgroundID))
        let gate = PopupStoreGate()
        let store = receiver.fixture.store
        let blocker = Task.detached { await store.holdPopupTestExecutor(gate) }
        await gate.waitUntilEntered()
        defer { gate.release() }
        let priorURL = URL(string: "https://popup.test/before-retiring-rejection")!
        receiver.session.openTab(url: priorURL, activate: false)
        var rejection: Task<TabOccurrenceID?, Never>?
        firstRetired.onDispose = {
            #expect(protected.disposalCount == 0)
            rejection = receiver.session.adoptSurface(protected, from: source,
                profileID: receiver.fixture.profileID, url: protected.currentURL!)
        }
        await owner.close()
        let acceptedRejection = try #require(rejection)
        let started = AsyncStream<Void>.makeStream()
        var resolved = false
        var drained = false
        let observer = Task { @MainActor in
            started.continuation.yield(())
            started.continuation.finish()
            #expect(await acceptedRejection.value == nil)
            resolved = true
            #expect(receiver.session.snapshot?.tabs.contains { $0.url == priorURL } == true)
        }
        let drain = Task { @MainActor in
            await receiver.session.waitForPendingCommands()
            drained = true
        }
        for await _ in started.stream { break }
        await Task { @MainActor in }.value
        #expect(!resolved && !drained && receiver.session.hasPendingCommands)
        #expect(protected.disposalCount == 1)
        gate.release()
        await blocker.value
        await observer.value
        await drain.value
        #expect(resolved && drained && !receiver.session.hasPendingCommands)
        #expect(receiver.session.occurrenceID(for: protected) == nil && protected.disposalCount == 1)
        #expect(source.disposalCount == 0 && receiver.recorder.errors.isEmpty)
        await receiver.close()
        #expect(protected.disposalCount == 1)
    }

    @Test("Retirement drains a protected rejection accepted behind an in-flight actor command", arguments: [false, true])
    func protectedRejectionDrainsAcrossRetirement(preserveModel: Bool) async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let source = try #require(session.selectedSurface)
        let before = await harness.fixture.store.sessionDocument()
        let gate = PopupStoreGate()
        let store = harness.fixture.store
        let blocker = Task.detached { await store.holdPopupTestExecutor(gate) }
        await gate.waitUntilEntered()
        defer { gate.release() }
        session.openTab(url: URL(string: "https://popup.test/revoked-before-rejection")!, activate: false)
        await Task { @MainActor in }.value
        let rejection = session.adoptSurface(source, from: source, profileID: harness.fixture.profileID, url: source.currentURL!)
        #expect(session.hasPendingCommands)
        if preserveModel { session.retireForApplicationTermination() }
        else { session.close() }
        let started = AsyncStream<Void>.makeStream()
        var resolved = false
        var drained = false
        let observer = Task { @MainActor in
            started.continuation.yield(())
            started.continuation.finish()
            #expect(await rejection.value == nil)
            resolved = true
        }
        let drain = Task { @MainActor in
            await session.waitForPendingCommands()
            drained = true
        }
        for await _ in started.stream { break }
        await Task { @MainActor in }.value
        #expect(!resolved && !drained && session.hasPendingCommands)
        #expect(source.disposalCount == 1 && session.isClosed)
        gate.release()
        await blocker.value
        await observer.value
        await drain.value
        #expect(resolved && drained && !session.hasPendingCommands && session.snapshot == nil)
        #expect(source.disposalCount == 1 && harness.recorder.errors.isEmpty)
        if preserveModel { #expect(await store.sessionDocument() == before) }
        else { await #expect(throws: BrowserStoreError.windowMissing) { try await store.snapshot(of: harness.fixture.windowID) } }
    }

    @Test("Closure during an actor hop resolves accepted adoption and preserves retirement semantics", arguments: [false, true])
    func closeDuringActorHop(preserveModel: Bool) async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let source = try #require(session.selectedSurface)
        let provided = harness.providedSurface(from: source)
        let before = await harness.fixture.store.sessionDocument()
        let gate = PopupStoreGate()
        let store = harness.fixture.store
        let blocker = Task.detached { await store.holdPopupTestExecutor(gate) }
        await gate.waitUntilEntered()
        defer { gate.release() }
        var publications = 0
        session.onChange = { publications += 1 }
        let adoption = session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
            url: provided.currentURL!)
        await Task { @MainActor in
            if preserveModel { session.retireForApplicationTermination() }
            else { session.close() }
        }.value
        gate.release()
        await blocker.value
        #expect(await adoption.value == nil)
        await session.waitForPendingCommands()
        #expect(session.isClosed && !session.hasPendingCommands && session.snapshot == nil)
        #expect(provided.disposalCount == 1 && source.disposalCount == 1)
        #expect(harness.recorder.generated.allSatisfy { $0.disposalCount == 1 })
        #expect(publications == 0 && harness.recorder.errors.isEmpty)
        if preserveModel { #expect(await store.sessionDocument() == before) }
        else { await #expect(throws: BrowserStoreError.windowMissing) { try await store.snapshot(of: harness.fixture.windowID) } }
    }

    @Test("A rejection disposal callback can close and reoffer without leaking pending work")
    func rejectionCanRetireReentrantly() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let source = try #require(session.selectedSurface)
        let provided = harness.providedSurface(from: source)
        var duplicate: Task<TabOccurrenceID?, Never>?
        provided.onDispose = {
            duplicate = session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
                url: provided.currentURL!)
            session.close()
            session.openTab()
        }
        #expect(await session.adoptSurface(provided, from: source, profileID: harness.fixture.otherProfileID,
            url: provided.currentURL!).value == nil)
        #expect(await duplicate?.value == nil)
        await session.waitForPendingCommands()
        #expect(session.isClosed && !session.hasPendingCommands)
        #expect(provided.disposalCount == 1 && source.disposalCount == 1)
        #expect(harness.recorder.errors.isEmpty)
        await #expect(throws: BrowserStoreError.windowMissing) { try await harness.fixture.store.snapshot(of: harness.fixture.windowID) }
    }

    @Test("Retirement revokes a conditional selection suspended at its mutation actor hop")
    func conditionalSelectionCannotMutateAfterRetirement() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let source = try #require(session.selectedSurface)
        let provided = harness.providedSurface(from: source)
        let id = try #require(await session.adoptSurface(provided, from: source,
            profileID: harness.fixture.profileID, url: provided.currentURL!).value)
        let expected = try #require(await session.captureContextInCommandOrder().value)
        let store = harness.fixture.store
        let before = await store.sessionDocument()
        let gate = PopupStoreGate()
        let blocker = Task.detached { await store.holdPopupTestExecutor(gate) }
        await gate.waitUntilEntered()
        defer { gate.release() }
        let selection = session.selectOccurrence(id, ifContextMatches: expected)
        await Task { @MainActor in session.retireForApplicationTermination() }.value
        gate.release()
        await blocker.value
        #expect(!(await selection.value))
        await session.waitForPendingCommands()
        #expect(await store.sessionDocument() == before)
        #expect(session.isClosed && !session.hasPendingCommands && session.snapshot == nil)
        #expect(source.disposalCount == 1 && provided.disposalCount == 1)
        #expect(harness.recorder.errors.isEmpty)
    }

    @Test("A revocable intent guards selection at commit after enqueue and the model actor hop", arguments: [false, true])
    func selectionIntentGuardsQueuedModelCommit(revokeBeforeCommit: Bool) async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let expected = try #require(await session.captureContextInCommandOrder().value)
        let source = try #require(session.selectedSurface)
        let target = try #require(session.surface(for: harness.fixture.backgroundID))
        let before = await harness.fixture.store.sessionDocument()
        let intent = BrowserSelectionIntent()
        #expect(!intent.isRevoked)
        var publications = 0
        session.onChange = { publications += 1 }
        let held = try await selectionQueuedBeforeStoreHold(harness, context: expected, intent: intent)
        defer { held.gate.release() }
        #expect(session.snapshot?.selectedOccurrenceID == expected.selectedOccurrenceID && session.hasPendingCommands)
        if revokeBeforeCommit {
            #expect(await Task.detached { intent.revoke(); return intent.isRevoked }.value)
        }
        var drained = false
        let drain = Task { @MainActor in
            await session.waitForPendingCommands()
            drained = true
        }
        await Task { @MainActor in }.value
        #expect(!drained)
        held.gate.release()
        await held.blocker.value
        #expect(await held.selection.value == !revokeBeforeCommit)
        await drain.value
        #expect(drained && !session.hasPendingCommands)
        if revokeBeforeCommit {
            #expect(try await harness.fixture.store.captureContext(in: harness.fixture.windowID) == expected)
            #expect(await harness.fixture.store.sessionDocument() == before)
            #expect(session.selectedSurface === source && publications == 0)
        } else {
            #expect(session.selectedSurface === target && publications == 1)
            #expect(session.snapshot?.revision == expected.revision &+ 1)
        }
        let committed = try await harness.fixture.store.captureContext(in: harness.fixture.windowID)
        intent.revoke()
        intent.revoke()
        #expect(intent.isRevoked)
        #expect(try await harness.fixture.store.captureContext(in: harness.fixture.windowID) == committed)
        let rejected = session.selectOccurrence(harness.fixture.selectedID, ifContextMatches: committed, while: intent)
        #expect(session.hasPendingCommands)
        #expect(!(await rejected.value))
        await session.waitForPendingCommands()
        #expect(try await harness.fixture.store.captureContext(in: harness.fixture.windowID) == committed)
        #expect(source.disposalCount == 0 && target.disposalCount == 0 && harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("Pre-revoked, absent and stale selection targets reject quietly and drain without publication")
    func selectionIntentRejectionsPreserveAuthority() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let expected = try #require(await session.captureContextInCommandOrder().value)
        let before = await harness.fixture.store.sessionDocument()
        var publications = 0
        session.onChange = { publications += 1 }
        let revoked = BrowserSelectionIntent()
        revoked.revoke()
        let rejected = session.selectOccurrence(harness.fixture.backgroundID, ifContextMatches: expected, while: revoked)
        #expect(session.hasPendingCommands)
        #expect(!(await rejected.value))
        #expect(!(await session.selectOccurrence(TabOccurrenceID(), ifContextMatches: expected, while: BrowserSelectionIntent()).value))
        await session.waitForPendingCommands()
        #expect(await harness.fixture.store.sessionDocument() == before && publications == 0)
        try await harness.fixture.store.selectOccurrence(harness.fixture.backgroundID, in: harness.fixture.windowID)
        try await harness.fixture.store.selectOccurrence(harness.fixture.selectedID, in: harness.fixture.windowID)
        let stale = await harness.fixture.store.sessionDocument()
        #expect(!(await session.selectOccurrence(harness.fixture.backgroundID, ifContextMatches: expected, while: BrowserSelectionIntent()).value))
        await session.waitForPendingCommands()
        #expect(await harness.fixture.store.sessionDocument() == stale && publications == 0)
        #expect(session.snapshot?.selectedOccurrenceID == expected.selectedOccurrenceID && session.snapshot?.revision == expected.revision)
        #expect(harness.recorder.errors.isEmpty && !session.hasPendingCommands)
        await harness.close()
    }

    @Test("A current context cannot authorize intent selection of a removed background target")
    func selectionIntentRejectsRevokedTargetInventory() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let target = try #require(session.surface(for: harness.fixture.backgroundID))
        let expected = try #require(await session.captureContextInCommandOrder().value)
        try await harness.fixture.store.closeOccurrence(harness.fixture.backgroundID, from: expected)
        #expect(await harness.fixture.store.isCurrent(expected))
        let before = await harness.fixture.store.sessionDocument()
        let snapshot = session.snapshot
        #expect(!(await session.selectOccurrence(harness.fixture.backgroundID, ifContextMatches: expected, while: BrowserSelectionIntent()).value))
        await session.waitForPendingCommands()
        #expect(await harness.fixture.store.sessionDocument() == before && session.snapshot == snapshot)
        #expect(target.disposalCount == 0 && harness.recorder.errors.isEmpty)
        session.refreshCatalog()
        await session.waitForPendingCommands()
        #expect(target.disposalCount == 1 && session.snapshot?.selectedOccurrenceID == expected.selectedOccurrenceID)
        await harness.close()
    }

    @Test("Retirement revokes intent selection already queued before the store becomes blocked")
    func selectionIntentCannotCommitAfterSessionRetirement() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let expected = try #require(await session.captureContextInCommandOrder().value)
        let before = await harness.fixture.store.sessionDocument()
        let intent = BrowserSelectionIntent()
        let held = try await selectionQueuedBeforeStoreHold(harness, context: expected, intent: intent)
        defer { held.gate.release() }
        session.retireForApplicationTermination()
        #expect(!intent.isRevoked && session.isClosed && session.hasPendingCommands)
        held.gate.release()
        await held.blocker.value
        #expect(!(await held.selection.value))
        await session.waitForPendingCommands()
        #expect(await harness.fixture.store.sessionDocument() == before)
        #expect(!session.hasPendingCommands && session.snapshot == nil)
        #expect(harness.recorder.generated.allSatisfy { $0.disposalCount == 1 })
        intent.revoke()
        #expect(intent.isRevoked && harness.recorder.errors.isEmpty)
        #expect(!(await session.selectOccurrence(harness.fixture.backgroundID, ifContextMatches: expected, while: intent).value))
    }

    @Test("Revocation during publication preserves the authoritative selection already committed")
    func selectionIntentRevocationAfterCommitDoesNotRollback() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let expected = try #require(await session.captureContextInCommandOrder().value)
        let intent = BrowserSelectionIntent()
        var publications = 0
        session.onChange = { publications += 1; intent.revoke() }
        #expect(await session.selectOccurrence(harness.fixture.backgroundID, ifContextMatches: expected, while: intent).value)
        await session.waitForPendingCommands()
        #expect(intent.isRevoked && publications == 1)
        #expect(session.snapshot?.selectedOccurrenceID == harness.fixture.backgroundID && session.snapshot?.revision == expected.revision &+ 1)
        #expect(session.snapshot == (try await harness.fixture.store.snapshot(of: harness.fixture.windowID)))
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("An installation factory callback can retire the already bound provided surface exactly once")
    func factoryCanRetireAdoptionReentrantly() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let source = try #require(session.selectedSurface)
        let provided = harness.providedSurface(from: source)
        _ = try await harness.fixture.store.openTab(url: URL(string: "https://popup.test/external-background")!,
            from: harness.fixture.store.captureContext(in: harness.fixture.windowID), activate: false)
        var publications = 0
        session.onChange = { publications += 1 }
        harness.recorder.onMake = { _ in
            #expect(session.occurrenceID(for: provided) != nil)
            session.close()
        }
        #expect(await session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
            url: provided.currentURL!).value == nil)
        await session.waitForPendingCommands()
        #expect(session.isClosed && !session.hasPendingCommands && session.ownedSurfaces.isEmpty)
        #expect(provided.disposalCount == 1 && harness.recorder.generated.count == 3)
        #expect(harness.recorder.generated.allSatisfy { $0.disposalCount == 1 })
        #expect(publications == 0 && harness.recorder.errors.isEmpty)
        await #expect(throws: BrowserStoreError.windowMissing) { try await harness.fixture.store.snapshot(of: harness.fixture.windowID) }
    }

    @Test("Reconciliation disposal can retire adoption without publishing a removed model occurrence")
    func reconciliationCanRetireAdoptionReentrantly() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let source = try #require(session.selectedSurface)
        let removed = try #require(session.surface(for: harness.fixture.backgroundID))
        let provided = harness.providedSurface(from: source)
        try await harness.fixture.store.closeOccurrence(harness.fixture.backgroundID,
            from: harness.fixture.store.captureContext(in: harness.fixture.windowID))
        removed.onDispose = {
            #expect(session.occurrenceID(for: removed) == nil)
            #expect(session.occurrenceID(for: provided) != nil)
            session.close()
        }
        var publications = 0
        session.onChange = { publications += 1 }
        #expect(await session.adoptSurface(provided, from: source, profileID: harness.fixture.profileID,
            url: provided.currentURL!).value == nil)
        await session.waitForPendingCommands()
        #expect(provided.disposalCount == 1 && removed.disposalCount == 1 && source.disposalCount == 1)
        #expect(session.isClosed && !session.hasPendingCommands && publications == 0)
        #expect(harness.recorder.errors.isEmpty)
        await #expect(throws: BrowserStoreError.windowMissing) { try await harness.fixture.store.snapshot(of: harness.fixture.windowID) }
    }

    @Test("Closing an adopted download occurrence preserves the opener and its selection revision")
    func exactAuxiliaryClosePreservesOpener() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let opener = try #require(session.selectedSurface)
        let expected = try #require(await session.captureContextInCommandOrder().value)
        let provided = harness.providedSurface(from: opener)
        let id = try #require(await session.adoptSurface(provided, from: opener, profileID: harness.fixture.profileID,
            url: provided.currentURL!).value)
        session.closeOccurrence(id)
        await session.waitForPendingCommands()
        #expect(session.selectedSurface === opener && opener.disposalCount == 0)
        #expect(session.snapshot?.tabs.map(\.occurrenceID) == [harness.fixture.selectedID, harness.fixture.backgroundID])
        #expect(session.snapshot?.revision == expected.revision)
        #expect(provided.disposalCount == 1 && provided.navigationCount == 0)
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("Bootstrap and terminal rejection resolve without manufacturing a source or blocking drain")
    func bootstrapAndClosedSessionResolve() async throws {
        let fixture = try await popupFixture()
        let expected = try await fixture.store.captureContext(in: fixture.windowID)
        let recorder = PopupRecorder()
        let session = recorder.session(fixture)
        let source = PopupSurface(profileID: fixture.profileID, url: URL(string: "https://popup.test/unowned-source")!)
        let provided = PopupSurface(profileID: fixture.profileID, url: URL(string: "https://popup.test/bootstrap")!)
        let adoption = session.adoptSurface(provided, from: source, profileID: fixture.profileID, url: provided.currentURL!)
        session.close()
        #expect(await adoption.value == nil)
        await session.waitForPendingCommands()
        let afterClose = PopupSurface(profileID: fixture.profileID, url: URL(string: "https://popup.test/after-close")!)
        #expect(await session.adoptSurface(afterClose, from: source, profileID: fixture.profileID, url: afterClose.currentURL!).value == nil)
        await session.waitForPendingCommands()
        #expect(!(await session.selectOccurrence(fixture.selectedID, ifContextMatches: expected).value))
        #expect(provided.disposalCount == 1 && afterClose.disposalCount == 1 && source.disposalCount == 0)
        #expect(!session.hasPendingCommands && recorder.errors.isEmpty)
    }

    @Test("Owned closure follows queued switching and preserves the active Space and profile", arguments: [false, true])
    func ownedClosureDoesNotActivateInactiveSpace(sameProfile: Bool) async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let target = try #require(session.selectedSurface)
        let neighbor = try #require(session.surface(for: harness.fixture.backgroundID))
        let destination = sameProfile ? harness.fixture.sameProfileSpace : harness.fixture.otherProfileSpace
        session.activateSpace(destination)
        session.openTab(url: URL(string: "https://popup.test/owned-close-active-destination")!)
        let boundary = session.captureContextInCommandOrder()
        let closure = session.closeOwnedSurface(target)
        #expect(session.hasPendingCommands)
        let expected = try #require(await boundary.value)
        #expect(await closure.value)
        await session.waitForPendingCommands()
        #expect(try await harness.fixture.store.captureContext(in: harness.fixture.windowID) == expected)
        #expect(session.snapshot?.activeSpaceID == destination && session.snapshot?.selectedOccurrenceID == expected.selectedOccurrenceID)
        #expect(session.selectedSurface?.profileID == expected.profileID)
        #expect(session.occurrenceID(for: target) == nil && target.disposalCount == 1 && target.navigationCount == 0)
        #expect(session.surface(for: harness.fixture.backgroundID) === neighbor && neighbor.disposalCount == 0)
        session.activateSpace(harness.fixture.home)
        await session.waitForPendingCommands()
        #expect(session.snapshot?.tabs.map(\.occurrenceID) == [harness.fixture.backgroundID])
        #expect(session.selectedSurface === neighbor && harness.recorder.generated.count == 3)
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("An adopted attachment can close while another profile is active without retiring its opener")
    func adoptedInactiveClosurePreservesOpenerAndCurrentSelection() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let opener = try #require(session.selectedSurface)
        let provided = harness.providedSurface(from: opener)
        let adoption = session.adoptSurface(provided, from: opener, profileID: harness.fixture.profileID, url: provided.currentURL!)
        _ = try #require(await adoption.value)
        session.activateSpace(harness.fixture.otherProfileSpace)
        session.openTab(url: URL(string: "https://popup.test/active-during-attachment")!)
        let expected = try #require(await session.captureContextInCommandOrder().value)
        let active = try #require(session.selectedSurface)
        #expect(await session.closeOwnedSurface(provided).value)
        await session.waitForPendingCommands()
        #expect(try await harness.fixture.store.captureContext(in: harness.fixture.windowID) == expected)
        #expect(session.selectedSurface === active && active.disposalCount == 0)
        #expect(provided.disposalCount == 1 && provided.navigationCount == 0 && opener.disposalCount == 0)
        #expect(session.surface(for: harness.fixture.selectedID) === opener)
        session.activateSpace(harness.fixture.home)
        await session.waitForPendingCommands()
        #expect(session.selectedSurface === opener)
        #expect(session.snapshot?.tabs.map(\.occurrenceID) == [harness.fixture.selectedID, harness.fixture.backgroundID])
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("Owned active closure retains neighbor rules and duplicate requests dispose only once", arguments: [false, true])
    func ownedActiveClosureRetainsNeighborRules(closeSelected: Bool) async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let before = try #require(session.snapshot)
        let targetID = closeSelected ? harness.fixture.selectedID : harness.fixture.backgroundID
        let remainingID = closeSelected ? harness.fixture.backgroundID : harness.fixture.selectedID
        let target = try #require(session.surface(for: targetID))
        let remaining = try #require(session.surface(for: remainingID))
        let first = session.closeOwnedSurface(target)
        let duplicate = session.closeOwnedSurface(target)
        #expect(await first.value)
        #expect(!(await duplicate.value))
        await session.waitForPendingCommands()
        #expect(session.snapshot?.tabs.map(\.occurrenceID) == [remainingID] && session.selectedSurface === remaining)
        #expect(session.snapshot?.revision == before.revision &+ (closeSelected ? 1 : 0))
        #expect(target.disposalCount == 1 && target.navigationCount == 0 && remaining.disposalCount == 0)
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("Unowned and foreign owned closure requests wait for earlier commands without disposing their targets", arguments: [false, true])
    func rejectedOwnedClosureFollowsQueue(foreignOwned: Bool) async throws {
        let harness = try await popupHarness()
        let foreign = try await popupHarness()
        let target = foreignOwned ? try #require(foreign.session.selectedSurface)
            : PopupSurface(profileID: harness.fixture.profileID, url: URL(string: "https://popup.test/unowned-close")!)
        let gate = PopupStoreGate()
        let store = harness.fixture.store
        let blocker = Task.detached { await store.holdPopupTestExecutor(gate) }
        await gate.waitUntilEntered()
        defer { gate.release() }
        let priorURL = URL(string: "https://popup.test/before-rejected-owned-close")!
        harness.session.openTab(url: priorURL, activate: false)
        let closure = harness.session.closeOwnedSurface(target)
        let started = AsyncStream<Void>.makeStream()
        var resolved = false
        let observer = Task { @MainActor in
            started.continuation.yield(())
            started.continuation.finish()
            #expect(!(await closure.value))
            resolved = true
            #expect(harness.session.snapshot?.tabs.contains { $0.url == priorURL } == true)
        }
        for await _ in started.stream { break }
        await Task { @MainActor in }.value
        #expect(!resolved && harness.session.hasPendingCommands && target.disposalCount == 0)
        gate.release()
        await blocker.value
        await observer.value
        await harness.session.waitForPendingCommands()
        #expect(!harness.session.hasPendingCommands && target.disposalCount == 0)
        #expect(harness.recorder.errors.isEmpty && foreign.recorder.errors.isEmpty)
        await harness.close()
        #expect(target.disposalCount == 0)
        await foreign.close()
        #expect(target.disposalCount == (foreignOwned ? 1 : 0))
    }

    @Test("Unpublished external context changes cannot authorize owned closure", arguments: [false, true])
    func staleContextRejectsOwnedClosure(roundTrip: Bool) async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let target = try #require(session.surface(for: harness.fixture.backgroundID))
        let before = session.snapshot
        try await harness.fixture.store.selectOccurrence(harness.fixture.backgroundID, in: harness.fixture.windowID)
        if roundTrip { try await harness.fixture.store.selectOccurrence(harness.fixture.selectedID, in: harness.fixture.windowID) }
        let document = await harness.fixture.store.sessionDocument()
        #expect(!(await session.closeOwnedSurface(target).value))
        await session.waitForPendingCommands()
        #expect(await harness.fixture.store.sessionDocument() == document && session.snapshot == before)
        #expect(target.disposalCount == 0 && session.surface(for: harness.fixture.backgroundID) === target)
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }

    @Test("An externally removed inactive lease cannot be closed again or republished")
    func removedInactiveLeaseRejectsOwnedClosure() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let target = try #require(session.surface(for: harness.fixture.backgroundID))
        session.activateSpace(harness.fixture.otherProfileSpace)
        session.openTab(url: URL(string: "https://popup.test/active-after-external-removal")!)
        let current = try #require(await session.captureContextInCommandOrder().value)
        let state = try await harness.fixture.store.captureWindowState(from: current)
        let lease = try #require(state.occurrenceAuthorities[harness.fixture.backgroundID])
        _ = try await harness.fixture.store.closeOwnedOccurrenceAndCaptureState(lease, validating: current)
        #expect(await harness.fixture.store.isCurrent(current))
        let document = await harness.fixture.store.sessionDocument()
        #expect(!(await session.closeOwnedSurface(target).value))
        await session.waitForPendingCommands()
        #expect(await harness.fixture.store.sessionDocument() == document && target.disposalCount == 0)
        session.refreshCatalog()
        await session.waitForPendingCommands()
        #expect(target.disposalCount == 1 && session.occurrenceID(for: target) == nil)
        #expect(!(await session.closeOwnedSurface(target).value))
        await session.waitForPendingCommands()
        #expect(target.disposalCount == 1 && harness.recorder.errors.isEmpty)
        #expect(try await harness.fixture.store.captureContext(in: harness.fixture.windowID) == current)
        await harness.close()
    }

    @Test("Retirement revokes an owned inactive closure suspended at an actor hop", arguments: [false, true])
    func ownedClosureCannotMutateAfterRetirement(preserveModel: Bool) async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let target = try #require(session.selectedSurface)
        session.activateSpace(harness.fixture.otherProfileSpace)
        session.openTab(url: URL(string: "https://popup.test/owned-close-retirement-active")!)
        await session.waitForPendingCommands()
        let store = harness.fixture.store
        let before = await store.sessionDocument()
        let gate = PopupStoreGate()
        let blocker = Task.detached { await store.holdPopupTestExecutor(gate) }
        await gate.waitUntilEntered()
        defer { gate.release() }
        let closure = session.closeOwnedSurface(target)
        await Task { @MainActor in
            if preserveModel { session.retireForApplicationTermination() }
            else { session.close() }
        }.value
        gate.release()
        await blocker.value
        #expect(!(await closure.value))
        await session.waitForPendingCommands()
        #expect(session.isClosed && !session.hasPendingCommands && session.snapshot == nil)
        #expect(target.disposalCount == 1 && harness.recorder.generated.allSatisfy { $0.disposalCount == 1 })
        let rejected = session.closeOwnedSurface(target)
        #expect(session.hasPendingCommands)
        #expect(!(await rejected.value))
        await session.waitForPendingCommands()
        #expect(target.disposalCount == 1 && !session.hasPendingCommands && harness.recorder.errors.isEmpty)
        if preserveModel { #expect(await store.sessionDocument() == before) }
        else { await #expect(throws: BrowserStoreError.windowMissing) { try await store.snapshot(of: harness.fixture.windowID) } }
    }

    @Test("Owned closure drains reentrant disposal requests using their captured remaining leases")
    func ownedClosureDrainsReentrantDisposal() async throws {
        let harness = try await popupHarness()
        let session = harness.session
        let first = try #require(session.selectedSurface)
        let remaining = try #require(session.surface(for: harness.fixture.backgroundID))
        var reentrant: Task<Bool, Never>?
        first.onDispose = {
            #expect(session.occurrenceID(for: first) == nil)
            reentrant = session.closeOwnedSurface(remaining)
        }
        #expect(await session.closeOwnedSurface(first).value)
        await session.waitForPendingCommands()
        #expect(await reentrant?.value == true)
        #expect(session.snapshot?.tabs.isEmpty == true && session.selectedSurface == nil)
        #expect(first.disposalCount == 1 && remaining.disposalCount == 1 && !session.hasPendingCommands)
        #expect(harness.recorder.errors.isEmpty)
        await harness.close()
    }
}
