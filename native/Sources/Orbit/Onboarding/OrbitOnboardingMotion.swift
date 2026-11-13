import AppKit
import QuartzCore
import BrowserShell

@MainActor
enum OrbitOnboardingMotion {
    static func pop(_ view: NSView, from: CGFloat, duration: Double) {
        guard !OrbitMotionPreferences.prefersReducedMotion, let layer = view.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = (0...60).map { frame -> NSValue in
            let t = Double(frame) / 60 - 1
            let progress = 1 + 4 * t * t * t + 3 * t * t
            let scale = from + (1 - from) * progress
            var transform = CATransform3DMakeTranslation(view.bounds.midX, view.bounds.midY, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            transform = CATransform3DTranslate(transform, -view.bounds.midX, -view.bounds.midY, 0)
            return NSValue(caTransform3D: transform)
        }
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: "orbit.choicePop")
    }

    static let curve = CAMediaTimingFunction(controlPoints: 0.19, 1, 0.22, 1)
    static func animate(_ layer: CALayer?, key: String, from: CGFloat, to: CGFloat, duration: Double,
                        delay: Double = 0, stick: Bool = false, outgoing: Bool = false) {
        guard let layer else { return }
        let reduced = OrbitMotionPreferences.prefersReducedMotion
        guard !reduced || key == "opacity" else { return }
        let animation: CAPropertyAnimation
        if outgoing && !reduced {
            let frames = CAKeyframeAnimation(keyPath: key)
            frames.values = (0...90).map { i in from + (to - from) * CGFloat(pow(Double(i) / 90, 3)) }
            animation = frames
        } else if stick && !reduced {
            let frames = CAKeyframeAnimation(keyPath: key)
            frames.values = (0...90).map { i -> CGFloat in
                let t = Double(i) / 90 - 1
                let y = 1 + t * t * (2.6 * t + 1.6)
                return from + (to - from) * CGFloat(y)
            }
            animation = frames
        } else if !reduced {
            let frames = CAKeyframeAnimation(keyPath: key)
            frames.values = (0...90).map { i -> CGFloat in
                let t = Double(i) / 90
                return from + (to - from) * CGFloat(1 - pow(1 - t, 4))
            }
            animation = frames
        } else {
            let basic = CABasicAnimation(keyPath: key)
            basic.fromValue = from; basic.toValue = to
            basic.timingFunction = CAMediaTimingFunction(name: .linear)
            animation = basic
        }
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = reduced ? 0.25 : duration
        animation.beginTime = CACurrentMediaTime() + (reduced ? 0 : delay)
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "orbit.onboarding." + key)
    }
    static func entrance(_ view: NSView, y: CGFloat = 18, duration: Double = 1, delay: Double = 0) {
        animate(view.layer, key: "transform.translation.y", from: view.superview?.isFlipped == true ? y : -y, to: 0, duration: duration, delay: delay)
        animate(view.layer, key: "opacity", from: 0, to: 1, duration: duration, delay: delay)
    }
}

@MainActor
final class OrbitOnboardingMarkView: NSView {
    private let image = NSImageView()
    private let vector = NSView()
    private var bands: [CAShapeLayer] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        image.image = BrandFonts.mark
        image.imageScaling = .scaleProportionallyUpOrDown
        image.frame = bounds; image.autoresizingMask = [.width, .height]
        addSubview(image)
        if let (box, strokes) = OrbitOnboardingMarkPaths.read() {
            vector.frame = bounds; vector.autoresizingMask = [.width, .height]
            vector.bounds = box; vector.wantsLayer = true
            vector.layer?.isGeometryFlipped = false
            for stroke in strokes {
                let shape = CAShapeLayer(); shape.frame = box
                shape.path = stroke.path; shape.fillColor = nil; shape.strokeColor = stroke.color.cgColor
                shape.lineWidth = stroke.width; shape.lineCap = .round
                vector.layer?.addSublayer(shape)
                if let rgb = stroke.color.usingColorSpace(.sRGB), min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) < 0.99 { bands.append(shape) }
            }
            if !bands.isEmpty { image.isHidden = true; addSubview(vector) }
        }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func land(delay: Double = 0.1, drawBands: Bool = true) {
        for (index, band) in bands.enumerated() where drawBands {
            let draw = CAKeyframeAnimation(keyPath: "strokeEnd")
            draw.values = (0...90).map { 1 - pow(1 - Double($0) / 90, 4) }
            draw.duration = 0.9
            draw.beginTime = CACurrentMediaTime() + delay + 0.25 + Double(index) * 0.12
            draw.fillMode = .both
            if !OrbitMotionPreferences.prefersReducedMotion { band.add(draw, forKey: "orbit.band.draw") }
        }
        guard !OrbitMotionPreferences.prefersReducedMotion else { return }
        let reveal = CAKeyframeAnimation(keyPath: "transform")
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        reveal.values = (0...90).map { i -> NSValue in
            let t = Double(i) / 90 - 1
            let value = 1 + t * t * (2.6 * t + 1.6)
            let revealProgress = min(1, max(0, (delay + Double(i) / 90 - 0.38) / 0.5))
            let rise = drawBands ? 0 : 31.58 * pow(1 - revealProgress, 4)
            var transform = CATransform3DMakeTranslation(center.x, center.y + rise, 0)
            transform = CATransform3DScale(transform, value, value, 1)
            transform = CATransform3DRotate(transform, -.pi * (1 - value), 0, 0, 1)
            transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
            return NSValue(caTransform3D: transform)
        }
        reveal.timingFunction = CAMediaTimingFunction(name: .linear)
        reveal.duration = 1; reveal.beginTime = CACurrentMediaTime() + delay
        reveal.fillMode = .both; reveal.isRemovedOnCompletion = false
        layer?.add(reveal, forKey: "orbit.mark.entry")
    }
}
