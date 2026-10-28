import AppKit

/// One presentation coordinate for clicks and direct manipulation; rows remain live throughout.
@MainActor
final class BrowserLibraryDrawer {
    let animation = LibrarySpringAnimator(value: 0)
    private let driver = LibraryMotionDriver()
    private weak var view: BrowserLibraryView?
    private weak var root: NSView?
    private var leading: NSLayoutConstraint?
    private(set) var isPresented = false
    private var closedWasDelivered = true
    var prefersReducedMotion: () -> Bool = { OrbitMotionPreferences.prefersReducedMotion }
    var shouldFinishClosing: (() -> Bool)?
    private var outsideMonitor: Any?
    var onVisibleWidthChange: ((CGFloat) -> Void)?
    var onProgressChange: ((CGFloat) -> Void)?
    var onOutsideClick: (() -> Void)?
    var onClosed: (() -> Void)?

    init() {
        animation.clock = { [weak driver] in driver?.time ?? CACurrentMediaTime() }
        driver.onFrame = { [weak self] in
            guard let self else { return }
            animation.advance(to: animation.clock?() ?? driver.time)
        }
    }

    func install(view: BrowserLibraryView, root: NSView, leading: NSLayoutConstraint) {
        self.view = view
        self.root = root
        self.leading = leading
        animation.onChange = { [weak self] value in self?.apply(value) }
        animation.onSettle = { [weak self] in self?.driver.stop(); self?.finishIfClosed() }
        view.onGeometryChange = { [weak self] in self?.updateOffset() }
    }

    var width: CGFloat { max(1, view?.bounds.width ?? 420) }
    var sidebarWidth: CGFloat = 228
    private(set) var isInteracting = false

    func setPresented(_ presented: Bool, velocity: Double? = nil) {
        isInteracting = false
        isPresented = presented
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if presented {
            outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.isPresented, let view = self.view,
                          event.window === view.window else { return }
                    let point = view.convert(event.locationInWindow, from: nil)
                    if !view.bounds.contains(point) { self.onOutsideClick?() }
                }
                return event
            }
        }
        closedWasDelivered = false
        view?.acceptsLibraryInput = presented
        view?.isHidden = false
        root?.layoutSubtreeIfNeeded()
        if prefersReducedMotion() {
            driver.stop()
            animation.set(presented ? 1 : 0)
            finishIfClosed()
        } else if view?.window?.isVisible != true {
            driver.stop()
            animation.set(presented ? 1 : 0)
            finishIfClosed()
        } else {
            driver.prepare()
            animation.beginSegment(to: presented ? 1 : 0, spring: LibraryMotion.spring, velocity: velocity ?? 0)
            if animation.isAnimating { driver.start() }
        }
    }

    /// Pixel deltas are applied synchronously, without retargeting a spring during contact.
    func track(visibleWidth: CGFloat) {
        driver.stop()
        isInteracting = true
        closedWasDelivered = false
        view?.isHidden = false
        animation.set(Double(min(width, max(0, visibleWidth)) / width))
    }

    func finishClosing() {
        driver.stop()
        isPresented = false
        isInteracting = false
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        view?.acceptsLibraryInput = false
        animation.set(0)
        finishIfClosed()
    }

    private func apply(_ value: Double) {
        if prefersReducedMotion(), animation.isAnimating {
            animation.set(isPresented ? 1 : 0)
            finishIfClosed()
            return
        }
        // Do not animate an old profile's rows over a newly selected profile.
        if value > 0, !isPresented, shouldFinishClosing?() == true {
            finishClosing()
            return
        }
        updateOffset()
        root?.layoutSubtreeIfNeeded()
    }

    private func updateOffset() {
        guard let view else { return }
        animation.pointsPerUnit = Double(width)
        onProgressChange?(CGFloat(min(1, max(0, animation.value))))
        let offset = -view.bounds.width * (1 - min(1, max(0, animation.value)))
        if leading?.constant != offset { leading?.constant = offset }
        onVisibleWidthChange?(view.bounds.width + offset)
    }

    private func finishIfClosed() {
        guard !isPresented, !closedWasDelivered else { return }
        closedWasDelivered = true
        view?.isHidden = true
        onClosed?()
    }
}
