import AppKit

@MainActor
protocol OrbitCancellable: AnyObject { func cancel() }

/// Main-run-loop timer that also fires during menu and resize tracking.
@MainActor
final class OrbitRunLoopTimer: OrbitCancellable {
    private var timer: Timer?

    init(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { action() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

/// UX-HOVER state machine for the hidden sidebar (design §8.2, reconstruction [L] C11): the
/// pointer must rest in the left-edge band for the dwell time before the floating sidebar appears,
/// so a pointer crossing the edge on its way elsewhere never reveals it; once revealed it stays
/// while the pointer is over it (or the edge band) and leaves after the leave delay.
/// Holds (menus, editing inside the sidebar, pressed buttons) keep it open.
@MainActor
final class OrbitSidebarHoverReveal {
    enum Phase: Equatable { case disabled, idle, arming, revealed, leaving }

    private(set) var phase: Phase = .disabled
    var dwell = OrbitTokens.Motion.sidebarHoverDwell
    var leaveDelay = OrbitTokens.Motion.sidebarHoverLeaveDelay
    /// Timer factory; tests substitute a manual clock.
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> any OrbitCancellable = { OrbitRunLoopTimer(after: $0, $1) }
    /// True while something must keep the revealed sidebar open.
    var isHeld: () -> Bool = { false }
    /// Whether the pointer is currently inside the keep region (checked when a hold ends).
    var isPointerInside: () -> Bool = { true }
    var onRevealChange: ((Bool) -> Void)?
    private var pending: (any OrbitCancellable)?

    var isRevealed: Bool { phase == .revealed || phase == .leaving }

    /// Enabled only while the sidebar is hidden and settled. Disabling never animates by itself:
    /// the owner decides what happens to a revealed panel (dock it or dismiss it).
    func setEnabled(_ enabled: Bool) {
        cancelPending()
        if enabled {
            if phase == .disabled { phase = .idle }
        } else {
            phase = .disabled
        }
    }

    func pointerEnteredEdge() {
        guard phase == .idle else {
            if phase == .leaving { keep() }
            return
        }
        phase = .arming
        pending = schedule(dwell) { [weak self] in self?.dwellElapsed() }
    }

    func pointerExitedEdge() {
        guard phase == .arming else { return }
        cancelPending()
        phase = .idle
    }

    func pointerEnteredPanel() {
        if phase == .leaving { keep() }
    }

    func pointerExitedPanel() {
        guard phase == .revealed else { return }
        guard !isHeld() else { return }
        phase = .leaving
        pending = schedule(leaveDelay) { [weak self] in self?.leaveElapsed() }
    }

    /// Re-evaluates after a hold ended (menu closed, editing ended, button released).
    func holdDidChange() {
        if isHeld() {
            if phase == .leaving { keep() }
        } else if phase == .revealed, !isPointerInside() {
            pointerExitedPanel()
        }
    }

    /// Dismisses immediately (Escape, focus moved to the page by keyboard).
    func dismiss() {
        guard isRevealed else { return }
        cancelPending()
        phase = .idle
        onRevealChange?(false)
    }

    private func keep() {
        cancelPending()
        phase = .revealed
    }

    private func dwellElapsed() {
        pending = nil
        guard phase == .arming else { return }
        phase = .revealed
        onRevealChange?(true)
    }

    private func leaveElapsed() {
        pending = nil
        guard phase == .leaving else { return }
        if isHeld() {
            phase = .revealed
            return
        }
        phase = .idle
        onRevealChange?(false)
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }
}

/// Owns the two tracking areas of the hover reveal and translates them into state-machine events.
@MainActor
final class OrbitSidebarHoverTracker: NSResponder {
    private enum Region: String { case edge, keep }
    private static let regionKey = "orbit.sidebar.hover.region"
    let reveal: OrbitSidebarHoverReveal
    private weak var view: NSView?
    private var areas: [NSTrackingArea] = []
    private(set) var edgeRect: CGRect?
    private(set) var keepRect: CGRect?

    init(reveal: OrbitSidebarHoverReveal) {
        self.reveal = reveal
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    /// Rects are in `view`'s coordinates; nil removes the region.
    func update(in view: NSView, edge: CGRect?, keep: CGRect?) {
        guard view !== self.view || edge != edgeRect || keep != keepRect else { return }
        for area in areas { self.view?.removeTrackingArea(area) }
        areas = []
        self.view = view
        edgeRect = edge
        keepRect = keep
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow]
        if let edge {
            let area = NSTrackingArea(rect: edge, options: options, owner: self, userInfo: [Self.regionKey: Region.edge.rawValue])
            view.addTrackingArea(area)
            areas.append(area)
        }
        if let keep {
            let area = NSTrackingArea(rect: keep, options: options.union(.assumeInside), owner: self,
                                      userInfo: [Self.regionKey: Region.keep.rawValue])
            view.addTrackingArea(area)
            areas.append(area)
        }
    }

    func isPointerInsideKeepRegion() -> Bool {
        guard let view, let window = view.window, let keepRect else { return false }
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return keepRect.contains(point)
    }

    override func mouseEntered(with event: NSEvent) {
        switch region(of: event) {
        case .edge: reveal.pointerEnteredEdge()
        case .keep: reveal.pointerEnteredPanel()
        case nil: break
        }
    }

    override func mouseExited(with event: NSEvent) {
        switch region(of: event) {
        case .edge: reveal.pointerExitedEdge()
        case .keep: reveal.pointerExitedPanel()
        case nil: break
        }
    }

    private func region(of event: NSEvent) -> Region? {
        (event.trackingArea?.userInfo?[Self.regionKey] as? String).flatMap(Region.init(rawValue:))
    }
}
