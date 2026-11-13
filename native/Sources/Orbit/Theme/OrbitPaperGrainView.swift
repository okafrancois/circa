import AppKit
import BrowserShell
import SwiftUI

/// One shared, deterministic paper tile; it never receives an input event.
@MainActor
final class OrbitPaperGrainView: NSView {
    static let tile: NSImage? = {
        let image = BrowserText.secondaryBrandResource("paper-grain", extension: "png").flatMap { NSImage(contentsOf: $0) }
        image?.size = NSSize(width: 220, height: 220)
        return image
    }()
    /// The same paper relief, normalized to the former dark noise's mean and deviation.
    /// A normal blend preserves fine variation over charcoal fills instead of crushing it.
    static let darkTile: NSImage? = {
        guard let source = tile?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = source.width, height = source.height, count = width * height
        var bytes = [UInt8](repeating: 255, count: count * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let means = [0.57, 0.532, 0.524], deviations = [0.284, 0.244, 0.244]
        for channel in 0..<3 {
            let mean = stride(from: channel, to: bytes.count, by: 4).reduce(0.0) { $0 + Double(bytes[$1]) } / Double(count)
            let variance = stride(from: channel, to: bytes.count, by: 4).reduce(0.0) {
                $0 + pow(Double(bytes[$1]) - mean, 2)
            } / Double(count)
            let deviation = max(1, sqrt(variance))
            for index in stride(from: channel, to: bytes.count, by: 4) {
                let normalized = (Double(bytes[index]) - mean) / deviation
                let value = min(1, max(0, means[channel] + normalized * deviations[channel]))
                bytes[index] = UInt8((value * 255).rounded())
            }
        }
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 220, height: 220))
    }()
    /// Existing stored strengths stay untouched. The standard 0.3 dial value reproduces
    /// the onboarding's 50% multiply tile; zero removes the texture completely.
    static func opacity(for strength: CGFloat) -> CGFloat {
        let value = min(1, max(0, strength))
        return value <= 0.3 ? value / 0.3 * 0.5 : 0.5 + (value - 0.3) / 0.7 * 0.5
    }
    var strength: CGFloat = 0.3 { didSet { refreshBlend() } }
    var patternOffset: CGPoint = .zero { didSet { if oldValue != patternOffset { needsDisplay = true } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0.5
        refreshBlend()
        setAccessibilityElement(false)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBlend()
    }
    private func refreshBlend() {
        let dark = OrbitAppearance.isDark(effectiveAppearance)
        layer?.compositingFilter = dark ? nil : "multiplyBlendMode"
        alphaValue = dark ? min(1, max(0, strength)) * 0.15 : Self.opacity(for: strength)
        needsDisplay = true
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let tile = OrbitAppearance.isDark(effectiveAppearance) ? Self.darkTile : Self.tile else { return }
        NSGraphicsContext.current?.patternPhase = NSPoint(x: -patternOffset.x, y: patternOffset.y)
        NSColor(patternImage: tile).setFill()
        dirtyRect.fill()
    }
}

struct OrbitPaperGrainSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { OrbitPaperGrainView() }
    func updateNSView(_ view: NSView, context: Context) {}
}
