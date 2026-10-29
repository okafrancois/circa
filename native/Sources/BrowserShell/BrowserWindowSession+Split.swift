import BrowserCore
import Foundation

public extension BrowserWindowSession {
    var splitCommandContext: BrowserContext? { isClosed ? nil : activeContext }

    var activeSplit: BrowserOrganizationSplitItem? {
        guard let selected = snapshot?.selectedOccurrenceID else { return nil }
        func search(_ items: [BrowserOrganizationItem]) -> BrowserOrganizationSplitItem? {
            for item in items {
                if case let .split(split) = item, split.tabs.contains(where: { $0.occurrenceID == selected }) { return split }
                if case let .folder(folder) = item, let result = search(folder.children) { return result }
            }
            return nil
        }
        guard let organization else { return nil }
        return search(organization.pinned + organization.today)
    }

    func createSplit(_ ids: [TabID], orientation: BrowserSplitOrientation = .horizontal) {
        enqueueOrganization { session, context in try await session.store.createSplit(ids, orientation: orientation, from: context).1 }
    }
    func addSplitPane(url: URL = URL(string: "about:blank")!, at index: Int? = nil) {
        enqueueOrganization { session, context in try await session.store.splitWithNewTab(url: url, at: index, from: context) }
    }
    func addSplitPane(_ id: TabID, to split: SplitGroupID, at index: Int? = nil, orientation: BrowserSplitOrientation? = nil) {
        enqueueOrganization { session, context in try await session.store.addPane(id, to: split, at: index, orientation: orientation, from: context) }
    }
    func selectSplit(_ id: SplitGroupID) {
        enqueueOrganization { session, context in
            try await session.store.selectSplitUpdating(id, from: context,
                state: session.selectionState, index: session.organizationRuntime.metadataIndex)
        }
    }
    func closeSplitPane(_ id: TabID) {
        enqueueOrganization { session, context in try await session.store.closeSplitPane(id, from: context) }
    }
    func separateSplitPane(_ id: TabID) {
        enqueueOrganization { session, context in try await session.store.separateSplitPane(id, from: context) }
    }
    func unsplit(_ id: SplitGroupID) {
        enqueueOrganization { session, context in try await session.store.unsplit(id, from: context) }
    }
    func orientSplit(_ id: SplitGroupID, to orientation: BrowserSplitOrientation) {
        enqueueOrganization { session, context in try await session.store.setSplitOrientation(orientation, for: id, from: context) }
    }
    func swapSplitPanes(_ id: SplitGroupID, first: Int, second: Int) {
        enqueueOrganization { session, context in try await session.store.swapSplitPanes(id, first: first, second: second, from: context) }
    }
    func resizeSplit(_ id: SplitGroupID, ratios: [Double], validating expectedContext: BrowserContext? = nil,
                     expectedGroup: BrowserSplitGroup? = nil) {
        enqueue { session in
            guard let context = try await session.validatedContext(), expectedContext.map({ $0 == context }) ?? true else { return }
            do {
                let state = try await session.store.resizeSplit(id, ratios: ratios, expectedGroup: expectedGroup, from: context)
                guard !session.isClosed else { return }
                session.install(state)
            } catch BrowserSplitError.staleLayout {
                // A concurrent layout change cancels the pointer gesture without overwriting it.
            }
        }
    }

    /// Uses the existing transfer ownership contract; the model creates the new pane and group in
    /// one transaction. The transferred document is recorded before install, so no duplicate page
    /// is constructed or loaded. CONTRACT-R2 supplies asynchronous rollback of failed adoption.
    func acceptSplitTransfer(_ transfer: BrowserSurfaceTransfer<Surface>, bind: (Surface) -> Void = { _ in }) -> Task<TabOccurrenceID?, Never> {
        guard !isClosed, !hasPendingCommands, let activeContext,
              activeContext.profileID == transfer.profileID, snapshot?.selectedOccurrenceID != nil,
              transfer.tabID == nil,
              let reservation = transfer.complete(to: self, state: .reserved) else { return Task { nil } }
        let surface = transfer.surface
        bind(surface)
        pendingCommandCount += 1
        let previous = pending
        let adoption = Task<TabOccurrenceID?, Never> { [self] in
            defer {
                if occurrencesBySurface[ObjectIdentifier(surface)] == nil { transfer.didFail(at: self) }
                pendingCommandCount -= 1
            }
            await previous?.value
            guard !isClosed, BrowserSurfaceProvenance.isReserved(reservation, surface: surface, for: self) else { return nil }
            do {
                let url = surface.currentURL ?? transfer.url
                guard let context = try await validatedContext(), context == activeContext,
                      let state = try await store.adoptSplitSurface(url: url, from: context,
                          lifetime: surfaceCommandLifetime, providedLifetime: reservation.lifetime),
                      !isClosed, let occurrenceID = state.snapshot.selectedOccurrenceID,
                      BrowserSurfaceProvenance.bind(reservation, surface: surface, to: self) else { return nil }
                record(surface, as: occurrenceID, authority: state.occurrenceAuthorities[occurrenceID])
                transfer.didRecord(by: self)
                install(state)
                reconcileDestination(of: surface, recorded: url)
                return isClosed ? nil : occurrenceID
            } catch { if !isClosed { onError?(error) }; return nil }
        }
        pending = Task { _ = await adoption.value }
        return adoption
    }
}

private extension BrowserStore {
    func adoptSplitSurface(url: URL, from context: BrowserContext, lifetime: SurfaceCommandLifetime,
                           providedLifetime: SurfaceCommandLifetime) throws -> BrowserWindowState? {
        try lifetime.whileActive {
            try providedLifetime.whileActive { try splitWithNewTab(url: url, from: context) } ?? nil
        } ?? nil
    }
}

/// Reserves one source command before any member can settle. Failure releases that command
/// before CONTRACT-R2 enqueues return reconciliation on the same source queue.
@MainActor
private final class SplitReleaseDecision {
    private var remaining: Int
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    init(count: Int) { remaining = count }
    func acknowledge() {
        guard result == nil else { return }
        remaining -= 1
        if remaining == 0 { finish(true) }
    }
    func reject() { if result == nil { finish(false) } }
    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
    private func finish(_ result: Bool) { self.result = result; waiter?.resume(returning: result); waiter = nil }
}

public extension BrowserWindowSession {
    /// Releases a whole live group without publishing any partial source membership. Every
    /// placeholder remains until all members have recorded, or each failed member has returned.
    func releaseSurfaces(_ batch: [Surface], rebind: ((Surface) -> Void)? = nil) -> [BrowserSurfaceTransfer<Surface>]? {
        guard !isClosed, !batch.isEmpty, Set(batch.map(ObjectIdentifier.init)).count == batch.count else { return nil }
        var captured: [(Surface, TabOccurrenceID, BrowserOccurrenceAuthority, Int, TabID, URL)] = []
        for surface in batch {
            guard let id = occurrenceID(for: surface), let authority = authorities[id],
                  let tab = snapshot?.tabs.first(where: { $0.occurrenceID == id }),
                  BrowserSurfaceProvenance.ownedRecord(for: surface, owner: self) != nil else { return nil }
            captured.append((surface, id, authority, surfaceOrder.firstIndex(of: id) ?? 0, tab.id, surface.currentURL ?? tab.url))
        }
        guard let group = organization?.split(containing: captured[0].4)?.group,
              group.tabIDs == captured.map({ $0.4 }),
              captured.allSatisfy({ $0.2.profileID == captured[0].2.profileID }) else { return nil }
        let decision = SplitReleaseDecision(count: captured.count)
        let cohort = BrowserSplitTransferCohort(group: group, profileID: captured[0].2.profileID, spaceID: captured[0].2.spaceID,
            members: Dictionary(uniqueKeysWithValues: captured.map { ($0.4, ObjectIdentifier($0.0)) }))
        var transfers: [BrowserSurfaceTransfer<Surface>] = []
        for (surface, id, authority, _, tabID, url) in captured {
            let source = BrowserSurfaceTransfer<Surface>.Source(
                reclaim: { [weak self] transfer, holder in
                    decision.reject()
                    return self?.reclaim(transfer, as: id, from: holder) ?? false
                }, commit: { [weak self] in
                    if var transit = self?.transits[id] {
                        transit.isCommitted = true; transit.rebind = nil; self?.transits[id] = transit
                    }
                    decision.acknowledge()
                })
            guard let transfer = BrowserSurfaceTransfer(surface: surface, profileID: authority.profileID, url: url,
                tabID: tabID, from: self, source: source, rescue: rescueContainer, cohort: cohort) else {
                decision.reject()
                for created in transfers { _ = created.restoreUnpublished(to: self) }
                return nil
            }
            transfers.append(transfer)
        }
        for (_, id, authority, order, _, _) in captured {
            if let surface = surfaces.removeValue(forKey: id) { occurrencesBySurface.removeValue(forKey: ObjectIdentifier(surface)) }
            authorities.removeValue(forKey: id)
            surfaceOrder.removeAll { $0 == id }
            transits[id] = SurfaceTransit(authority: authority, orderIndex: order, rebind: rebind)
        }
        // No source callback can observe only the first member released. The reservation is
        // counted before receiver ACKs and before any membership observer can initiate quit.
        splitReleaseReservationCount += 1
        pendingCommandCount += 1
        let previous = pending
        pending = Task { [self] in
            defer { splitReleaseReservationCount -= 1; pendingCommandCount -= 1 }
            await previous?.value
            guard await decision.wait(), !isClosed, let windowID else { return }
            let leases = captured.map { transits[$0.1]?.authority ?? $0.2 }
            do {
                guard let state = try await store.releaseSplitSurfaceTabs(leases, in: windowID,
                    lifetime: surfaceCommandLifetime), !isClosed else { return }
                install(state)
            } catch { if !isClosed { onError?(error) } }
        }
        for (surface, _, _, _, _, _) in captured { onSurfaceMembershipChange?(surface, nil) }
        return transfers
    }

    /// Reserves all live members before binding any engine delegate, then records the complete
    /// model batch in one transaction. CONTRACT-R2 returns all members if admission fails.
    func acceptSplitGroupTransfers(_ transfers: [BrowserSurfaceTransfer<Surface>], group: BrowserSplitGroup,
                                  activating tabID: TabID?, bind: (Surface) -> Void = { _ in }) -> Task<[TabOccurrenceID]?, Never> {
        guard !isClosed, group.isValid, splitReleaseReservationCount == 0, let capturedContext = activeContext,
              let batchToken = transfers.first?.batchToken, transfers.count == group.tabIDs.count,
              transfers.map(\.tabID) == group.tabIDs.map(Optional.some),
              transfers.allSatisfy({ $0.profileID == capturedContext.profileID && $0.state == .pending && $0.batchToken == batchToken && !$0.originates(from: self) }) else {
            transfers.forEach { $0.cancel() }; return Task { nil }
        }
        var reservations: [BrowserSurfaceProvenance.Record] = []
        for transfer in transfers {
            guard let reservation = transfer.complete(to: self, state: .reserved, batchToken: batchToken) else {
                // Settle failures before their source can wait for another queue boundary.
                for accepted in transfers { accepted.didFail(at: self); accepted.cancel() }
                return Task { nil }
            }
            reservations.append(reservation)
        }
        let members = Set(group.tabIDs)
        let existing = occurrenceTabIDs.compactMap { occurrenceID, tabID in
            members.contains(tabID) ? (id: tabID, occurrenceID: occurrenceID) : nil
        }
        let expected = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.occurrenceID) })
        let capturedAuthorities = Dictionary(uniqueKeysWithValues: existing.compactMap { tab in
            modelOccurrenceAuthorities[tab.occurrenceID].map { (tab.occurrenceID, $0) }
        })
        let oldSurfaces = existing.compactMap { tab -> (TabOccurrenceID, Surface, BrowserSurfaceProvenance.Record)? in
            guard let surface = surfaces[tab.occurrenceID],
                  let provenance = BrowserSurfaceProvenance.ownedRecord(for: surface, owner: self) else { return nil }
            return (tab.occurrenceID, surface, provenance)
        }
        guard existing.allSatisfy({ tab in
            transits[tab.occurrenceID] == nil && (surfaces[tab.occurrenceID].map {
                BrowserSurfaceProvenance.ownedRecord(for: $0, owner: self) != nil
            } ?? true)
        }) else {
            transfers.forEach { $0.didFail(at: self) }; return Task { nil }
        }
        func replacementsAreCurrent(in context: BrowserContext) -> Bool {
            existing.allSatisfy { tab in
                let id = tab.occurrenceID
                guard let authority = capturedAuthorities[id], authority.storeGeneration == context.storeGeneration,
                      authority.windowID == context.windowID, authority.profileID == context.profileID,
                      modelOccurrenceAuthorities[id] == authority, transits[id] == nil else { return false }
                if let (_, surface, record) = oldSurfaces.first(where: { $0.0 == id }) {
                    return surfaces[id] === surface && authorities[id] == authority
                        && BrowserSurfaceProvenance.ownedRecord(for: surface, owner: self) === record
                }
                // A previously cold occurrence must remain cold until the atomic replacement.
                return surfaces[id] == nil && authorities[id] == nil
            }
        }
        pendingCommandCount += 1
        let previous = pending
        let adoption = Task<[TabOccurrenceID]?, Never> { [self] in
            var committed = false
            defer {
                if !committed { transfers.forEach { $0.didFail(at: self) } }
                pendingCommandCount -= 1
            }
            await previous?.value
            guard !isClosed, zip(transfers, reservations).allSatisfy({
                BrowserSurfaceProvenance.isReserved($0.1, surface: $0.0.surface, for: self)
            }) else { return nil }
            do {
                guard let context = try await validatedContext(), context.spaceID == capturedContext.spaceID,
                      context.profileID == capturedContext.profileID, replacementsAreCurrent(in: context) else { return nil }
                let urls = Dictionary(uniqueKeysWithValues: transfers.map { ($0.tabID!, $0.surface.currentURL ?? $0.url) })
                let lifetimes = reservations.map(\.lifetime) + oldSurfaces.map { $0.2.lifetime }
                guard let result = try await store.adoptSplitGroup(group, urls: urls, existing: expected, from: context,
                    activating: tabID, lifetime: surfaceCommandLifetime, provided: lifetimes), !isClosed else { return nil }
                // No callbacks or actor hops between the first definitive map and the final ACK.
                // A reentrant close after ACK owns every member and must never return one of them.
                guard zip(transfers, reservations).allSatisfy({ BrowserSurfaceProvenance.bind($0.1, surface: $0.0.surface, to: self) }) else { return nil }
                let replaced = Set(existing.map(\.occurrenceID))
                for id in replaced {
                    if let old = surfaces.removeValue(forKey: id) { occurrencesBySurface.removeValue(forKey: ObjectIdentifier(old)) }
                    authorities.removeValue(forKey: id)
                }
                surfaceOrder.removeAll { replaced.contains($0) }
                for transfer in transfers {
                    let id = result.occurrenceIDs[transfer.tabID!]!
                    record(transfer.surface, as: id, authority: result.state.occurrenceAuthorities[id], notifying: false)
                }
                for (_, old, _) in oldSurfaces { BrowserSurfaceProvenance.revoke(old, ownedBy: self) }
                committed = true
                for transfer in transfers { transfer.didRecord(by: self) }
                for transfer in transfers {
                    if !isClosed, let id = occurrenceID(for: transfer.surface), let windowID {
                        onSurfaceMembershipChange?(transfer.surface, .init(windowID: windowID, occurrenceID: id))
                    }
                }
                for (_, old, _) in oldSurfaces { disposeSurface(old) }
                guard !isClosed else { return nil }
                install(result.state)
                for transfer in transfers { reconcileDestination(of: transfer.surface, recorded: urls[transfer.tabID!]!) }
                return isClosed ? nil : group.tabIDs.compactMap { result.occurrenceIDs[$0] }
            } catch { return nil }
        }
        pending = Task { _ = await adoption.value }
        // The complete reservation table exists and the command is counted before the first bind.
        for transfer in transfers { bind(transfer.surface) }
        return adoption
    }
}

private extension BrowserStore {
    func releaseSplitSurfaceTabs(_ authorities: [BrowserOccurrenceAuthority], in windowID: WindowID,
                                 lifetime: SurfaceCommandLifetime) throws -> BrowserWindowState? {
        try lifetime.whileActive {
            let state = try captureWindowState(in: windowID)
            // A peer may already have removed a placeholder after the receiver committed. That
            // removal is final: release every surviving exact lease, never resurrect the missing one.
            let remaining = authorities.filter { state.occurrenceAuthorities[$0.occurrenceID] != nil }
            guard !remaining.isEmpty else { return state }
            return try releaseOwnedOccurrencesAndCaptureState(remaining, validating: state.context)
        }
    }
    func adoptSplitGroup(_ group: BrowserSplitGroup, urls: [TabID: URL], existing: [TabID: TabOccurrenceID],
                        from context: BrowserContext, activating tabID: TabID?, lifetime: SurfaceCommandLifetime,
                        provided: [SurfaceCommandLifetime]) throws -> (occurrenceIDs: [TabID: TabOccurrenceID], state: BrowserWindowState)? {
        func hold(_ index: Int) throws -> (occurrenceIDs: [TabID: TabOccurrenceID], state: BrowserWindowState)? {
            if index == provided.count {
                return try openTransferredSplitOccurrences(group, urlsByTabID: urls,
                    expectedExistingOccurrences: existing, from: context, activating: tabID)
            }
            return try provided[index].whileActive { try hold(index + 1) } ?? nil
        }
        return try lifetime.whileActive { try hold(0) } ?? nil
    }
}
