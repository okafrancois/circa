import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct BrowsingCacheTests {
    @Test("Cost admission replaces incrementally and keeps recently displayed pixels")
    func lruAndOversizedAdmission() {
        var cache = BrowserCostCache<Int, String>(budget: 10)
        cache.insert("first", for: 1, cost: 4)
        cache.insert("second", for: 2, cost: 4)
        #expect(cache.value(for: 1) == "first")
        #expect(cache.peekValue(for: 2) == "second")
        cache.insert("third", for: 3, cost: 4)
        #expect(cache.value(for: 2) == nil)
        #expect(cache.value(for: 1) == "first")
        cache.insert("large", for: 4, cost: 11)
        #expect(cache.count == 2 && cache.cost == 8)
        cache.insert("replacement", for: 1, cost: 1)
        #expect(cache.cost == 5)
    }

    @Test("A thousand distinct origins stay within budget and evicted known icons restore synchronously")
    func sidebarResidencyAndPressure() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = ProfileID(), other = ProfileID()
        let store = FavoriteIconStore(directory: directory)
        let sidebar = SidebarIconMemoryCache(store: store, budget: 32 * 1024)
        let first = URL(string: "http://o0.localhost:28163/")!
        let pixels = try #require(BrowserFaviconImage(sourceURL: first, png: NativeFaviconReceiptTests.png()))
        let image = try #require(await pixels.nativeImage())
        await store.put(pixels, profile: profile, home: first)
        sidebar.put(image, profile: profile, home: first)
        for n in 1...1000 {
            let home = URL(string: "http://o\(n).localhost:28163/")!
            sidebar.put(image, profile: profile, home: home)
            await store.put(pixels, profile: profile, home: home)
        }
        #expect(sidebar.cacheStatistics["bytes", default: 0] <= 32 * 1024)
        #expect(sidebar.cacheStatistics["entries", default: 0] < 1000)
        #expect(await store.cacheStatistics["bytes", default: 0] <= 4 * 1024 * 1024)
        sidebar.releaseMemory()
        await store.releaseMemory()
        #expect(sidebar.cacheStatistics["entries"] == 0)
        #expect(await store.cacheStatistics["entries"] == 0)
        let restored = try #require(sidebar.image(profile: profile, home: first))
        #expect(restored.representations.count == 1)
        #expect(restored.representations.allSatisfy { $0.pixelsWide <= 64 && $0.pixelsHigh <= 64 })
        #expect(sidebar.image(profile: other, home: first) == nil)
        sidebar.remove(profile: profile)
        #expect(sidebar.image(profile: profile, home: first) == nil)
    }

    @Test("Negative inline keys remain bounded without retaining source URL payloads")
    func paletteFailures() async throws {
        let cache = BrowserPaletteFaviconCache()
        for n in 0..<1000 {
            _ = cache.image(for: URL(string: "data:image/png;base64,invalid\(n)")!)
            if n % 8 == 0 { await cache.waitForPendingImages() }
        }
        await cache.waitForPendingImages()
        #expect(cache.cacheStatistics["failures", default: 0] <= 512)
        #expect(cache.cacheStatistics["failureBytes", default: 0] <= 65536)
        cache.clear()
        #expect(cache.cacheStatistics["failures"] == 0)
    }

    @Test("Closing drains accepted visits before disabling future store access")
    func closeDrainsAcceptedWrites() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-cache-close-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = BrowserHistoryRecorder(directory: directory, resolveProfile: { .init(profileID: $0, persistence: .persistent) })
        let surface = SwitcherSnapshotSurface()
        surface.navigationState.committedURL = URL(string: "https://synthetic.test/queued")!
        recorder.committed(surface, profile: .init(profileID: surface.profileID, persistence: .persistent))
        try await recorder.close()
        let reopened = BrowserHistoryRecorder(directory: directory, resolveProfile: { .init(profileID: $0, persistence: .persistent) })
        #expect(try await reopened.visits(for: surface.profileID).count == 1)
        try await reopened.close()
    }

    @Test("Pressure retains foreground history, skips active imports and reloads exact first suggestions")
    func historyEvictionAndReload() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-cache-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var timestamp = Date()
        let recorder = BrowserHistoryRecorder(directory: directory,
            resolveProfile: { .init(profileID: $0, persistence: .persistent) }, now: { timestamp })
        let profiles = (0..<3).map { _ in ProfileID() }
        recorder.activeProfiles = { [profiles[0]] }
        for (n, profile) in profiles.enumerated() {
            let visits = (0..<20).map { BrowserHistoryVisit(url: URL(string: "https://p\(n).test/\($0)")!, title: "Synthetic \($0)", visitedAt: timestamp) }
            _ = try await recorder.importDocument(.init(profileID: profile, visits: visits))
            await recorder.prepareSuggestions(for: profile)
        }
        let before = recorder.cachedSuggestions(for: profiles[1], query: "synthetic")
        #expect(!before.isEmpty)
        recorder.beginImport(for: profiles[2])
        await recorder.releaseInactiveMemory()
        #expect(recorder.cacheStatistics["stores"] == 2)
        #expect(!recorder.cachedSuggestions(for: profiles[0], query: "synthetic").isEmpty)
        recorder.endImport(for: profiles[2])
        await recorder.prepareSuggestions(for: profiles[2])
        await recorder.prepareSuggestions(for: profiles[1])
        #expect(recorder.cachedSuggestions(for: profiles[1], query: "synthetic") == before)
        timestamp.addTimeInterval(301)
        await recorder.releaseInactiveMemory(olderThan: 300)
        #expect(recorder.cacheStatistics["stores"] == 1)
        #expect(try await recorder.visits(for: profiles[1]).count == 20)
        try await recorder.close()
    }
}
}
