import AppKit
import BrowserCore
import BrowserEngine

/// Window-local player state the media model does not hold: who paused a session, which cards
/// the user closed, and the last known title and icon of each tab (so a card that followed the
/// user into another Space keeps them).
@MainActor
final class SidebarMediaPlayerState {
    enum Dismissal: Equatable {
        /// Closed while the media still played; waits for the pause the close requested.
        case awaitingPause
        /// Stays hidden until the page plays again.
        case paused
    }

    /// Pauses requested from the card. A request survives the playing state still reported
    /// right after the click, and ends once the page plays again after the pause landed.
    private var pauseRequests: [TabOccurrenceID: Bool] = [:]
    var pausedFromPlayer: Set<TabOccurrenceID> { Set(pauseRequests.keys) }
    private(set) var dismissed: [TabOccurrenceID: Dismissal] = [:]
    var titles: [TabOccurrenceID: String] = [:]
    var favicons: [TabOccurrenceID: NSImage] = [:]
    /// Picture-in-Picture observation per tab, keyed by the observed surface.
    var lifecycleObservers: [TabOccurrenceID: (surface: ObjectIdentifier, task: Task<Void, Never>)] = [:]

    var pipTasks: [TabOccurrenceID: Task<Void, Never>] = [:]
    var pipQueryTimes: [TabOccurrenceID: Date] = [:]

    /// Call before performing a play or pause from the card.
    func willPerform(_ action: BrowserMediaAction, on id: TabOccurrenceID) {
        switch action {
        case .pause: pauseRequests[id] = false
        case .play: pauseRequests.removeValue(forKey: id)
        default: break
        }
    }

    /// The engine refused the action: the page keeps ownership of its state.
    func didFail(_ action: BrowserMediaAction, on id: TabOccurrenceID) {
        if action == .pause { pauseRequests.removeValue(forKey: id) }
    }

    /// The close button removes the card; the tab stays.
    func dismiss(_ id: TabOccurrenceID) {
        dismissed[id] = .awaitingPause
    }

    /// Sessions the stack shows, oldest first: not in a visible pane, not closed by the user,
    /// not in Picture in Picture. Settles the bookkeeping against the latest playback states.
    func shown(_ sessions: [(id: TabOccurrenceID, session: BrowserTabMediaSession)],
               visible: Set<TabOccurrenceID>,
               pictureInPicture: (TabOccurrenceID) -> Bool) -> [TabOccurrenceID] {
        let ids = Set(sessions.map(\.id))
        pauseRequests = pauseRequests.filter { ids.contains($0.key) }
        dismissed = dismissed.filter { ids.contains($0.key) }
        titles = titles.filter { ids.contains($0.key) }
        favicons = favicons.filter { ids.contains($0.key) }
        for (id, session) in sessions {
            if session.playback == .playing {
                if pauseRequests[id] == true { pauseRequests.removeValue(forKey: id) }
                if dismissed[id] == .paused { dismissed.removeValue(forKey: id) }
            } else {
                if pauseRequests[id] == false { pauseRequests[id] = true }
                if dismissed[id] == .awaitingPause { dismissed[id] = .paused }
            }
        }
        return sessions.map(\.id).filter { id in
            !visible.contains(id) && dismissed[id] == nil && !pictureInPicture(id)
        }
    }

    func cancelObservers() {
        for observer in lifecycleObservers.values { observer.task.cancel() }
        lifecycleObservers.removeAll()
        for task in pipTasks.values { task.cancel() }
        pipTasks.removeAll()
        pipQueryTimes.removeAll()
    }

    /// Playing: pause glyph. Paused from the card: play glyph. Paused by the page (or ended):
    /// the pause glyph stays and every transport control is greyed out.
    static func item(id: TabOccurrenceID, session: BrowserTabMediaSession, title: String, favicon: NSImage?,
                     pausedFromPlayer: Bool) -> SidebarMediaPlayerItem {
        let actions = session.actions
        switch session.playback {
        case .playing:
            return .init(id: id, title: title, favicon: favicon, toggle: .pause, canToggle: actions.contains(.pause),
                         canGoBack: actions.contains(.previous), canGoForward: actions.contains(.next))
        case .paused where pausedFromPlayer:
            return .init(id: id, title: title, favicon: favicon, toggle: .play, canToggle: actions.contains(.play),
                         canGoBack: actions.contains(.previous), canGoForward: actions.contains(.next))
        case .paused:
            return .init(id: id, title: title, favicon: favicon, toggle: .pause, canToggle: false,
                         canGoBack: false, canGoForward: false)
        }
    }
}
