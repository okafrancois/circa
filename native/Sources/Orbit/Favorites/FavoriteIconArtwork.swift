import AppKit

/// Presentation-only normalization; shared site artwork and disk caches retain their original pixels.
@MainActor
enum FavoriteIconArtwork {
    static func normalized(_ image: NSImage) -> NSImage {
        guard image.size.width > 0, image.size.height > 0,
              image.size.width.isFinite, image.size.height.isFinite,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let bytes = bitmap.bitmapData, let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let scale = 64 / max(image.size.width, image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: (64 - size.width) / 2, y: (64 - size.height) / 2,
                             width: size.width, height: size.height), from: .zero,
                   operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var minX = 64, minY = 64, maxX = -1, maxY = -1
        for y in 0..<64 { for x in 0..<64 {
            guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.01 else { continue }
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        } }
        guard maxX >= minX, maxY >= minY,
              let cropped = bitmap.cgImage?.cropping(to: CGRect(x: minX, y: minY,
                width: maxX - minX + 1, height: maxY - minY + 1)) else { return image }
        let result = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        result.isTemplate = image.isTemplate
        return result
    }
}
