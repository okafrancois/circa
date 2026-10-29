import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Long media grid viewport and thumbnails", .serialized)
@MainActor
struct LongListMediaTests {
    private func snapshot(_ url: URL, profile: ProfileID) -> BrowserDownloadSnapshot {
        .init(key: .init(id: UUID(), profileID: profile, lifetime: UUID()), owner: .init(profileID: profile),
              revision: 1, sequence: 1, suggestedFilename: url.lastPathComponent, state: .complete,
              receivedBytes: 1, totalBytes: 1, capabilities: [], currentURL: nil, destinationURL: url,
              fileAvailability: .available, failure: nil, pendingAction: nil, isCancellationRequested: false, controlError: nil)
    }

    private static let png: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 96, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }()

    private func fixture(_ count: Int, missing: Set<Int> = []) throws -> (URL, [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-grid-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = (0..<count).map { root.appendingPathComponent("Synthetic \($0).png") }
        for (index, url) in urls.enumerated() where !missing.contains(index) { try Self.png.write(to: url) }
        return (root, urls)
    }

    private func settle(_ view: BrowserLibraryMediaView) async throws {
        for _ in 0..<400 where view.pendingCheck { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!view.pendingCheck)
        view.layoutSubtreeIfNeeded()
    }

    private func image(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    @Test("Tiles in view are exact at once; the rest of the inventory is checked off the main thread")
    func firstScreenThenBackground() async throws {
        let (root, urls) = try fixture(300, missing: [2, 5, 250])
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let view = BrowserLibraryMediaView(frame: NSRect(x: 0, y: 0, width: 305, height: 780))
        view.render(urls.map { snapshot($0, profile: profile) }, profile: profile)
        let expected = urls.enumerated().filter { ![2, 5, 250].contains($0.offset) }.map(\.element)
        #expect(view.rows.count >= 12 && view.rows.count < 60, "only the first screen and overscan were checked synchronously")
        #expect(view.rows.map(\.url) == Array(expected.prefix(view.rows.count)))
        #expect(view.pendingCheck)
        try await settle(view)
        #expect(view.rows.map(\.url) == expected)
    }

    @Test("Only tiles near the viewport exist, at their grid positions, and scrolling recycles them")
    func viewportTiles() async throws {
        let (root, urls) = try fixture(400)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let view = BrowserLibraryMediaView(frame: NSRect(x: 0, y: 0, width: 305, height: 780))
        view.render(urls.map { snapshot($0, profile: profile) }, profile: profile)
        try await settle(view)
        let side = (view.scroll.contentSize.width - 40) / 2
        func check() {
            #expect(view.materializedTileCount > 0 && view.materializedTileCount <= 22)
            for tile in view.displayedTiles {
                guard let index = view.rows.firstIndex(of: tile.item) else { Issue.record("tile without a row"); continue }
                #expect(tile.frame == NSRect(x: 12 + CGFloat(index % 2) * (side + 16), y: 8 + CGFloat(index / 2) * (side + 8), width: side, height: side))
            }
        }
        check()
        let grid = try #require(view.scroll.documentView)
        #expect(grid.frame.height == 8 + 200 * (side + 8))
        let before = grid.subviews.count
        for y in stride(from: 0, through: 20_000, by: 333) { view.scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(y))) }
        check()
        #expect(before <= 22 && grid.subviews.count <= 24, "recycled tiles are reused, not recreated")
    }

    @Test("A recycled tile never shows a thumbnail completed for its previous file")
    func staleThumbnailRejected() async throws {
        let (root, urls) = try fixture(200)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let view = BrowserLibraryMediaView(frame: NSRect(x: 0, y: 0, width: 305, height: 780))
        view.render(urls.map { snapshot($0, profile: profile) }, profile: profile)
        try await settle(view)
        // Requests start for the first screen, then every tile is reused for other files.
        for y in stride(from: 0, through: 12_000, by: 700) { view.scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(y))) }
        for _ in 0..<300 where view.displayedTiles.contains(where: { $0.thumbnail == nil }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!view.displayedTiles.isEmpty)
        for tile in view.displayedTiles {
            let cached = view.thumbnails.lookup(.init(tile.item))
            #expect(tile.thumbnail == nil || tile.thumbnail === cached?.image, "each tile shows its own file's thumbnail")
        }
        #expect(view.thumbnails.count <= view.thumbnails.countLimit && view.thumbnails.bytes <= view.thumbnails.byteLimit)
    }

    @Test("Deleted files and another profile revoke cached thumbnails")
    func revocation() async throws {
        let (root, urls) = try fixture(6)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let view = BrowserLibraryMediaView(frame: NSRect(x: 0, y: 0, width: 305, height: 780))
        let records = urls.map { snapshot($0, profile: profile) }
        view.render(records, profile: profile)
        try await settle(view)
        for _ in 0..<300 where view.displayedTiles.contains(where: { $0.thumbnail == nil }) { try await Task.sleep(for: .milliseconds(10)) }
        let first = try #require(view.rows.first)
        #expect(view.thumbnails.lookup(.init(first))?.image != nil)
        try FileManager.default.removeItem(at: urls[0])
        view.render(records, profile: profile)
        #expect(view.rows.first?.url == urls[1])
        #expect(view.thumbnails.lookup(.init(first)) == nil)
        #expect(!view.displayedTiles.contains { $0.item.url == urls[0] })
        view.render([], profile: ProfileID())
        #expect(view.thumbnails.count == 0 && view.thumbnails.bytes == 0 && view.materializedTileCount == 0)
    }

    @Test("The thumbnail cache is bounded by count and bytes, least recently used first out")
    func cacheBounds() {
        var resident = 0
        BrowserLibraryMediaView.thumbnailBytesProbe = { resident += $0 }
        defer { BrowserLibraryMediaView.thumbnailBytesProbe = nil }
        let profile = ProfileID()
        func key(_ index: Int) -> LibraryThumbnailCache.Key {
            .init(.init(snapshot: snapshot(URL(fileURLWithPath: "/synthetic/\(index).png"), profile: profile),
                        url: URL(fileURLWithPath: "/synthetic/\(index).png"), isVideo: false))
        }
        let keys = (0..<6).map(key)
        let cache = LibraryThumbnailCache(countLimit: 3, byteLimit: 3 * 64 * 64 * 4)
        for index in 0..<3 { cache.store(image(64, 64), for: keys[index]) }
        _ = cache.lookup(keys[0])
        cache.store(image(64, 64), for: keys[3])
        #expect(cache.count == 3 && cache.lookup(keys[1]) == nil && cache.lookup(keys[0]) != nil)
        cache.store(image(128, 64), for: keys[4]) // Twice the bytes: two older entries leave.
        #expect(cache.bytes <= cache.byteLimit && cache.lookup(keys[4]) != nil)
        #expect(resident == cache.bytes)
        cache.store(nil, for: keys[5])
        #expect(cache.lookup(keys[5]).map { $0.image == nil } == true, "a file without a thumbnail is remembered")
        cache.retain([keys[4]])
        #expect(cache.count == 1 && resident == cache.bytes)
        cache.removeAll()
        #expect(cache.count == 0 && resident == 0)
    }
}
}
