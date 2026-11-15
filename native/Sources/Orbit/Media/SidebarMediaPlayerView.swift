import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import QuartzCore

/// One tab whose media keeps playing after the user left it, as the sidebar card shows it.
struct SidebarMediaPlayerItem: Equatable {
    enum Toggle: Equatable { case pause, play }
    let id: TabOccurrenceID
    var title: String
    var favicon: NSImage?
    /// The glyph of the middle control. The page pausing its own media keeps the pause glyph.
    var toggle: Toggle
    var canToggle: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var trackIdentity = ""
    var position: Double? = nil
    var duration: Double? = nil
    var playbackRate: Double? = nil
    var canSeek = false
    var volume: Double? = nil
    var isMuted: Bool? = nil
    var pip: BrowserManualPiP.State = .unavailable
    var pipFailure: BrowserManualPiP.Failure = .rejected
}

/// Card frames as a function of the hover progress (0 at rest, 1 expanded). Index 0 is the
/// oldest session: the front card at rest and the bottom card once expanded.
struct SidebarMediaPlayerLayout: Equatable {
    struct Card: Equatable {
        /// Visible rectangle in the player view (flipped, origin at its top-left).
        var frame: CGRect
        /// The card renders at its unscaled height, scaled by this factor about its centre.
        var scale: CGFloat
        var height: CGFloat
        var opacity: CGFloat
        var volumeHeight: CGFloat = 0
        var additionsOpacity: CGFloat = 0
        var titleOpacity: CGFloat
    }
    typealias Tokens = OrbitTokens.MediaPlayer

    static func expandedHeight(count: Int, availableHeight: CGFloat = .infinity) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * (count > 1 && availableHeight < 253 ? 66 : Tokens.expandedHeight)
            + (count > 1 && availableHeight < 253 ? 58 : 0) + CGFloat(count - 1) * Tokens.stackGap
    }

    /// Height kept free above the footer while the stack rests.
    static func restingHeight(count: Int) -> CGFloat {
        count == 0 ? 0 : Tokens.collapsedHeight + (count > 1 ? Tokens.stackPeek : 0)
    }

    static func cards(count: Int, width: CGFloat, progress: CGFloat, availableHeight: CGFloat = .infinity, focusedIndex: Int = 0, volumeHeights: [CGFloat] = []) -> [Card] {
        let p = min(1, max(0, progress))
        let extras = (0..<count).map { volumeHeights.indices.contains($0) ? volumeHeights[$0] : 0 }
        let bottom = expandedHeight(count: count, availableHeight: availableHeight) + extras.reduce(0, +)
        let heights = (0..<count).map { index -> CGFloat in
            (count > 1 && availableHeight < 253 && index != focusedIndex ? 66 : Tokens.expandedHeight) + extras[index]
        }
        let backScale = width > 0 ? max(0, width - 2 * Tokens.stackInset) / width : 1
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        return (0..<count).map { index in
            let expanded = CGRect(x: 0, y: bottom - heights.prefix(index + 1).reduce(0, +) - CGFloat(index) * Tokens.stackGap,
                                  width: width, height: heights[index])
            let rest: CGRect, restScale: CGFloat, restOpacity: CGFloat
            if index == 0 {
                rest = CGRect(x: 0, y: bottom - Tokens.collapsedHeight, width: width, height: Tokens.collapsedHeight)
                restScale = 1; restOpacity = 1
            } else {
                let height = Tokens.collapsedHeight * backScale
                rest = CGRect(x: Tokens.stackInset, y: bottom - Tokens.collapsedHeight - Tokens.stackPeek,
                              width: width * backScale, height: height)
                restScale = backScale
                // Only the second card peeks; later ones wait behind it.
                restOpacity = index == 1 ? Tokens.stackDimmedOpacity : 0
            }
            let frame = CGRect(x: lerp(rest.minX, expanded.minX), y: lerp(rest.minY, expanded.minY),
                               width: lerp(rest.width, expanded.width), height: lerp(rest.height, expanded.height))
            return Card(frame: frame, scale: lerp(restScale, 1),
                        height: lerp(Tokens.collapsedHeight, heights[index]),
                        opacity: lerp(restOpacity, 1), volumeHeight: extras[index] * p, titleOpacity: p * p)
        }
    }

    /// Centre x of control `slot` (0 favicon … 4 speaker) in a card of `width`.
    static func controlCenterX(_ slot: Int, width: CGFloat) -> CGFloat {
        width / 2 + CGFloat(slot - 2) * Tokens.controlPitch
    }
}

/// The stack of cards between the Space list and the footer. The sidebar sizes it to the
/// expanded stack and reserves only the resting height; points outside the cards fall through.
@MainActor
final class SidebarMediaPlayerView: NSView {
    var onBackToTab: ((TabOccurrenceID) -> Void)?
    var onToggle: ((TabOccurrenceID) -> Void)?
    var onPrevious: ((TabOccurrenceID) -> Void)?
    var onNext: ((TabOccurrenceID) -> Void)?
    var onClose: ((TabOccurrenceID) -> Void)?
    var onSeek: ((TabOccurrenceID, Double) -> Void)?
    var onVolume: ((TabOccurrenceID, Double) -> Void)?
    var onMute: ((TabOccurrenceID) -> Void)?
    var onPiP: ((TabOccurrenceID) -> Void)?
    var onInteraction: ((Bool) -> Void)?
    var onFocus: (() -> Void)?
    /// The card count changed: the sidebar reserves the new resting height and resizes the view.
    var onRestingHeightChange: (() -> Void)?
    var onReveal: (() -> Void)?

    private(set) var items: [SidebarMediaPlayerItem] = []
    private var cards: [TabOccurrenceID: SidebarMediaPlayerCard] = [:]
    private let expansion = OrbitTimedAnimator(value: 0)
    private let reveal = OrbitTimedAnimator(value: 0)
    private var revealDelay: Task<Void, Never>?
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?
    private var interaction = false
    private var pointerInside = false
    private var focusTimer: Timer?

    var restingHeight: CGFloat { SidebarMediaPlayerLayout.restingHeight(count: items.count) }
    var availableHeight: CGFloat = .infinity
    private var focusedIndex = 0
    private var scrollOffset: CGFloat = 0
    private var volumeHeights: [CGFloat] { items.map { cards[$0.id]?.volumeHeight ?? 0 } }
    var expandedHeight: CGFloat { min(max(124, availableHeight), contentHeight) }
    private var contentHeight: CGFloat { SidebarMediaPlayerLayout.expandedHeight(count: items.count, availableHeight: availableHeight) + volumeHeights.reduce(0, +) }
    var progress: CGFloat { CGFloat(expansion.value) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        isHidden = true
        expansion.onChange = { [weak self] _ in self?.layoutCards() }
        expansion.onSettle = { [weak self] in self?.closeCollapsedVolumeRows() }
        reveal.onChange = { [weak self] _ in self?.layoutCards() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(uiText("Media Player"))
        setAccessibilityIdentifier("sidebar-media-player")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Cards appear and leave at once (no transition); known titles and icons never flicker
    /// because a card is reused for its tab and only redraws what changed.
    func apply(_ next: [SidebarMediaPlayerItem]) {
        guard next != items else { return }
        let oldCount = items.count
        items = next
        let ids = Set(next.map(\.id))
        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperview()
            cards.removeValue(forKey: id)
        }
        for item in next {
            let card = cards[item.id] ?? makeCard()
            cards[item.id] = card
            card.apply(item)
        }
        // The oldest card is in front at rest: the newest is the bottom subview.
        let order: [NSView] = next.reversed().compactMap { cards[$0.id] }
        if subviews != order {
            for card in order { addSubview(card, positioned: .above, relativeTo: nil) }
        }
        isHidden = next.isEmpty
        if next.isEmpty { isHovered = false; expansion.set(0) }
        if oldCount != next.count { onRestingHeightChange?() }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func makeCard() -> SidebarMediaPlayerCard {
        let card = SidebarMediaPlayerCard()
        card.onBackToTab = { [weak self] in self?.onBackToTab?($0) }
        card.onToggle = { [weak self] in self?.onToggle?($0) }
        card.onPrevious = { [weak self] in self?.onPrevious?($0) }
        card.onNext = { [weak self] in self?.onNext?($0) }
        card.onClose = { [weak self] in self?.onClose?($0) }
        card.onSeek = { [weak self] in self?.onSeek?($0, $1) }
        card.onVolume = { [weak self] in self?.onVolume?($0, $1) }
        card.onVolumeLayout = { [weak self] in
            guard let self else { return }
            onRestingHeightChange?()
            superview?.layoutSubtreeIfNeeded()
            layoutCards()
        }
        card.onMute = { [weak self] in self?.onMute?($0) }
        card.onPiP = { [weak self] in self?.onPiP?($0) }
        card.onFocus = { [weak self] in self?.setHovered(true) }
        card.onInteraction = { [weak self] active in
            self?.interaction = active
            if active { self?.setHovered(true) }
        }
        return card
    }

    override func layout() {
        super.layout()
        layoutCards()
    }

    private func layoutCards() {
        let frames = SidebarMediaPlayerLayout.cards(count: items.count, width: bounds.width, progress: progress, availableHeight: availableHeight, focusedIndex: focusedIndex, volumeHeights: volumeHeights)
        layer?.masksToBounds = contentHeight > bounds.height && isHovered
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, item) in items.enumerated() {
            guard let card = cards[item.id], frames.indices.contains(index) else { continue }
            var placement = frames[index]
            placement.additionsOpacity = CGFloat(reveal.value)
            placement.frame.origin.y -= max(0, contentHeight - bounds.height) - scrollOffset
            card.place(placement)
        }
        CATransaction.commit()
    }

    // MARK: Hover

    /// Cards of the target state: the expanded stack while hovered, the resting deck otherwise.
    private var hotRect: CGRect {
        let frames = SidebarMediaPlayerLayout.cards(count: items.count, width: bounds.width, progress: isHovered ? 1 : 0, availableHeight: availableHeight, focusedIndex: focusedIndex, volumeHeights: volumeHeights)
        return frames.filter { $0.opacity > 0 }.reduce(CGRect.null) {
            $0.union($1.frame.offsetBy(dx: 0, dy: -max(0, contentHeight - bounds.height) + scrollOffset))
        }.intersection(bounds)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        guard hotRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func scrollWheel(with event: NSEvent) {
        guard isHovered, contentHeight > bounds.height else { super.scrollWheel(with: event); return }
        scrollOffset = min(contentHeight - bounds.height, max(0, scrollOffset + event.scrollingDeltaY))
        layoutCards()
    }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { pointerInside = false; setHovered(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTimer?.invalidate(); focusTimer = nil
        if window == nil { setHovered(false, animated: false) }
        else {
            focusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let focused = self.window?.firstResponder as? NSView
                    if let focused, focused.isDescendant(of: self) {
                        if let index = self.items.firstIndex(where: { item in self.cards[item.id].map { focused.isDescendant(of: $0) } == true }), index != self.focusedIndex {
                            self.focusedIndex = index
                            self.scrollOffset = index == 0 ? 0 : max(0, self.contentHeight - self.bounds.height)
                            self.layoutCards()
                        }
                        self.setHovered(true)
                    }
                    else if !self.pointerInside { self.setHovered(false) }
                }
            }
        }
    }

    private func updateHover(_ event: NSEvent) {
        pointerInside = !isHidden && hotRect.contains(convert(event.locationInWindow, from: nil))
        setHovered(pointerInside)
    }

    func setHovered(_ hovered: Bool, animated: Bool = true) {
        let focused = (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
        if !hovered && (interaction || focused) { return }
        guard hovered != isHovered else { return }
        isHovered = hovered
        if hovered { onReveal?() }
        let target: Double = hovered ? 1 : 0
        revealDelay?.cancel()
        if animated, !OrbitMotionPreferences.prefersReducedMotion {
            revealDelay = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
                guard let self else { return }
                reveal.animate(to: target, timing: .init(duration: 0.12, x1: 0, y1: 0, x2: 0.58, y2: 1), in: self)
            }
        } else { reveal.set(target) }
        if animated, !OrbitMotionPreferences.prefersReducedMotion {
            expansion.animate(to: target, timing: OrbitTokens.MediaPlayer.expansion, in: self)
        } else {
            expansion.set(target)
            closeCollapsedVolumeRows()
        }
    }

    private func closeCollapsedVolumeRows() {
        guard !isHovered else { return }
        for card in cards.values { card.setVolumeOpen(false, animated: false) }
    }

    /// Test seam: the card shown for a tab.
    func card(for id: TabOccurrenceID) -> SidebarMediaPlayerCard? { cards[id] }
}

/// One card: a clipped content plate (title row on top, controls row at the bottom) over a
/// shadowed surface. Both scale together about the card's centre.
@MainActor
final class SidebarMediaPlayerCard: NSView {
    typealias Tokens = OrbitTokens.MediaPlayer
    var onBackToTab: ((TabOccurrenceID) -> Void)?
    var onToggle: ((TabOccurrenceID) -> Void)?
    var onPrevious: ((TabOccurrenceID) -> Void)?
    var onNext: ((TabOccurrenceID) -> Void)?
    var onClose: ((TabOccurrenceID) -> Void)?
    var onSeek: ((TabOccurrenceID, Double) -> Void)?
    var onVolume: ((TabOccurrenceID, Double) -> Void)?
    var onMute: ((TabOccurrenceID) -> Void)?
    var onPiP: ((TabOccurrenceID) -> Void)?
    var onInteraction: ((Bool) -> Void)?
    var onFocus: (() -> Void)?

    private let surface = CALayer()
    /// The outer shadow only: masked off inside the card so it never darkens the translucent fill.
    private let shadowCaster = CAShapeLayer()
    private let shadowMask = CAShapeLayer()
    private let plate = SidebarMediaPlayerPlate()
    let titleView = SidebarMediaPlayerTitle()
    let closeButton = SidebarMediaPlayerButton(symbol: "xmark", pointSize: Tokens.closeGlyphSize, label: uiText("Close"))
    let faviconButton = SidebarMediaPlayerButton(symbol: nil, pointSize: Tokens.faviconSize, label: uiText("Back to Tab"))
    let previousButton = SidebarMediaPlayerButton(symbol: "backward.end.fill", pointSize: Tokens.trackSkipGlyphSize, label: uiText("Previous Track"))
    let toggleButton = SidebarMediaPlayerButton(symbol: "pause.fill", pointSize: Tokens.glyphSize, label: uiText("Pause"))
    let nextButton = SidebarMediaPlayerButton(symbol: "forward.end.fill", pointSize: Tokens.trackSkipGlyphSize, label: uiText("Next Track"))
    let volumeButton = SidebarMediaPlayerButton(symbol: "speaker.wave.3.fill", pointSize: Tokens.glyphSize, label: uiText("Adjust Tab Volume"))
    let volumeSlider = SidebarMediaVolumeSlider()
    private let volumeReveal = OrbitTimedAnimator(value: 0)
    private(set) var isVolumeOpen = false
    var volumeHeight: CGFloat { 33 * CGFloat(volumeReveal.value) }
    var onVolumeLayout: (() -> Void)?
    let timeline = SidebarMediaTimeline()
    let muteButton = SidebarMediaPlayerButton(symbol: "speaker.wave.2.fill", pointSize: Tokens.utilityGlyphSize, label: uiText("Mute tab"))
    let pipButton = SidebarMediaPlayerButton(symbol: "rectangle.on.rectangle", pointSize: Tokens.utilityGlyphSize, label: uiText("Enter Picture in Picture"))
    let audioStatus = NSTextField(labelWithString: "")
    private let additions = SidebarMediaPlayerPlate()
    private let seekTooltip = OrbitFrostView(radius: 6)
    private let tooltipOpacity = OrbitTimedAnimator(value: 0)
    private let seekTooltipText = NSTextField(labelWithString: "")
    private(set) var item: SidebarMediaPlayerItem?
    private(set) var placement: SidebarMediaPlayerLayout.Card?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        surface.cornerRadius = Tokens.cornerRadius
        surface.cornerCurve = .continuous
        // The shadow comes from `shadowPath`; an unfilled caster leaves no edge under the card.
        shadowCaster.fillColor = NSColor.clear.cgColor
        shadowCaster.shadowOffset = .zero
        shadowCaster.shadowRadius = Tokens.shadowRadius
        shadowCaster.shadowOpacity = 1
        shadowMask.fillRule = .evenOdd
        shadowCaster.mask = shadowMask
        layer?.addSublayer(shadowCaster)
        layer?.addSublayer(surface)
        addSubview(plate)
        for view in [titleView, closeButton, faviconButton, previousButton, toggleButton, nextButton, volumeButton] {
            plate.addSubview(view)
        }
        plate.addSubview(volumeSlider)
        volumeSlider.isHidden = true
        volumeSlider.onInteraction = { [weak self] in self?.onInteraction?($0) }
        volumeSlider.onChange = { [weak self] value in
            guard let self, let id = item?.id else { return }
            onVolume?(id, value)
        }
        volumeReveal.onChange = { [weak self] value in
            guard let self else { return }
            volumeSlider.alphaValue = value
            volumeSlider.isHidden = value <= 0
            onVolumeLayout?()
        }
        volumeButton.onPress = { [weak self] in
            guard let self else { return }
            onFocus?()
            setVolumeOpen(!isVolumeOpen)
        }
        plate.addSubview(additions)
        for view in [timeline, muteButton, audioStatus, pipButton] { additions.addSubview(view) }
        audioStatus.font = .systemFont(ofSize: 10)
        audioStatus.textColor = .secondaryLabelColor
        audioStatus.lineBreakMode = .byTruncatingTail
        audioStatus.alignment = .center
        muteButton.setAccessibilityIdentifier("sidebar-media-mute")
        pipButton.setAccessibilityIdentifier("sidebar-media-pip")
        timeline.onSeek = { [weak self] seconds in if let self, let id = item?.id { onSeek?(id, seconds) } }
        timeline.onInteraction = { [weak self] active in
            guard let self else { return }
            onInteraction?(active)
            if OrbitMotionPreferences.prefersReducedMotion { tooltipOpacity.set(active ? 1 : 0) }
            else { tooltipOpacity.animate(to: active ? 1 : 0,
                timing: .init(duration: active ? 0.07 : 0.09, x1: 0, y1: 0, x2: 1, y2: 1), in: self) }
        }
        tooltipOpacity.onChange = { [weak self] value in
            self?.seekTooltip.alphaValue = value
            self?.seekTooltip.isHidden = value <= 0
        }
        seekTooltip.isHidden = true
        seekTooltipText.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        seekTooltipText.alignment = .center
        seekTooltip.addSubview(seekTooltipText)
        addSubview(seekTooltip)
        timeline.onPreview = { [weak self] in self?.updateSeekTooltip() }
        muteButton.onPress = { [weak self] in if let self, let id = item?.id { onMute?(id) } }
        pipButton.onPress = { [weak self] in if let self, let id = item?.id { onPiP?(id) } }
        faviconButton.onPress = { [weak self] in if let self, let id = item?.id { onBackToTab?(id) } }
        previousButton.onPress = { [weak self] in if let self, let id = item?.id { onPrevious?(id) } }
        toggleButton.onPress = { [weak self] in if let self, let id = item?.id { onToggle?(id) } }
        nextButton.onPress = { [weak self] in if let self, let id = item?.id { onNext?(id) } }
        closeButton.onPress = { [weak self] in if let self, let id = item?.id { onClose?(id) } }
        faviconButton.setAccessibilityIdentifier("sidebar-media-back-to-tab")
        previousButton.setAccessibilityIdentifier("sidebar-media-previous")
        toggleButton.setAccessibilityIdentifier("sidebar-media-toggle")
        nextButton.setAccessibilityIdentifier("sidebar-media-next")
        volumeButton.setAccessibilityIdentifier("sidebar-media-volume")
        closeButton.setAccessibilityIdentifier("sidebar-media-close")
        volumeButton.isEnabled = false
        for button in [faviconButton, previousButton, toggleButton, nextButton, closeButton, muteButton, pipButton, volumeButton] {
            button.onFocus = { [weak self] in self?.onFocus?() }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        refreshColors()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func apply(_ next: SidebarMediaPlayerItem) {
        guard next != item else { return }
        if item?.trackIdentity != next.trackIdentity || item?.duration != next.duration { _ = timeline.seek.finish(cancel: true) }
        let volumeChanged = item?.volume != next.volume
        item = next
        volumeButton.isEnabled = next.volume != nil
        volumeSlider.isEnabled = next.volume != nil
        if let volume = next.volume { volumeSlider.level = volume }
        else { setVolumeOpen(false, animated: false) }
        titleView.title = next.title
        faviconButton.favicon = next.favicon
        let pausing = next.toggle == .pause
        toggleButton.symbol = pausing ? "pause.fill" : "play.fill"
        toggleButton.label = uiText(pausing ? "Pause" : "Play")
        toggleButton.isEnabled = next.canToggle
        previousButton.isEnabled = next.canGoBack
        nextButton.isEnabled = next.canGoForward
        timeline.seek.duration = next.duration
        timeline.seek.position = next.position
        timeline.seek.playbackRate = next.playbackRate
        timeline.seek.offered = next.canSeek
        timeline.toolTip = timeline.seek.canSeek ? uiText("Playback position") : uiText("Seeking unavailable")
        muteButton.isEnabled = next.isMuted != nil
        muteButton.symbol = next.isMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill"
        muteButton.label = next.isMuted == true ? uiText("Unmute tab") : uiText("Mute tab")
        muteButton.setAccessibilityValue(next.isMuted == true ? 1 : 0)
        muteButton.selectedWash = next.isMuted == true
        muteButton.tint = next.isMuted == true ? .controlAccentColor : Tokens.glyph
        volumeButton.symbol = next.isMuted == true ? "speaker.slash.fill" : "speaker.wave.3.fill"
        pipButton.isEnabled = [.ready, .failed, .active].contains(next.pip)
        pipButton.symbol = next.pip == .requesting ? "hourglass" : "rectangle.on.rectangle"
        pipButton.label = next.pip == .active ? uiText("Exit Picture in Picture") : uiText("Enter Picture in Picture")
        let failureHelp: String
        switch next.pipFailure {
        case .rejected: failureHelp = uiText("The page refused Picture in Picture. Try again.")
        case .timeout: failureHelp = uiText("Picture in Picture did not respond. Try again.")
        case .transport: failureHelp = uiText("The media page could not be reached. Try again.")
        }
        let pipHelp = next.pip == .unavailable ? uiText("Picture in Picture unavailable for this media") :
            next.pip == .failed ? failureHelp : pipButton.label
        pipButton.toolTip = pipHelp
        pipButton.setAccessibilityHelp(pipHelp)
        let status = next.pip == .failed ? uiText("PiP failed") :
            next.isMuted == true ? uiText("Muted") : next.volume.map { String(format: uiText("Volume %ld%%"), Int(($0 * 100).rounded())) } ?? uiText("Tab audio")
        audioStatus.textColor = next.pip == .failed ? .systemRed : .secondaryLabelColor
        if audioStatus.stringValue != status {
            audioStatus.stringValue = status
            if !OrbitMotionPreferences.prefersReducedMotion && !volumeChanged {
                audioStatus.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.08
                    context.timingFunction = CAMediaTimingFunction(name: .linear)
                    audioStatus.animator().alphaValue = 1
                }
            } else { audioStatus.alphaValue = 1 }
        }
        audioStatus.toolTip = next.volume == nil ? uiText("Per-tab volume is unavailable") : uiText("Adjust Tab Volume")
        updateFocusOrder()
        setAccessibilityHelp(next.volume == nil ? pipHelp + ". " + uiText("Per-tab volume is unavailable") : pipHelp)
        setAccessibilityLabel(next.title)
    }

    func setVolumeOpen(_ open: Bool, animated: Bool = true) {
        isVolumeOpen = open && item?.volume != nil
        let target = isVolumeOpen ? 1.0 : 0.0
        if volumeReveal.target == target && volumeReveal.value == target { return }
        if animated && !OrbitMotionPreferences.prefersReducedMotion {
            volumeReveal.animate(to: target, timing: Tokens.volumeExpansion, in: self)
        } else { volumeReveal.set(target) }
        volumeButton.setAccessibilityValue(isVolumeOpen ? 1 : 0)
        updateFocusOrder()
    }

    private func updateFocusOrder() {
        var focusOrder: [NSView] = [faviconButton]
        if timeline.seek.canSeek { focusOrder.append(timeline) }
        if muteButton.isEnabled { focusOrder.append(muteButton) }
        if isVolumeOpen { focusOrder.append(volumeSlider) }
        if pipButton.isEnabled { focusOrder.append(pipButton) }
        focusOrder += [closeButton, previousButton, toggleButton, nextButton, volumeButton].filter { $0.isEnabled }
        for pair in zip(focusOrder, focusOrder.dropFirst()) { pair.0.nextKeyView = pair.1 }
        focusOrder.last?.nextKeyView = focusOrder.first
    }

    func place(_ card: SidebarMediaPlayerLayout.Card) {
        guard card != placement else { return }
        placement = card
        let width = card.scale > 0 ? card.frame.width / card.scale : card.frame.width
        let size = CGSize(width: width, height: card.height)
        frame = CGRect(x: card.frame.midX - size.width / 2, y: card.frame.midY - size.height / 2,
                       width: size.width, height: size.height)
        alphaValue = card.opacity
        isHidden = card.opacity <= 0
        if let layer {
            let pivot = CGPoint(x: size.width * (0.5 - layer.anchorPoint.x), y: size.height * (0.5 - layer.anchorPoint.y))
            var transform = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
            transform = CATransform3DScale(transform, card.scale, card.scale, 1)
            transform = CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
            layer.sublayerTransform = transform
        }
        surface.frame = CGRect(origin: .zero, size: size)
        let outline = CGPath(roundedRect: surface.bounds, cornerWidth: Tokens.cornerRadius,
                             cornerHeight: Tokens.cornerRadius, transform: nil)
        shadowCaster.frame = surface.frame
        shadowCaster.path = outline
        shadowCaster.shadowPath = outline
        let ring = CGMutablePath()
        ring.addRect(surface.bounds.insetBy(dx: -4 * Tokens.shadowRadius, dy: -4 * Tokens.shadowRadius))
        ring.addPath(outline)
        shadowMask.path = ring
        plate.frame = CGRect(origin: .zero, size: size)
        let controlsY = size.height - card.volumeHeight - Tokens.controlsCenterFromBottom
        let slot = CGSize(width: Tokens.controlPitch, height: Tokens.collapsedHeight)
        for (index, button) in [faviconButton, previousButton, toggleButton, nextButton, volumeButton].enumerated() {
            let x = SidebarMediaPlayerLayout.controlCenterX(index, width: size.width)
            button.frame = CGRect(x: x - slot.width / 2, y: controlsY - slot.height / 2, width: slot.width, height: slot.height)
        }
        let closeX = SidebarMediaPlayerLayout.controlCenterX(4, width: size.width)
        closeButton.frame = CGRect(x: closeX - slot.width / 2, y: size.height - card.volumeHeight - 66 + Tokens.titleCenterFromTop - slot.height / 2,
                                   width: slot.width, height: slot.height)
        // The title stops short of the close button's hover square.
        let titleRight = closeX - Tokens.hoverSquare / 2 - 6
        titleView.frame = CGRect(x: Tokens.titleOriginX, y: size.height - card.volumeHeight - 66, width: max(0, titleRight - Tokens.titleOriginX),
                                 height: Tokens.titleCenterFromTop * 2)
        additions.frame = CGRect(x: 0, y: size.height - card.volumeHeight - 124, width: size.width, height: 58)
        timeline.frame = CGRect(x: 12, y: 0, width: size.width - 24, height: 30)
        muteButton.frame = CGRect(x: 12, y: 30, width: 24, height: 28)
        audioStatus.frame = CGRect(x: 40, y: 38, width: size.width - 80, height: 14)
        pipButton.frame = CGRect(x: size.width - 36, y: 30, width: 24, height: 28)
        volumeSlider.alphaValue = card.volumeHeight / 33
        volumeSlider.isHidden = card.volumeHeight <= 0
        volumeSlider.frame = CGRect(x: 8, y: size.height - 33, width: size.width - 16, height: 33)
        additions.alphaValue = card.additionsOpacity
        additions.isHidden = card.height <= 66
        titleView.alphaValue = card.titleOpacity
        closeButton.alphaValue = card.titleOpacity
        closeButton.isHidden = card.titleOpacity <= 0
    }

    private func updateSeekTooltip() {
        seekTooltipText.stringValue = String(format: uiText("%@ of %@"), SidebarMediaSeekState.time(timeline.seek.displayed), SidebarMediaSeekState.time(timeline.seek.finiteDuration))
        let width = seekTooltipText.intrinsicContentSize.width + 16
        let fraction = (timeline.seek.displayed ?? 0) / max(1, timeline.seek.finiteDuration ?? 1)
        seekTooltip.frame = CGRect(x: min(bounds.width - width, max(0, 12 + 150 * fraction - width / 2)), y: -28, width: width, height: 24)
        seekTooltipText.frame = CGRect(x: 8, y: 5, width: width - 16, height: 14)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    /// A Space switch restyles the card in the same frame as the window.
    private func refreshColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.backgroundColor = Tokens.surface.resolvedCGColor(for: effectiveAppearance)
        shadowCaster.shadowColor = Tokens.shadow.resolvedCGColor(for: effectiveAppearance)
        CATransaction.commit()
    }
}

/// Clips the rows to the card's rounded outline.
@MainActor
final class SidebarMediaPlayerPlate: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = OrbitTokens.MediaPlayer.cornerRadius
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
}

/// The tab title, truncated with an ellipsis, on the title row's centre line.
@MainActor
final class SidebarMediaPlayerTitle: NSView {
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    private var font: NSFont { BrandTextStyle.ui.font(size: OrbitTokens.MediaPlayer.titleFontSize) }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: OrbitTokens.MediaPlayer.title,
                                                         .paragraphStyle: paragraph]
        // Cap-height centre on the row's centre line.
        let baseline = bounds.midY + font.capHeight / 2
        let rect = NSRect(x: 0, y: baseline - font.ascender, width: bounds.width, height: ceil(font.ascender - font.descender))
        NSAttributedString(string: title, attributes: attributes)
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// A card control: a 24 pt hover square and a tinted glyph, or the tab's favicon.
/// Disabled controls show neither a hover square nor help.
@MainActor
final class SidebarMediaPlayerButton: OrbitGlyphButton {
    typealias Tokens = OrbitTokens.MediaPlayer
    var onPress: (() -> Void)?
    var onFocus: (() -> Void)?
    var selectedWash = false { didSet { if oldValue != selectedWash { needsDisplay = true } } }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool { onFocus?(); needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 4, dy: 4) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 5, yRadius: 5).fill() }
    override func draw(_ dirtyRect: NSRect) {
        if selectedWash {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
    private let pointSize: CGFloat
    var symbol: String? { didSet { if symbol != oldValue { refreshGlyph() } } }
    var label: String { didSet { if label != oldValue { refreshHelp() } } }
    var favicon: NSImage? { didSet { if favicon !== oldValue { needsDisplay = true } } }

    init(symbol: String?, pointSize: CGFloat, label: String) {
        self.symbol = symbol
        self.pointSize = pointSize
        self.label = label
        super.init(glyph: nil, label: label)
        tint = Tokens.glyph
        disabledTint = Tokens.disabledGlyph
        hoverFill = HoverFill(color: OrbitTokens.Color.State.rowCloseButtonHover, side: Tokens.hoverSquare,
                              radius: OrbitTokens.Radius.closeButton)
        target = self
        action = #selector(press)
        refreshGlyph()
        refreshHelp()
        if symbol == nil {
            customDrawing = { [weak self] _, rect in self?.drawFavicon(in: rect) }
        }
    }
    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool {
        get { super.isEnabled }
        set { super.isEnabled = newValue; refreshHelp() }
    }

    private func refreshGlyph() {
        glyph = symbol.flatMap { OrbitGlyph.symbol($0, pointSize: pointSize, weight: .regular) }
    }

    private func refreshHelp() {
        setAccessibilityLabel(label)
        toolTip = isEnabled && symbol != "xmark" ? label : nil
    }

    @objc private func press() { onPress?() }

    private func drawFavicon(in rect: NSRect) {
        let side = Tokens.faviconSize
        let target = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        guard let favicon, !favicon.isTemplate else {
            if let image = favicon ?? OrbitGlyph.faviconPlaceholder {
                OrbitGlyph.draw(image, centeredIn: rect, tint: Tokens.glyph, in: self)
            }
            return
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        shadow.shadowColor = Tokens.faviconShadow
        shadow.set()
        favicon.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
