import Foundation
import CoreGraphics

/// Opaque sRGB bytes; no AppKit appearance or Space theme is baked into engine metadata.
public struct BrowserPageTint: Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red; self.green = green; self.blue = blue
    }

    /// WCAG 2 relative luminance and contrast against opaque black/white.
    public var prefersWhiteForeground: Bool {
        func linear(_ byte: UInt8) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return 1.05 / (luminance + 0.05) > (luminance + 0.05) / 0.05
    }

    /// Dominant colour from at most 64 evenly spaced edge samples. Quantized buckets prevent
    /// antialiasing, a logo or a single high-contrast pixel from deciding the whole toolbar.
    public static func sampledTopEdge(_ image: CGImage) -> BrowserPageTint? {
        let width = min(64, image.width)
        guard width > 0, image.height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let edge = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: 1)) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .none
            context.draw(edge, in: CGRect(x: 0, y: 0, width: width, height: 1))
            var buckets: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
            let bytes = buffer.bindMemory(to: UInt8.self)
            for x in 0..<width where bytes[x * 4 + 3] == 255 {
                let r = Int(bytes[x * 4]), g = Int(bytes[x * 4 + 1]), b = Int(bytes[x * 4 + 2])
                let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                let old = buckets[key, default: (0, 0, 0, 0)]
                buckets[key] = (old.count + 1, old.red + r, old.green + g, old.blue + b)
            }
            // Stable tie break; dictionaries have no deterministic iteration order.
            guard let winner = buckets.keys.sorted().max(by: { buckets[$0]!.count < buckets[$1]!.count }),
                  let best = buckets[winner] else { return nil }
            return BrowserPageTint(red: UInt8(best.red / best.count), green: UInt8(best.green / best.count),
                                   blue: UInt8(best.blue / best.count))
        }
    }
}
