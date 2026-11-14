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
