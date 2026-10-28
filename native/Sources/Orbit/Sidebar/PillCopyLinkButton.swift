import AppKit
import QuartzCore

/// Whole-glyph bounds and contrast reconstructed from 's 60 Hz copy recording.
/// These samples describe the observed transition, not Orbit's original animation API.
@MainActor
final class PillCopyLinkButton: OrbitGlyphButton {
    private struct Frame {
        let time: Double
        let scale: CGFloat
        let opacity: CGFloat
        init(_ time: Double, _ scale: CGFloat, _ opacity: CGFloat) {
            self.time = time; self.scale = scale; self.opacity = opacity
        }
    }
    private enum Phase { case idle, confirming(CFTimeInterval), returning(CFTimeInterval) }
    @MainActor private final class Tick: NSObject {
        weak var button: PillCopyLinkButton?
        @objc func step(_ link: CADisplayLink) {
            guard let button else { link.invalidate(); return }
            button.advance(to: link.targetTimestamp)
        }
    }
    private static let linkImage = OrbitGlyph.symbol("link", pointSize: 14, weight: .regular)
    private static let checkImage = OrbitGlyph.symbol("checkmark", pointSize: 14, weight: .regular)
    private static let linkOut: [Frame] = [
        .init(0, 1, 1), .init(0.016, 1, 1), .init(0.033, 0.90, 0.83),
        .init(0.051, 0.72, 0.67), .init(0.068, 0.55, 0.43),
        .init(0.085, 0.30, 0.30), .init(0.103, 0.10, 0.03), .init(0.12, 0, 0)
    ]
    private static let checkIn: [Frame] = [
        .init(0.19, 0, 0), .init(0.207, 0.20, 0.15), .init(0.224, 0.40, 0.34),
        .init(0.241, 0.55, 0.46), .init(0.258, 0.67, 0.56), .init(0.276, 0.79, 0.61),
        .init(0.293, 0.88, 0.70), .init(0.310, 0.96, 0.74), .init(0.327, 1, 0.78),
        .init(0.344, 1, 0.86), .init(0.361, 1, 0.94), .init(0.38, 1, 1)
    ]
    private static let checkOut: [Frame] = [
        .init(0, 1, 1), .init(0.017, 0.96, 1), .init(0.036, 0.88, 1),
        .init(0.053, 0.79, 1), .init(0.070, 0.71, 1), .init(0.086, 0.63, 1),
        .init(0.106, 0.54, 1), .init(0.122, 0.50, 1), .init(0.14, 0.42, 1),
        .init(0.159, 0.38, 1), .init(0.177, 0.30, 0.7), .init(0.195, 0.20, 0.2), .init(0.212, 0, 0)
    ]
    private static let linkIn: [Frame] = [
        .init(0.13, 0, 0), .init(0.158, 0.10, 0), .init(0.177, 0.30, 0.2),
        .init(0.195, 0.60, 0.6), .init(0.213, 0.75, 0.8), .init(0.231, 0.90, 0.95),
        .init(0.248, 1, 1), .init(0.266, 1.07, 1), .init(0.283, 1.10, 1),
        .init(0.30, 1.14, 1), .init(0.318, 1.14, 1), .init(0.335, 1.10, 1),
        .init(0.355, 1.07, 1), .init(0.387, 1.05, 1), .init(0.405, 1.03, 1),
        .init(0.422, 1, 1), .init(0.458, 0.99, 1), .init(0.492, 0.98, 1), .init(0.6, 1, 1)
    ]
    private var phase: Phase = .idle
    private var resetTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var tick: Tick?
    private(set) var isShowingConfirmation = false

    init() {
        super.init(glyph: nil, label: uiText("Copy URL"))
        hoverFill = HoverFill(color: OrbitTokens.Color.State.standaloneButton, side: 28, radius: 10)
    }
    required init?(coder: NSCoder) { nil }

    func confirmCopied() {
        resetTask?.cancel()
        // A second click extends the existing confirmation without flashing the link again.
        if !isShowingConfirmation { phase = .confirming(CACurrentMediaTime()) }
        isShowingConfirmation = true
        startTicking()
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .announcementRequested,
            userInfo: [.announcement: uiText("Copied"), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled, let self else { return }
            isShowingConfirmation = false
            phase = .returning(CACurrentMediaTime())
            startTicking()
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let reduced = OrbitMotionPreferences.prefersReducedMotion
        switch phase {
        case .idle: draw(Self.linkImage, frame: .init(0, 1, 1))
        case .confirming(let start):
            if reduced { draw(Self.checkImage, frame: .init(0, 1, 1)) }
            else {
                let time = CACurrentMediaTime() - start
                draw(Self.linkImage, frame: Self.sample(Self.linkOut, at: time))
                draw(Self.checkImage, frame: Self.sample(Self.checkIn, at: time))
            }
        case .returning(let start):
            if reduced { draw(Self.linkImage, frame: .init(0, 1, 1)) }
            else {
                let time = CACurrentMediaTime() - start
                draw(Self.checkImage, frame: Self.sample(Self.checkOut, at: time))
                draw(Self.linkImage, frame: Self.sample(Self.linkIn, at: time))
            }
        }
    }

    private static func sample(_ frames: [Frame], at time: Double) -> Frame {
        guard let first = frames.first, let last = frames.last else { return .init(time, 0, 0) }
        if time <= first.time { return first }
        for (left, right) in zip(frames, frames.dropFirst()) where time <= right.time {
            let progress = CGFloat((time - left.time) / (right.time - left.time))
            return .init(time, left.scale + (right.scale - left.scale) * progress,
                         left.opacity + (right.opacity - left.opacity) * progress)
        }
        return last
    }

    private func draw(_ image: NSImage?, frame: Frame) {
        guard let image, frame.scale > 0, frame.opacity > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.scaleBy(x: frame.scale, y: frame.scale)
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        let color = isEnabled ? tint : disabledTint
        OrbitGlyph.draw(image, centeredIn: bounds,
                      tint: color.withAlphaComponent(color.alphaComponent * frame.opacity), in: self)
        context.restoreGState()
    }

    private func startTicking() {
        guard displayLink == nil, !OrbitMotionPreferences.prefersReducedMotion, window?.isVisible == true else { return }
        let tick = Tick(); tick.button = self
        let link = displayLink(target: tick, selector: #selector(Tick.step(_:)))
        link.add(to: .main, forMode: .common)
        self.tick = tick; displayLink = link
    }
    private func advance(to time: CFTimeInterval) {
        needsDisplay = true
        switch phase {
        case .idle: stopTicking()
        case .confirming(let start): if time - start >= 0.4 { stopTicking() }
        case .returning(let start): if time - start >= 0.62 { phase = .idle; stopTicking() }
        }
    }
    private func stopTicking() { displayLink?.invalidate(); displayLink = nil; tick = nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            resetTask?.cancel(); stopTicking(); phase = .idle; isShowingConfirmation = false
        }
    }
}
