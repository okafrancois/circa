import AppKit
import BrowserCore
import QuartzCore

/// The onboarding window's backdrop: the measured looping colour field until a theme is chosen, then
/// that theme's fill (swapped within one frame, like every theme surface).
@MainActor
final class OrbitOnboardingBackgroundView: NSView {
    static let animationKey = "orbit.onboarding.background"
    let field = CALayer()
    let themeFill = OrbitThemeFillView()
    private(set) var theme: BrowserSpaceTheme?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        field.contentsGravity = .resize
        field.magnificationFilter = .linear
        field.minificationFilter = .linear
        field.contents = Self.frames.first
        layer?.addSublayer(field)
        themeFill.frame = bounds
        themeFill.autoresizingMask = [.width, .height]
        themeFill.isHidden = true
        addSubview(themeFill)
        startLoop()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.frame = bounds
        CATransaction.commit()
    }

    /// nil returns to the default backdrop.
    func apply(theme: BrowserSpaceTheme?) {
        self.theme = theme
        if let theme {
            themeFill.applyInteractiveTheme(OrbitSpaceThemes.rendered(theme))
            themeFill.isHidden = false
        } else {
            themeFill.isHidden = true
        }
    }

    private func startLoop() {
        guard !OrbitMotionPreferences.prefersReducedMotion, Self.frames.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = Self.frames + [Self.frames[0]]
        animation.calculationMode = .linear
        animation.duration = Double(Self.frames.count) / OrbitOnboardingBackgroundData.framesPerSecond
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        field.add(animation, forKey: Self.animationKey)
    }

    /// Keyframes decoded once and upsampled ×8 with a uniform cubic B-spline (smooth, no overshoot), so
    /// the layer's linear magnification stays soft.
    static let frames: [CGImage] = decodeFrames()

    static func hexData(_ text: String) -> Data? {
        let digits = Array(text.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        func value(_ digit: UInt8) -> UInt8? {
            switch digit {
            case 48...57: digit - 48
            case 97...102: digit - 87
            default: nil
            }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = value(digits[index]), let low = value(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return Data(bytes)
    }

    static func decodeFrames() -> [CGImage] {
        let columns = OrbitOnboardingBackgroundData.columns, rows = OrbitOnboardingBackgroundData.rows
        let frameBytes = columns * rows * 3
        guard let compressed = hexData(OrbitOnboardingBackgroundData.encoded),
              let raw = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              raw.count == frameBytes * OrbitOnboardingBackgroundData.frameCount else { return [] }
        var bytes = [UInt8](raw)
        for index in frameBytes..<bytes.count { bytes[index] = bytes[index] &+ bytes[index - frameBytes] }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let factor = 8, width = columns * factor, height = rows * factor
        // Cubic B-spline weights for each output sample: (cell index, weight) × 4, clamped at the edges.
        func taps(_ count: Int, _ size: Int) -> [[(Int, Float)]] {
            (0..<size).map { index in
                let position = (Float(index) + 0.5) / Float(factor) - 0.5
                let base = Int(floor(position)), t = position - Float(base)
                let weights = [(1 - t) * (1 - t) * (1 - t) / 6, (3 * t * t * t - 6 * t * t + 4) / 6,
                               (-3 * t * t * t + 3 * t * t + 3 * t + 1) / 6, t * t * t / 6]
                return (0..<4).map { (min(count - 1, max(0, base - 1 + $0)), weights[$0]) }
            }
        }
        let xTaps = taps(columns, width), yTaps = taps(rows, height)
        return (0..<OrbitOnboardingBackgroundData.frameCount).compactMap { frame in
            let offset = frame * frameBytes
            var horizontal = [Float](repeating: 0, count: rows * width * 3)
            for row in 0..<rows {
                for x in 0..<width {
                    for channel in 0..<3 {
                        var value: Float = 0
                        for (cell, weight) in xTaps[x] { value += weight * Float(bytes[offset + (row * columns + cell) * 3 + channel]) }
                        horizontal[(row * width + x) * 3 + channel] = value
                    }
                }
            }
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    for channel in 0..<3 {
                        var value: Float = 0
                        for (row, weight) in yTaps[y] { value += weight * horizontal[(row * width + x) * 3 + channel] }
                        rgba[(y * width + x) * 4 + channel] = UInt8(max(0, min(255, value.rounded())))
                    }
                }
            }
            guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }
}
