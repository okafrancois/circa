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
        let key = "\(variant.rawValue)/\(pointSize)/\(sfName)"
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
                } else { images[key] = source }
            }
            // Callers may resize or annotate their image without mutating another control's copy.
            guard let result = images[key]?.copy() as? NSImage else { return nil }
            result.accessibilityDescription = accessibilityDescription
            return result
        }
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
    static func view(sfName: String, pointSize: CGFloat) -> some View {
        // Retain the original font-driven symbol metrics so adjacent text never reflows.
        Image(systemName: sfName).hidden().overlay {
            Image(nsImage: image(sfName: sfName, pointSize: pointSize) ?? NSImage())
                .resizable().scaledToFit().accessibilityHidden(true)
        }.accessibilityRepresentation { Image(systemName: sfName) }
    }
}
