import AppKit
import BrowserCore
import Testing
@testable import Orbit

@MainActor
@Suite struct SidebarMediaVolumeTests {
    private func item(_ id: TabOccurrenceID, volume: Double?) -> SidebarMediaPlayerItem {
        var item = SidebarMediaPlayerItem(id: id, title: "Tone", favicon: nil, toggle: .pause,
                                         canToggle: true, canGoBack: false, canGoForward: false)
        item.volume = volume
        item.isMuted = false
        return item
    }

    @Test func volumeRowKeepsBottomAnchorAndMovesControlsTogether() throws {
        OrbitMotionPreferences.overrideReducedMotion = true
        defer { OrbitMotionPreferences.overrideReducedMotion = nil }
        let host = SidebarMediaPlayerPlate(frame: CGRect(x: 0, y: 0, width: 174, height: 400))
        let view = SidebarMediaPlayerView()
        host.addSubview(view)
        view.onRestingHeightChange = {
            view.frame = CGRect(x: 0, y: 400 - view.expandedHeight, width: 174, height: view.expandedHeight)
        }
        let id = TabOccurrenceID()
        view.apply([item(id, volume: 0.4)])
        view.setHovered(true, animated: false)
        let card = try #require(view.card(for: id))
        let title = card.closeButton.frame.midY, transport = card.toggleButton.frame.midY
        let bottom = card.convert(card.bounds, to: host).maxY
        card.volumeButton.performClick(nil)
        #expect(card.isVolumeOpen && card.volumeHeight == 33)
        #expect(card.bounds.height == 157 && card.convert(card.bounds, to: host).maxY == bottom)
        #expect(card.closeButton.frame.midY == title && card.toggleButton.frame.midY == transport)
        #expect(card.volumeSlider.frame == CGRect(x: 8, y: 124, width: 158, height: 33))
        #expect(card.volumeSlider.level == 0.4 && !card.volumeSlider.isHidden)
        card.volumeButton.performClick(nil)
        #expect(!card.isVolumeOpen && card.volumeSlider.isHidden && card.bounds.height == 124)
        card.setVolumeOpen(true, animated: false)
        view.setHovered(false, animated: false)
        #expect(!card.isVolumeOpen)
    }

    @Test func liveWritesAreClampedAndKeepTheirTabIdentity() throws {
        let view = SidebarMediaPlayerView()
        let a = TabOccurrenceID(), b = TabOccurrenceID()
        view.apply([item(a, volume: 0.2), item(b, volume: 0.8)])
        var writes: [(TabOccurrenceID, Double)] = []
        view.onVolume = { writes.append(($0, $1)) }
        let card = try #require(view.card(for: a))
        for value in [0.3, 0.5, -1, 2, Double.nan] { card.volumeSlider.changeLevel(value) }
        #expect(writes.map(\.0) == [a, a, a, a])
        #expect(writes.map(\.1) == [0.3, 0.5, 0, 1])
        #expect(view.card(for: b)?.volumeSlider.level == 0.8)
        var muted = item(a, volume: 0.35); muted.isMuted = true
        view.apply([muted])
        #expect(card.volumeButton.isEnabled && card.volumeSlider.level == 0.35)
        #expect(card.volumeButton.symbol == "speaker.slash.fill")
        #expect(card.accessibilityHelp()?.contains(uiText("Per-tab volume is unavailable")) == false)
        view.apply([item(a, volume: nil)])
        card.volumeSlider.changeLevel(0.6)
        #expect(writes.count == 4 && !card.volumeButton.isEnabled && !card.isVolumeOpen)
        #expect(card.audioStatus.toolTip == uiText("Per-tab volume is unavailable"))
    }

    @Test func keyboardAndAccessibilityUseTheSameContinuousRoute() {
        let slider = SidebarMediaVolumeSlider(frame: CGRect(x: 0, y: 0, width: 158, height: 33))
        slider.level = 0.5
        var values: [Double] = []
        slider.onChange = { values.append($0) }
        #expect(slider.accessibilityPerformIncrement())
        #expect(slider.accessibilityPerformDecrement())
        #expect(values == [0.55, 0.5])
        slider.isEnabled = false
        #expect(!slider.accessibilityPerformIncrement())
        #expect(values.count == 2)
    }
}
