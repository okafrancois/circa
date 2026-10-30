import AppKit
import BrowserShell
import SwiftUI
import os

/// Optical-size resources for interface glyphs. User-selected Space symbols use SpaceIconImages.
enum OrbitIcon {
    enum Variant: String { case template, color }
    private struct Catalog: Decodable, Sendable {
        var template: [String]
        var color: [String]
    }
    private static let catalog: Catalog = {
        guard let url = BrowserText.iconResource("catalog", extension: "json"),
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Catalog.self, from: data)
        else { return Catalog(template: [], color: []) }
        return value
    }()
    static var templateNames: [String] { catalog.template }
    static var colorNames: [String] { catalog.color }
    // Cached sources are immutable after publication; copies leave the lock.
    private static let images = OSAllocatedUnfairLock(uncheckedState: [String: NSImage]())

    private static let templateIdentities = OSAllocatedUnfairLock(uncheckedState:
        NSMapTable<NSImage, NSString>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory))

    /// Re-resolve at a control's final size instead of applying an SF-only configuration to vector ink.
    static func reconfiguredTemplate(_ source: NSImage, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        guard let name = templateIdentities.withLockUnchecked({ $0.object(forKey: source) as String? }) else { return nil }
        return image(sfName: name, pointSize: pointSize, accessibilityDescription: source.accessibilityDescription, weight: weight)
    }

    static func opticalSize(for pointSize: CGFloat) -> Int {
        pointSize < 18 ? 16 : pointSize < 22 ? 20 : 24
    }

    static func resourceURL(sfName: String, pointSize: CGFloat, variant: Variant = .template) -> URL? {
        let names = variant == .template ? catalog.template : catalog.color
        guard names.contains(sfName) else { return nil }
        let size = opticalSize(for: pointSize)
        guard variant == .template || size == 24 else { return nil }
        return BrowserText.iconResource("\(variant.rawValue)/\(size)/\(sfName)",
                                        extension: variant == .template ? "pdf" : "svg")
    }

    static func image(sfName: String, pointSize: CGFloat, variant: Variant = .template,
                      accessibilityDescription: String? = nil, weight: NSFont.Weight = .regular) -> NSImage? {
        guard let url = resourceURL(sfName: sfName, pointSize: pointSize, variant: variant) else {
            return NSImage(systemSymbolName: sfName, accessibilityDescription: accessibilityDescription)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        }
        let key = "\(variant.rawValue)/\(pointSize)/\(weight.rawValue)/\(sfName)"
        return images.withLockUnchecked { images in
            if images[key] == nil {
                guard let source = NSImage(contentsOf: url) else { return nil }
                source.size = NSSize(width: pointSize, height: pointSize)
                source.isTemplate = variant == .template
                if variant == .color, let data = try? String(contentsOf: url, encoding: .utf8) {
                    // SVG ink follows the current appearance; the accent stays embedded in the asset.
                    func coloredInk(_ appearance: NSAppearance.Name, ink: String) -> NSImage? {
                        var alpha: CGFloat = 1
                        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                            alpha = NSColor.secondaryLabelColor.usingColorSpace(.sRGB)?.alphaComponent ?? 1
                        }
                        let svg = data.replacingOccurrences(of: "stroke=\"currentColor\"",
                            with: "stroke=\"\(ink)\" stroke-opacity=\"\(alpha)\"")
                            .replacingOccurrences(of: "fill=\"currentColor\"",
                            with: "fill=\"\(ink)\" fill-opacity=\"\(alpha)\"")
                        return NSImage(data: Data(svg.utf8))
                    }
                    let light = coloredInk(.aqua, ink: "#000000")
                    let dark = coloredInk(.darkAqua, ink: "#FFFFFF")
                    let image = NSImage(size: source.size, flipped: false) { rect in
                        let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                        (isDark ? dark : light)?.draw(in: rect)
                        return true
                    }
                    image.cacheMode = .never
                    images[key] = image
                } else {
                    images[key] = matchedTemplate(source, sfName: sfName, pointSize: pointSize, weight: weight)
                }
            }
            // Callers may resize or annotate their image without mutating another control's copy.
            guard let result = images[key]?.copy() as? NSImage else { return nil }
            result.accessibilityDescription = accessibilityDescription
            if variant == .template {
                templateIdentities.withLockUnchecked { $0.setObject(sfName as NSString, forKey: result) }
            }
            return result
        }
    }

    /// Match the symbol's ink inside its original canvas, retaining its alignment and baseline.
    /// Sources stay vector-backed; only the cached bounds measurement is rasterized.
    private static func matchedTemplate(_ source: NSImage, sfName: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
        guard let symbol = NSImage(systemSymbolName: sfName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)),
              let originalInk = inkBounds(of: symbol), let sourceInk = inkBounds(of: source) else { return source }
        let sx = originalInk.width / sourceInk.width, sy = originalInk.height / sourceInk.height
        let destination = NSRect(x: originalInk.minX - sourceInk.minX * sx,
                                 y: originalInk.minY - sourceInk.minY * sy,
                                 width: source.size.width * sx, height: source.size.height * sy)
        let image = NSImage(size: symbol.size, flipped: false) { _ in
            source.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        image.alignmentRect = symbol.alignmentRect
        return image
    }

    /// Alpha bounds in image points. Oversampling keeps sub-point strokes and optical sizes stable.
    static func inkBounds(of image: NSImage, scale: CGFloat = 4) -> NSRect? {
        let width = Int(ceil(image.size.width * scale)), height = Int(ceil(image.size.height * scale))
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), let pixels = bitmap.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * bitmap.bytesPerRow + x * 4 + 3] >= 32 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return nil }
        return NSRect(x: CGFloat(left) / scale, y: CGFloat(height - bottom - 1) / scale,
                      width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale)
    }

    /// Explicit tint for custom drawing; SF-only palette configurations do not tint PDF images.
    static func draw(_ image: NSImage?, in rect: NSRect, tint: NSColor) {
        guard let image else { return }
        guard image.isTemplate, let context = NSGraphicsContext.current?.cgContext else {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        context.saveGState()
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        tint.setFill()
        rect.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    @MainActor
    static func view(sfName: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> some View {
        // Retain the original font-driven symbol metrics so adjacent text never reflows.
        Image(systemName: sfName).hidden().overlay {
            Image(nsImage: image(sfName: sfName, pointSize: pointSize, weight: weight) ?? NSImage())
                .resizable().scaledToFit().accessibilityHidden(true)
        }.accessibilityRepresentation { Image(systemName: sfName) }
    }
}
