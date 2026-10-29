import BrowserCore
import Foundation

/// Where a window session records one of its live surfaces.
public struct BrowserSurfaceMembership: Equatable, Sendable {
    public let windowID: WindowID
    public let occurrenceID: TabOccurrenceID

    public init(windowID: WindowID, occurrenceID: TabOccurrenceID) {
        self.windowID = windowID
        self.occurrenceID = occurrenceID
    }
}

/// Runtime-only identity of a complete group handoff. It holds no engine document or owner.
@MainActor
final class BrowserSplitTransferCohort {
    let token = UUID()
    let group: BrowserSplitGroup
    let profileID: ProfileID
    let spaceID: SpaceID
    let members: [TabID: ObjectIdentifier]
    private var settled: Set<ObjectIdentifier> = []
    private var observers: [ObjectIdentifier: @MainActor () -> Void] = [:]
    var isSettled: Bool { settled.count == members.count }
    init(group: BrowserSplitGroup, profileID: ProfileID, spaceID: SpaceID, members: [TabID: ObjectIdentifier]) {
        self.group = group; self.profileID = profileID; self.spaceID = spaceID; self.members = members
    }
    func observe(owner: AnyObject, _ observer: @escaping @MainActor () -> Void) {
        observers[ObjectIdentifier(owner)] = observer
    }
    func didSettle(_ surface: any BrowserSurface) {
        let id = ObjectIdentifier(surface)
        guard members.values.contains(id), settled.insert(id).inserted, isSettled else { return }
        let callbacks = Array(observers.values)
        observers.removeAll()
        callbacks.forEach { $0() }
    }
}

/// An exact, complete group held by the rescue container, ready for one atomic rehome.
@MainActor
package struct BrowserRescuedSplit<Surface: BrowserSurface> {
    package let group: BrowserSplitGroup
    package let profileID: ProfileID
    package var spaceID: SpaceID { cohort.spaceID }
    package let surfaces: [Surface]
    fileprivate let cohort: BrowserSplitTransferCohort
}

/// A live surface moving between two owners: window sessions, Peek, Little Orbit.
/// Every live surface has exactly one owner in the shared provenance registry. A releasing owner
/// (the source) creates the transfer, which owns the surface while in flight; the receiver accepts
/// it and runs its binding (engine delegate, observers, placement) in the same main-actor turn, so
/// no engine event can reach the previous owner in between. Nothing in a move disposes, reloads or
/// replays the document.
/// A move is reversible until the receiver has recorded the surface. The source keeps a placeholder
/// (a window keeps the tab's model occurrence) and takes the live surface back, rebound, when no
/// receiver accepts it before the main actor next becomes free, or when the receiver fails to
/// record it (its window closed, its Space changed profile, a model error). When the source can no
/// longer hold it either, the surface goes to the source's rescue container, or, without one, to
/// the stranded registry (`BrowserSurfaceTransfers`). A failed move never disposes a live document.
/// Only a recorded transfer lets the source drop its placeholder.
@MainActor
public final class BrowserSurfaceTransfer<Surface: BrowserSurface> {
    public enum State: Equatable, Sendable {
        /// Released by its source and not accepted yet.
        case pending
        /// A receiver holds the surface and is recording it.
        case accepted
        /// The receiver recorded the surface; the source dropped its placeholder. Final.
        case completed
        /// The source took the surface back, rebound, as it was before the move. Final.
        case returned
        /// Neither receiver nor source could hold it; a rescue container owns it. Final.
        case rescued
        /// No rescue container either: `BrowserSurfaceTransfers` keeps it alive. Final.
        case stranded

        public var isSettled: Bool { self != .pending && self != .accepted }
    }

    /// The source's return path, captured when it releases the surface.
    struct Source {
        /// Takes the surface back from `holder` synchronously and rebinds it; false when the source
        /// can no longer hold it (closed, placeholder gone, profile changed).
        let reclaim: @MainActor (BrowserSurfaceTransfer<Surface>, AnyObject) -> Bool
        /// The receiver recorded the surface: the source drops its placeholder.
        let commit: @MainActor () -> Void
    }

    public let surface: Surface
    public let profileID: ProfileID
    public let url: URL
    /// The sidebar tab moving with the document, when the releasing owner had one.
    public let tabID: TabID?
    /// A degraded rescued pane must become standalone without changing a peer's live group.
    let isStandaloneRescue: Bool
    /// Group handoffs can only be consumed by the complete batch receiver.
    let cohort: BrowserSplitTransferCohort?
    var batchToken: UUID? { cohort?.token }
    public private(set) var state: State = .pending
    private let source: Source
    private weak var releasingOwner: AnyObject?
    private let rescue: BrowserSurfaceContainer<Surface>?
    private weak var receiver: AnyObject?
    private var waiters: [CheckedContinuation<State, Never>] = []

    init?(surface: Surface, profileID: ProfileID, url: URL, tabID: TabID? = nil, from owner: AnyObject,
          source: Source, rescue: BrowserSurfaceContainer<Surface>?, cohort: BrowserSplitTransferCohort? = nil,
          isStandaloneRescue: Bool = false) {
        self.surface = surface
        self.profileID = profileID
        self.url = url
        self.tabID = tabID
        self.cohort = cohort
        self.isStandaloneRescue = isStandaloneRescue
        self.source = source
        self.releasingOwner = owner
        self.rescue = rescue
        guard BrowserSurfaceProvenance.handOff(surface, from: owner, to: self, state: .owned) != nil else { return nil }
        BrowserSurfaceTransfers.begin(self)
        // A transfer nobody accepted in its turn goes back to its source; it is never disposed.
        Task { @MainActor [self] in cancel() }
    }

    func originates(from owner: AnyObject) -> Bool { releasingOwner === owner }

    /// Hands the surface to `receiver`. The caller records it, or reports `didFail(at:)`, and runs
    /// its binding before returning to the main actor's executor.
    func complete(to receiver: AnyObject, state: BrowserSurfaceProvenance.Record.State,
                  batchToken: UUID? = nil) -> BrowserSurfaceProvenance.Record? {
        guard self.batchToken == batchToken, self.state == .pending,
              let record = BrowserSurfaceProvenance.handOff(surface, from: self, to: receiver, state: state) else { return nil }
        self.state = .accepted
        self.receiver = receiver
        return record
    }

    /// Receiver side: the surface is recorded. The source drops its placeholder.
    func didRecord(by receiver: AnyObject) {
        guard state == .accepted, self.receiver === receiver else { return }
        settle(.completed)
        source.commit()
    }

    /// Receiver side: recording failed while the receiver still held the surface.
    func didFail(at receiver: AnyObject) {
        guard state == .accepted, self.receiver === receiver else { return }
        returnSurface(from: receiver)
    }

    /// Abandons a transfer that no receiver accepted: the live surface returns to its source, or
    /// is rescued. No effect once accepted.
    public func cancel() {
        guard state == .pending else { return }
        returnSurface(from: self)
    }

    /// Construction rollback before a batch publishes any source transit or membership change.
    /// The source's ownership maps are still intact; its normal reclaim path is not applicable.
    func restoreUnpublished(to owner: AnyObject) -> Bool {
        guard state == .pending, originates(from: owner),
              BrowserSurfaceProvenance.handOff(surface, from: self, to: owner, state: .owned) != nil else { return false }
        settle(.returned)
        return true
    }

    /// The final state, once the receiver recorded the surface or it went back or to a rescue.
    public func settled() async -> State {
        if state.isSettled { return state }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func returnSurface(from holder: AnyObject) {
        if source.reclaim(self, holder) {
            settle(.returned)
        } else if let rescue, rescue.rescue(surface, tabID: tabID, from: holder, cohort: cohort,
                                          isStandaloneRescue: isStandaloneRescue) {
            settle(.rescued)
        } else if BrowserSurfaceTransfers.strand(surface, tabID: tabID, from: holder) {
            settle(.stranded)
        } else {
            // The holder no longer held a live surface (already disposed by its owner).
            settle(.returned)
        }
    }

    private func settle(_ final: State) {
        state = final
        BrowserSurfaceTransfers.end(self)
        cohort?.didSettle(surface)
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume(returning: final) }
    }
}

/// Process-wide view of moves in flight and of surfaces stranded by failed moves.
@MainActor
public enum BrowserSurfaceTransfers {
    /// Keeps a stranded surface alive and owned until someone claims it or termination disposes it.
    final class StrandedOwner {
        let surface: any BrowserSurface
        let tabID: TabID?
        init(_ surface: any BrowserSurface, tabID: TabID?) {
            self.surface = surface
            self.tabID = tabID
        }
    }

    private static var inFlight: [ObjectIdentifier: AnyObject] = [:]
    private static var stranded: [ObjectIdentifier: StrandedOwner] = [:]

    public static var inFlightCount: Int { inFlight.count }

    static func begin(_ transfer: AnyObject) { inFlight[ObjectIdentifier(transfer)] = transfer }
    static func end(_ transfer: AnyObject) { inFlight.removeValue(forKey: ObjectIdentifier(transfer)) }

    /// Waits until every move in flight is recorded, returned or rescued. False on timeout.
    public static func settle(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !inFlight.isEmpty {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    static func strand(_ surface: any BrowserSurface, tabID: TabID?, from holder: AnyObject) -> Bool {
        let owner = StrandedOwner(surface, tabID: tabID)
        guard BrowserSurfaceProvenance.handOff(surface, from: holder, to: owner, state: .owned) != nil else { return false }
        stranded[ObjectIdentifier(surface)] = owner
        return true
    }

    public static func isStranded(_ surface: some BrowserSurface) -> Bool {
        guard let owner = stranded[ObjectIdentifier(surface)], owner.surface === surface else { return false }
        return BrowserSurfaceProvenance.isHeld(surface, by: owner)
    }

    public static func strandedSurfaces<Surface: BrowserSurface>(of type: Surface.Type) -> [Surface] {
        stranded.values.compactMap { owner in
            guard let surface = owner.surface as? Surface, BrowserSurfaceProvenance.isHeld(surface, by: owner) else { return nil }
            return surface
        }
    }

    /// Moves a stranded surface into `container`, which becomes its owner.
    @discardableResult
    public static func claimStranded<Surface: BrowserSurface>(
        _ surface: Surface, into container: BrowserSurfaceContainer<Surface>
    ) -> Bool {
        guard let owner = stranded[ObjectIdentifier(surface)], owner.surface === surface,
              container.take(surface, tabID: owner.tabID, from: owner, notifyRescue: false) else { return false }
        stranded.removeValue(forKey: ObjectIdentifier(surface))
        return true
    }

    /// Application termination only, after the session was saved: disposes stranded surfaces.
    public static func disposeStranded<Surface: BrowserSurface>(
        of type: Surface.Type, where predicate: (Surface) -> Bool = { _ in true }
    ) {
        for (key, owner) in stranded {
            guard let surface = owner.surface as? Surface, predicate(surface) else { continue }
            stranded.removeValue(forKey: key)
            BrowserSurfaceProvenance.dispose(surface, ownedBy: owner)
        }
    }
}

/// Ownership of live surfaces outside window sessions: Peek, Little Orbit, prepared panes, and the
/// rescue holder of failed moves. The same provenance rules apply: one owner per surface, disposal
/// exactly once, moves only through `BrowserSurfaceTransfer`.
@MainActor
public final class BrowserSurfaceContainer<Surface: BrowserSurface> {
    public private(set) var surfaces: [Surface] = []
    /// A document released by a window keeps its logical tab through intermediate owners.
    /// Engine-created documents have no logical tab until a window records them.
    private var logicalTabs: [ObjectIdentifier: TabID] = [:]
    private var splitCohorts: [ObjectIdentifier: BrowserSplitTransferCohort] = [:]
    private var standaloneRescues: Set<ObjectIdentifier> = []
    package var onRescueReadinessChange: (() -> Void)?
    public private(set) var isClosed = false
    /// Where a surface released from this container goes if its move fails after this container
    /// closed. Nil leaves it to the stranded registry.
    public var rescueContainer: BrowserSurfaceContainer<Surface>?
    /// Called on the next main-actor turn when a failed move left a surface in this container as
    /// its rescue holder, so the application can give it a visible home.
    public var onRescue: ((Surface) -> Void)?

    public init() {}

    /// Takes ownership of a surface that has no owner yet, such as a new target obtained from the
    /// engine's `make()`. False when another owner already holds it.
    @discardableResult
    public func claim(_ surface: Surface) -> Bool {
        guard !isClosed, BrowserSurfaceProvenance.registerFactorySurface(surface, for: self) else { return false }
        surfaces.append(surface)
        return true
    }

    public func owns(_ surface: Surface) -> Bool {
        !isClosed && surfaces.contains { $0 === surface } && BrowserSurfaceProvenance.isHeld(surface, by: self)
    }

    /// Starts moving a surface out of this container. Accept the result in the same turn. Should
    /// the move fail, the surface comes back here and `rebind` runs synchronously before any engine
    /// event, to restore this owner's delegate and observers (see `restoringBinding()` for engine
    /// surfaces); without it the surface keeps whatever binding the failed receiver installed.
    public func release(
        _ surface: Surface, profileID: ProfileID, rebind: ((Surface) -> Void)? = nil
    ) -> BrowserSurfaceTransfer<Surface>? {
        guard splitCohorts[ObjectIdentifier(surface)] == nil else { return nil }
        return release(surface, profileID: profileID, rebind: rebind, cohort: nil)
    }

    private func release(_ surface: Surface, profileID: ProfileID, rebind: ((Surface) -> Void)?,
                         cohort: BrowserSplitTransferCohort?) -> BrowserSurfaceTransfer<Surface>? {
        guard owns(surface) else { return nil }
        let url = surface.currentURL ?? URL(string: "about:blank")!
        let tabID = logicalTabs[ObjectIdentifier(surface)]
        let isStandaloneRescue = standaloneRescues.contains(ObjectIdentifier(surface))
        let source = BrowserSurfaceTransfer<Surface>.Source(
            reclaim: { [weak self] transfer, holder in
                guard let self, take(transfer.surface, tabID: transfer.tabID, from: holder,
                                     notifyRescue: false, cohort: cohort, isStandaloneRescue: isStandaloneRescue) else { return false }
                rebind?(transfer.surface)
                return true
            },
            commit: {})
        guard let transfer = BrowserSurfaceTransfer(surface: surface, profileID: profileID, url: url,
                                                    tabID: tabID, from: self,
                                                    source: source, rescue: rescueContainer, cohort: cohort,
                                                    isStandaloneRescue: isStandaloneRescue) else {
            return nil
        }
        surfaces.removeAll { $0 === surface }
        logicalTabs.removeValue(forKey: ObjectIdentifier(surface))
        splitCohorts.removeValue(forKey: ObjectIdentifier(surface))
        standaloneRescues.remove(ObjectIdentifier(surface))
        return transfer
    }

    /// Takes a transferred surface. `bind` runs synchronously after ownership changed and before
    /// any engine event can be delivered; it installs the container's delegate and observers.
    @discardableResult
    public func accept(_ transfer: BrowserSurfaceTransfer<Surface>, bind: (Surface) -> Void) -> Bool {
        guard !isClosed, transfer.complete(to: self, state: .owned) != nil else { return false }
        surfaces.append(transfer.surface)
        logicalTabs[ObjectIdentifier(transfer.surface)] = transfer.tabID
        if transfer.isStandaloneRescue { standaloneRescues.insert(ObjectIdentifier(transfer.surface)) }
        bind(transfer.surface)
        transfer.didRecord(by: self)
        return true
    }

    public func dispose(_ surface: Surface) {
        guard surfaces.contains(where: { $0 === surface }) else { return }
        surfaces.removeAll { $0 === surface }
        logicalTabs.removeValue(forKey: ObjectIdentifier(surface))
        splitCohorts.removeValue(forKey: ObjectIdentifier(surface))
        standaloneRescues.remove(ObjectIdentifier(surface))
        BrowserSurfaceProvenance.dispose(surface, ownedBy: self)
    }

    /// Disposes every owned surface. Later claims and accepts fail.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        let retired = surfaces
        surfaces.removeAll()
        logicalTabs.removeAll()
        splitCohorts.removeAll()
        standaloneRescues.removeAll()
        for surface in retired { BrowserSurfaceProvenance.revoke(surface, ownedBy: self) }
        for surface in retired { BrowserSurfaceProvenance.dispose(surface, ownedBy: self) }
    }

    package var groupedRescueIDs: Set<SplitGroupID> { Set(splitCohorts.values.map { $0.group.id }) }

    package func isGroupedRescue(_ surface: Surface) -> Bool { splitCohorts[ObjectIdentifier(surface)] != nil }

    /// Includes a settled cohort's surviving held members even when siblings returned elsewhere.
    package var settledSplitRescues: [BrowserRescuedSplit<Surface>] {
        var seen: Set<ObjectIdentifier> = []
        return splitCohorts.values.compactMap { cohort in
            guard seen.insert(ObjectIdentifier(cohort)).inserted, cohort.isSettled else { return nil }
            let ordered = cohort.group.tabIDs.compactMap { tabID -> Surface? in
                guard let expected = cohort.members[tabID], let surface = surfaces.first(where: { ObjectIdentifier($0) == expected }),
                      owns(surface), logicalTabs[expected] == tabID, splitCohorts[expected] === cohort else { return nil }
                return surface
            }
            guard !ordered.isEmpty else { return nil }
            return BrowserRescuedSplit(group: cohort.group, profileID: cohort.profileID, surfaces: ordered, cohort: cohort)
        }
    }

    package var readySplitRescues: [BrowserRescuedSplit<Surface>] {
        settledSplitRescues.filter { $0.surfaces.count == $0.group.tabIDs.count }
    }

    /// Keep the original identity as a hint; Core reuses it only if no live occurrence depends
    /// on it. An archived/deleted tab or a peer's live document gets an independent new identity.
    @discardableResult
    package func dissolveSplitRescue(_ rescued: BrowserRescuedSplit<Surface>) -> Bool {
        guard rescued.cohort.isSettled, rescued.surfaces.allSatisfy({
            owns($0) && splitCohorts[ObjectIdentifier($0)] === rescued.cohort
        }) else { return false }
        for surface in rescued.surfaces {
            splitCohorts.removeValue(forKey: ObjectIdentifier(surface))
            standaloneRescues.insert(ObjectIdentifier(surface))
        }
        return true
    }

    package func rescuedTabID(for surface: Surface) -> TabID? { logicalTabs[ObjectIdentifier(surface)] }
    package func isStandaloneRescue(_ surface: Surface) -> Bool { standaloneRescues.contains(ObjectIdentifier(surface)) }

    package func recordRescuedTab(_ tabID: TabID, for surface: Surface) {
        guard owns(surface), !isGroupedRescue(surface) else { return }
        logicalTabs[ObjectIdentifier(surface)] = tabID
    }

    package func releaseSplit(_ rescued: BrowserRescuedSplit<Surface>) -> [BrowserSurfaceTransfer<Surface>]? {
        guard rescued.cohort.isSettled, rescued.surfaces.count == rescued.group.tabIDs.count, rescued.surfaces.allSatisfy({
            owns($0) && splitCohorts[ObjectIdentifier($0)] === rescued.cohort
        }) else { return nil }
        let cohort = BrowserSplitTransferCohort(group: rescued.group, profileID: rescued.profileID, spaceID: rescued.spaceID,
            members: rescued.cohort.members)
        var transfers: [BrowserSurfaceTransfer<Surface>] = []
        for surface in rescued.surfaces {
            guard let transfer = release(surface, profileID: rescued.profileID, rebind: nil, cohort: cohort) else {
                transfers.forEach { $0.cancel() }; return nil
            }
            transfers.append(transfer)
        }
        return transfers
    }

    /// Rescue holder side of a failed move.
    func rescue(_ surface: Surface, tabID: TabID?, from holder: AnyObject, cohort: BrowserSplitTransferCohort? = nil,
                isStandaloneRescue: Bool = false) -> Bool {
        take(surface, tabID: tabID, from: holder, notifyRescue: true, cohort: cohort, isStandaloneRescue: isStandaloneRescue)
    }

    func take(_ surface: Surface, tabID: TabID?, from holder: AnyObject, notifyRescue: Bool,
              cohort: BrowserSplitTransferCohort? = nil, isStandaloneRescue: Bool = false) -> Bool {
        guard !isClosed, BrowserSurfaceProvenance.handOff(surface, from: holder, to: self, state: .owned) != nil else {
            return false
        }
        surfaces.append(surface)
        logicalTabs[ObjectIdentifier(surface)] = tabID
        splitCohorts[ObjectIdentifier(surface)] = cohort
        if isStandaloneRescue { standaloneRescues.insert(ObjectIdentifier(surface)) }
        if notifyRescue {
            cohort?.observe(owner: self) { [weak self] in self?.onRescueReadinessChange?() }
            Task { @MainActor [weak self, weak surface] in
                guard let self, let surface, owns(surface) else { return }
                onRescue?(surface)
            }
        }
        return true
    }
}

/// A source placeholder: the model occurrence of a window tab whose live surface is in transit.
struct SurfaceTransit<Surface: BrowserSurface> {
    var authority: BrowserOccurrenceAuthority
    let orderIndex: Int
    var rebind: ((Surface) -> Void)?
    /// The receiver recorded the surface; the occurrence is being removed from the model.
    var isCommitted = false
}

public extension BrowserWindowSession {
    func releaseSurface(
        _ surface: Surface, rebind: ((Surface) -> Void)? = nil
    ) -> BrowserSurfaceTransfer<Surface>? {
        guard !isClosed, let occurrenceID = occurrenceID(for: surface), let authority = authorities[occurrenceID],
              BrowserSurfaceProvenance.ownedRecord(for: surface, owner: self) != nil else { return nil }
        let url = surface.currentURL
            ?? snapshot?.tabs.first(where: { $0.occurrenceID == occurrenceID })?.url
            ?? URL(string: "about:blank")!
        let tabID = snapshot?.tabs.first(where: { $0.occurrenceID == occurrenceID })?.id
        let source = BrowserSurfaceTransfer<Surface>.Source(
            reclaim: { [weak self] transfer, holder in
                self?.reclaim(transfer, as: occurrenceID, from: holder) ?? false
            },
            commit: { [weak self] in self?.commitRelease(of: occurrenceID) })
        guard let transfer = BrowserSurfaceTransfer(surface: surface, profileID: authority.profileID, url: url,
                                                    tabID: tabID, from: self, source: source,
                                                    rescue: rescueContainer) else {
            return nil
        }
        let orderIndex = surfaceOrder.firstIndex(of: occurrenceID) ?? surfaceOrder.count
        surfaces.removeValue(forKey: occurrenceID)
        surfaceOrder.removeAll { $0 == occurrenceID }
        occurrencesBySurface.removeValue(forKey: ObjectIdentifier(surface))
        authorities.removeValue(forKey: occurrenceID)
        transits[occurrenceID] = SurfaceTransit(authority: authority, orderIndex: orderIndex, rebind: rebind)
        onSurfaceMembershipChange?(surface, nil)
        return transfer
    }

    func acceptTransfer(
        _ transfer: BrowserSurfaceTransfer<Surface>, activate: Bool = true, replacingExisting: Bool = false,
        movingTo destination: BrowserOrganizationDestination? = nil,
        bind: (Surface) -> Void = { _ in }, didAdopt: (() -> Void)? = nil
    ) -> Task<TabOccurrenceID?, Never> {
        guard !isClosed, let activeContext, activeContext.profileID == transfer.profileID else { return Task { nil } }
        let expectedOccurrenceID = replacingExisting ? occurrenceTabIDs.first { $0.value == transfer.tabID }?.key : nil
        let replacementSurface = expectedOccurrenceID.flatMap { surfaces[$0] }
        let replacementAuthority = expectedOccurrenceID.flatMap { modelOccurrenceAuthorities[$0] }
        let replacementOwnership = replacementSurface.flatMap { BrowserSurfaceProvenance.ownedRecord(for: $0, owner: self) }
        func replacementIsCurrent(in context: BrowserContext) -> Bool {
            guard let expectedOccurrenceID else { return true } // Core checks the captured absence.
            guard let replacementAuthority,
                  replacementAuthority.storeGeneration == context.storeGeneration,
                  replacementAuthority.windowID == context.windowID,
                  replacementAuthority.profileID == transfer.profileID,
                  modelOccurrenceAuthorities[expectedOccurrenceID] == replacementAuthority,
                  transits[expectedOccurrenceID] == nil else { return false }
            if let replacementSurface {
                return surfaces[expectedOccurrenceID] === replacementSurface
                    && authorities[expectedOccurrenceID] == replacementAuthority
                    && replacementOwnership != nil
                    && BrowserSurfaceProvenance.ownedRecord(for: replacementSurface, owner: self) === replacementOwnership
            }
            // Restoration materializes only active tabs. A cold inactive model lease is valid
            // without provenance; a transit, stale physical authority or newly loaded document is not.
            return replacementAuthority.spaceID != context.spaceID
                && surfaces[expectedOccurrenceID] == nil && authorities[expectedOccurrenceID] == nil
        }
        if replacingExisting {
            guard transfer.tabID != nil, replacementIsCurrent(in: activeContext) else { return Task { nil } }
        }
        let replacementLifetime = replacementOwnership?.lifetime ?? SurfaceCommandLifetime()
        guard let reservation = transfer.complete(to: self, state: .reserved) else { return Task { nil } }
        let surface = transfer.surface
        bind(surface)
        pendingCommandCount += 1
        let previous = pending
        let adoption = Task<TabOccurrenceID?, Never> { [self] in
            defer {
                // Ignored once recorded: a recorded surface belongs to this window from then on.
                if occurrencesBySurface[ObjectIdentifier(surface)] == nil { transfer.didFail(at: self) }
                pendingCommandCount -= 1
            }
            await previous?.value
            guard !isClosed, BrowserSurfaceProvenance.isReserved(reservation, surface: surface, for: self) else { return nil }
            do {
                guard let context = try await validatedContext(), context.profileID == transfer.profileID,
                      BrowserSurfaceProvenance.isReserved(reservation, surface: surface, for: self) else { return nil }
                guard !replacingExisting || replacementIsCurrent(in: context) else { return nil }
                let url = surface.currentURL ?? transfer.url
                guard let (occurrenceID, state) = try await store.openTransferredSurfaceTab(
                          url: url, tabID: transfer.tabID, from: context, activate: activate,
                          standaloneRescue: transfer.isStandaloneRescue,
                          replacingExisting: replacingExisting,
                          expectedExistingOccurrenceID: expectedOccurrenceID, movingTo: destination,
                          lifetime: surfaceCommandLifetime, providedLifetime: reservation.lifetime,
                          replacementLifetime: replacementLifetime),
                      !isClosed, BrowserSurfaceProvenance.bind(reservation, surface: surface, to: self) else { return nil }
                record(surface, as: occurrenceID, authority: state.occurrenceAuthorities[occurrenceID])
                transfer.didRecord(by: self)
                install(state)
                reconcileDestination(of: surface, recorded: url)
                guard !isClosed, let adopted = self.occurrenceID(for: surface) else { return nil }
                // Retire transient source chrome in the same turn that presents the live host.
                didAdopt?()
                return adopted
            } catch {
                return nil
            }
        }
        pending = Task { _ = await adoption.value }
        return adoption
    }

    /// True while a surface released from `occurrenceID` is in flight; its placeholder stays.
    func isInTransit(_ occurrenceID: TabOccurrenceID) -> Bool { transits[occurrenceID] != nil }
}

extension BrowserWindowSession {
    /// Source side of a failed move: records the live surface again as its placeholder occurrence.
    func reclaim(_ transfer: BrowserSurfaceTransfer<Surface>, as occurrenceID: TabOccurrenceID,
                 from holder: AnyObject) -> Bool {
        guard !isClosed, let transit = transits[occurrenceID], !transit.isCommitted,
              transit.authority.profileID == transfer.profileID, surfaces[occurrenceID] == nil,
              BrowserSurfaceProvenance.handOff(transfer.surface, from: holder, to: self, state: .owned) != nil else {
            return false
        }
        transits.removeValue(forKey: occurrenceID)
        record(transfer.surface, as: occurrenceID, authority: transit.authority, at: transit.orderIndex)
        transit.rebind?(transfer.surface)
        reconcileDestination(of: transfer.surface, recorded: transfer.url)
        onChange?()
        // The placeholder may have changed in the model while the surface was away.
        refreshCatalog()
        return true
    }

    /// Source side of a recorded move: releases the placeholder occurrence in command order. The
    /// logical tab stays with the receiver (ORG-MODEL), which may already have moved it to its
    /// Space and relocated this occurrence, so the release adopts such a change.
    func commitRelease(of occurrenceID: TabOccurrenceID) {
        guard !isClosed, var transit = transits[occurrenceID], !transit.isCommitted else { return }
        transit.isCommitted = true
        transit.rebind = nil
        transits[occurrenceID] = transit
        let authority = transit.authority
        enqueue { session in
            guard let context = try await session.organizationContext(),
                  let state = try await session.store.closeReleasedSurfaceTab(
                      authority, validating: context, lifetime: session.surfaceCommandLifetime),
                  !session.isClosed else { return }
            session.install(state)
        }
    }

    /// Records the address a live surface reached while its model tab was being created.
    func reconcileDestination(of surface: Surface, recorded url: URL) {
        guard !isClosed, occurrenceID(for: surface) != nil,
              let current = surface.currentURL, current != url else { return }
        updateDestination(for: surface, to: current)
    }
}

private extension BrowserStore {
    func closeReleasedSurfaceTab(
        _ authority: BrowserOccurrenceAuthority, validating context: BrowserContext, lifetime: SurfaceCommandLifetime
    ) throws -> BrowserWindowState? {
        try lifetime.whileActive {
            try releaseOwnedOccurrenceAndCaptureState(authority, validating: context)
        }
    }

    func openTransferredSurfaceTab(
        url: URL, tabID: TabID?, from context: BrowserContext, activate: Bool, standaloneRescue: Bool, replacingExisting: Bool,
        expectedExistingOccurrenceID: TabOccurrenceID?, movingTo destination: BrowserOrganizationDestination? = nil,
        lifetime: SurfaceCommandLifetime, providedLifetime: SurfaceCommandLifetime,
        replacementLifetime: SurfaceCommandLifetime
    ) throws -> (TabOccurrenceID, BrowserWindowState)? {
        try lifetime.whileActive { () throws -> (TabOccurrenceID, BrowserWindowState)? in
            try providedLifetime.whileActive { () throws -> (TabOccurrenceID, BrowserWindowState)? in
                try replacementLifetime.whileActive { () throws -> (TabOccurrenceID, BrowserWindowState)? in
                    if standaloneRescue {
                        let occurrenceID = try openStandaloneRescuedOccurrence(of: tabID, url: url, from: context, activate: activate)
                        return (occurrenceID, try captureWindowState(in: context.windowID))
                    }
                    let occurrenceID = try openTransferredOccurrence(of: tabID, url: url, from: context, activate: activate,
                        replacingExisting: replacingExisting, expectedExistingOccurrenceID: expectedExistingOccurrenceID, movingTo: destination)
                    return (occurrenceID, try captureWindowState(in: context.windowID))
                } ?? nil
            } ?? nil
        } ?? nil
    }
}
