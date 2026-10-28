import AppKit
import CoreVideo

/// Orbit's Motion.CoreVideoDriver passes the current/target video timestamps through to
/// SpringAnimation. On ProMotion these can span two refresh intervals. Using wall time
/// with the same response would therefore produce a visibly different transition.
final class LibraryMotionDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (start: Double, end: Double)?
    private var generation = 0
    private var link: CVDisplayLink?
    @MainActor private(set) var time: Double = 0
    @MainActor var onFrame: (() -> Void)?

    @MainActor init() {}

    @MainActor func prepare() {
        if link == nil { time = CACurrentMediaTime() }
    }

    @MainActor func start() {
        guard link == nil else { return }
        var newLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &newLink) == kCVReturnSuccess,
              let newLink else { return }
        CVDisplayLinkSetOutputCallback(newLink, { _, current, target, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let driver = Unmanaged<LibraryMotionDriver>.fromOpaque(context).takeUnretainedValue()
            driver.receive(start: Double(current.pointee.videoTime) / Double(current.pointee.videoTimeScale),
                           end: Double(target.pointee.videoTime) / Double(target.pointee.videoTimeScale))
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        link = newLink
        CVDisplayLinkStart(newLink)
    }

    @MainActor func stop() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
        lock.lock()
        generation += 1
        pending = nil
        lock.unlock()
    }

    private func receive(start: Double, end: Double) {
        lock.lock()
        let shouldSchedule = pending == nil
        pending = (pending?.start ?? start, end)
        let ticket = generation
        lock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in self?.deliver(ticket: ticket) }
    }

    @MainActor private func deliver(ticket: Int) {
        lock.lock()
        guard generation == ticket else { lock.unlock(); return }
        let frame = pending
        pending = nil
        lock.unlock()
        guard link != nil, let frame else { return }
        time += max(0, frame.end - frame.start)
        onFrame?()
    }

    deinit { if let link { CVDisplayLinkStop(link) } }
}
