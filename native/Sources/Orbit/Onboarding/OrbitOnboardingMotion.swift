import AppKit
import QuartzCore
import BrowserShell

@MainActor
enum OrbitOnboardingMotion {
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
            // Invert x(t) to sample the overshooting cubic path at uniform times.
            frames.values = (0...90).map { i -> CGFloat in
                let x = Double(i) / 90
                var low = 0.0, high = 1.0
                for _ in 0..<20 {
                    let t = (low + high) / 2
                    let v = 0.9 * t * pow(1-t, 2) + 1.5 * t*t*(1-t) + t*t*t
                    if v < x { low = t } else { high = t }
                }
                let t = (low + high) / 2
                let y = 4.8*t*pow(1-t, 2) + 3*t*t*(1-t) + t*t*t
                return from + (to-from) * y
            }
            animation = frames
        } else {
            let basic = CABasicAnimation(keyPath: key)
            basic.fromValue = from; basic.toValue = to
            basic.timingFunction = reduced ? CAMediaTimingFunction(name: .linear) : outgoing ? CAMediaTimingFunction(controlPoints: 0.55, 0.085, 0.68, 0.53) : curve
            animation = basic
        }
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
        OrbitOnboardingMotion.animate(layer, key: "transform.scale", from: 0.6, to: 1, duration: 0.9, delay: delay, stick: true)
        OrbitOnboardingMotion.animate(layer, key: "transform.rotation.z", from: -.pi * 14 / 180, to: 0, duration: 0.9, delay: delay, stick: true)
        OrbitOnboardingMotion.animate(layer, key: "opacity", from: 0, to: 1, duration: 0.9, delay: delay)
    }
}
