import BrowserCore
import Foundation

/// Controls a document's media session from outside the page (sidebar, menus, commands),
/// whether or not the document is visible. Engines without a native media session keep the
/// `BrowserEngineSurface` defaults: no state, a finished stream and `unsupportedOperation`.
@MainActor
public protocol BrowserMediaSessionControlling: AnyObject {
    var isDisposed: Bool { get }
    /// Current native snapshot, nil when unsupported, closed or before the document exists.
    func mediaSessionState() -> BrowserMediaSessionState?
    /// Starts with the current snapshot when one exists. Finishes when the document closes,
    /// when the engine cannot observe it (yet), or when the engine lacks media sessions.
    func mediaSessionChanges() -> AsyncStream<BrowserMediaSessionState>
    /// Throws `unsupportedOperation` without a native media session. False means the session
    /// refused the action (no session, or the action is not currently offered).
    @discardableResult func performMediaSessionAction(_ action: BrowserMediaAction, seconds: Double) throws -> Bool
    /// The tab's mute flag as the engine holds it now; nil when unknown.
    func tabAudioMuted() -> Bool?
    /// Identifies the current document; it changes on navigation. Nil when unknown.
    var mediaDocumentIdentity: UInt64? { get }
    /// True when the document's media element can be driven directly, for media the engine
    /// keeps out of its session (a muted tab's players).
    var supportsMediaElementControl: Bool { get }
    /// Plays, pauses or seeks the document's media element directly. Nil when unsupported, when
    /// no element answers, or when the document changed.
    func performMediaElementAction(_ action: BrowserMediaAction, seconds: Double) async -> BrowserMediaElementState?
}

public extension BrowserMediaSessionControlling {
    func tabAudioMuted() -> Bool? { nil }
    var mediaDocumentIdentity: UInt64? { nil }
    var supportsMediaElementControl: Bool { false }
    func performMediaElementAction(_ action: BrowserMediaAction, seconds: Double) async -> BrowserMediaElementState? { nil }
}

/// A media element's state right after a direct action. Non-finite values are nil.
public struct BrowserMediaElementState: Sendable, Equatable {
    public var paused: Bool
    public var position: Double?
    public var duration: Double?
    public var playbackRate: Double?
    public init(paused: Bool, position: Double? = nil, duration: Double? = nil, playbackRate: Double? = nil) {
        self.paused = paused; self.position = position; self.duration = duration; self.playbackRate = playbackRate
    }
}

/// Stable native MediaSessionAction and session-state values (Chromium mojom).
enum BrowserNativeMediaSession {
    static let play = 0, pause = 1, previousTrack = 2, nextTrack = 3, seekTo = 8
    static let inactiveSession = 3
    static let playingPlayback = 1
}

/// One tab's controllable media, derived from the native session and the tab's audio state.
/// Absent (nil) when the tab has no controllable media session.
public struct BrowserTabMediaSession: Sendable, Equatable {
    public enum Playback: Sendable, Equatable { case playing, paused }

    public var playback: Playback
    public var title: String
    public var artist: String
    public var album: String
    /// MediaSession artwork in page order. URLs only; the shell fetches pixels itself.
    public var artwork: [URL]
    /// Actions the page currently accepts through `performMediaSessionAction`.
    public var actions: Set<BrowserMediaAction>
    public var position: Double?
    public var duration: Double?
    public var playbackRate: Double?
    /// Nil when the engine cannot observe the value, never false by default.
    public var isAudible: Bool?
    public var isAudioMuted: Bool?

    public init?(_ native: BrowserMediaSessionState, audio: BrowserMediaState? = nil) {
        var actions = Set<BrowserMediaAction>()
        for value in native.actions {
            switch value {
            case BrowserNativeMediaSession.play: actions.insert(.play)
            case BrowserNativeMediaSession.pause: actions.insert(.pause)
            case BrowserNativeMediaSession.previousTrack: actions.insert(.previous)
            case BrowserNativeMediaSession.nextTrack: actions.insert(.next)
            case BrowserNativeMediaSession.seekTo: actions.insert(.seek)
            default: break
            }
        }
        guard native.sessionState != BrowserNativeMediaSession.inactiveSession,
              !actions.isDisjoint(with: [.play, .pause]) else { return nil }
        playback = native.playbackState == BrowserNativeMediaSession.playingPlayback ? .playing : .paused
        title = native.title
        artist = native.artist
        album = native.album
        artwork = native.artwork
        self.actions = actions
        position = native.position
        duration = native.duration
        playbackRate = native.playbackRate
        isAudible = audio?.isAudible ?? audio?.isAudioPlaying
        isAudioMuted = audio?.isAudioMuted
    }

    /// The first artwork a shell image loader may fetch (http, https or data).
    public var artworkURL: URL? {
        artwork.first { ["http", "https", "data"].contains($0.scheme?.lowercased() ?? "") }
    }

    /// The toggle a single play/pause control performs: pause while playing, play otherwise.
    public var toggleAction: BrowserMediaAction? {
        let action: BrowserMediaAction = playback == .playing ? .pause : .play
        return actions.contains(action) ? action : nil
    }
}

/// Window-scoped list of tabs with controllable media, for views that show media outside the
/// playing tab. The owner feeds membership (`reconcile`) and audio state; the list observes each
/// source's native session and never polls. Order is the order in which sessions appeared.
@MainActor
public final class BrowserBackgroundMediaSessions<Source: BrowserMediaSessionControlling> {
    public struct Member {
        public let source: Source
        public let occurrenceID: TabOccurrenceID
        public let tabID: TabID
        public let spaceID: SpaceID
        public init(source: Source, occurrenceID: TabOccurrenceID, tabID: TabID, spaceID: SpaceID) {
            self.source = source; self.occurrenceID = occurrenceID; self.tabID = tabID; self.spaceID = spaceID
        }
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: TabOccurrenceID { occurrenceID }
        public let occurrenceID: TabOccurrenceID
        public let tabID: TabID
        public let spaceID: SpaceID
        public let session: BrowserTabMediaSession
    }

    public enum ActionResult: Sendable, Equatable {
        case performed
        /// No session for this tab, or the page does not offer the action now.
        case unavailable
        /// The engine has no native media session control.
        case unsupported
    }

    private struct Tracked {
        weak var source: Source?
        var sourceID: ObjectIdentifier
        var tabID: TabID
        var spaceID: SpaceID
        var native: BrowserMediaSessionState?
        var audio: BrowserMediaState?
        var observation: Task<Void, Never>?
        var observing = false
        var generation: UInt64
        var order: UInt64?
        /// The last controllable session of the current document, kept while the tab is muted:
        /// the engine leaves a muted tab's players out of its media session though they play on.
        var lastSession: BrowserTabMediaSession?
        var lastDocument: UInt64?
        /// True while `lastSession` stands in for a session the engine dropped.
        var kept = false
        /// The element state after the last direct action on a kept session.
        var element: BrowserMediaElementState?
        var elementRevision: UInt64 = 0
    }

    private var tracked: [TabOccurrenceID: Tracked] = [:]
    private var nextGeneration: UInt64 = 0
    private var nextOrder: UInt64 = 0
    private var published: [Entry] = []
    /// Called after the derived entries change, on the main actor.
    public var onChange: (() -> Void)?

    public init() {}

    /// Every tab of the window with a controllable session, in appearance order.
    public var sessions: [Entry] { published }

    public func session(for occurrenceID: TabOccurrenceID) -> BrowserTabMediaSession? {
        published.first { $0.occurrenceID == occurrenceID }?.session
    }

    /// Sessions of `spaceID` that are not shown in a visible pane.
    public func backgroundSessions(in spaceID: SpaceID, excluding visible: Set<TabOccurrenceID>) -> [Entry] {
        published.filter { $0.spaceID == spaceID && !visible.contains($0.occurrenceID) }
    }

    /// Replaces the membership. New or replaced sources start observing; gone ones stop.
    /// A source whose stream finished (not ready yet) is observed again here.
    public func reconcile(_ members: [Member]) {
        var seen = Set<TabOccurrenceID>()
        for member in members where !member.source.isDisposed {
            seen.insert(member.occurrenceID)
            let sourceID = ObjectIdentifier(member.source)
            if var item = tracked[member.occurrenceID], item.sourceID == sourceID, item.source != nil {
                item.tabID = member.tabID
                item.spaceID = member.spaceID
                tracked[member.occurrenceID] = item
                if !item.observing { observe(member.occurrenceID, member.source) }
                continue
            }
            tracked[member.occurrenceID]?.observation?.cancel()
            nextGeneration &+= 1
            tracked[member.occurrenceID] = Tracked(source: member.source, sourceID: sourceID, tabID: member.tabID,
                spaceID: member.spaceID, native: nil, audio: tracked[member.occurrenceID]?.audio, generation: nextGeneration)
            observe(member.occurrenceID, member.source)
        }
        for id in Array(tracked.keys) where !seen.contains(id) {
            tracked.removeValue(forKey: id)?.observation?.cancel()
        }
        publish()
    }

    /// Engine-reported audibility and mute for one tab (from the window's media refresh).
    public func updateAudio(_ audio: BrowserMediaState, for occurrenceID: TabOccurrenceID) {
        guard let item = tracked[occurrenceID], item.audio != audio else { return }
        // A play or pause the engine reports after a direct action (the page's own, or one
        // from elsewhere) is newer than that action's answer.
        if item.element != nil, item.audio?.playback != audio.playback, audio.playback == .playing || audio.playback == .paused {
            tracked[occurrenceID]?.element?.paused = audio.playback == .paused
        }
        tracked[occurrenceID]?.audio = audio
        publish()
    }

    /// Performs a media action on a tab of this window, visible or not. A kept (muted) session
    /// is driven through its media element: the card shows the requested state at once and
    /// settles on the element's answer, or returns to the previous state when none comes.
    @discardableResult
    public func perform(_ action: BrowserMediaAction, on occurrenceID: TabOccurrenceID, seconds: Double = 0) -> ActionResult {
        guard let item = tracked[occurrenceID], let source = item.source, !source.isDisposed else { return .unavailable }
        if item.kept {
            guard let session = session(for: occurrenceID), session.actions.contains(action),
                  action != .seek || seconds.isFinite else { return .unavailable }
            let previous = item.element
            var requested = previous ?? BrowserMediaElementState(paused: session.playback == .paused,
                position: session.position, duration: session.duration, playbackRate: session.playbackRate)
            switch action {
            case .play: requested.paused = false
            case .pause: requested.paused = true
            case .seek: requested.position = seconds
            default: return .unavailable
            }
            let revision = item.elementRevision &+ 1
            tracked[occurrenceID]?.elementRevision = revision
            tracked[occurrenceID]?.element = requested
            publish()
            Task { [weak self] in
                let answer = await source.performMediaElementAction(action, seconds: seconds)
                guard let self, let current = tracked[occurrenceID], current.generation == item.generation,
                      current.kept, current.elementRevision == revision else { return }
                tracked[occurrenceID]?.element = answer ?? previous
                publish()
            }
            return .performed
        }
        do {
            return try source.performMediaSessionAction(action, seconds: seconds) ? .performed : .unavailable
        } catch {
            return .unsupported
        }
    }

    public func removeAll() {
        for item in tracked.values { item.observation?.cancel() }
        tracked.removeAll()
        publish()
    }

    private func observe(_ id: TabOccurrenceID, _ source: Source) {
        guard let generation = tracked[id]?.generation else { return }
        tracked[id]?.observing = true
        let stream = source.mediaSessionChanges()
        tracked[id]?.observation = Task { [weak self] in
            for await state in stream {
                guard let self, tracked[id]?.generation == generation else { return }
                tracked[id]?.native = state
                publish()
            }
            guard let self, tracked[id]?.generation == generation else { return }
            tracked[id]?.observing = false
            tracked[id]?.observation = nil
        }
    }

    private func publish() {
        var entries: [(UInt64, Entry)] = []
        for (id, item) in tracked {
            guard let session = derivedSession(id, item) else {
                if item.order != nil { tracked[id]?.order = nil }
                continue
            }
            let order: UInt64
            if let existing = item.order { order = existing } else {
                nextOrder &+= 1
                order = nextOrder
                tracked[id]?.order = order
            }
            entries.append((order, Entry(occurrenceID: id, tabID: item.tabID, spaceID: item.spaceID, session: session)))
        }
        let next = entries.sorted { $0.0 < $1.0 }.map(\.1)
        guard next != published else { return }
        published = next
        onChange?()
    }

    /// The native session, or the last playing one of the same document while the tab stays
    /// muted (or was just unmuted) and its media keeps playing (or was paused from the card). The engine cannot act on
    /// players outside its session, so a kept session offers play, pause and seek only when the
    /// source drives the media element directly.
    private func derivedSession(_ id: TabOccurrenceID, _ item: Tracked) -> BrowserTabMediaSession? {
        var audio = item.audio
        let muted = item.source?.tabAudioMuted() ?? audio?.isAudioMuted
        if let muted, audio?.isAudioMuted != muted {
            var updated = audio ?? BrowserMediaState()
            updated.isAudioMuted = muted
            audio = updated
        }
        let document = item.source?.mediaDocumentIdentity
        if let native = item.native, let session = BrowserTabMediaSession(native, audio: audio) {
            let playing = session.playback == .playing
            tracked[id]?.lastSession = playing ? session : nil
            tracked[id]?.lastDocument = playing ? document : nil
            tracked[id]?.kept = false
            tracked[id]?.element = nil
            return session
        }
        // Unmuting returns the player to the engine session asynchronously: the kept session
        // bridges that gap (and stays controllable) instead of the card leaving and re-entering.
        guard muted == true || (muted == false && item.kept), item.element != nil || audio?.playback != .paused,
              var kept = item.lastSession, item.lastDocument == document else {
            tracked[id]?.lastSession = nil
            tracked[id]?.lastDocument = nil
            tracked[id]?.kept = false
            tracked[id]?.element = nil
            return nil
        }
        tracked[id]?.kept = true
        if let element = item.element {
            kept.playback = element.paused ? .paused : .playing
            kept.position = element.position ?? kept.position
            kept.duration = element.duration ?? kept.duration
            kept.playbackRate = element.playbackRate ?? kept.playbackRate
        }
        kept.actions = []
        if item.source?.supportsMediaElementControl == true {
            kept.actions = [.play, .pause]
            if let duration = kept.duration, duration.isFinite, duration > 0 { kept.actions.insert(.seek) }
        }
        kept.isAudioMuted = muted ?? true
        kept.isAudible = audio?.isAudible ?? audio?.isAudioPlaying ?? kept.isAudible
        return kept
    }
}
