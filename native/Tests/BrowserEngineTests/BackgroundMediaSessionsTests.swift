import BrowserCore
import BrowserEngine
import BrowserEngineConformance
import Foundation
import Testing

@MainActor
private final class FakeMediaSource: BrowserMediaSessionControlling {
    var isDisposed = false
    var state: BrowserMediaSessionState?
    var accepts = true
    var unsupported = false
    var performed: [BrowserMediaAction] = []
    var subscriptions = 0
    var finishImmediately = false
    var muted: Bool?
    var document: UInt64? = 1
    private var continuations: [AsyncStream<BrowserMediaSessionState>.Continuation] = []

    func mediaSessionState() -> BrowserMediaSessionState? { state }
    func mediaSessionChanges() -> AsyncStream<BrowserMediaSessionState> {
        subscriptions += 1
        return AsyncStream { continuation in
            if finishImmediately { continuation.finish(); return }
            continuations.append(continuation)
            if let state { continuation.yield(state) }
        }
    }
    func performMediaSessionAction(_ action: BrowserMediaAction, seconds: Double) throws -> Bool {
        if unsupported { throw BrowserEngineError.unsupportedOperation }
        performed.append(action)
        return accepts
    }
    func tabAudioMuted() -> Bool? { muted }
    var mediaDocumentIdentity: UInt64? { document }
    var elementControl = false
    var elementAnswers: [BrowserMediaElementState?] = []
    var elementActions: [(BrowserMediaAction, Double)] = []
    var supportsMediaElementControl: Bool { elementControl }
    func performMediaElementAction(_ action: BrowserMediaAction, seconds: Double) async -> BrowserMediaElementState? {
        elementActions.append((action, seconds))
        return elementAnswers.isEmpty ? nil : elementAnswers.removeFirst()
    }
    func send(_ value: BrowserMediaSessionState) {
        state = value
        for continuation in continuations { continuation.yield(value) }
    }
}

private func native(playing: Bool = true, session: Int = 0, actions: [Int] = [0, 1, 2, 3, 8],
                    title: String = "Synthetic title", artwork: [String] = ["https://example.invalid/art.png"]) -> BrowserMediaSessionState {
    let artworkJSON = artwork.map { "\"\($0)\"" }.joined(separator: ",")
    let json = #"{"title":"\#(title)","artist":"Synthetic artist","album":"","playbackState":\#(playing ? 1 : 0),"sessionState":\#(session),"artwork":[\#(artworkJSON)],"actions":\#(actions),"position":1.5,"duration":10}"#
    return try! JSONDecoder().decode(BrowserMediaSessionState.self, from: Data(json.utf8))
}

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
@Suite("Background media sessions")
struct BackgroundMediaSessionsTests {
    @Test("Native session values map to a tab model with metadata, artwork and actions")
    func model() throws {
        let audio = BrowserMediaState(playback: .playing, isAudible: true, isAudioMuted: false)
        let model = try #require(BrowserTabMediaSession(native(artwork: ["blob:x", "https://example.invalid/a.png"]), audio: audio))
        #expect(model.playback == .playing)
        #expect(model.title == "Synthetic title" && model.artist == "Synthetic artist")
        #expect(model.actions == [.play, .pause, .previous, .next, .seek])
        #expect(model.artworkURL?.absoluteString == "https://example.invalid/a.png")
        #expect(model.isAudible == true && model.isAudioMuted == false)
        #expect(model.toggleAction == .pause && model.duration == 10)
        let paused = try #require(BrowserTabMediaSession(native(playing: false, session: 2)))
        #expect(paused.playback == .paused && paused.toggleAction == .play && paused.isAudible == nil)
    }

    @Test("Inactive sessions and sessions without play or pause are not controllable")
    func absent() {
        #expect(BrowserTabMediaSession(native(session: 3)) == nil)
        #expect(BrowserTabMediaSession(native(actions: [3, 8])) == nil)
        #expect(BrowserTabMediaSession(native(actions: [1]))?.toggleAction == .pause)
        #expect(BrowserTabMediaSession(native(playing: false, actions: [1]))?.toggleAction == nil)
    }

    @Test("Only tabs of the Space outside visible panes are background sessions")
    func backgroundFilter() async {
        let list = BrowserBackgroundMediaSessions<FakeMediaSource>()
        let space = SpaceID(), other = SpaceID()
        let visible = FakeMediaSource(), hidden = FakeMediaSource(), elsewhere = FakeMediaSource(), silent = FakeMediaSource()
        visible.state = native(); hidden.state = native(); elsewhere.state = native()
        let ids = (0..<4).map { _ in TabOccurrenceID() }
        var changes = 0
        list.onChange = { changes += 1 }
        list.reconcile([
            .init(source: visible, occurrenceID: ids[0], tabID: TabID(), spaceID: space),
            .init(source: hidden, occurrenceID: ids[1], tabID: TabID(), spaceID: space),
            .init(source: elsewhere, occurrenceID: ids[2], tabID: TabID(), spaceID: other),
            .init(source: silent, occurrenceID: ids[3], tabID: TabID(), spaceID: space),
        ])
        await settle()
        #expect(list.sessions.count == 3)
        #expect(list.backgroundSessions(in: space, excluding: [ids[0]]).map(\.occurrenceID) == [ids[1]])
        #expect(list.backgroundSessions(in: other, excluding: [ids[0]]).map(\.occurrenceID) == [ids[2]])
        #expect(changes >= 1)
    }

    @Test("A playing tab muted from the card or elsewhere keeps its session while the engine drops it")
    func mutedPlayingSessionStays() async throws {
        let list = BrowserBackgroundMediaSessions<FakeMediaSource>()
        let source = FakeMediaSource(), other = FakeMediaSource(), space = SpaceID()
        let id = TabOccurrenceID(), otherID = TabOccurrenceID()
        source.state = native(); other.state = native(title: "Second")
        source.muted = false
        let member = BrowserBackgroundMediaSessions<FakeMediaSource>.Member(source: source, occurrenceID: id, tabID: TabID(), spaceID: space)
        list.reconcile([member])
        await settle()
        list.reconcile([member, .init(source: other, occurrenceID: otherID, tabID: TabID(), spaceID: space)])
        await settle()
        list.updateAudio(BrowserMediaState(playback: .playing, isAudible: true, isAudioMuted: false), for: id)
        #expect(list.sessions.map(\.occurrenceID) == [id, otherID])

        // The engine leaves a muted tab's players out of its media session; playback goes on.
        source.muted = true
        source.send(native(session: 3))
        await settle()
        let kept = try #require(list.session(for: id))
        #expect(kept.isAudioMuted == true && kept.playback == .playing && kept.title == "Synthetic title")
        #expect(kept.actions.isEmpty && kept.toggleAction == nil)
        #expect(list.sessions.map(\.occurrenceID) == [id, otherID])

        // Unmuting brings the engine session back with its actions, in the same place.
        source.muted = false
        source.send(native())
        await settle()
        #expect(list.session(for: id)?.isAudioMuted == false && list.session(for: id)?.toggleAction == .pause)
        #expect(list.sessions.map(\.occurrenceID) == [id, otherID])

        // Muted from elsewhere: only the media refresh knows the flag.
        list.updateAudio(BrowserMediaState(playback: .playing, isAudible: true, isAudioMuted: true), for: otherID)
        other.send(native(session: 3))
        await settle()
        #expect(list.session(for: otherID)?.isAudioMuted == true && list.session(for: otherID)?.title == "Second")

        // Media that stops while muted, or a new document, ends the card.
        list.updateAudio(BrowserMediaState(playback: .paused, isAudible: false, isAudioMuted: true), for: otherID)
        #expect(list.session(for: otherID) == nil)
        source.muted = true
        source.send(native(session: 3))
        await settle()
        #expect(list.session(for: id) != nil)
        source.document = 2
        source.send(native(session: 3))
        await settle()
        #expect(list.session(for: id) == nil)
    }

    @Test("A kept muted session plays, pauses and seeks through its media element and stays in sync")
    func keptSessionDrivesElement() async throws {
        let list = BrowserBackgroundMediaSessions<FakeMediaSource>()
        let source = FakeMediaSource(), id = TabOccurrenceID()
        source.state = native(); source.muted = false; source.elementControl = true
        list.reconcile([.init(source: source, occurrenceID: id, tabID: TabID(), spaceID: SpaceID())])
        await settle()
        source.muted = true
        source.send(native(session: 3))
        await settle()
        let kept = try #require(list.session(for: id))
        #expect(kept.actions == [.play, .pause, .seek] && kept.toggleAction == .pause)
        #expect(list.perform(.next, on: id) == .unavailable && source.elementActions.isEmpty)

        // Pause: the card shows it at once, then the element's answer settles position.
        source.elementAnswers = [BrowserMediaElementState(paused: true, position: 4, duration: 10, playbackRate: 1)]
        #expect(list.perform(.pause, on: id) == .performed)
        #expect(list.session(for: id)?.playback == .paused)
        await settle()
        #expect(source.elementActions.map(\.0) == [.pause])
        #expect(list.session(for: id)?.playback == .paused && list.session(for: id)?.position == 4)
        // A pause from the card keeps the card although the engine now reports paused media.
        list.updateAudio(BrowserMediaState(playback: .paused, isAudible: false, isAudioMuted: true), for: id)
        #expect(list.session(for: id)?.toggleAction == .play)

        // Seek, then a play the element refuses: the card returns to the last known state.
        source.elementAnswers = [BrowserMediaElementState(paused: true, position: 7.5, duration: 10, playbackRate: 1)]
        #expect(list.perform(.seek, on: id, seconds: 7.5) == .performed)
        await settle()
        #expect(source.elementActions.last?.1 == 7.5 && list.session(for: id)?.position == 7.5)
        source.elementAnswers = [nil]
        #expect(list.perform(.play, on: id) == .performed)
        #expect(list.session(for: id)?.playback == .playing)
        await settle()
        #expect(list.session(for: id)?.playback == .paused && list.session(for: id)?.position == 7.5)
        // The page plays again on its own: the engine's report wins over the last answer.
        list.updateAudio(BrowserMediaState(playback: .playing, isAudible: false, isAudioMuted: true), for: id)
        #expect(list.session(for: id)?.playback == .playing && list.session(for: id)?.toggleAction == .pause)

        // Unmuting hands control back to the engine session.
        source.muted = false
        source.send(native())
        await settle()
        #expect(list.perform(.pause, on: id) == .performed && source.performed == [.pause])
        #expect(source.elementActions.count == 3)
    }

    @Test("Changes stream into the model; ended sessions disappear and removed tabs stop")
    func streaming() async {
        let list = BrowserBackgroundMediaSessions<FakeMediaSource>()
        let source = FakeMediaSource(), id = TabOccurrenceID(), space = SpaceID()
        list.reconcile([.init(source: source, occurrenceID: id, tabID: TabID(), spaceID: space)])
        await settle()
        #expect(list.sessions.isEmpty)
        source.send(native())
        await settle()
        #expect(list.session(for: id)?.playback == .playing)
        source.send(native(playing: false, session: 2))
        await settle()
        #expect(list.session(for: id)?.playback == .paused)
        list.updateAudio(BrowserMediaState(isAudible: false, isAudioMuted: true), for: id)
        #expect(list.session(for: id)?.isAudioMuted == true)
        source.send(native(session: 3))
        await settle()
        #expect(list.session(for: id) == nil)
        source.send(native())
        await settle()
        #expect(list.session(for: id) != nil)
        list.reconcile([])
        #expect(list.sessions.isEmpty)
        #expect(list.perform(.pause, on: id) == .unavailable)
    }

    @Test("Actions reach the source of a background tab and report refusal or no support")
    func actions() async {
        let list = BrowserBackgroundMediaSessions<FakeMediaSource>()
        let source = FakeMediaSource(), id = TabOccurrenceID()
        source.state = native()
        list.reconcile([.init(source: source, occurrenceID: id, tabID: TabID(), spaceID: SpaceID())])
        await settle()
        #expect(list.perform(.pause, on: id) == .performed)
        #expect(list.perform(.play, on: id) == .performed)
        #expect(list.perform(.next, on: id) == .performed)
        #expect(list.perform(.previous, on: id) == .performed)
        #expect(source.performed == [.pause, .play, .next, .previous])
        source.accepts = false
        #expect(list.perform(.pause, on: id) == .unavailable)
        source.unsupported = true
        #expect(list.perform(.pause, on: id) == .unsupported)
        source.isDisposed = true
        #expect(list.perform(.pause, on: id) == .unavailable)
    }

    @Test("A source not ready on first observation is observed again on the next reconcile")
    func resubscribe() async {
        let list = BrowserBackgroundMediaSessions<FakeMediaSource>()
        let source = FakeMediaSource(), id = TabOccurrenceID(), space = SpaceID()
        source.finishImmediately = true
        let member = BrowserBackgroundMediaSessions<FakeMediaSource>.Member(source: source, occurrenceID: id, tabID: TabID(), spaceID: space)
        list.reconcile([member])
        await settle()
        source.finishImmediately = false
        source.state = native()
        list.reconcile([member])
        await settle()
        #expect(source.subscriptions == 2)
        #expect(list.session(for: id) != nil)
        list.reconcile([member])
        await settle()
        #expect(source.subscriptions == 2)
    }

    @Test("Engines without native media sessions fall back to unsupported")
    func unsupportedEngine() async {
        let engine = SyntheticEngine()
        let delegate = RecordingSurfaceDelegate()
        let surface = engine.makeSurface(profileID: ProfileID(), delegate: delegate)
        #expect(surface.mediaSessionState() == nil)
        #expect(throws: BrowserEngineError.unsupportedOperation) { try surface.performMediaSessionAction(.pause, seconds: 0) }
        var received = 0
        for await _ in surface.mediaSessionChanges() { received += 1 }
        #expect(received == 0)
        let list = BrowserBackgroundMediaSessions<SyntheticEngine.Surface>()
        let id = TabOccurrenceID()
        list.reconcile([.init(source: surface, occurrenceID: id, tabID: TabID(), spaceID: SpaceID())])
        #expect(list.perform(.play, on: id) == .unsupported)
        surface.dispose()
    }
}
