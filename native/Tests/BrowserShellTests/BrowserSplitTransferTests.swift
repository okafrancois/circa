import BrowserCore
import Foundation
import Testing
@testable import BrowserShell

@MainActor
private final class SplitTransferSurface: BrowserSurface {
    var currentURL: URL?
    var draft = "unchanged draft"
    var disposals = 0
    var onDispose: (() -> Void)?
    init(_ url: URL) { currentURL = url }
    func dispose() { disposals += 1; onDispose?() }
}

@MainActor
private struct SplitTransferFixture {
    let store: BrowserStore
    let group: BrowserSplitGroup
    let source: BrowserWindowSession<SplitTransferSurface>
    let destination: BrowserWindowSession<SplitTransferSurface>
    let space: SpaceID
    let peer: WindowID
    let surfaces: [SplitTransferSurface]
    let made: SplitFactory
    static func make(destinationLoaded: Bool = false, paneCount: Int = 2) async throws -> Self {
        try #require((2...4).contains(paneCount))
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Space", profileID: profile)
        let sourceID = try await store.createWindow(activeSpaceID: space)
        let destinationID = try await store.createWindow(activeSpaceID: space)
        let peer = try await store.createWindow(activeSpaceID: space)
        for index in 0..<paneCount {
            _ = try await store.openTab(url: URL(string: "https://split-transfer.test/pane-\(index)")!,
                from: store.captureContext(in: sourceID), activate: true)
        }
        let tabs = try await store.captureWindowState(in: sourceID).snapshot.tabs
        let (groupID, _) = try await store.createSplit(tabs.map(\.id), from: store.captureContext(in: sourceID))
        let weights = (1...paneCount).map(Double.init)
        let total = weights.reduce(0, +)
        _ = try await store.resizeSplit(groupID, ratios: weights.map { $0 / total }, from: store.captureContext(in: sourceID))
        let group = try #require(await store.sessionDocument().organization.splits.first)
        if destinationLoaded { _ = try await store.selectSplit(groupID, from: store.captureContext(in: destinationID)) }
        let made = SplitFactory()
        let source = BrowserWindowSession(store: store, restoringWindowID: sourceID, makeSurface: made.make)
        let destination = BrowserWindowSession(store: store, restoringWindowID: destinationID, makeSurface: made.make)
        await source.waitForPendingCommands(); await destination.waitForPendingCommands()
        let surfaces = try group.tabIDs.map { id in
            let occurrence = try #require(source.organization?.tab(id)?.occurrenceID)
            return try #require(source.surface(for: occurrence))
        }
        return Self(store: store, group: group, source: source, destination: destination,
                    space: space, peer: peer, surfaces: surfaces, made: made)
    }
    func finish() async { source.close(); destination.close(); await source.waitForPendingCommands(); await destination.waitForPendingCommands() }
    func release() throws -> [BrowserSurfaceTransfer<SplitTransferSurface>] {
        try #require(source.releaseSurfaces(surfaces))
    }
}

@MainActor
private final class SplitFactory {
    var surfaces: [SplitTransferSurface] = []
    func make(_ profile: ProfileID, _ url: URL) -> SplitTransferSurface? {
        let surface = SplitTransferSurface(url); surfaces.append(surface); return surface
    }
}

@Suite("Atomic live Split handoff", .serialized)
@MainActor
struct BrowserSplitTransferTests {
    @Test("Peer reconciliation after first source release and first destination ACK sees complete groups", arguments: [2, 3, 4])
    func peerInterleaving(paneCount: Int) async throws {
        let f = try await SplitTransferFixture.make(paneCount: paneCount)
        var releaseCallbacks = 0, recordedCallbacks = 0
        let sourceID = try #require(f.source.snapshot?.id)
        let destinationID = try #require(f.destination.snapshot?.id)
        f.source.onSurfaceMembershipChange = { _, membership in
            guard membership == nil else { return }
            releaseCallbacks += 1
            #expect(f.surfaces.allSatisfy { f.source.occurrenceID(for: $0) == nil })
            #expect(f.source.hasPendingCommands)
            if releaseCallbacks == 1 { runSplitPeerMutation(f.store, window: f.peer, space: f.space) }
        }
        f.destination.onSurfaceMembershipChange = { _, membership in
            guard membership != nil else { return }
            recordedCallbacks += 1
            #expect(f.surfaces.allSatisfy { f.destination.occurrenceID(for: $0) != nil })
            if recordedCallbacks == 1 { runSplitPeerMutation(f.store, window: f.peer, space: f.space) }
        }
        let transfers = try f.release()
        let result = await f.destination.acceptSplitGroupTransfers(transfers, group: f.group, activating: f.group.tabIDs[1]).value
        #expect(result?.count == paneCount)
        await f.source.waitForPendingCommands(); await f.destination.waitForPendingCommands()
        let saved = await f.store.sessionDocument()
        #expect(saved.tabs.filter { $0.windowID == sourceID }.isEmpty)
        #expect(Set(saved.tabs.filter { $0.windowID == destinationID }.map(\.id)) == Set(f.group.tabIDs))
        #expect(f.destination.snapshot?.tabs.map(\.id) == f.group.tabIDs)
        #expect(saved.organization.tabs.count == paneCount)
        #expect(saved.organization.splits.first == f.group)
        #expect(f.destination.selectedSurface === f.surfaces[1])
        #expect(f.surfaces.allSatisfy { $0.draft == "unchanged draft" && $0.disposals == 0 })
        #expect(f.made.surfaces.count == paneCount)
        #expect(transfers.allSatisfy { $0.state == .completed })
        #expect(releaseCallbacks == paneCount && recordedCallbacks == paneCount)
        await f.finish()
    }

    @Test("Reentrant destination closure at the first bind returns every document and drains both queues")
    func closeDuringBind() async throws {
        let f = try await SplitTransferFixture.make()
        let transfers = try f.release()
        var bindings = 0
        let task = f.destination.acceptSplitGroupTransfers(transfers, group: f.group, activating: f.group.tabIDs[0]) { _ in
            bindings += 1
            #expect(f.destination.hasPendingCommands)
            if bindings == 1 { f.destination.close() }
        }
        #expect(await task.value == nil)
        await f.source.waitForPendingCommands(); await f.destination.waitForPendingCommands()
        #expect(transfers.allSatisfy { $0.state == .returned })
        #expect(f.surfaces.allSatisfy { f.source.occurrenceID(for: $0) != nil && $0.disposals == 0 })
        #expect(f.made.surfaces.count == 2)
        await f.finish()
    }

    @Test("A group changed after reservation refuses all members without a partial model write")
    func staleGroupRollback() async throws {
        let f = try await SplitTransferFixture.make()
        let transfers = try f.release()
        let stale = BrowserSplitGroup(id: f.group.id, tabIDs: f.group.tabIDs, orientation: .vertical, ratios: f.group.ratios)
        #expect(await f.destination.acceptSplitGroupTransfers(transfers, group: stale, activating: stale.tabIDs[0]).value == nil)
        await f.source.waitForPendingCommands(); await f.destination.waitForPendingCommands()
        #expect(transfers.allSatisfy { $0.state == .returned })
        #expect(f.surfaces.allSatisfy { f.source.occurrenceID(for: $0) != nil && $0.disposals == 0 })
        #expect(f.destination.snapshot?.tabs.isEmpty == true)
        #expect(f.made.surfaces.count == 2)
        await f.finish()
    }

    @Test("Every member is recorded and acknowledged before the first replacement disposal closes the receiver")
    func reentrantReplacementDisposal() async throws {
        let f = try await SplitTransferFixture.make(destinationLoaded: true)
        let old = f.destination.ownedSurfaces
        let transfers = try f.release()
        old.first?.onDispose = {
            #expect(transfers.allSatisfy { $0.state == .completed })
            #expect(f.surfaces.allSatisfy { f.destination.occurrenceID(for: $0) != nil })
            f.destination.close()
        }
        #expect(await f.destination.acceptSplitGroupTransfers(transfers, group: f.group, activating: f.group.tabIDs[0]).value == nil)
        await f.source.waitForPendingCommands(); await f.destination.waitForPendingCommands()
        #expect(transfers.allSatisfy { $0.state == .completed })
        #expect(old.allSatisfy { $0.disposals == 1 })
        #expect(f.surfaces.allSatisfy { $0.disposals == 1 && f.source.occurrenceID(for: $0) == nil })
        #expect(f.made.surfaces.count == 4)
        await f.finish()
    }

    @Test("A source closed during the first release callback still moves both live documents")
    func closeSourceDuringRelease() async throws {
        let f = try await SplitTransferFixture.make()
        f.source.onSurfaceMembershipChange = { _, membership in if membership == nil { f.source.close() } }
        let transfers = try f.release()
        #expect(await f.destination.acceptSplitGroupTransfers(transfers, group: f.group, activating: f.group.tabIDs[1]).value?.count == 2)
        await f.source.waitForPendingCommands(); await f.destination.waitForPendingCommands()
        #expect(transfers.allSatisfy { $0.state == .completed })
        #expect(f.surfaces.allSatisfy { f.destination.occurrenceID(for: $0) != nil && $0.disposals == 0 })
        await f.finish()
    }

    @Test("Accepting a group into its own source refuses before waiting on its cleanup reservation")
    func noSelfDependency() async throws {
        let f = try await SplitTransferFixture.make()
        let transfers = try f.release()
        #expect(await f.source.acceptSplitGroupTransfers(transfers, group: f.group, activating: nil).value == nil)
        await f.source.waitForPendingCommands()
        #expect(transfers.allSatisfy { $0.state == .returned })
        #expect(f.surfaces.allSatisfy { f.source.occurrenceID(for: $0) != nil })
        await f.finish()
    }
}

/// The peer's transaction completes while the callback is held, making this an actual
/// reconciliation between the first callback and the next member callback, without sleeps.
private func runSplitPeerMutation(_ store: BrowserStore, window: WindowID, space: SpaceID) {
    let result = SplitPeerSignal()
    Task.detached {
        do { _ = try await store.createFolder(title: "Peer folder", at: .init(.pinned(space)), from: store.captureContext(in: window)); result.finish(true) }
        catch { result.finish(false) }
    }
    #expect(result.wait())
}
private final class SplitPeerSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var succeeded = false
    func finish(_ value: Bool) { lock.withLock { succeeded = value }; semaphore.signal() }
    func wait() -> Bool { semaphore.wait(timeout: .now() + 5) == .success && lock.withLock { succeeded } }
}

extension BrowserSplitTransferTests {
    @Test("A queued receiver profile switch returns every member to the original profile")
    func profileSwitchRollback() async throws {
        let f = try await SplitTransferFixture.make()
        let profile = await f.store.createProfile(name: "Other profile")
        let space = try await f.store.createSpace(name: "Other", profileID: profile)
        f.destination.activateSpace(space)
        let transfers = try f.release()
        #expect(await f.destination.acceptSplitGroupTransfers(transfers, group: f.group, activating: f.group.tabIDs[0]).value == nil)
        await f.source.waitForPendingCommands(); await f.destination.waitForPendingCommands()
        #expect(f.destination.activeProfileID == profile)
        #expect(f.destination.ownedSurfaces.isEmpty)
        #expect(transfers.allSatisfy { $0.state == .returned })
        #expect(f.surfaces.allSatisfy { f.source.occurrenceID(for: $0) != nil && $0.disposals == 0 })
        #expect(f.made.surfaces.count == 2)
        await f.finish()
    }

    @Test("Source cleanup is already pending while receiver binding observes a handoff during quit preparation")
    func drainBeforeFinalSnapshot() async throws {
        let f = try await SplitTransferFixture.make()
        let sourceID = try #require(f.source.snapshot?.id)
        let gate = SplitStoreGate()
        let store = f.store
        let blocker = Task.detached { await store.holdSplitStore(gate) }
        await gate.waitUntilEntered()
        let transfers = try f.release()
        var drained = false
        let adoption = f.destination.acceptSplitGroupTransfers(transfers, group: f.group, activating: f.group.tabIDs[1]) { _ in
            #expect(!drained && f.source.hasPendingCommands)
            #expect(transfers.allSatisfy { $0.state == .accepted })
        }
        let finalSnapshot = Task { @MainActor in
            await f.source.waitForPendingCommands()
            drained = true
            return await f.store.sessionDocument()
        }
        await Task.yield()
        #expect(!drained && f.source.hasPendingCommands)
        gate.release()
        await blocker.value
        #expect(await adoption.value?.count == 2)
        let saved = await finalSnapshot.value
        #expect(drained)
        #expect(saved.tabs.filter { $0.windowID == sourceID }.isEmpty)
        #expect(saved.tabs.count == 2)
        await f.finish()
    }

    @Test("Source profile changes ahead of cleanup retain independent lease authority without leaking the group")
    func sourceProfileSwitch() async throws {
        let f = try await SplitTransferFixture.make()
        let profile = await f.store.createProfile(name: "Other source profile")
        let space = try await f.store.createSpace(name: "Other source", profileID: profile)
        f.source.activateSpace(space)
        let transfers = try f.release()
        #expect(await f.destination.acceptSplitGroupTransfers(transfers, group: f.group, activating: f.group.tabIDs[0]).value?.count == 2)
        await f.source.waitForPendingCommands(); await f.destination.waitForPendingCommands()
        #expect(f.source.activeProfileID == profile)
        #expect(f.source.ownedSurfaces.isEmpty)
        #expect(f.surfaces.allSatisfy { f.destination.occurrenceID(for: $0) != nil && $0.disposals == 0 })
        #expect(await f.store.sessionDocument().tabs.count == 2)
        await f.finish()
    }
}


private final class SplitStoreGate: @unchecked Sendable {
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let entered = AsyncStream<Void>.makeStream()
    func hold() {
        entered.continuation.yield(())
        entered.continuation.finish()
        #expect(releaseSignal.wait(timeout: .now() + 10) == .success)
    }
    func waitUntilEntered() async { for await _ in entered.stream { return } }
    func release() { releaseSignal.signal() }
}
private extension BrowserStore { func holdSplitStore(_ gate: SplitStoreGate) { gate.hold() } }

extension BrowserSplitTransferTests {
    @Test("When both windows close before admission, CONTRACT-R2 rescues both documents without partial ownership")
    func rescueWholeBatch() async throws {
        let f = try await SplitTransferFixture.make()
        let rescue = BrowserSurfaceContainer<SplitTransferSurface>()
        f.source.rescueContainer = rescue
        let transfers = try f.release()
        let task = f.destination.acceptSplitGroupTransfers(transfers, group: f.group, activating: f.group.tabIDs[0]) { _ in
            f.source.close(); f.destination.close()
        }
        #expect(await task.value == nil)
        await f.source.waitForPendingCommands(); await f.destination.waitForPendingCommands()
        #expect(transfers.allSatisfy { $0.state == .rescued })
        #expect(f.surfaces.allSatisfy { rescue.owns($0) && $0.disposals == 0 })
        #expect(await f.store.sessionDocument().tabs.isEmpty)
        rescue.close()
        #expect(f.surfaces.allSatisfy { $0.disposals == 1 })
    }
}

extension BrowserSplitTransferTests {
    @Test("Reciprocal reserved source batches reject before either receiver can create a queue cycle")
    func reciprocalReservations() async throws {
        let f = try await SplitTransferFixture.make(destinationLoaded: true)
        let first = try f.release()
        let second = try #require(f.destination.releaseSurfaces(f.destination.ownedSurfaces))
        let one = f.destination.acceptSplitGroupTransfers(first, group: f.group, activating: nil)
        let two = f.source.acceptSplitGroupTransfers(second, group: f.group, activating: nil)
        #expect(await one.value == nil)
        #expect(await two.value == nil)
        await f.source.waitForPendingCommands(); await f.destination.waitForPendingCommands()
        #expect(first.allSatisfy { $0.state == .returned })
        #expect(second.allSatisfy { $0.state == .returned })
        #expect(f.surfaces.allSatisfy { f.source.occurrenceID(for: $0) != nil && $0.disposals == 0 })
        #expect(f.source.splitReleaseReservationCount == 0 && f.destination.splitReleaseReservationCount == 0)
        await f.finish()
    }
}

extension BrowserSplitTransferTests {
    @Test("An unpublished batch construction rollback restores provenance without invoking a transit reclaim")
    func unpublishedConstructionRollback() async throws {
        let f = try await SplitTransferFixture.make()
        let surface = f.surfaces[0]
        let occurrence = try #require(f.source.occurrenceID(for: surface))
        let profile = try #require(f.source.activeProfileID)
        let url = try #require(surface.currentURL)
        var didReclaim = false
        let transfer = try #require(BrowserSurfaceTransfer(surface: surface, profileID: profile,
            url: url, tabID: f.group.tabIDs[0], from: f.source,
            source: .init(reclaim: { _, _ in didReclaim = true; return false }, commit: {}), rescue: nil))
        #expect(transfer.restoreUnpublished(to: f.source))
        #expect(transfer.state == .returned && !didReclaim)
        #expect(f.source.occurrenceID(for: surface) == occurrence)
        #expect(BrowserSurfaceProvenance.ownedRecord(for: surface, owner: f.source) != nil)
        let completeBatch = try f.release()
        #expect(await f.destination.acceptSplitGroupTransfers(completeBatch, group: f.group, activating: nil).value?.count == 2)
        #expect(f.made.surfaces.count == 2 && surface.disposals == 0)
        await f.finish()
    }

    @Test("Two source groups racing into one receiver commit one complete cohort and return the stale cohort", arguments: [2, 3, 4])
    func competingSources(paneCount: Int) async throws {
        let f = try await SplitTransferFixture.make(destinationLoaded: true, paneCount: paneCount)
        let receiver = BrowserWindowSession(store: f.store, restoringWindowID: f.peer, makeSurface: f.made.make)
        await receiver.waitForPendingCommands()
        let competingSurfaces = try f.group.tabIDs.map { id in
            let occurrence = try #require(f.destination.organization?.tab(id)?.occurrenceID)
            return try #require(f.destination.surface(for: occurrence))
        }
        let sourceID = try #require(f.source.snapshot?.id)
        let competingID = try #require(f.destination.snapshot?.id)
        let gate = SplitStoreGate()
        let blocker = Task.detached { await f.store.holdSplitStore(gate) }
        await gate.waitUntilEntered()
        // Both admissions capture absence while the actor is held. Queue order, rather than
        // sleeps or scheduler luck, determines which complete transaction wins admission.
        let first = try #require(f.source.releaseSurfaces(f.surfaces))
        let second = try #require(f.destination.releaseSurfaces(competingSurfaces))
        let winner = receiver.acceptSplitGroupTransfers(first, group: f.group, activating: f.group.tabIDs.last)
        let stale = receiver.acceptSplitGroupTransfers(second, group: f.group, activating: f.group.tabIDs.first)
        #expect(first.allSatisfy { $0.state == .accepted })
        #expect(second.allSatisfy { $0.state == .accepted })
        gate.release()
        await blocker.value
        #expect(await winner.value?.count == paneCount)
        #expect(await stale.value == nil)
        await f.source.waitForPendingCommands()
        await f.destination.waitForPendingCommands()
        await receiver.waitForPendingCommands()
        #expect(first.allSatisfy { $0.state == .completed })
        #expect(second.allSatisfy { $0.state == .returned })
        #expect(f.surfaces.allSatisfy { receiver.occurrenceID(for: $0) != nil && $0.disposals == 0 })
        #expect(competingSurfaces.allSatisfy { f.destination.occurrenceID(for: $0) != nil && $0.disposals == 0 })
        #expect(f.made.surfaces.count == 2 * paneCount)
        #expect(receiver.selectedSurface === f.surfaces.last)
        let saved = await f.store.sessionDocument()
        #expect(saved.tabs.filter { $0.windowID == sourceID }.isEmpty)
        #expect(Set(saved.tabs.filter { $0.windowID == competingID }.map(\.id)) == Set(f.group.tabIDs))
        #expect(Set(saved.tabs.filter { $0.windowID == f.peer }.map(\.id)) == Set(f.group.tabIDs))
        #expect(saved.tabs.count == 2 * paneCount)
        #expect(saved.organization.tabs.count == paneCount)
        #expect(saved.organization.splits == [f.group])
        try saved.validate()
        receiver.close()
        await receiver.waitForPendingCommands()
        await f.finish()
    }

    @Test("Individual consumers cannot partially acknowledge a reserved group")
    func individualConsumerRefusesGroup() async throws {
        let f = try await SplitTransferFixture.make()
        let transfers = try f.release()
        #expect(await f.destination.acceptTransfer(transfers[0]).value == nil)
        transfers.forEach { $0.cancel() }
        await f.source.waitForPendingCommands(); await f.destination.waitForPendingCommands()
        #expect(transfers.allSatisfy { $0.state == .returned })
        #expect(f.surfaces.allSatisfy { f.source.occurrenceID(for: $0) != nil && $0.disposals == 0 })
        #expect(f.destination.ownedSurfaces.isEmpty)
        #expect(f.made.surfaces.count == 2)
        await f.finish()
    }
}

extension BrowserSplitTransferTests {
    @Test("Peer removal of one already committed placeholder cannot retain the other source occurrence")
    func peerAlreadyReleasedPlaceholder() async throws {
        let f = try await SplitTransferFixture.make()
        let sourceID = try #require(f.source.snapshot?.id)
        let state = try await f.store.captureWindowState(in: sourceID)
        let lease = try #require(state.occurrenceAuthorities[state.snapshot.tabs[0].occurrenceID])
        var callbacks = 0
        f.destination.onSurfaceMembershipChange = { _, membership in
            guard membership != nil else { return }
            callbacks += 1
            guard callbacks == 1 else { return }
            let signal = SplitPeerSignal()
            Task.detached {
                do { _ = try await f.store.releaseOwnedOccurrenceAndCaptureState(lease, validating: f.store.captureContext(in: sourceID)); signal.finish(true) }
                catch { signal.finish(false) }
            }
            #expect(signal.wait())
        }
        let transfers = try f.release()
        #expect(await f.destination.acceptSplitGroupTransfers(transfers, group: f.group, activating: f.group.tabIDs[1]).value?.count == 2)
        await f.source.waitForPendingCommands(); await f.destination.waitForPendingCommands()
        #expect(await f.store.sessionDocument().tabs.filter { $0.windowID == sourceID }.isEmpty)
        #expect(f.surfaces.allSatisfy { f.destination.occurrenceID(for: $0) != nil && $0.disposals == 0 })
        await f.finish()
    }
}

extension BrowserSplitTransferTests {
    @Test("A delayed second rescue keeps its cohort across turns and transfer deallocation before atomic rehome")
    func delayedRescueCohort() async throws {
        let f = try await SplitTransferFixture.make()
        let rescue = BrowserSurfaceContainer<SplitTransferSurface>()
        f.source.rescueContainer = rescue
        let firstNotice = AsyncStream<Void>.makeStream()
        var notifications = 0, readiness = 0
        rescue.onRescue = { _ in
            notifications += 1
            if notifications == 1 { firstNotice.continuation.yield(()); firstNotice.continuation.finish() }
        }
        rescue.onRescueReadinessChange = { readiness += 1 }
        var transfers: [BrowserSurfaceTransfer<SplitTransferSurface>]? = try f.release()
        let holder = NSObject()
        for transfer in transfers! {
            #expect(transfer.complete(to: holder, state: .reserved, batchToken: transfer.batchToken) != nil)
        }
        f.source.close()
        transfers![0].didFail(at: holder)
        for await _ in firstNotice.stream { break }
        #expect(rescue.surfaces.count == 1 && rescue.readySplitRescues.isEmpty)
        #expect(readiness == 0)
        #expect(rescue.release(f.surfaces[0], profileID: transfers![0].profileID) == nil)
        #expect(!(await BrowserSurfaceTransfers.settle(timeout: .zero)))
        // B is explicitly retained by the synthetic receiver across several executor turns.
        for _ in 0..<3 { await Task.yield() }
        runSplitPeerMutation(f.store, window: f.peer, space: f.space)
        #expect(rescue.readySplitRescues.isEmpty)
        #expect(f.made.surfaces.count == 2)
        transfers![1].didFail(at: holder)
        weak var releasedTransfer = transfers![0]
        transfers = nil
        await f.source.waitForPendingCommands()
        await Task.yield()
        #expect(releasedTransfer == nil)
        #expect(readiness == 1)
        let ready = try #require(rescue.readySplitRescues.first)
        #expect(ready.surfaces.count == 2)
        #expect(zip(ready.surfaces, f.surfaces).allSatisfy { $0 === $1 })
        let forward = try #require(rescue.releaseSplit(ready))
        #expect(await f.destination.acceptSplitGroupTransfers(forward, group: ready.group, activating: ready.group.tabIDs[1]).value?.count == 2)
        await f.destination.waitForPendingCommands()
        #expect(f.made.surfaces.count == 2)
        #expect(f.surfaces.allSatisfy { f.destination.occurrenceID(for: $0) != nil && $0.disposals == 0 })
        #expect(rescue.surfaces.isEmpty)
        await f.finish(); rescue.close()
    }
}
