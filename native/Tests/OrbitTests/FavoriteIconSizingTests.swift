import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@MainActor
struct FavoriteIconSizingTests {
    private func artwork(width: Int, height: Int, rect: NSRect) throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.bitmapData)
        bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * height)
        for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) {
            let offset = y * bitmap.bytesPerRow + x * 4
            bytes[offset] = 25; bytes[offset + 1] = 180
            bytes[offset + 2] = 75; bytes[offset + 3] = 255
        } }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }

    private func renderedBounds(_ image: NSImage) throws -> NSSize {
        let profile = ProfileID(), url = URL(string: "https://icon.example.test/")!
        let tab = BrowserOrganizationTabItem(id: TabID(), section: .favorites(profile), url: url, pinnedURL: url,
            pageTitle: "Synthetic icon", customTitle: nil, occurrenceID: nil, isLoadedInThisWindow: false,
            isSelected: false, isOpenInAnotherWindow: false)
        let tile = FavoriteTileView(item: .init(tab: tab, favicon: image))
        tile.frame = NSRect(x: 0, y: 0, width: 80, height: 48)
        tile.layoutSubtreeIfNeeded()
        let view = try #require(tile.subviews.compactMap { $0 as? FavoriteFaviconImageView }.first)
        view.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        } }
        #expect(maxX >= minX && maxY >= minY)
        let pixelWidth = CGFloat(bitmap.pixelsWide), pixelHeight = CGFloat(bitmap.pixelsHigh)
        let width = CGFloat(maxX - minX + 1) * 20 / pixelWidth
        let height = CGFloat(maxY - minY + 1) * 20 / pixelHeight
        #expect(abs(CGFloat(minX + maxX + 1) * 10 / pixelWidth - 10) <= 1)
        #expect(abs(CGFloat(minY + maxY + 1) * 10 / pixelHeight - 10) <= 1)
        return NSSize(width: width, height: height)
    }

    @Test("Small, large and asymmetrically padded site artwork occupies the same visible size",
          arguments: [16, 32, 64])
    func visibleSize(side: Int) throws {
        for padded in [false, true] {
            let rect = padded ? NSRect(x: side / 8, y: side / 4, width: side / 2, height: side / 2)
                : NSRect(x: 0, y: 0, width: side, height: side)
            let image = try artwork(width: side, height: side, rect: rect)
            let bounds = try renderedBounds(image)
            #expect(abs(bounds.width - 20) <= 1)
            #expect(abs(bounds.height - 20) <= 1)
            #expect(image.size == NSSize(width: side, height: side))
            #expect(!image.isTemplate)
        }
    }

    @Test("Wide and tall logos keep their proportions while matching the common longest edge")
    func aspectRatio() throws {
        for wide in [false, true] {
            let width = wide ? 32 : 16, height = wide ? 16 : 32
            let image = try artwork(width: width, height: height, rect: NSRect(x: 0, y: 0, width: width, height: height))
            let bounds = try renderedBounds(image)
            #expect(abs(max(bounds.width, bounds.height) - 20) <= 1)
            #expect(abs(min(bounds.width, bounds.height) - 10) <= 1)
        }
    }
}
}
