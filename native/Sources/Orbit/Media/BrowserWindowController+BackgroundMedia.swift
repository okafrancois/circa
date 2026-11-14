import BrowserCore
import BrowserEngine

/// Invisible plumbing for media that keeps playing in a tab the user left. A future sidebar
/// view binds to `backgroundMediaSessions` and `onBackgroundMediaChange`; no UI is built here.
extension BrowserWindowController {
    typealias BackgroundMediaEntry = BrowserBackgroundMediaSessions<Engine.Surface>.Entry

    func installBackgroundMedia() {
        backgroundMedia.onChange = { [weak self] in self?.onBackgroundMediaChange?() }
        let previousMediaHook = siteControls.onMediaStateChange
        siteControls.onMediaStateChange = { [weak self] surface, state in
            previousMediaHook?(surface, state)
            guard let self, let occurrenceID = session.occurrenceID(for: surface) else { return }
            backgroundMedia.updateAudio(state, for: occurrenceID)
        }
        // A surface that was not ready when first observed is observed again once it reports.
        backgroundMediaObserver = engineEventHooks.observe { [weak self] _, event in
            guard event == .stateChanged || event == .navigationFinished else { return }
            self?.reconcileBackgroundMedia()
        }
    }

    func reconcileBackgroundMedia() {
        guard backgroundMediaObserver != nil else { return }
        let members = session.ownedSurfaces.compactMap { surface -> BrowserBackgroundMediaSessions<Engine.Surface>.Member? in
            guard let occurrenceID = session.occurrenceID(for: surface),
                  let tabID = session.tabID(for: occurrenceID),
                  let spaceID = session.spaceID(for: occurrenceID) else { return nil }
            return .init(source: surface, occurrenceID: occurrenceID, tabID: tabID, spaceID: spaceID)
        }
        backgroundMedia.reconcile(members)
    }

    /// Media sessions of the active Space whose tab is not shown in a visible pane.
    var backgroundMediaSessions: [BackgroundMediaEntry] {
        guard let spaceID = session.snapshot?.activeSpaceID else { return [] }
        return backgroundMedia.backgroundSessions(in: spaceID, excluding: session.visibleOccurrenceIDs)
    }

    /// Play, pause, next or previous on a tab of this window without selecting it.
    @discardableResult
    func performBackgroundMediaAction(_ action: BrowserMediaAction, on occurrenceID: TabOccurrenceID)
        -> BrowserBackgroundMediaSessions<Engine.Surface>.ActionResult {
        backgroundMedia.perform(action, on: occurrenceID)
    }
}
