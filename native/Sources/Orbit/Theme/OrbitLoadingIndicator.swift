import AppKit
import QuartzCore

/// Page-loading indicator of (D46, measured + ): no glow around
/// the card, but a 4 pt capsule centred on the card in the window's top margin. While the request is
/// pending it is 47 wide and pulses (period 1.59 s); once the page is in progress it widens to
/// 127.5 (spring 0.78 / 0.90) with a dark sweep (period 1.12 s). Neutral colours: black 21 % track,
/// black 78 % fill. Decorative: it never takes events.
@MainActor
final class OrbitLoadingIndicatorView: NSView {
    enum Phase: Equatable {
        case idle
        /// Request sent, nothing committed yet.
        case waiting
        /// The new document is committed and loading.
        case progress

        /// Engine-neutral mapping of the navigation state: loading with a provisional URL different from
        /// the committed one is waiting, otherwise progress (: the engines publish no
        /// progress fraction).
        static func resolve(isLoading: Bool, url: URL?, committedURL: URL?) -> Phase {
            guard isLoading else { return .idle }
            return url != nil && url != committedURL ? .waiting : .progress
        }
    }

    private typealias Content = OrbitTokens.Metrics.Content
    private let track = CALayer()
    private let fill = CALayer()
    private(set) var phase: Phase = .idle
    private var placement: (card: CGRect, rootSize: CGSize)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(track)
        track.addSublayer(fill)
        track.masksToBounds = true
        isHidden = true
        setAccessibilityElement(false)
        refreshColors()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Width of the capsule for the current phase.
    var capsuleWidth: CGFloat {
        phase == .progress ? Content.loadingCapsuleProgressWidth : Content.loadingCapsuleWaitingWidth
    }

    /// Places the capsule centred on `card` (root coordinates, top-left origin) in the margin above it;
    /// hidden when the margin cannot hold it (full screen with the sidebar hidden).
    func place(over card: CGRect, in rootSize: CGSize) {
        placement = (card, rootSize)
        let height = Content.loadingCapsuleHeight
        let width = capsuleWidth
        let topLeft = CGRect(x: card.midX - width / 2, y: (card.minY - height) / 2, width: width, height: height)
        let target = CGRect(x: topLeft.minX, y: rootSize.height - topLeft.maxY, width: width, height: height)
        if frame != target { frame = target }
        let hidden = phase == .idle || card.minY < height + 2
        if isHidden != hidden { isHidden = hidden }
        layoutCapsule()
    }

    func setPhase(_ newPhase: Phase, animated: Bool) {
        guard newPhase != phase else { return }
        let previousWidth = capsuleWidth
        phase = newPhase
        if let placement { place(over: placement.card, in: placement.rootSize) } else { isHidden = newPhase == .idle }
        restartAnimations(fromWidth: previousWidth, animated: animated)
    }

    override func layout() {
        super.layout()
        layoutCapsule()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func layoutCapsule() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        fill.cornerRadius = bounds.height / 2
        fill.frame = phase == .progress
            ? CGRect(x: 0, y: 0, width: bounds.width * Self.sweepFraction, height: bounds.height)
            : bounds
        CATransaction.commit()
    }

    ///  — length of the dark sweep segment, as a fraction of the capsule.
    static let sweepFraction: CGFloat = 0.4

    private func restartAnimations(fromWidth previousWidth: CGFloat, animated: Bool) {
        fill.removeAllAnimations()
        layer?.removeAnimation(forKey: "orbit.loading.expand")
        layoutCapsule()
        guard phase != .idle, animated, !OrbitMotionPreferences.prefersReducedMotion else { return }
        switch phase {
        case .waiting:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0
            pulse.toValue = 1
            pulse.duration = OrbitTokens.Motion.loadingPulsePeriod / 2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fill.add(pulse, forKey: "orbit.loading.pulse")
        case .progress:
            let sweep = CABasicAnimation(keyPath: "position.x")
            let segment = capsuleWidth * Self.sweepFraction
            sweep.fromValue = -segment / 2
            sweep.toValue = capsuleWidth + segment / 2
            sweep.duration = OrbitTokens.Motion.loadingSweepPeriod
            sweep.repeatCount = .infinity
            fill.add(sweep, forKey: "orbit.loading.sweep")
            if previousWidth != capsuleWidth, let layer {
                let expand = OrbitTokens.Motion.loadingExpand.animation(keyPath: "bounds.size.width")
                expand.fromValue = previousWidth
                expand.toValue = capsuleWidth
                layer.add(expand, forKey: "orbit.loading.expand")
            }
        case .idle:
            break
        }
    }

    private func refreshColors() {
        track.backgroundColor = OrbitTokens.Color.State.loadingTrack.resolvedCGColor(for: effectiveAppearance)
        fill.backgroundColor = OrbitTokens.Color.State.loadingFill.resolvedCGColor(for: effectiveAppearance)
    }
}
