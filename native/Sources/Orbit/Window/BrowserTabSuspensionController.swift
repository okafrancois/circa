import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation

/// One low-frequency sweep per window. Native discard keeps page state in the engine session;
/// no page content is written to disk by the shell. Selection reloads the discarded renderer.
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
    private(set) var covers = BrowserSuspensionCoverStore()
    private struct ActiveCover {
        let view: BrowserSuspensionCoverView
        let generation: UInt64
        let url: URL
        let timeout: Task<Void, Never>
    }
    private var activeCovers: [TabOccurrenceID: ActiveCover] = [:]
    var activeCoverIDs: Set<TabOccurrenceID> { Set(activeCovers.keys) }
    private var inputMonitor: Any?
    private var isSweeping = false
    private var presentationRevision: UInt64 = 0

    init(owner: BrowserWindowController<Engine>, store: BrowserStore) {
        self.owner = owner
        self.store = store
        observer = owner.engineEventHooks.observe { [weak self] surface, event in
            guard let self else { return }
            self.updateCover(for: surface)
            guard let owner = self.owner,
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
        dismissCover()
        covers.retain([])
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

    /// Called before reparenting makes the native host visible (and resumes its renderer).
    func prepareCover(for surface: Surface) {
        guard let owner, let id = owner.session.occurrenceID(for: surface) else { return }
        if activeCovers[id] != nil { return }
        guard let cover = covers.value(for: id) else { return }
        guard surface.navigationState.committedURL == cover.url,
              surface.documentGeneration == cover.generation,
              surface.hostView.bounds.size == cover.size,
              owner.window?.backingScaleFactor == cover.scale,
              let image = cover.image() else { covers.remove(id); return }
        let view = BrowserSuspensionCoverView(image: image, size: cover.size, scale: cover.scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.hostView.addSubview(view, positioned: .above, relativeTo: nil)
        CATransaction.commit()
        view.resized = { [weak self] in self?.dismissCover(id) }
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            self?.dismissCover(id)
        }
        activeCovers[id] = ActiveCover(view: view, generation: cover.generation, url: cover.url, timeout: timeout)
        if inputMonitor == nil {
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged,
                .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp,
                .otherMouseUp, .leftMouseDragged,
                .rightMouseDragged, .otherMouseDragged, .scrollWheel, .magnify, .rotate, .swipe,
                .pressure, .tabletPoint, .tabletProximity, .gesture, .beginGesture, .endGesture]) { [weak self] event in
                MainActor.assumeIsolated {
                    if event.window === self?.owner?.window { self?.dismissCover() }
                }
                return event
            }
        }
    }

    func dismissCover(_ id: TabOccurrenceID? = nil) {
        for key in id.map({ [$0] }) ?? Array(activeCovers.keys) {
            guard let active = activeCovers.removeValue(forKey: key) else { continue }
            active.timeout.cancel()
            active.view.resized = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // AppKit can crossfade a reused native content layer on reattachment.
            // Retiring the cover must reveal the current pixels without that transition.
            for sibling in active.view.superview?.subviews ?? [] where sibling !== active.view {
                sibling.layer?.removeAnimation(forKey: kCATransition)
            }
            active.view.removeFromSuperview()
            CATransaction.commit()
            covers.remove(key)
        }
        if activeCovers.isEmpty, let inputMonitor {
            NSEvent.removeMonitor(inputMonitor)
            self.inputMonitor = nil
        }
    }

    private func updateCover(for surface: Surface) {
        guard let owner, let id = owner.session.occurrenceID(for: surface) else { return }
        if let active = activeCovers[id] {
            if surface.navigationState.url != active.url || surface.isDisposed {
                dismissCover(id)
            } else if let paint = surface.suspensionPaintGeneration,
                      paint != active.generation, paint == surface.documentGeneration {
                dismissCover(id)
            }
        } else if let cover = covers.value(for: id),
                  surface.navigationState.url != cover.url || surface.documentGeneration != cover.generation {
            covers.remove(id)
        }
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
        let occurrences = Set(owner.session.ownedSurfaces.compactMap { owner.session.occurrenceID(for: $0) })
        covers.retain(occurrences)
        for id in activeCovers.keys where !owner.session.visibleOccurrenceIDs.contains(id) { dismissCover(id) }
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
            guard let candidate = await surface.captureStateForSuspension() else { continue }
            var cover: BrowserSuspensionCover?
            if surface.supportsSuspensionPaint {
                let size = surface.hostView.bounds.size
                let scale = owner.window?.backingScaleFactor ?? 1
                guard size.width > 0, size.height > 0, await surface.prepareSuspensionPaint(),
                      let snapshot = try? await surface.captureSnapshot(.init(width: size.width * scale,
                          documentGeneration: candidate.documentGeneration)) else { continue }
                let limit = covers.perTabLimit
                cover = await Task.detached(priority: .utility) {
                    BrowserSuspensionCover.encode(snapshot, size: size, scale: scale, url: candidate.url, maximumBytes: limit)
                }.value
                guard cover != nil, surface.hostView.bounds.size == size else { continue }
            }
            // Capturing/encoding yields: re-check form/media state and scroll before discard.
            guard let state = await surface.captureStateForSuspension(), !surface.isDisposed, surface.allowsSuspension,
                  candidate.documentGeneration == state.documentGeneration,
                  candidate.scrollX == state.scrollX, candidate.scrollY == state.scrollY,
                  state.documentGeneration == surface.documentGeneration,
                  state.url == surface.navigationState.committedURL,
                  owner.acceptsCommands, !owner.isPreparingForTermination, presentationRevision == expectedRevision,
                  (owner.settingsPreferences?.runtime.document.memorySaver ?? .oneHour).interval == interval,
                  backgroundSince[identity] == since,
                  owner.session.surface(for: id) === surface else { continue }
            // Store the scroll state before retirement invokes onChange synchronously.
            suspended[id] = state
            if let cover { covers.insert(cover, for: id) }
            if let icon { sleepingIcons[id] = (surface.profileID, state.url, icon) }
            if owner.session.suspendSurface(surface) { count += 1 }
            else { suspended[id] = nil; sleepingIcons[id] = nil; covers.remove(id) }
            expectedRevision = presentationRevision
        }
        return count
    }
}
