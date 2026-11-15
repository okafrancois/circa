import AppKit
import QuartzCore

/// Paces a time-based AppKit animation on the refresh of the display that shows the view, instead
/// of a fixed sleep. Callers keep computing progress from elapsed time, so curve and duration do not
/// depend on the frame rate. The loop ends when a frame asks to stop, on `stop()`, or when the view
/// is no longer in a window: that last frame receives `.infinity`, so elapsed-time progress lands on
/// its final value. A view outside a visible window gets that final frame at once.
@MainActor
final class OrbitFrameTicker {
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }
    /// Tests drive frames with `tick()` instead of a display link and ignore window attachment.
    var isManual = false
    private var frame: ((CFTimeInterval) -> Bool)?
    private weak var view: NSView?
    private var generation = 0
    private var link: CADisplayLink?
    private var proxy: OrbitFrameTickerProxy?
    var isRunning: Bool { frame != nil }

    /// `frame` receives the current time and returns whether another frame is needed.
    func start(in view: NSView, frame: @escaping (CFTimeInterval) -> Bool) {
        stop()
        self.view = view
        self.frame = frame
        if isManual { return }
        guard view.window?.isVisible == true else { deliver(.infinity); return }
        let proxy = OrbitFrameTickerProxy { [weak self] in
            guard let self else { return false }
            tick(); return isRunning
        }
        let link = view.displayLink(target: proxy, selector: #selector(OrbitFrameTickerProxy.step(_:)))
        link.add(to: .main, forMode: .common)
        self.proxy = proxy; self.link = link
    }

    /// A finite animation: `step` receives the linear fraction of `duration` elapsed since this call,
    /// clamped to 0...1, and the loop ends on the frame that delivers 1.
    func run(duration: TimeInterval, in view: NSView, step: @escaping (Double) -> Void) {
        let start = clock()
        self.start(in: view) { time in
            let fraction = duration > 0 ? min(1, max(0, (time - start) / duration)) : 1
            step(fraction)
            return fraction < 1
        }
    }

    func tick() {
        deliver(isManual || view?.window != nil ? clock() : .infinity)
    }

    private func deliver(_ time: CFTimeInterval) {
        guard let frame else { return }
        let ticket = generation
        let more = frame(time)
        // A frame may stop this loop or start another one; only end the loop that just ran.
        if ticket == generation, !more || time == .infinity { stop() }
    }

    func stop() {
        generation += 1
        frame = nil
        link?.invalidate(); link = nil; proxy = nil
    }
}

@MainActor
private final class OrbitFrameTickerProxy: NSObject {
    let tick: () -> Bool
    init(_ tick: @escaping () -> Bool) { self.tick = tick }
    @objc func step(_ link: CADisplayLink) { if !tick() { link.invalidate() } }
}
