import AppKit
import BrowserCore
import BrowserEngine
import Foundation

/// Owns lifecycle subscriptions for this window, including visited tabs in inactive Spaces.
@MainActor
final class BrowserWindowResources<Engine: BrowserEngine> {
    private weak var owner: BrowserWindowController<Engine>?
    let coordinator: BrowserResourceCoordinator
    private var subscriptions: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var observer: BrowserHookRegistration?

    init(owner: BrowserWindowController<Engine>, coordinator: BrowserResourceCoordinator = .shared) {
        self.owner = owner; self.coordinator = coordinator
        observer = owner.engineEventHooks.observe { [weak self] surface, _ in
            guard let self else { return }
            self.update(surface)
            if !surface.isSuspended && !surface.navigationState.isLoading {
                self.coordinator.settled(ObjectIdentifier(surface))
            }
        }
    }
    deinit { for subscription in subscriptions.values { subscription.cancel() } }
    func close() {
        observer?.cancel(); observer = nil
        for subscription in subscriptions.values { subscription.cancel() }
        subscriptions.removeAll()
        if let owner { coordinator.retain(window: owner.id, identities: []) }
    }
    func reconcile(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let owner else { return }
        guard coordinator.enabled else {
            for subscription in subscriptions.values { subscription.cancel() }
            subscriptions.removeAll()
            return
        }
        let surfaces = owner.session.ownedSurfaces
        let identities = Set(surfaces.map(ObjectIdentifier.init))
        for id in subscriptions.keys where !identities.contains(id) { subscriptions.removeValue(forKey: id)?.cancel() }
        coordinator.retain(window: owner.id, identities: identities)
        for surface in surfaces {
            update(surface, now: now)
            let identity = ObjectIdentifier(surface)
            if subscriptions[identity] == nil, let api = surface.pagePerformance {
                let stream = api.changes()
                subscriptions[identity] = Task { [weak self, weak surface] in
                    for await change in stream {
                        guard !Task.isCancelled, let self, let owner = self.owner, let surface,
                              owner.session.occurrenceID(for: surface) != nil else { return }
                        self.coordinator.change(change, identity: identity)
                        // Buffered notifications can arrive after activation; retain counts but
                        // reconcile current native state rather than putting a restored tab to sleep.
                        if change.event != .closed { self.update(surface); self.coordinator.publishCounters() }
                        if !surface.isSuspended && !surface.navigationState.isLoading { self.coordinator.settled(identity) }
                    }
                }
            }
        }
        coordinator.publishCounters()
    }
    private func update(_ surface: Engine.Surface, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard coordinator.enabled, let owner, let occurrence = owner.session.occurrenceID(for: surface) else { return }
        coordinator.update(identity: ObjectIdentifier(surface), window: owner.id, occurrence: occurrence,
            profile: surface.profileID, lifecycle: surface.pagePerformance?.lifecycle(),
            suspended: owner.tabSuspension?.isPolicySuspended(occurrence) == true,
            visible: owner.session.visibleOccurrenceIDs.contains(occurrence)
                && owner.window?.isVisible == true && owner.window?.occlusionState.contains(.visible) == true,
            selected: owner.session.visibleOccurrenceIDs.contains(occurrence), engineAllowsSuspension: surface.allowsSuspension, now: now)
    }
    func willActivate(_ surface: Engine.Surface) {
        if surface.isSuspended { coordinator.beginWake(ObjectIdentifier(surface)) }
    }
    /// Invoked by the existing 30-second suspension sweep, even when Memory Saver is disabled.
    func sweep() {
        guard coordinator.enabled else { return }
        let start = ProcessInfo.processInfo.systemUptime
        reconcile()
        coordinator.sampleMemory()
        BrowserPerformance.count(.resourceSweeps)
        BrowserPerformance.count(.resourceSweepNanoseconds, amount: Int((ProcessInfo.processInfo.systemUptime - start) * 1e9))
    }
}
