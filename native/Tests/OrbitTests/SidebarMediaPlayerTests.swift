import AppKit
import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

private func media(playing: Bool, actions: [Int] = [0, 1]) -> BrowserTabMediaSession {
    let json = #"{"title":"","artist":"","album":"","playbackState":\#(playing ? 1 : 0),"sessionState":0,"artwork":[],"actions":\#(actions),"position":0,"duration":10}"#
    let native = try! JSONDecoder().decode(BrowserMediaSessionState.self, from: Data(json.utf8))
    return BrowserTabMediaSession(native)!
}

private func item(_ id: TabOccurrenceID = TabOccurrenceID(), title: String = "Track", toggle: SidebarMediaPlayerItem.Toggle = .pause,
                  canToggle: Bool = true, back: Bool = false, forward: Bool = false) -> SidebarMediaPlayerItem {
    .init(id: id, title: title, favicon: nil, toggle: toggle, canToggle: canToggle, canGoBack: back, canGoForward: forward)
}

@MainActor
@Suite("Sidebar media player")
struct SidebarMediaPlayerTests {
    typealias Layout = SidebarMediaPlayerLayout

    @Test("A single card rests 33 pt high on the footer and grows upward to 124 pt")
    func singleCardGeometry() {
        #expect(Layout.restingHeight(count: 0) == 0 && Layout.restingHeight(count: 1) == 33)
        #expect(Layout.expandedHeight(count: 1) == 124)
        let rest = Layout.cards(count: 1, width: 174, progress: 0)[0]
        #expect(rest.frame == CGRect(x: 0, y: 91, width: 174, height: 33) && rest.scale == 1 && rest.titleOpacity == 0)
        let open = Layout.cards(count: 1, width: 174, progress: 1)[0]
        #expect(open.frame == CGRect(x: 0, y: 0, width: 174, height: 124) && open.titleOpacity == 1)
        // The title row's opacity is the square of the geometry progress.
        #expect(Layout.cards(count: 1, width: 174, progress: 0.5)[0].titleOpacity == 0.25)
        #expect([0, 1, 2, 3, 4].map { Layout.controlCenterX($0, width: 174) } == [22, 54.5, 87, 119.5, 152])
    }

    @Test("Two players rest as a deck with a 7 pt peek and expand into two full cards, newest on top")
    func stackGeometry() {
        #expect(Layout.restingHeight(count: 2) == 40 && Layout.expandedHeight(count: 2) == 253)
        let rest = Layout.cards(count: 2, width: 174, progress: 0)
        #expect(rest[0].frame == CGRect(x: 0, y: 220, width: 174, height: 33))
        #expect(rest[1].frame.minX == 6 && rest[1].frame.width == 162 && rest[1].frame.minY == 213)
        #expect(abs(rest[1].scale - 162.0 / 174.0) < 0.0001 && rest[1].opacity == OrbitTokens.MediaPlayer.stackDimmedOpacity)
        let open = Layout.cards(count: 2, width: 174, progress: 1)
        #expect(open[0].frame == CGRect(x: 0, y: 129, width: 174, height: 124))
        #expect(open[1].frame == CGRect(x: 0, y: 0, width: 174, height: 124) && open[1].scale == 1 && open[1].opacity == 1)
        // A third card waits hidden behind the peeking one.
        #expect(Layout.cards(count: 3, width: 174, progress: 0)[2].opacity == 0)
    }

    @Test("Playing, paused from the card and paused by the page map to their controls")
    func itemStates() {
        let id = TabOccurrenceID()
        let playing = SidebarMediaPlayerState.item(id: id, session: media(playing: true, actions: [0, 1, 3]), title: "A",
                                                   favicon: nil, pausedFromPlayer: false)
        #expect(playing.toggle == .pause && playing.canToggle && playing.canGoForward && !playing.canGoBack)
        let fromCard = SidebarMediaPlayerState.item(id: id, session: media(playing: false, actions: [0, 1, 2]), title: "A",
                                                    favicon: nil, pausedFromPlayer: true)
        #expect(fromCard.toggle == .play && fromCard.canToggle && fromCard.canGoBack && !fromCard.canGoForward)
        let fromPage = SidebarMediaPlayerState.item(id: id, session: media(playing: false, actions: [0, 1, 2, 3]), title: "A",
                                                    favicon: nil, pausedFromPlayer: false)
        #expect(fromPage.toggle == .pause && !fromPage.canToggle && !fromPage.canGoBack && !fromPage.canGoForward)
    }

    @Test("Visible panes, Picture in Picture and closed cards are left out until the page plays again")
    func shownSessions() {
        let state = SidebarMediaPlayerState()
        let a = TabOccurrenceID(), b = TabOccurrenceID(), c = TabOccurrenceID()
        var sessions = [(id: a, session: media(playing: true)), (id: b, session: media(playing: true)), (id: c, session: media(playing: true))]
        #expect(state.shown(sessions, visible: [b], pictureInPicture: { $0 == c }) == [a])
        state.willPerform(.pause, on: a)
        state.dismiss(b)
        // The playing state reported right after the click keeps the card's pause request.
        #expect(state.shown(sessions, visible: [], pictureInPicture: { _ in false }) == [a, c])
        #expect(state.pausedFromPlayer.contains(a))
        sessions[0].session = media(playing: false)
        // The pause the close requested lands; the card stays closed while paused.
        sessions[1].session = media(playing: false)
        #expect(state.shown(sessions, visible: [], pictureInPicture: { _ in false }) == [a, c])
        #expect(state.dismissed[b] == .paused)
        // Playing again from the page brings the card back and clears the card's pause.
        sessions[0].session = media(playing: true)
        sessions[1].session = media(playing: true)
        #expect(state.shown(sessions, visible: [], pictureInPicture: { _ in false }) == [a, b, c])
        #expect(!state.pausedFromPlayer.contains(a))
        // Closed tabs drop their bookkeeping.
        state.dismiss(c)
        _ = state.shown([(id: a, session: media(playing: true))], visible: [], pictureInPicture: { _ in false })
        #expect(state.dismissed.isEmpty)
    }

    @Test("The view keeps one card per tab, oldest in front, and hover expands it without motion when reduced")
    func viewStack() throws {
        OrbitMotionPreferences.overrideReducedMotion = true
        defer { OrbitMotionPreferences.overrideReducedMotion = nil }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 190, height: 400))
        let view = SidebarMediaPlayerView()
        host.addSubview(view)
        var relayouts = 0
        view.onRestingHeightChange = { relayouts += 1 }
        let old = TabOccurrenceID(), new = TabOccurrenceID()
        view.apply([item(old, title: "Old"), item(new, title: "New")])
        view.frame = NSRect(x: 8, y: 0, width: 174, height: view.expandedHeight)
        view.layoutSubtreeIfNeeded()
        #expect(relayouts == 1 && !view.isHidden && view.restingHeight == 40)
        let front = try #require(view.card(for: old)), back = try #require(view.card(for: new))
        #expect(view.subviews.last === front)
        #expect(front.frame == CGRect(x: 0, y: 220, width: 174, height: 33))
        #expect(back.alphaValue == OrbitTokens.MediaPlayer.stackDimmedOpacity)
        let card = front.titleView
        #expect(card.alphaValue == 0)
        // Points above the deck fall through to the list (the host is not flipped).
        #expect(view.hitTest(NSPoint(x: 90, y: 130)) == nil)
        #expect(view.hitTest(NSPoint(x: 90, y: 10)) != nil)
        view.setHovered(true)
        #expect(view.progress == 1 && front.titleView.alphaValue == 1)
        #expect(front.frame == CGRect(x: 0, y: 129, width: 174, height: 124) && back.frame.minY == 0)
        view.apply([])
        #expect(view.isHidden && !view.isHovered && view.progress == 0 && relayouts == 2)
    }

    @Test("Controls carry the evidenced help; the volume control stays disabled without a per-tab volume API")
    func controls() throws {
        let view = SidebarMediaPlayerView()
        let id = TabOccurrenceID()
        view.apply([item(id, toggle: .play, canToggle: true, back: false, forward: true)])
        let card = try #require(view.card(for: id))
        #expect(card.faviconButton.toolTip == uiText("Back to Tab"))
        #expect(card.toggleButton.toolTip == uiText("Play") && card.toggleButton.symbol == "play.fill")
        #expect(card.previousButton.toolTip == nil && !card.previousButton.isEnabled)
        #expect(card.nextButton.isEnabled)
        #expect(!card.volumeButton.isEnabled && card.volumeButton.toolTip == nil)
        var pressed: [TabOccurrenceID] = []
        view.onToggle = { pressed.append($0) }
        card.toggleButton.performClick(nil)
        #expect(pressed == [id])
        view.apply([item(id, toggle: .pause)])
        #expect(card.toggleButton.toolTip == uiText("Pause") && card.toggleButton.symbol == "pause.fill")
    }

    @Test("Media template icons ship in every optical size")
    func icons() {
        for name in ["backward.end.fill", "forward.end.fill", "pause.fill", "play.fill", "speaker.wave.3.fill"] {
            #expect(OrbitIcon.templateNames.contains(name))
            for size: CGFloat in [14, 20, 24] { #expect(OrbitIcon.resourceURL(sfName: name, pointSize: size) != nil) }
        }
        // Previous/next draw larger than play/pause but keep the 16 pt optical master.
        #expect(OrbitIcon.opticalSize(for: OrbitTokens.MediaPlayer.trackSkipGlyphSize) == 16)
        let card = SidebarMediaPlayerCard()
        for button in [card.previousButton, card.nextButton] {
            #expect(OrbitGlyph.configuration(of: button.glyph)?.pointSize == 14.5)
        }
        #expect(OrbitGlyph.configuration(of: card.toggleButton.glyph)?.pointSize == 14)
    }
}

@MainActor
@Suite struct SidebarMediaAdditionsTests {
    @Test func seekMappingAndThrottle() {
        var seek = SidebarMediaSeekState(duration: 248, position: 102, offered: true)
        seek.update(fraction: 0.5, now: 0)
        #expect(seek.displayed == 124)
        seek.position = 106
        seek.update(fraction: 0.8, now: 0.01)
        #expect(seek.displayed == 124)
        seek.update(fraction: 2, now: 0.02, force: true)
        #expect(seek.finish(cancel: false) == 248)
        #expect(seek.displayed == 106)
        seek.update(fraction: -1, now: 1)
        #expect(seek.preview == 0 && seek.finish(cancel: true) == nil)
        #expect(SidebarMediaSeekState.time(nil) == "—")
        #expect(SidebarMediaSeekState.time(248) == "4:08")
    }
    @Test func interpolationRespectsPlaybackAndMotion() {
        var seek = SidebarMediaSeekState(duration: 248, position: 102, offered: true)
        seek.playbackRate = 2
        let now = ProcessInfo.processInfo.systemUptime
        #expect(abs((seek.currentPosition(now: now + 2, interpolate: true) ?? 0) - 106) < 0.1)
        #expect(seek.currentPosition(now: now + 2, interpolate: false) == 102)
        seek.update(fraction: 0.5, now: now)
        #expect(seek.currentPosition(now: now + 2, interpolate: true) == 124)
        _ = seek.finish(cancel: true)
        seek.playbackRate = nil
        #expect(seek.currentPosition(now: now + 2, interpolate: true) == 102)
    }
    @Test func capabilityTruth() {
        for duration: Double? in [nil, 0, -1, .infinity, .nan] {
            let seek = SidebarMediaSeekState(duration: duration, position: 10, offered: true)
            #expect(!seek.canSeek && seek.finiteDuration == nil)
        }
        #expect(!SidebarMediaSeekState(duration: 100, position: nil, offered: true).canSeek)
        #expect(!SidebarMediaSeekState(duration: 100, position: 10, offered: false).canSeek)
        let card = SidebarMediaPlayerCard()
        var model = item()
        model.isMuted = true
        card.apply(model)
        #expect(card.muteButton.isEnabled && !card.volumeButton.isEnabled)
        #expect(card.muteButton.symbol == "speaker.slash.fill" && !card.pipButton.isEnabled)
        #expect(card.audioStatus.stringValue == uiText("Muted") && card.muteButton.label == uiText("Unmute tab"))
        model.isMuted = false; model.pip = .ready
        card.apply(model)
        #expect(card.pipButton.isEnabled && card.muteButton.symbol == "speaker.wave.2.fill")
        #expect(card.audioStatus.stringValue == uiText("Tab audio"))
        for button in [card.muteButton, card.pipButton] {
            #expect(OrbitGlyph.configuration(of: button.glyph)?.pointSize == OrbitTokens.MediaPlayer.utilityGlyphSize)
        }
        model.pip = .requesting
        card.apply(model)
        #expect(!card.pipButton.isEnabled)
        model.pip = .failed
        card.apply(model)
        #expect(card.pipButton.isEnabled && card.audioStatus.stringValue == uiText("PiP failed"))
    }
    @Test func mutedSessionKeptByTheModelStaysWithUnavailableTransport() {
        var kept = media(playing: true, actions: [0, 1, 2, 3, 8])
        kept.actions = []
        kept.isAudioMuted = true
        let id = TabOccurrenceID()
        let mapped = SidebarMediaPlayerState.item(id: id, session: kept, title: "Track", favicon: nil, pausedFromPlayer: false)
        #expect(mapped.toggle == .pause && !mapped.canToggle && !mapped.canGoBack && !mapped.canGoForward)
        let state = SidebarMediaPlayerState()
        #expect(state.shown([(id, kept)], visible: [], pictureInPicture: { _ in false }) == [id])
        #expect(state.shown([(id, kept)], visible: [id], pictureInPicture: { _ in false }).isEmpty)
    }
    @Test func constrainedDeckAndRows() {
        let frames = SidebarMediaPlayerLayout.cards(count: 2, width: 174, progress: 1, availableHeight: 200, focusedIndex: 1)
        #expect(SidebarMediaPlayerLayout.expandedHeight(count: 2, availableHeight: 200) == 195)
        #expect(frames[0].height == 66 && frames[1].height == 124)
        let card = SidebarMediaPlayerCard()
        card.place(SidebarMediaPlayerLayout.cards(count: 1, width: 174, progress: 1)[0])
        #expect(card.timeline.frame == CGRect(x: 12, y: 0, width: 150, height: 30))
        #expect(card.muteButton.frame == CGRect(x: 12, y: 30, width: 24, height: 28))
        #expect(card.pipButton.frame == CGRect(x: 138, y: 30, width: 24, height: 28))
        #expect(card.toggleButton.frame.midY == 107.5 && card.closeButton.frame.midY == 74.75)
    }
}
