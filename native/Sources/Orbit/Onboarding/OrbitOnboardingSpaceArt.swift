import AppKit
import BrowserShell
import QuartzCore

/// Layered artwork keeps orbiting objects independent from the paper illustrations.
@MainActor
class OrbitOnboardingSpaceArt: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    func image(_ name: String) -> NSImageView {
        let view = OrbitOnboardingIllustrationView(name)
        view.frame = bounds; view.autoresizingMask = [.width, .height]
        addSubview(view)
        return view
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func artwork(_ name: String, on artworkLayer: CALayer) {
        if let url = BrowserText.secondaryBrandResource(name, extension: "png"), let image = NSImage(contentsOf: url) {
            var rect = NSRect(origin: .zero, size: image.size)
            artworkLayer.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        artworkLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(artworkLayer)
    }
    func animate(_ layer: CALayer?, key: String, values: [Any], duration: Double, delay: Double = 0, repeats: Bool = false) {
        guard !OrbitMotionPreferences.prefersReducedMotion else { return }
        let motion = CAKeyframeAnimation(keyPath: key)
        motion.values = values; motion.duration = duration
        motion.beginTime = CACurrentMediaTime() + delay
        motion.fillMode = .both; motion.isRemovedOnCompletion = false
        motion.repeatCount = repeats ? .infinity : 0
        layer?.add(motion, forKey: "space-art." + key)
    }
}

@MainActor
final class OrbitOnboardingMoonArt: OrbitOnboardingSpaceArt {
    private let moon: NSImageView
    private let frameArt: NSImageView
    private let front: NSImageView
    private let satellite = CALayer()
    override init(frame: NSRect) {
        moon = OrbitOnboardingIllustrationView("onboarding-moon-body")
        frameArt = OrbitOnboardingIllustrationView("onboarding-moon-frame")
        front = OrbitOnboardingIllustrationView("onboarding-moon-front")
        super.init(frame: frame)
        for view in [frameArt, moon, front] { addSubview(view) }
        artwork("sputnik", on: satellite)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        frameArt.frame = bounds; moon.frame = bounds; front.frame = bounds
        let s = bounds.width / 300
        CATransaction.begin(); CATransaction.setDisableActions(true)
        satellite.bounds = NSRect(x: 0, y: 0, width: 80 * s * 0.95, height: 80 * s * 0.95)
        satellite.position = CGPoint(x: 150 * s, y: 150 * s)
        CATransaction.commit()
    }
    func play() {
        layoutSubtreeIfNeeded()
        let s = bounds.width / 300
        OrbitOnboardingMotion.entrance(moon, y: 60 * s, duration: 1.1, delay: 0.2)
        let points = (0...360).map { i -> NSValue in
            let angle = 1 + Double(i) / 360 * 2 * .pi
            let x = 140 * cos(angle), y = 46 * sin(angle), rotation = -Double.pi / 10
            return NSValue(point: NSPoint(x: (150 + x * cos(rotation) - y * sin(rotation)) * s,
                                         y: (150 + x * sin(rotation) + y * cos(rotation)) * s))
        }
        animate(satellite, key: "position", values: points, duration: 4 * .pi, repeats: true)
        animate(satellite, key: "opacity", values: (0...360).map { sin(1 + Double($0) / 360 * 2 * .pi) > -0.2 ? 1.0 : 0.0 }, duration: 4 * .pi, repeats: true)
        satellite.setAffineTransform(CGAffineTransform(rotationAngle: -.pi * 24 / 180))
        layer?.sublayers?.filter { $0.name == "space-art.sparkle" }.forEach { $0.removeFromSuperlayer() }
        for (index, item) in [(30.0, 40.0, 10.0, BrandPalette.ink), (270, 250, 7, BrandPalette.coral), (250, 30, 5, BrandPalette.cobalt)].enumerated() {
            let (x, y, radius, color) = item
            let star = CAShapeLayer(), r = radius * s, k = radius * s * 0.16
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: -r))
            path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: k, y: -k))
            path.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: k, y: k))
            path.addQuadCurve(to: CGPoint(x: -r, y: 0), control: CGPoint(x: -k, y: k))
            path.addQuadCurve(to: CGPoint(x: 0, y: -r), control: CGPoint(x: -k, y: -k))
            star.name = "space-art.sparkle"
            star.path = path; star.fillColor = color.cgColor; star.position = CGPoint(x: x * s, y: y * s)
            layer?.addSublayer(star)
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = (0...60).map { 0.45 + 0.55 * (1 + cos(Double($0) / 60 * 2 * .pi)) / 2 }
            pulse.duration = [1.0, 1.4, 1.6][index] * 2; pulse.repeatCount = .infinity
            if !OrbitMotionPreferences.prefersReducedMotion {
                star.add(pulse, forKey: "twinkle")
                let size = CAKeyframeAnimation(keyPath: "transform.scale")
                size.values = (0...60).map { 0.55 + 0.45 * (1 + cos(Double($0) / 60 * 2 * .pi)) / 2 }
                size.duration = pulse.duration; size.repeatCount = .infinity
                star.add(size, forKey: "twinkle-size")
            }
        }
    }
}

@MainActor
final class OrbitOnboardingSyncArt: OrbitOnboardingSpaceArt {
    private let first: NSImageView
    private let second: NSImageView
    private let link: NSImageView
    override init(frame: NSRect) {
        first = OrbitOnboardingIllustrationView("onboarding-sync-first")
        second = OrbitOnboardingIllustrationView("onboarding-sync-second")
        link = OrbitOnboardingIllustrationView("onboarding-sync-link")
        super.init(frame: frame)
        for view in [link, first, second] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); for view in [link, first, second] { view.frame = bounds } }
    func play() {
        for (view, direction, duration) in [(first, -1.0, 3.0), (second, 1.0, 3.4)] {
            let values = (0...120).map { direction * 6 * Double(bounds.width / 240) * (1 - cos(Double($0) / 120 * 2 * .pi)) / 2 }
            animate(view.layer, key: "transform.translation.y", values: values, duration: duration * 2, repeats: true)
        }
    }
    func select(_ enabled: Bool) { second.alphaValue = enabled ? 1 : 0.25; link.alphaValue = enabled ? 1 : 0 }
}

@MainActor
final class OrbitOnboardingHorizonArt: OrbitOnboardingSpaceArt {
    private let moon = OrbitOnboardingIllustrationView("onboarding-horizon-moon")
    private let flag = OrbitOnboardingIllustrationView("onboarding-horizon-flag")
    private let flagRise = NSView()
    private let satellite = OrbitOnboardingIllustrationView("onboarding-horizon-satellite")
    private let stars = (0..<5).map { OrbitOnboardingIllustrationView("onboarding-horizon-star-" + String($0)) }
    private static let centers = [CGPoint(x: 140, y: 60), CGPoint(x: 660, y: 30), CGPoint(x: 90, y: 130),
                                  CGPoint(x: 470, y: 40), CGPoint(x: 300, y: 70)]
    override init(frame: NSRect) {
        super.init(frame: frame)
        flagRise.wantsLayer = true
        flagRise.addSubview(flag)
        for view in [moon, flagRise, satellite] + stars { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        for view in [moon, flagRise, satellite] + stars { view.frame = bounds }
        flag.frame = flagRise.bounds
    }
    func play() {
        layoutSubtreeIfNeeded()
        let scale = min(bounds.width / 760, bounds.height / 200)
        let offset = CGPoint(x: (bounds.width - 760 * scale) / 2, y: (bounds.height - 200 * scale) / 2)
        OrbitOnboardingMotion.animate(moon.layer, key: "transform.translation.y", from: 170 * scale, to: 0, duration: 1.3, delay: 0.2)
        OrbitOnboardingMotion.animate(flagRise.layer, key: "transform.translation.y", from: 170 * scale, to: 0, duration: 1.3, delay: 0.2)
        func pivot(_ point: CGPoint, in view: NSView) -> CGPoint {
            let top = point.y * scale + offset.y
            return CGPoint(x: point.x * scale + offset.x, y: view.isFlipped ? top : bounds.height - top)
        }
        let flagPivot = pivot(CGPoint(x: 570, y: 112), in: flag)
        let flags = (0...90).map { i -> NSValue in
            let t = Double(i) / 90 - 1, value = 1 + t * t * (4 * t + 3)
            var transform = CATransform3DMakeTranslation(flagPivot.x, flagPivot.y, 0)
            transform = CATransform3DScale(transform, 1, value, 1)
            transform = CATransform3DTranslate(transform, -flagPivot.x, -flagPivot.y, 0)
            return NSValue(caTransform3D: transform)
        }
        animate(flag.layer, key: "transform", values: flags, duration: 0.5, delay: 1.2)
        for (index, star) in stars.enumerated() {
            let center = pivot(Self.centers[index], in: star)
            let transforms = (0...90).map { i -> NSValue in
                let t = Double(i) / 90 - 1, value = 1 + t * t * (4 * t + 3)
                var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
                transform = CATransform3DScale(transform, value, value, 1)
                transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
                return NSValue(caTransform3D: transform)
            }
            animate(star.layer, key: "transform", values: transforms, duration: 0.5, delay: 0.9 + Double(index) * 0.1)
            if !OrbitMotionPreferences.prefersReducedMotion {
                let pulse = CAKeyframeAnimation(keyPath: "transform")
                let twinkleDuration = [1.0, 1.4, 1.6, 0.9, 1.2][index] * 2
                let loopStart = 1.4 + Double(index) * 0.1
                pulse.values = (0...120).map { frame -> NSValue in
                    let phase = Double(frame) / 120 + loopStart / twinkleDuration
                    let value = 0.55 + 0.45 * (1 + cos(phase * 2 * .pi)) / 2
                    var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
                    transform = CATransform3DScale(transform, value, value, 1)
                    transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
                    return NSValue(caTransform3D: transform)
                }
                pulse.duration = twinkleDuration
                pulse.beginTime = CACurrentMediaTime() + loopStart
                pulse.repeatCount = .infinity
                pulse.fillMode = .forwards
                pulse.isRemovedOnCompletion = false
                star.layer?.add(pulse, forKey: "space-art.twinkle")
                animate(star.layer, key: "opacity", values: (0...120).map {
                    0.45 + 0.55 * (1 + cos(Double($0) / 120 * 2 * .pi)) / 2
                }, duration: pulse.duration, repeats: true)
            }
        }
        let drift = (0...120).map { (1 - cos(Double($0) / 120 * 2 * .pi)) / 2 }
        animate(satellite.layer, key: "transform.translation.x", values: drift.map { $0 * 30 * scale }, duration: 10, repeats: true)
        animate(satellite.layer, key: "transform.translation.y", values: drift.map { -$0 * 8 * scale }, duration: 10, repeats: true)
    }
}

@MainActor
final class OrbitOnboardingTrajectoryArt: OrbitOnboardingSpaceArt {
    private let pathArt = OrbitOnboardingIllustrationView("onboarding-trajectory")
    private let satellite = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(pathArt)
        artwork("sputnik", on: satellite)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout(); pathArt.frame = bounds
        let side = 64 * bounds.width / 280
        CATransaction.begin(); CATransaction.setDisableActions(true)
        satellite.bounds = NSRect(x: 0, y: 0, width: side, height: side)
        satellite.position = CGPoint(x: side / 2, y: side / 2)
        CATransaction.commit()
    }
    func play() {
        layoutSubtreeIfNeeded()
        let scale = bounds.width / 280
        let samples = (0...600).map { index -> CGPoint in
            let t = Double(index) / 600, u = 1 - t
            return CGPoint(x: u*u*u*40 + 3*u*u*t*70 + 3*u*t*t*210 + t*t*t*236,
                           y: u*u*u*150 + 3*u*u*t*20 + 3*u*t*t*20 + t*t*t*96)
        }
        var lengths: [CGFloat] = [0]
        for index in 1..<samples.count {
            lengths.append(lengths[index - 1] + hypot(samples[index].x - samples[index - 1].x,
                                                      samples[index].y - samples[index - 1].y))
        }
        let total = lengths.last ?? 1
        var points: [NSValue] = [], angles: [Double] = [], opacity: [Double] = []
        for frame in 0...148 {
            let fraction = min(1, Double(frame) / 40 / 3.2)
            let progress = fraction < 0.5 ? 2 * fraction * fraction : 1 - pow(-2 * fraction + 2, 2) / 2
            let target = total * progress
            let index = min(600, max(1, lengths.firstIndex(where: { $0 >= target }) ?? 600))
            let ratio = (target - lengths[index - 1]) / max(0.001, lengths[index] - lengths[index - 1])
            let a = samples[index - 1], b = samples[index]
            let point = CGPoint(x: a.x + (b.x - a.x) * ratio, y: a.y + (b.y - a.y) * ratio)
            points.append(NSValue(point: NSPoint(x: point.x * scale, y: (point.y - 12) * scale)))
            angles.append(atan2(b.y - a.y, b.x - a.x) + .pi)
            opacity.append(progress > 0.03 && progress < 0.93 ? 1 : 0)
        }
        animate(satellite, key: "position", values: points, duration: 3.7, repeats: true)
        animate(satellite, key: "transform.rotation.z", values: angles, duration: 3.7, repeats: true)
        animate(satellite, key: "opacity", values: opacity, duration: 3.7, repeats: true)
    }
}
