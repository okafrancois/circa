import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing

/// Two windows of one profile and a third window of another profile, all on one synthetic store.
@MainActor
private struct TransferFixture {
    let engine = SyntheticEngine()
    let store: BrowserStore
    let profileID: ProfileID
    let first: BrowserWindowSession<SyntheticSurface>
    let second: BrowserWindowSession<SyntheticSurface>
    let foreign: BrowserWindowSession<SyntheticSurface>
    let firstDelegate = RecordingSurfaceDelegate()
    let secondDelegate = RecordingSurfaceDelegate()
    let foreignDelegate = RecordingSurfaceDelegate()
    let created: Counter
    let foreignSpace: SpaceID

    final class Counter { var first = 0 }

    static func make(coldInactiveFavorite: Bool = false) async throws -> TransferFixture {
        var store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic Transfer Profile")
        let otherProfile = await store.createProfile(name: "Synthetic Foreign Profile")
        let space = try await store.createSpace(name: "Synthetic Transfer", profileID: profile)
        let otherSpace = try await store.createSpace(name: "Synthetic Foreign", profileID: otherProfile)
        let firstWindow = try await store.createWindow(activeSpaceID: space)
        let secondWindow = try await store.createWindow(activeSpaceID: space)
        let foreignWindow = try await store.createWindow(activeSpaceID: otherSpace)
        if coldInactiveFavorite {
            let context = try await store.captureContext(in: firstWindow)
            let occurrence = try await store.openTab(url: URL(string: "https://move.test/cold-favorite")!, from: context, activate: true)
            let first = try await store.captureWindowState(in: firstWindow)
            let tabID = try #require(first.snapshot.tabs.first { $0.occurrenceID == occurrence }?.id)
            _ = try await store.addToFavorites([tabID], from: first.context)
            let inactive = try await store.createSpace(name: "Cold restored Space", profileID: profile)
            try await store.activateSpace(inactive, in: secondWindow)
            _ = try await store.selectTab(tabID, from: store.captureContext(in: secondWindow))
            try await store.activateSpace(space, in: secondWindow)
            // No engine/session exists yet: B's inactive occurrence was never materialized.
            store = try await BrowserStore(restoring: store.sessionDocument())
        }
        return await TransferFixture(store: store, profileID: profile, foreignSpace: otherSpace,
                                     windows: (firstWindow, secondWindow, foreignWindow))
    }

    private init(store: BrowserStore, profileID: ProfileID, foreignSpace: SpaceID,
                 windows: (WindowID, WindowID, WindowID)) async {
        self.store = store
        self.profileID = profileID
        self.foreignSpace = foreignSpace
        let engine = engine
        let created = Counter()
        self.created = created
        let start: (SyntheticSurface, URL) -> Void = { surface, url in surface.navigate(to: url) }
        let firstDelegate = firstDelegate, secondDelegate = secondDelegate, foreignDelegate = foreignDelegate
        first = BrowserWindowSession(store: store, restoringWindowID: windows.0, makeSurface: { profileID, _ in
            created.first += 1
            return engine.makeSurface(profileID: profileID, delegate: firstDelegate)
        }, startSurface: start)
        second = BrowserWindowSession(store: store, restoringWindowID: windows.1, makeSurface: { profileID, _ in
            engine.makeSurface(profileID: profileID, delegate: secondDelegate)
        }, startSurface: start)
        foreign = BrowserWindowSession(store: store, restoringWindowID: windows.2, makeSurface: { profileID, _ in
            engine.makeSurface(profileID: profileID, delegate: foreignDelegate)
        }, startSurface: start)
        await settle()
    }

    func settle() async {
        for session in [first, second, foreign] { await session.waitForPendingCommands() }
    }

    func close() async {
        for session in [first, second, foreign] { session.close() }
        await settle()
    }

    /// The first window's binding, restored when a move out of it fails.
    var firstRebind: (SyntheticSurface) -> Void {
        let delegate = firstDelegate
        return { $0.delegate = delegate }
    }

    /// Opens a tab in the first window and returns its live surface and occurrence.
    func openInFirst(_ url: URL) async throws -> (SyntheticSurface, TabOccurrenceID) {
        first.openTab(url: url)
        await settle()
        let surface = try #require(first.selectedSurface)
        return (surface, try #require(first.occurrenceID(for: surface)))
    }
}

/// Occupies only a synthetic store executor; cancellation cannot release this gate.
private final class TransferStoreGate: @unchecked Sendable {
    let entered = AsyncStream<Void>.makeStream()
    private let signal = DispatchSemaphore(value: 0)

    func hold() {
        entered.continuation.yield(())
        entered.continuation.finish()
        #expect(signal.wait(timeout: .now() + 5) == .success, "the test must release its synthetic store gate")
    }

    func release() { signal.signal() }
    func waitUntilEntered() async { for await _ in entered.stream { return } }
}

private extension BrowserStore {
    func holdTransferTestExecutor(_ gate: TransferStoreGate) { gate.hold() }

    /// Replaces only a background occurrence while holding the store executor across the gate.
    /// No selection revision changes, so context freshness alone cannot detect this mutation.
    func replaceBackgroundTransferTarget(_ tabID: TabID, windowID: WindowID,
                                         gate: TransferStoreGate) throws -> TabOccurrenceID {
        let state = try captureWindowState(in: windowID)
        let old = state.occurrenceTabIDs.first { $0.value == tabID }?.key
        let url = try #require(state.organization.tab(tabID)?.url)
        #expect(old == nil || state.context.selectedOccurrenceID != old)
        gate.hold()
        if let old {
            let authority = try #require(state.occurrenceAuthorities[old])
            _ = try releaseOwnedOccurrenceAndCaptureState(authority, validating: state.context)
        }
        let replacement = try openTransferredOccurrence(of: tabID, url: url, from: state.context, activate: false)
        #expect(isCurrent(state.context), "the test must replace a background target without changing selection context")
        return replacement
    }
}

/// A Peek-like owner: it claims new targets into its own container and receives their events.
@MainActor
private final class PeekLikeOwner: BrowserEngineSurfaceDelegate {
    let container = BrowserSurfaceContainer<SyntheticSurface>()
    var events: [String] = []

    func surfaceDidStartNavigation(_ surface: SyntheticSurface) { events.append("start") }
    func surfaceDidCommitNavigation(_ surface: SyntheticSurface) { events.append("commit") }
    func surfaceDidFinishNavigation(_ surface: SyntheticSurface) { events.append("finish") }
    func surfaceDidFailNavigation(_ surface: SyntheticSurface) { events.append("fail") }

    func surface(_ surface: SyntheticSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        decision.decide(container.owns(surface) ? .allow : .cancel)
    }

    func surface(_ surface: SyntheticSurface, decidePolicyFor response: BrowserNavigationResponse,
                 decision: BrowserPolicyDecision<BrowserNavigationResponsePolicy>) {
        decision.decide(container.owns(surface) ? .allow : .cancel)
    }

    func surface(_ surface: SyntheticSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> SyntheticSurface) -> SyntheticSurface? { nil }

    func surfaceDidRequestClose(_ surface: SyntheticSurface) { container.dispose(surface) }

    func surface(_ surface: SyntheticSurface, didStartDownload download: any BrowserEngineDownload) {
        download.cancel()
    }
}

/// The window's delegate routes a new target into Peek, as a feature hook would.
@MainActor
private final class RoutingWindowDelegate: BrowserEngineSurfaceDelegate {
    let peek: PeekLikeOwner
    init(peek: PeekLikeOwner) { self.peek = peek }

    func surfaceDidStartNavigation(_ surface: SyntheticSurface) {}
    func surfaceDidCommitNavigation(_ surface: SyntheticSurface) {}
    func surfaceDidFinishNavigation(_ surface: SyntheticSurface) {}
    func surfaceDidFailNavigation(_ surface: SyntheticSurface) {}

    func surface(_ surface: SyntheticSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }

    func surface(_ surface: SyntheticSurface, decidePolicyFor response: BrowserNavigationResponse,
                 decision: BrowserPolicyDecision<BrowserNavigationResponsePolicy>) { decision.decide(.allow) }

    func surface(_ surface: SyntheticSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> SyntheticSurface) -> SyntheticSurface? {
        let child = make()
        guard peek.container.claim(child) else { return nil }
        child.delegate = peek
        return child
    }

    func surfaceDidRequestClose(_ surface: SyntheticSurface) {}
    func surface(_ surface: SyntheticSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
}

@MainActor
@Suite("Live surface transfer")
struct BrowserSurfaceTransferTests {
    @Test("A live surface moves between windows with its owner and delegate, never disposed or reloaded")
    func moveBetweenWindows() async throws {
        let fixture = try await TransferFixture.make()
        let document = URL(string: "https://move.test/document")!
        let stays = URL(string: "https://move.test/stays")!
        fixture.first.openTab(url: document)
        fixture.first.openTab(url: stays, activate: false)
        await fixture.settle()
        let moving = try #require(fixture.first.selectedSurface)
        let generation = moving.documentGeneration
        let requests = moving.requestedURLs

        let source = try #require(fixture.first.occurrenceID(for: moving))
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        #expect(!fixture.first.holds(moving))
        #expect(!fixture.first.ownedSurfaces.contains { $0 === moving })
        // The source keeps its model occurrence as a placeholder until the receiver records it.
        #expect(fixture.first.isInTransit(source))
        let adoption = fixture.second.acceptTransfer(transfer) { $0.delegate = fixture.secondDelegate }
        // Owner and receiver change in the same turn as the acceptance.
        #expect(moving.delegate === fixture.secondDelegate)
        #expect(fixture.second.holds(moving))
        #expect(transfer.state == .accepted)
        let occurrence = try #require(await adoption.value)
        #expect(transfer.state == .completed)
        await fixture.settle()
        #expect(!fixture.first.isInTransit(source))

        #expect(fixture.second.occurrenceID(for: moving) == occurrence)
        #expect(fixture.second.selectedSurface === moving)
        #expect(fixture.second.snapshot?.tabs.first { $0.occurrenceID == occurrence }?.url == document)
        #expect(!moving.isDisposed)
        #expect(moving.documentGeneration == generation)
        #expect(moving.requestedURLs == requests)
        #expect(fixture.first.snapshot?.tabs.map(\.url) == [stays])
        #expect(fixture.created.first == 2, "a released occurrence must never be recreated by the factory")

        fixture.firstDelegate.events.removeAll()
        fixture.secondDelegate.events.removeAll()
        moving.navigate(to: URL(string: "https://move.test/after")!)
        #expect(fixture.firstDelegate.events.isEmpty)
        #expect(fixture.secondDelegate.events == ["start", "commit", "finish"])
        await fixture.close()
        #expect(moving.isDisposed)
    }

    @Test("A replacement records the same logical tab before retiring the receiver's old document",
          arguments: [false, true])
    func replacementCommitsAtAdoptionReceipt(activate: Bool) async throws {
        let fixture = try await TransferFixture.make()
        let (moving, source) = try await fixture.openInFirst(URL(string: "https://move.test/replacement")!)
        let tabID = try #require(fixture.first.snapshot?.tabs.first?.id)
        fixture.second.selectTab(tabID)
        await fixture.settle()
        let old = try #require(fixture.second.selectedSurface)
        let oldOccurrence = try #require(fixture.second.occurrenceID(for: old))
        let created = fixture.engine.surfaces.count
        let requests = moving.requestedURLs
        let generation = moving.documentGeneration
        var disposals = 0
        old.onDispose = { disposals += 1 }
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer, activate: activate, replacingExisting: true) {
            $0.delegate = fixture.secondDelegate
        }
        #expect(transfer.state == .accepted && fixture.first.isInTransit(source))
        #expect(fixture.second.surface(for: oldOccurrence) === old && !old.isDisposed && disposals == 0)
        // This captures the displaced physical document after adoption was queued. Its authority
        // must not close the replacement even though the logical TabID stays the same.
        let staleClose = fixture.second.closeOwnedSurface(old)
        let receipt = try #require(await adoption.value)
        #expect(transfer.state == .completed)
        #expect(fixture.second.selectedSurface === moving && fixture.second.occurrenceID(for: moving) == receipt)
        #expect(fixture.second.organization?.tab(tabID)?.isSelected == true)
        #expect(fixture.second.snapshot?.tabs.map(\.id) == [tabID])
        #expect(fixture.second.snapshot?.selectedOccurrenceID == receipt && receipt != oldOccurrence)
        #expect(fixture.second.surface(for: oldOccurrence) == nil && old.isDisposed && disposals == 1)
        #expect(await staleClose.value == false)
        await fixture.settle()
        #expect(fixture.first.snapshot?.tabs.isEmpty == true && !fixture.first.isInTransit(source))
        #expect(fixture.engine.surfaces.count == created && moving.requestedURLs == requests)
        #expect(moving.documentGeneration == generation && !moving.isDisposed)
        #expect(await fixture.first.archivedTabs().value.contains { $0.id == tabID } == false)
        await fixture.close()
        #expect(disposals == 1)
    }

    @Test("Retiring a replaced document revokes its maps before a reentrant receiver close")
    func replacementDisposalCanCloseReceiver() async throws {
        let fixture = try await TransferFixture.make()
        let (moving, _) = try await fixture.openInFirst(URL(string: "https://move.test/reentrant-replacement")!)
        let tabID = try #require(fixture.first.snapshot?.tabs.first?.id)
        fixture.second.selectTab(tabID)
        await fixture.settle()
        let old = try #require(fixture.second.selectedSurface)
        let oldOccurrence = try #require(fixture.second.occurrenceID(for: old))
        var oldDisposals = 0
        var movedDisposals = 0
        moving.onDispose = { movedDisposals += 1 }
        old.onDispose = {
            oldDisposals += 1
            #expect(fixture.second.surface(for: oldOccurrence) == nil && !fixture.second.holds(old))
            #expect(fixture.second.occurrenceID(for: moving) != nil && fixture.second.holds(moving))
            fixture.second.close()
        }
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer, replacingExisting: true) { $0.delegate = fixture.secondDelegate }
        #expect(await adoption.value == nil && transfer.state == .completed)
        #expect(old.isDisposed && moving.isDisposed && oldDisposals == 1 && movedDisposals == 1)
        await fixture.settle()
        #expect(fixture.first.snapshot?.tabs.isEmpty == true && fixture.second.ownedSurfaces.isEmpty)
        await fixture.close()
        #expect(oldDisposals == 1 && movedDisposals == 1)
    }

    @Test("A Favorite live in an inactive Space is replaced only after the receiver records the dragged document")
    func replacementOfInactiveFavorite() async throws {
        let fixture = try await TransferFixture.make()
        let (moving, _) = try await fixture.openInFirst(URL(string: "https://move.test/inactive-favorite")!)
        let tabID = try #require(fixture.first.snapshot?.tabs.first?.id)
        fixture.first.addToFavorites([tabID])
        await fixture.settle()
        let activeSpace = try #require(fixture.second.snapshot?.activeSpaceID)
        let inactiveSpace = try await fixture.store.createSpace(name: "Inactive synthetic", profileID: fixture.profileID)
        fixture.second.activateSpace(inactiveSpace)
        fixture.second.selectTab(tabID)
        await fixture.settle()
        let old = try #require(fixture.second.selectedSurface)
        let oldOccurrence = try #require(fixture.second.occurrenceID(for: old))
        fixture.second.activateSpace(activeSpace)
        await fixture.settle()
        #expect(fixture.second.organization?.tab(tabID)?.isLoadedInThisWindow == true)
        #expect(fixture.second.organization?.tab(tabID)?.occurrenceID == nil)
        #expect(fixture.second.surface(for: oldOccurrence) === old)
        let windowID = try #require(fixture.second.snapshot?.id)
        let inventory = try await fixture.store.captureWindowState(in: windowID)
        #expect(Set(inventory.occurrenceTabIDs.keys) == Set(inventory.occurrenceAuthorities.keys))
        #expect(inventory.occurrenceTabIDs[oldOccurrence] == tabID)
        #expect(inventory.occurrenceAuthorities[oldOccurrence]?.spaceID == inactiveSpace)
        let created = fixture.engine.surfaces.count
        let requests = moving.requestedURLs
        var disposals = 0
        old.onDispose = { disposals += 1 }
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer, replacingExisting: true) { $0.delegate = fixture.secondDelegate }
        #expect(transfer.state == .accepted && !old.isDisposed && disposals == 0)
        let receipt = try #require(await adoption.value)
        #expect(fixture.second.selectedSurface === moving && fixture.second.snapshot?.selectedOccurrenceID == receipt)
        #expect(fixture.second.organization?.tab(tabID)?.isSelected == true)
        #expect(fixture.second.snapshot?.tabs.map(\.id) == [tabID])
        #expect(fixture.second.surface(for: oldOccurrence) == nil && old.isDisposed && disposals == 1)
        #expect(fixture.engine.surfaces.count == created && moving.requestedURLs == requests && !moving.isDisposed)
        await fixture.settle()
        #expect(fixture.first.snapshot?.tabs.isEmpty == true)
        await fixture.close()
        #expect(disposals == 1)
    }

    @Test("A restored inactive Favorite with no physical document accepts the exact live source without a factory load")
    func replacementOfColdInactiveFavorite() async throws {
        let fixture = try await TransferFixture.make(coldInactiveFavorite: true)
        let moving = try #require(fixture.first.selectedSurface)
        let source = try #require(fixture.first.occurrenceID(for: moving))
        let tabID = try #require(fixture.first.snapshot?.tabs.first?.id)
        let windowID = try #require(fixture.second.snapshot?.id)
        let inventory = try await fixture.store.captureWindowState(in: windowID)
        let cold = try #require(inventory.occurrenceTabIDs.first { $0.value == tabID }?.key)
        #expect(inventory.occurrenceAuthorities[cold]?.spaceID != inventory.context.spaceID)
        #expect(fixture.second.surface(for: cold) == nil && fixture.second.ownedSurfaces.isEmpty)
        #expect(fixture.second.organization?.tab(tabID)?.isLoadedInThisWindow == true)
        #expect(fixture.engine.surfaces.count == 1, "restoration must not materialize the inactive destination")
        moving.navigate(to: URL(string: "https://move.test/cold-favorite/form")!)
        let draft = NSTextField(string: "Unsaved restored transfer")
        moving.documentView.addSubview(draft)
        let requests = moving.requestedURLs
        let generation = moving.documentGeneration
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer, replacingExisting: true) { $0.delegate = fixture.secondDelegate }
        #expect(transfer.state == .accepted)
        let result = await adoption.value
        #expect(result != nil)
        guard let receipt = result else { transfer.cancel(); await fixture.close(); return }
        #expect(transfer.state == .completed && fixture.second.selectedSurface === moving)
        #expect(fixture.second.snapshot?.tabs.map(\.id) == [tabID] && fixture.second.snapshot?.selectedOccurrenceID == receipt)
        #expect(fixture.second.organization?.tab(tabID)?.isSelected == true && receipt != cold)
        #expect(fixture.second.surface(for: cold) == nil && fixture.second.ownedSurfaces.count == 1)
        #expect(fixture.engine.surfaces.count == 1 && moving.requestedURLs == requests && moving.documentGeneration == generation)
        #expect(draft.superview === moving.documentView && draft.stringValue == "Unsaved restored transfer" && !moving.isDisposed)
        await fixture.settle()
        #expect(fixture.first.snapshot?.tabs.isEmpty == true && !fixture.first.isInTransit(source))
        await fixture.close()
    }

    @Test("A cold inactive replacement rolls back without creating a destination document when the receiver closes or changes profile",
          arguments: [false, true])
    func coldReplacementFailure(receiverCloses: Bool) async throws {
        let fixture = try await TransferFixture.make(coldInactiveFavorite: true)
        let moving = try #require(fixture.first.selectedSurface)
        let source = try #require(fixture.first.occurrenceID(for: moving))
        let tabID = try #require(fixture.first.snapshot?.tabs.first?.id)
        let windowID = try #require(fixture.second.snapshot?.id)
        let before = try await fixture.store.captureWindowState(in: windowID)
        let cold = try #require(before.occurrenceTabIDs.first { $0.value == tabID }?.key)
        let requests = moving.requestedURLs
        if !receiverCloses { fixture.second.activateSpace(fixture.foreignSpace) }
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer, replacingExisting: true) { $0.delegate = fixture.secondDelegate }
        #expect(transfer.state == .accepted)
        if receiverCloses { fixture.second.close() }
        #expect(await adoption.value == nil && transfer.state == .returned)
        #expect(fixture.first.selectedSurface === moving && fixture.first.occurrenceID(for: moving) == source)
        #expect(!moving.isDisposed && moving.delegate === fixture.firstDelegate && moving.requestedURLs == requests)
        #expect(fixture.engine.surfaces.count == 1 && fixture.second.ownedSurfaces.isEmpty)
        if !receiverCloses {
            let after = try await fixture.store.captureWindowState(in: windowID)
            #expect(after.occurrenceTabIDs[cold] == tabID && after.occurrenceAuthorities[cold] == before.occurrenceAuthorities[cold])
        }
        await fixture.close()
    }

    @Test("A cold inactive target recreated after capture survives the refused replacement")
    func coldReplacementRejectsRecreatedTarget() async throws {
        let fixture = try await TransferFixture.make(coldInactiveFavorite: true)
        let moving = try #require(fixture.first.selectedSurface)
        let source = try #require(fixture.first.occurrenceID(for: moving))
        let tabID = try #require(fixture.first.snapshot?.tabs.first?.id)
        let windowID = try #require(fixture.second.snapshot?.id)
        let before = try await fixture.store.captureWindowState(in: windowID)
        let cold = try #require(before.occurrenceTabIDs.first { $0.value == tabID }?.key)
        let gate = TransferStoreGate()
        let store = fixture.store
        let mutation = Task.detached {
            try await store.replaceBackgroundTransferTarget(tabID, windowID: windowID, gate: gate)
        }
        await gate.waitUntilEntered()
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer, replacingExisting: true) { $0.delegate = fixture.secondDelegate }
        #expect(transfer.state == .accepted && fixture.second.surface(for: cold) == nil)
        gate.release()
        let newer = try await mutation.value
        #expect(newer != cold)
        #expect(await adoption.value == nil && transfer.state == .returned)
        let after = try await fixture.store.captureWindowState(in: windowID)
        #expect(after.context == before.context)
        #expect(after.occurrenceTabIDs.values.filter { $0 == tabID }.count == 1 && after.occurrenceTabIDs[newer] == tabID)
        #expect(fixture.first.selectedSurface === moving && fixture.first.occurrenceID(for: moving) == source)
        #expect(!moving.isDisposed && fixture.engine.surfaces.count == 1)
        await fixture.close()
    }

    @Test("A reserved outgoing transfer remains a transit and cannot be mistaken for a cold inactive target")
    func replacementRejectsReservedTransit() async throws {
        let fixture = try await TransferFixture.make(coldInactiveFavorite: true)
        let moving = try #require(fixture.first.selectedSurface)
        let source = try #require(fixture.first.occurrenceID(for: moving))
        let tabID = try #require(fixture.first.snapshot?.tabs.first?.id)
        let windowID = try #require(fixture.second.snapshot?.id)
        let inventory = try await fixture.store.captureWindowState(in: windowID)
        let oldOccurrence = try #require(inventory.occurrenceTabIDs.first { $0.value == tabID }?.key)
        let inactiveSpace = try #require(inventory.occurrenceAuthorities[oldOccurrence]?.spaceID)
        fixture.second.activateSpace(inactiveSpace)
        await fixture.settle()
        let old = try #require(fixture.second.surface(for: oldOccurrence))
        fixture.second.activateSpace(inventory.context.spaceID)
        await fixture.settle()
        let otherWindow = try await fixture.store.createWindow(activeSpaceID: inventory.context.spaceID)
        let recipient = BrowserWindowSession(store: fixture.store, restoringWindowID: otherWindow,
            makeSurface: { profile, _ in fixture.engine.makeSurface(profileID: profile, delegate: fixture.secondDelegate) },
            startSurface: { $0.navigate(to: $1) })
        await recipient.waitForPendingCommands()
        let outgoing = try #require(fixture.second.releaseSurface(old))
        let reservation = recipient.acceptTransfer(outgoing) { $0.delegate = fixture.secondDelegate }
        #expect(outgoing.state == .accepted && fixture.second.isInTransit(oldOccurrence))
        #expect(fixture.second.surface(for: oldOccurrence) == nil)
        let incoming = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let refused = fixture.second.acceptTransfer(incoming, replacingExisting: true) { $0.delegate = fixture.secondDelegate }
        #expect(incoming.state == .pending, "a transit must be refused synchronously without stealing its model lease")
        incoming.cancel()
        #expect(await refused.value == nil && incoming.state == .returned)
        #expect(fixture.first.selectedSurface === moving && fixture.first.occurrenceID(for: moving) == source)
        recipient.close()
        #expect(await reservation.value == nil && outgoing.state == .returned)
        #expect(fixture.second.surface(for: oldOccurrence) === old && !fixture.second.isInTransit(oldOccurrence))
        #expect(!old.isDisposed && !moving.isDisposed && fixture.engine.surfaces.count == 2)
        await recipient.waitForPendingCommands()
        await fixture.close()
    }

    @Test("A prior queued activation that materializes the cold target revokes the older physical replacement boundary")
    func coldReplacementRejectsNewlyMaterializedTarget() async throws {
        let fixture = try await TransferFixture.make(coldInactiveFavorite: true)
        let moving = try #require(fixture.first.selectedSurface)
        let source = try #require(fixture.first.occurrenceID(for: moving))
        let tabID = try #require(fixture.first.snapshot?.tabs.first?.id)
        let windowID = try #require(fixture.second.snapshot?.id)
        let before = try await fixture.store.captureWindowState(in: windowID)
        let cold = try #require(before.occurrenceTabIDs.first { $0.value == tabID }?.key)
        let inactive = try #require(before.occurrenceAuthorities[cold]?.spaceID)
        fixture.second.activateSpace(inactive)
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer, replacingExisting: true) { $0.delegate = fixture.secondDelegate }
        #expect(transfer.state == .accepted && fixture.second.surface(for: cold) == nil)
        #expect(await adoption.value == nil && transfer.state == .returned)
        let newlyMaterialized = try #require(fixture.second.surface(for: cold))
        #expect(fixture.second.selectedSurface === newlyMaterialized && !newlyMaterialized.isDisposed)
        #expect(fixture.second.organization?.tab(tabID)?.isSelected == true)
        #expect(fixture.first.selectedSurface === moving && fixture.first.occurrenceID(for: moving) == source && !moving.isDisposed)
        // Exactly one load belongs to the earlier accepted activation, never to the replacement.
        #expect(fixture.engine.surfaces.count == 2 && newlyMaterialized.requestedURLs.count == 1)
        await fixture.close()
    }

    @Test("A background target created outside the queue cannot be destroyed by an older replacement",
          arguments: [false, true])
    func replacementRejectsRecreatedBackgroundTarget(hadExisting: Bool) async throws {
        let fixture = try await TransferFixture.make()
        let (moving, source) = try await fixture.openInFirst(URL(string: "https://move.test/background-replacement")!)
        let tabID = try #require(fixture.first.snapshot?.tabs.first?.id)
        if hadExisting { fixture.second.selectTab(tabID) }
        fixture.second.openTab(url: URL(string: "https://move.test/selected")!, activate: true)
        await fixture.settle()
        let oldOccurrence = fixture.second.organization?.tab(tabID)?.occurrenceID
        let old = oldOccurrence.flatMap { fixture.second.surface(for: $0) }
        #expect((old != nil) == hadExisting)
        let windowID = try #require(fixture.second.snapshot?.id)
        let context = try await fixture.store.captureWindowState(in: windowID).context
        let gate = TransferStoreGate()
        let store = fixture.store
        let mutation = Task.detached {
            try await store.replaceBackgroundTransferTarget(tabID, windowID: windowID, gate: gate)
        }
        await gate.waitUntilEntered()
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer, replacingExisting: true) { $0.delegate = fixture.secondDelegate }
        #expect(transfer.state == .accepted && old?.isDisposed != true)
        gate.release()
        let newer = try await mutation.value
        #expect(newer != oldOccurrence)
        #expect(await adoption.value == nil && transfer.state == .returned)
        let state = try await fixture.store.captureWindowState(in: windowID)
        #expect(state.context == context)
        #expect(state.snapshot.tabs.filter { $0.id == tabID }.map(\.occurrenceID) == [newer])
        #expect(fixture.first.occurrenceID(for: moving) == source && fixture.first.selectedSurface === moving)
        #expect(!moving.isDisposed && old?.isDisposed != true, "refused replacement must not retire the stale cached target itself")
        fixture.second.synchronizeOrganization()
        await fixture.settle()
        let newSurface = try #require(fixture.second.surface(for: newer))
        #expect(newSurface !== moving && newSurface !== old && !newSurface.isDisposed && old?.isDisposed != false)
        #expect(fixture.second.organization?.selectedTab?.id != tabID)
        await fixture.close()
    }

    @Test("A failed replacement returns the source without removing the receiver's logical occurrence",
          arguments: [false, true], [false, true])
    func replacementFailurePreservesExistingOccurrence(receiverCloses: Bool, inactive: Bool) async throws {
        let fixture = try await TransferFixture.make()
        let (moving, source) = try await fixture.openInFirst(URL(string: "https://move.test/replacement-rollback")!)
        let tabID = try #require(fixture.first.snapshot?.tabs.first?.id)
        let activeSpace = try #require(fixture.second.snapshot?.activeSpaceID)
        let oldSpace: SpaceID
        if inactive {
            fixture.first.addToFavorites([tabID])
            await fixture.settle()
            oldSpace = try await fixture.store.createSpace(name: "Inactive rollback", profileID: fixture.profileID)
            fixture.second.activateSpace(oldSpace)
        } else { oldSpace = activeSpace }
        fixture.second.selectTab(tabID)
        await fixture.settle()
        let old = try #require(fixture.second.selectedSurface)
        let oldOccurrence = try #require(fixture.second.occurrenceID(for: old))
        if inactive {
            fixture.second.activateSpace(activeSpace)
            await fixture.settle()
            #expect(fixture.second.organization?.tab(tabID)?.occurrenceID == nil)
        }
        let requests = moving.requestedURLs
        let created = fixture.engine.surfaces.count
        var disposals = 0
        old.onDispose = { disposals += 1 }
        if !receiverCloses { fixture.second.activateSpace(fixture.foreignSpace) }
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer, replacingExisting: true) { $0.delegate = fixture.secondDelegate }
        #expect(transfer.state == .accepted && !old.isDisposed)
        if receiverCloses { fixture.second.close() }
        #expect(await adoption.value == nil && transfer.state == .returned)
        #expect(fixture.first.occurrenceID(for: moving) == source && fixture.first.selectedSurface === moving)
        #expect(moving.delegate === fixture.firstDelegate && !moving.isDisposed && moving.requestedURLs == requests)
        #expect(old.isDisposed == receiverCloses && disposals == (receiverCloses ? 1 : 0))
        await fixture.settle()
        if !receiverCloses {
            #expect(fixture.second.surface(for: oldOccurrence) === old)
            fixture.second.activateSpace(oldSpace)
            await fixture.settle()
            #expect(fixture.second.selectedSurface === old && fixture.second.organization?.tab(tabID)?.isSelected == true)
        }
        #expect(fixture.engine.surfaces.count == created)
        #expect(await fixture.first.archivedTabs().value.contains { $0.id == tabID } == false)
        await fixture.close()
        #expect(disposals == 1)
    }

    @Test("Commands captured by the previous owner cannot act on a moved surface")
    func staleOwnerCommandsFail() async throws {
        let fixture = try await TransferFixture.make()
        fixture.first.openTab(url: URL(string: "https://move.test/stale")!)
        await fixture.settle()
        let moving = try #require(fixture.first.selectedSurface)
        let staleClose = fixture.first.closeOwnedSurface(moving)
        let transfer = try #require(fixture.first.releaseSurface(moving))
        let adoption = fixture.second.acceptTransfer(transfer) { $0.delegate = fixture.secondDelegate }
        #expect(await staleClose.value == false)
        #expect(await adoption.value != nil)
        await fixture.settle()
        #expect(!moving.isDisposed)
        #expect(fixture.second.ownedSurfaces.contains { $0 === moving })
        await fixture.close()
    }

    @Test("A live document keeps its logical tab through a feature container")
    func containerPreservesLogicalTab() async throws {
        let fixture = try await TransferFixture.make()
        let (moving, source) = try await fixture.openInFirst(URL(string: "https://move.test/container")!)
        let tabID = try #require(fixture.first.snapshot?.tabs.first { $0.occurrenceID == source }?.id)
        let requests = moving.requestedURLs
        let feature = BrowserSurfaceContainer<SyntheticSurface>()
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        #expect(feature.accept(transfer) { $0.delegate = fixture.secondDelegate })
        await fixture.settle()
        let onward = try #require(feature.release(moving, profileID: fixture.profileID))
        #expect(onward.tabID == tabID)
        let occurrence = try #require(await fixture.second.acceptTransfer(onward).value)
        await fixture.settle()
        #expect(fixture.second.snapshot?.tabs.first { $0.occurrenceID == occurrence }?.id == tabID)
        #expect(moving.requestedURLs == requests)
        #expect(!moving.isDisposed)
        feature.close()
        await fixture.close()
    }

    @Test("A transfer refused by a foreign profile returns to its source occurrence, rebound and alive")
    func refusedTransferReturns() async throws {
        let fixture = try await TransferFixture.make()
        let (moving, occurrence) = try await fixture.openInFirst(URL(string: "https://move.test/refused")!)
        let requests = moving.requestedURLs
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let refused = fixture.foreign.acceptTransfer(transfer) { $0.delegate = fixture.foreignDelegate }
        #expect(transfer.state == .pending)
        #expect(await refused.value == nil)
        #expect(await transfer.settled() == .returned)
        #expect(!moving.isDisposed)
        #expect(fixture.first.occurrenceID(for: moving) == occurrence, "the live surface returns to the same occurrence")
        #expect(fixture.first.holds(moving))
        #expect(moving.delegate === fixture.firstDelegate)
        #expect(moving.requestedURLs == requests, "a returned surface is never reloaded")
        await fixture.settle()
        #expect(fixture.first.selectedSurface === moving)
        #expect(fixture.first.snapshot?.tabs.map(\.occurrenceID) == [occurrence])
        #expect(fixture.foreign.snapshot?.tabs.isEmpty == true)
        await fixture.close()
        #expect(moving.isDisposed)
    }

    @Test("A transfer nobody accepts returns to its source after one turn instead of being disposed")
    func abandonedTransferReturns() async throws {
        let fixture = try await TransferFixture.make()
        let (moving, occurrence) = try await fixture.openInFirst(URL(string: "https://move.test/abandoned")!)
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        moving.delegate = fixture.secondDelegate
        #expect(await transfer.settled() == .returned)
        #expect(!moving.isDisposed)
        #expect(fixture.first.occurrenceID(for: moving) == occurrence)
        #expect(moving.delegate === fixture.firstDelegate)
        await fixture.close()
    }

    @Test("A receiver closed before recording returns the live surface to its source")
    func receiverClosedBeforeRecording() async throws {
        let fixture = try await TransferFixture.make()
        let (moving, occurrence) = try await fixture.openInFirst(URL(string: "https://move.test/closed-receiver")!)
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer) { $0.delegate = fixture.secondDelegate }
        #expect(transfer.state == .accepted)
        fixture.second.close()
        #expect(await adoption.value == nil)
        #expect(transfer.state == .returned)
        #expect(!moving.isDisposed)
        #expect(fixture.first.occurrenceID(for: moving) == occurrence)
        #expect(moving.delegate === fixture.firstDelegate)
        await fixture.close()
    }

    @Test("A profile change queued in the receiver before recording returns the surface to its source")
    func receiverChangesProfileBeforeRecording() async throws {
        let fixture = try await TransferFixture.make()
        let (moving, occurrence) = try await fixture.openInFirst(URL(string: "https://move.test/profile-change")!)
        fixture.second.activateSpace(fixture.foreignSpace)
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer) { $0.delegate = fixture.secondDelegate }
        #expect(transfer.state == .accepted, "the receiver still had the source profile when it accepted")
        #expect(await adoption.value == nil)
        #expect(transfer.state == .returned)
        #expect(!moving.isDisposed)
        #expect(fixture.first.occurrenceID(for: moving) == occurrence)
        #expect(moving.delegate === fixture.firstDelegate)
        await fixture.settle()
        #expect(fixture.second.activeProfileID != fixture.profileID)
        await fixture.close()
    }

    @Test("When neither receiver nor source can hold it, a failed move goes to the rescue container")
    func failedMoveIsRescued() async throws {
        let fixture = try await TransferFixture.make()
        let rescue = BrowserSurfaceContainer<SyntheticSurface>()
        var rescued: [SyntheticSurface] = []
        rescue.onRescue = { rescued.append($0) }
        fixture.first.rescueContainer = rescue
        let (moving, _) = try await fixture.openInFirst(URL(string: "https://move.test/rescued")!)
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer) { $0.delegate = fixture.secondDelegate }
        fixture.first.close()
        fixture.second.close()
        #expect(await adoption.value == nil)
        #expect(transfer.state == .rescued)
        #expect(!moving.isDisposed, "a failed move never disposes a live document")
        #expect(rescue.owns(moving))
        try await waitUntil { rescued.count == 1 }
        #expect(rescued.first === moving)
        // The rescue container hands it on like any owner.
        let rehome = try #require(rescue.release(moving, profileID: fixture.profileID))
        let peek = BrowserSurfaceContainer<SyntheticSurface>()
        #expect(peek.accept(rehome) { $0.delegate = fixture.firstDelegate })
        #expect(rehome.state == .completed)
        peek.close()
        rescue.close()
        await fixture.close()
        #expect(moving.isDisposed)
    }

    @Test("Without a rescue container a failed move strands the live surface instead of disposing it")
    func failedMoveIsStranded() async throws {
        let fixture = try await TransferFixture.make()
        let (moving, _) = try await fixture.openInFirst(URL(string: "https://move.test/stranded")!)
        let transfer = try #require(fixture.first.releaseSurface(moving))
        let tabID = try #require(transfer.tabID)
        fixture.first.close()
        #expect(await transfer.settled() == .stranded)
        #expect(!moving.isDisposed)
        #expect(BrowserSurfaceTransfers.isStranded(moving))
        #expect(BrowserSurfaceTransfers.strandedSurfaces(of: SyntheticSurface.self).contains { $0 === moving })
        let holder = BrowserSurfaceContainer<SyntheticSurface>()
        #expect(BrowserSurfaceTransfers.claimStranded(moving, into: holder))
        #expect(holder.owns(moving))
        #expect(!BrowserSurfaceTransfers.isStranded(moving))
        let onward = try #require(holder.release(moving, profileID: fixture.profileID))
        #expect(onward.tabID == tabID, "claiming a stranded document must preserve its logical tab")
        onward.cancel()
        holder.close()
        #expect(moving.isDisposed)
        await fixture.close()
    }

    @Test("A Peek-like release that is not accepted returns to its container with its binding")
    func containerReleaseReturns() async throws {
        let fixture = try await TransferFixture.make()
        let peek = PeekLikeOwner()
        let child = fixture.engine.makeSurface(profileID: fixture.profileID, delegate: peek)
        #expect(peek.container.claim(child))
        child.navigate(to: URL(string: "https://move.test/peek-return")!)
        let transfer = try #require(peek.container.release(child, profileID: fixture.profileID,
                                                           rebind: child.restoringBinding()))
        // A receiver accepts, binds, then fails to record (its window closes).
        let adoption = fixture.second.acceptTransfer(transfer) { $0.delegate = fixture.secondDelegate }
        fixture.second.close()
        #expect(await adoption.value == nil)
        #expect(transfer.state == .returned)
        #expect(peek.container.owns(child))
        #expect(child.delegate === peek)
        #expect(!child.isDisposed)
        // Abandoned for one turn: back again, never disposed.
        let abandoned = try #require(peek.container.release(child, profileID: fixture.profileID))
        #expect(await abandoned.settled() == .returned)
        #expect(peek.container.owns(child))
        peek.container.close()
        #expect(child.isDisposed)
        await fixture.close()
    }

    @Test("Termination settles a move in flight before saving, then detaches without touching the model")
    func terminationSettlesMoves() async throws {
        let fixture = try await TransferFixture.make()
        let (moving, _) = try await fixture.openInFirst(URL(string: "https://move.test/quit")!)
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        _ = fixture.second.acceptTransfer(transfer) { $0.delegate = fixture.secondDelegate }
        let sessions = [fixture.first, fixture.second, fixture.foreign]
        #expect(await BrowserTermination.settleTransfers(in: sessions, timeout: .seconds(5)))
        #expect(transfer.state == .completed)
        #expect(fixture.first.snapshot?.tabs.isEmpty == true, "the source placeholder is released before saving")
        #expect(fixture.second.snapshot?.tabs.map(\.url) == [URL(string: "https://move.test/quit")!])
        let saved = await fixture.store.sessionDocument()
        fixture.engine.teardown = .delayed(.milliseconds(100))
        let outcome = await BrowserTermination.detachAndShutDown(sessions: sessions, timeout: .seconds(5)) {
            await fixture.engine.shutdown()
        }
        #expect(outcome == .engineShutDown)
        #expect(moving.isDisposed && moving.isTeardownComplete)
        #expect(fixture.engine.surfaces.allSatisfy { $0.isTeardownComplete })
        #expect(await fixture.store.sessionDocument() == saved, "detaching must preserve the saved model")
    }

    @Test("A receiver records where the document is when it records the tab, not where it was released")
    func receiverRecordsCurrentDestination() async throws {
        let fixture = try await TransferFixture.make()
        let (moving, _) = try await fixture.openInFirst(URL(string: "https://move.test/start")!)
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer) { $0.delegate = fixture.secondDelegate }
        let moved = URL(string: "https://move.test/navigated-during-adoption")!
        moving.navigate(to: moved)
        let occurrence = try #require(await adoption.value)
        await fixture.settle()
        #expect(fixture.second.snapshot?.tabs.first { $0.occurrenceID == occurrence }?.url == moved)
        await fixture.close()
    }

    @Test("A failed receiver returns the latest address to the original occurrence without replay")
    func returnedSurfaceRecordsCurrentDestination() async throws {
        let fixture = try await TransferFixture.make()
        let (moving, source) = try await fixture.openInFirst(URL(string: "https://move.test/rollback-a")!)
        fixture.second.activateSpace(fixture.foreignSpace)
        let transfer = try #require(fixture.first.releaseSurface(moving, rebind: fixture.firstRebind))
        let adoption = fixture.second.acceptTransfer(transfer) { $0.delegate = fixture.secondDelegate }
        let latest = URL(string: "https://move.test/rollback-b")!
        moving.navigate(to: latest)
        let requests = moving.requestedURLs
        #expect(await adoption.value == nil)
        #expect(transfer.state == .returned)
        await fixture.settle()
        #expect(fixture.first.occurrenceID(for: moving) == source)
        #expect(fixture.first.snapshot?.tabs.first { $0.occurrenceID == source }?.url == latest)
        #expect(moving.requestedURLs == requests)
        #expect(!moving.isDisposed)
        await fixture.close()
    }

    @Test("Transfer settlement times out while a non-cooperative store still blocks a queued command")
    func terminationBoundsPendingCommandDrain() async throws {
        let fixture = try await TransferFixture.make()
        let (surface, occurrence) = try await fixture.openInFirst(URL(string: "https://quit.test/retained")!)
        let before = fixture.first.snapshot
        let gate = TransferStoreGate()
        let blocker = Task.detached { await fixture.store.holdTransferTestExecutor(gate) }
        await gate.waitUntilEntered()
        defer { gate.release() }
        let queued = URL(string: "https://quit.test/queued")!
        fixture.first.openTab(url: queued)
        let started = ContinuousClock.now
        let settled = await BrowserTermination.settleTransfers(in: [fixture.first], timeout: .milliseconds(100))
        #expect(!settled)
        #expect(ContinuousClock.now - started < .seconds(1), "return before the gate is released")
        #expect(fixture.first.hasPendingCommands)
        #expect(fixture.first.snapshot == before)
        #expect(fixture.first.occurrenceID(for: surface) == occurrence)
        #expect(!fixture.first.isClosed && !surface.isDisposed)
        gate.release()
        await blocker.value
        await fixture.settle()
        #expect(fixture.first.snapshot?.tabs.contains { $0.url == queued } == true)
        #expect(fixture.first.ownedSurfaces.contains { $0 === surface })
        await fixture.close()
    }

    @Test("A Peek-like container receives a new target's events and promotes it without reload")
    func peekRoundTrip() async throws {
        let fixture = try await TransferFixture.make()
        let peek = PeekLikeOwner()
        let router = RoutingWindowDelegate(peek: peek)
        fixture.first.openTab(url: URL(string: "https://move.test/opener")!)
        await fixture.settle()
        let opener = try #require(fixture.first.selectedSurface)
        opener.delegate = router
        let target = URL(string: "https://move.test/peek")!
        let child = try #require(opener.openNewTarget(target))
        #expect(peek.container.owns(child))
        #expect(child.delegate === peek)
        #expect(peek.events == ["start", "commit", "finish"])
        #expect(fixture.firstDelegate.events.filter { $0 == "commit" }.count == 1, "only the opener's own load")

        let transfer = try #require(peek.container.release(child, profileID: fixture.profileID))
        let promotion = fixture.first.acceptTransfer(transfer) { $0.delegate = fixture.firstDelegate }
        #expect(child.delegate === fixture.firstDelegate)
        #expect(!peek.container.owns(child))
        let occurrence = try #require(await promotion.value)
        await fixture.settle()
        #expect(fixture.first.selectedSurface === child)
        #expect(fixture.first.snapshot?.tabs.first { $0.occurrenceID == occurrence }?.url == target)
        #expect(child.requestedURLs == [target])
        #expect(!child.isDisposed)
        peek.container.close()
        await fixture.close()
        #expect(child.isDisposed)
    }
}
