import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Moving live tabs between windows. The document keeps its process, history, opener and form
/// state: ownership and the engine delegate move together through `BrowserSurfaceTransfer`.
extension BrowserWindowController {
    /// Moves a live tab of this window into `destination`, of the same engine and profile, as a
    /// tab of its active Space. Nil, leaving the tab untouched, when the move is impossible. The
    /// move is reversible until the destination recorded the tab: should it fail (refusal, the
    /// destination closing or changing profile meanwhile), the live document returns to the same
    /// tab here, rebound, or to the environment's rescue holder if this window is gone too.
    @discardableResult
    func moveSurface(_ surface: Surface, to destination: BrowserWindowController,
                     activate: Bool = true, replacingExisting: Bool = false) -> Task<TabOccurrenceID?, Never>? {
        guard destination !== self, destination.engine === engine,
              engine.capabilities.contains(.liveSurfaceTransfer),
              acceptsCommands, destination.acceptsCommands, owns(surface),
              destination.session.activeProfileID == surface.profileID,
              let destinationWindowID = destination.prepareEngineMove([surface]) else {
            return nil
        }
        guard let transfer = session.releaseSurface(surface, rebind: { [weak self] in self?.bindSurface($0) }) else {
            engine.shellDidFinishMovingSurfaces([surface], toWindow: destinationWindowID, committed: false)
            return nil
        }
        surfaceDidLeave(surface)
        let adoption = destination.acceptSurface(transfer, activate: activate, replacingExisting: replacingExisting)
        // Refused in this same turn: the live document goes straight back to its tab here.
        guard transfer.state != .pending else {
            transfer.cancel()
            engine.shellDidFinishMovingSurfaces([surface], toWindow: destinationWindowID, committed: false)
            return nil
        }
        settleEngineMove([surface], toWindow: destinationWindowID, after: adoption) { $0 != nil }
        return adoption
    }

    /// Tells the engine how a move announced to it settled, once the destination recorded (or gave
    /// back) the surfaces; the engine keeps its source state until then (CHROMIUM-APP-R3).
    func settleEngineMove<Result: Sendable>(_ surfaces: [Surface], toWindow windowID: WindowID,
                                            after adoption: Task<Result, Never>, committed: @escaping (Result) -> Bool) {
        let engine = engine
        Task { @MainActor in
            let result = await adoption.value
            engine.shellDidFinishMovingSurfaces(surfaces, toWindow: windowID, committed: committed(result))
        }
    }

    /// Accepts a surface released by another owner (window, Peek, Little Orbit, rescue holder) as a
    /// tab of the active Space; this window becomes its delegate in the same turn. Events that
    /// arrive before the tab is recorded are reconciled when recording resolves. Refused (the
    /// transfer stays pending and returns to its source) while the window prepares to quit.
    func acceptSurface(_ transfer: BrowserSurfaceTransfer<Surface>, activate: Bool,
                       replacingExisting: Bool = false, didAdopt: (() -> Void)? = nil) -> Task<TabOccurrenceID?, Never> {
        guard acceptsCommands else { return Task { nil } }
        let surface = transfer.surface
        let adoption = session.acceptTransfer(transfer, activate: activate, replacingExisting: replacingExisting,
                                             bind: { bindSurface($0) }, didAdopt: didAdopt)
        guard transfer.state != .pending else { return adoption }
        reconcileTransferredSurface(surface, after: adoption)
        return adoption
    }

    /// Every receiver path keeps the provisional event holder alive until the original transfer
    /// has recorded or returned. Split and ordinary tabs share the same reconciliation policy.
    func reconcileTransferredSurface(_ surface: Surface, after adoption: Task<TabOccurrenceID?, Never>) {
        // The receiver owns the provisional events even after its window closes. Keep it alive
        // until adoption settles and the events follow the returned or recorded document. This
        // task is not stored by the controller, so the retention ends after reconciliation.
        Task { [self, weak surface] in
            let occurrence = await adoption.value
            guard let surface else { return }
            reconcileProvisionalEvents(of: surface, recordedAs: occurrence)
        }
    }

    /// The engine moves its native tabs into this window first, all or none (CHROMIUM-APP-R2,
    /// `shellWillMoveSurfaces`): this window's ID, or nil when refused with nothing changed. The move
    /// settles with `shellDidFinishMovingSurfaces` (R3); until then the engine keeps its source.
    func prepareEngineMove(_ surfaces: [Surface]) -> WindowID? {
        guard let windowID = session.snapshot?.id else { return nil }
        announceEngineWindow(windowID)
        return engine.shellWillMoveSurfaces(surfaces, toWindow: windowID) ? windowID : nil
    }

    /// Publishes the live tabs of this window in sidebar order (Favorites, Pinned, Today, then
    /// live tabs of other Spaces) when it changed, for engines that mirror it (review M2).
    func publishTabOrder() {
        guard let windowID = session.snapshot?.id else { return }
        var ordered: [Surface] = []
        var seen = Set<ObjectIdentifier>()
        func add(_ occurrence: TabOccurrenceID?) {
            guard let occurrence, let surface = session.surface(for: occurrence),
                  seen.insert(ObjectIdentifier(surface)).inserted else { return }
            ordered.append(surface)
        }
        func visit(_ items: [BrowserOrganizationItem]) {
            for item in items {
                switch item {
                case .tab(let tab): add(tab.occurrenceID)
                case .folder(let folder): visit(folder.children)
                case .split(let split): split.tabs.forEach { add($0.occurrenceID) }
                }
            }
        }
        if let organization = session.organization, organization.windowID == windowID {
            visit(organization.favorites)
            visit(organization.pinned)
            visit(organization.today)
        }
        for tab in session.snapshot?.tabs ?? [] { add(tab.occurrenceID) }
        let identity = ordered.map(ObjectIdentifier.init)
        guard identity != publishedTabOrder.surfaces || windowID != publishedTabOrder.windowID else { return }
        publishedTabOrder = (windowID, identity)
        engine.shellWindowTabOrderDidChange(windowID, surfaces: ordered)
    }

    /// Drops window-local state of a surface that left alive.
    func surfaceDidLeave(_ surface: Surface) {
        let key = ObjectIdentifier(surface)
        nativeCreations.removeValue(forKey: key)
        pendingNativeClosures.remove(key)
        if nativePromotion?.surface === surface {
            nativePromotion?.intent.revoke()
            nativePromotion = nil
        }
        findSession.retire(surface)
    }
}
