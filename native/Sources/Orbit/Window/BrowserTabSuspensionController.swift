import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation

/// One low-frequency sweep per window. Native discard keeps page state in the engine session;
/// no document content is persisted by the shell. Selection reloads the discarded renderer.
@MainActor
final class BrowserTabSuspensionController<Engine: BrowserEngine> {
    typealias Surface = Engine.Surface
    private weak var owner: BrowserWindowController<Engine>?
    private let store: BrowserStore
    private var backgroundSince: [ObjectIdentifier: TimeInterval] = [:]
    private var previouslyVisible: Set<ObjectIdentifier> = []
    private var suspended: [TabOccurrenceID: BrowserSuspensionState] = [:]
    private var restoring: Set<TabOccurrenceID> = []
    private var sleepingIcons: [TabOccurrenceID: (ProfileID, URL, NSImage)] = [:]
    private var timer: Task<Void, Never>?
    private var observer: BrowserHookRegistration?
    private var isSweeping = false
    private var presentationRevision: UInt64 = 0

    init(owner: BrowserWindowController<Engine>, store: BrowserStore) {
        self.owner = owner
        self.store = store
        observer = owner.engineEventHooks.observe { [weak self] surface, event in
            guard let self, let owner = self.owner,
                  let id = owner.session.occurrenceID(for: surface), let state = self.suspended[id] else { return }
            if event == .navigationStarted { self.restoring.insert(id) }
            // Native load-end can precede the loading-state update. Retain the sleeping
            // presentation until the resumed load settles; discard itself is not a wake.
            guard event == .navigationFinished || event == .stateChanged,
                  self.restoring.contains(id), !surface.navigationState.isLoading else { return }
            self.suspended[id] = nil
            self.restoring.remove(id)
            guard surface.navigationState.committedURL == state.url else { return }
            Task { [weak surface] in await surface?.restoreAfterSuspension(state) }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                await self.sweep()
            }
        }
    }

    deinit { timer?.cancel() }

    func close() {
        timer?.cancel()
        timer = nil
        observer?.cancel()
        suspended.removeAll()
        sleepingIcons.removeAll()
        restoring.removeAll()
    }

    func icon(for occurrence: TabOccurrenceID) -> NSImage? {
        guard let owner, let tab = owner.session.snapshot?.tabs.first(where: { $0.occurrenceID == occurrence }),
              let (profile, url, image) = sleepingIcons[occurrence],
              owner.session.activeProfileID == profile, tab.url == url else { return nil }
        return image
    }

    /// Keep a sleeping row stable while its same-URL native restoration is loading.
    /// Ordinary navigation still gets the normal loading presentation.
    func preservesSleepingPresentation(for occurrence: TabOccurrenceID) -> Bool {
        guard let owner, let state = suspended[occurrence],
              let surface = owner.session.surface(for: occurrence) else { return false }
        return surface.navigationState.url == state.url
    }

    func selectionDidChange(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let owner else { return }
        presentationRevision &+= 1
        let owned = Set(owner.session.ownedSurfaces.map(ObjectIdentifier.init))
        backgroundSince = backgroundSince.filter { owned.contains($0.key) }
        let visible = Set(owner.session.visibleOccurrenceIDs.compactMap { owner.session.surface(for: $0) }.map(ObjectIdentifier.init))
        for id in owned where backgroundSince[id] == nil || visible.contains(id) || previouslyVisible.contains(id) {
            backgroundSince[id] = now
        }
        previouslyVisible = visible
    }

    /// `now` is injectable for targeted tests; production uses the monotonic uptime. Safety is
    /// always obtained from the actual engine, then selection/document/ownership are rechecked.
    @discardableResult
    func sweep(now: TimeInterval = ProcessInfo.processInfo.systemUptime) async -> Int {
        guard !isSweeping, let owner, !owner.session.isClosed, !owner.isPreparingForTermination,
              let interval = (owner.settingsPreferences?.runtime.document.memorySaver ?? .oneHour).interval else { return 0 }
        isSweeping = true
        defer { isSweeping = false }
        var expectedRevision = presentationRevision
        let document = await store.sessionDocument()
        guard presentationRevision == expectedRevision else { return 0 }
        let tabs = Dictionary(uniqueKeysWithValues: document.tabs.map { ($0.occurrenceID, $0) })
        let logical = Set(document.organization.tabs.map(\.id))
        let retained = Set(tabs.keys)
        suspended = suspended.filter { retained.contains($0.key) }
        restoring.formIntersection(retained)
        sleepingIcons = sleepingIcons.filter { retained.contains($0.key) }
        var count = 0
        for surface in owner.session.ownedSurfaces {
            let identity = ObjectIdentifier(surface)
            guard let id = owner.session.occurrenceID(for: surface), let tab = tabs[id],
                  logical.contains(tab.id),
                  !owner.session.visibleOccurrenceIDs.contains(id),
                  let since = backgroundSince[identity], now - since >= interval else { continue }
            let icon = await surface.navigationState.faviconImage?.nativeImage()
            guard let state = await surface.captureStateForSuspension(), !surface.isDisposed, surface.allowsSuspension,
                  state.documentGeneration == surface.documentGeneration,
                  state.url == surface.navigationState.committedURL,
                  owner.acceptsCommands, !owner.isPreparingForTermination, presentationRevision == expectedRevision,
                  (owner.settingsPreferences?.runtime.document.memorySaver ?? .oneHour).interval == interval,
                  backgroundSince[identity] == since,
                  owner.session.surface(for: id) === surface else { continue }
            // Store the scroll state before retirement invokes onChange synchronously.
            suspended[id] = state
            if let icon { sleepingIcons[id] = (surface.profileID, state.url, icon) }
            if owner.session.suspendSurface(surface) { count += 1 }
            else { suspended[id] = nil; sleepingIcons[id] = nil }
            expectedRevision = presentationRevision
        }
        return count
    }
}
