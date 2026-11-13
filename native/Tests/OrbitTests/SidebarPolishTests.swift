import AppKit
@testable import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SidebarPolishTests {
    private func pixels() throws -> BrowserFaviconImage {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.bitmapData)
        bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        for x in 0..<20 { for y in 0..<20 {
            let offset = y * bitmap.bytesPerRow + x * 4
            bytes[offset + 1] = 180; bytes[offset + 2] = 80; bytes[offset + 3] = 255
        } }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        return try #require(BrowserFaviconImage(sourceURL: URL(string: "https://cdn.example.test/icon.png")!, png: data))
    }

    @Test("Favorite pixels survive a new cache instance and remain isolated by profile and origin")
    func persistentFavorites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-icons-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = ProfileID(), image = try pixels(), home = URL(string: "https://site.example.test/path?q=private")!
        let first = FavoriteIconStore(directory: directory)
        await first.put(image, profile: profile, home: home)
        let reopened = FavoriteIconStore(directory: directory)
        #expect(await reopened.cachedImage(profile: profile, home: home)?.png == image.png)
        #expect(await reopened.cachedImage(profile: profile, home: URL(string: "https://site.example.test/other")!)?.png == image.png)
        #expect(await reopened.cachedImage(profile: ProfileID(), home: home) == nil)
        #expect(await reopened.cachedImage(profile: profile, home: URL(string: "http://site.example.test/")!) == nil)
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent(profile.rawValue.uuidString), includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let before = try FileManager.default.attributesOfItem(atPath: files[0].path)
        await first.put(image, profile: profile, home: home)
        await reopened.put(image, profile: profile, home: home)
        let after = try FileManager.default.attributesOfItem(atPath: files[0].path)
        #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        #expect(try Data(contentsOf: files[0]) == image.png)
        #expect(!files[0].lastPathComponent.contains("site"))
        try await reopened.remove(profile: profile)
        await reopened.put(image, profile: profile, home: home)
        #expect(await reopened.cachedImage(profile: profile, home: home) == nil)
        #expect(!FileManager.default.fileExists(atPath: files[0].path))
    }

    @Test("Dormant favorites resolve persisted pixels without an engine surface")
    func dormantFavorite() async throws {
        let profile = ProfileID(), home = URL(string: "https://site.example.test/")!
        let store = FavoriteIconStore()
        await store.put(try pixels(), profile: profile, home: home)
        let pipeline = FavoriteIconPipeline<SiteSyntheticSurface>()
        pipeline.store = store
        let tab = BrowserOrganizationTabItem(id: TabID(), section: .favorites(profile), url: home, pinnedURL: home,
            pageTitle: "Public favorite", customTitle: nil, occurrenceID: nil, isLoadedInThisWindow: false,
            isSelected: false, isOpenInAnotherWindow: false)
        var changed = false
        pipeline.onChange = { changed = true }
        #expect(pipeline.image(for: tab, surface: nil, isOwned: { _ in false }) == nil)
        for _ in 0..<200 where !changed { try await Task.sleep(for: .milliseconds(5)) }
        #expect(changed)
        #expect(pipeline.image(for: tab, surface: nil, isOwned: { _ in false }) != nil)
        pipeline.clear()
    }

    @Test("Public favicon discovery respects link declarations, CDN paths and image bounds")
    func discovery() throws {
        let base = URL(string: "https://site.example.test/directory/")!
        let urls = FavoriteIconStore.iconURLs(html: """
            <link href='../small.png' rel='shortcut icon'>
            <link REL="apple-touch-icon" href="https://cdn.example.test/touch.png?a=1&amp;b=2">
            <link rel="stylesheet" href="style.css"><link rel="icon" href="file:///private/icon.png">
            <link rel="icon" href="icon.svg">
            """, base: base)
        #expect(urls.map(\.absoluteString) == ["https://site.example.test/small.png", "https://cdn.example.test/touch.png?a=1&b=2"])
        let image = try pixels()
        #expect(FavoriteIconStore.decode(image.png, source: base) != nil)
        #expect(FavoriteIconStore.decode(Data("not an image".utf8), source: base) == nil)
        #expect(FavoriteIconStore.decode(Data(repeating: 0, count: 524_289), source: base) == nil)
    }

    @Test("The Space header exposes the same icon action as the footer and projects its persisted choice")
    func spaceHeaderIcon() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 228, height: 640))
        let page = sidebar.page
        let menu = try #require(page.spaceContextMenu)
        let action = try #require(menu.items.first { $0.title == uiText("Change Space Icon…") })
        var invoked = false
        page.onEditIcon = { invoked = true }
        _ = (action.target as? NSObject)?.perform(try #require(action.action), with: action)
        #expect(invoked)
        page.geometry = sidebar.geometry
        page.iconSelection = .grapheme("🧪")
        page.layoutSubtreeIfNeeded()
        #expect(page.titleFrame.minX == OrbitTokens.Metrics.Sidebar.titleOriginX)
        page.iconSelection = .none
        page.layoutSubtreeIfNeeded()
        #expect(page.titleFrame.minX == OrbitTokens.Metrics.Sidebar.spaceTitleOriginXWithoutIcon)
    }

    @Test("A transparent black public favicon paints white in a dark Space without loading its page")
    func monochromeFavicon() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.bitmapData)
        bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        for x in 4..<16 { for y in 4..<16 { bytes[y * bitmap.bytesPerRow + x * 4 + 3] = 255 } }
        let image = NSImage(size: NSSize(width: 20, height: 20)); image.addRepresentation(bitmap)
        let profile = ProfileID(), home = URL(string: "https://site.example.test/")!
        let tab = BrowserOrganizationTabItem(id: TabID(), section: .favorites(profile), url: home, pinnedURL: home,
            pageTitle: "Public icon", customTitle: nil, occurrenceID: nil, isLoadedInThisWindow: false,
            isSelected: false, isOpenInAnotherWindow: false)
        let tile = FavoriteTileView(item: .init(tab: tab, favicon: image))
        let icon = try #require(tile.subviews.compactMap { $0 as? FavoriteFaviconImageView }.first)
        icon.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        #expect(icon.image?.isTemplate == true)
        icon.appearance = NSAppearance(named: .darkAqua)
        let output = try #require(icon.bitmapImageRepForCachingDisplay(in: icon.bounds))
        icon.cacheDisplay(in: icon.bounds, to: output)
        let center = try #require(output.colorAt(x: output.pixelsWide / 2, y: output.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(center.redComponent > 0.85 && center.greenComponent > 0.85 && center.blueComponent > 0.85)
    }
}
}
