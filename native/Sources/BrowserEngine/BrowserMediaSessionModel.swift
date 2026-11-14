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
        guard tracked[occurrenceID] != nil, tracked[occurrenceID]?.audio != audio else { return }
        tracked[occurrenceID]?.audio = audio
        publish()
    }

    /// Performs a media action on a tab of this window, visible or not.
    @discardableResult
    public func perform(_ action: BrowserMediaAction, on occurrenceID: TabOccurrenceID, seconds: Double = 0) -> ActionResult {
        guard let source = tracked[occurrenceID]?.source, !source.isDisposed else { return .unavailable }
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
            guard let native = item.native, let session = BrowserTabMediaSession(native, audio: item.audio) else {
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
}
