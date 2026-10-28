import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SpaceMotionTests {
    @Test("Space motion uses the recovered critical spring and preserves release velocity")
    func recoveredSpring() {
        let spring = OrbitTokens.Motion.spaceSwitchSidebar
        #expect(spring.response == 0.4 && spring.dampingFraction == 1)
        #expect(OrbitTokens.Motion.spaceSwipeScrollScale == 0.5)
        var gesture = SpaceSwipeGesture()
        gesture.update(x: -40, y: 0, time: 1, translationScale: OrbitTokens.Motion.spaceSwipeScrollScale)
        #expect(gesture.displacement == -20)
        gesture.update(x: 20, y: 0, time: 1.1, translationScale: OrbitTokens.Motion.spaceSwipeScrollScale)
        #expect(gesture.displacement == -10)
        let flight = SidebarSlotMotion(from: -80, to: -330, at: 10, spring: spring, velocity: -420)
        #expect(flight.state(at: 10).value == -80)
        #expect(abs(flight.state(at: 10).velocity + 420) < 0.001)
        // The shipped Motion tick advances by target minus current CoreVideo timestamps.
        // A 120 Hz callback can report a 1/60 s frame; nominal response remains 0.4 s.
        let samples: [(Double, Double)] = [(0.1, 0.534416), (0.2, 0.178974), (0.3, 0.051322)]
        for (springTime, remaining) in samples {
            #expect(abs(spring.state(after: springTime, displacement: 1, velocity: 0).displacement - remaining) < 0.00001)
        }
    }

    @Test("Known selected URLs replace without a blank frame; the security and status group reflows")
    func urlReplacementAndStatus() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let first = try await store.createSpace(name: "One", profileID: profile)
        let second = try await store.createSpace(name: "Two", profileID: profile)
        let spaces = await store.catalogSnapshot().spaces
        let field = OrbitLocationField(frame: NSRect(x: 0, y: 0, width: 220, height: 32))
        field.stringValue = "https://example.org/"
        field.setAddress("https://example.net/", from: first, to: second, spaces: spaces)
        #expect(field.stringValue == "https://example.net/")
        field.setAddress("https://example.org/", from: second, to: first, spaces: spaces)
        #expect(field.stringValue == "https://example.org/" && !field.hasStatus)
        #expect(AddressStatusMotion.duration == 0.12 && AddressStatusMotion.baseline == -4)
        #expect(AddressStatusMotion.timingFunction == .easeOut)
        field.setStatusVisible(true, animated: false)
        field.layoutSubtreeIfNeeded()
        #expect(field.hasStatus)
        #expect(field.textGroup.constraints.contains { $0.isActive && $0.firstAttribute == .lastBaseline && $0.constant == -4 })
        field.setStatusVisible(false, animated: false)
        #expect(!field.hasStatus)
        #expect(!field.textGroup.constraints.contains { $0.isActive && $0.firstAttribute == .lastBaseline && ($0.firstItem as? NSView) === field.displayLabel })
    }

    @Test("Released swipe URL ignores late source metadata and restores on refusal")
    func pendingAddress() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let first = try await store.createSpace(name: "One", profileID: profile)
        let second = try await store.createSpace(name: "Two", profileID: profile)
        let spaces = await store.catalogSnapshot().spaces
        let field = OrbitLocationField()
        field.stringValue = "https://example.com/"
        field.setAddress("https://example.org/", from: first, to: second, spaces: spaces, awaitingPublication: true)
        field.refreshAddress("https://example.com/late", in: first)
        #expect(field.stringValue == "https://example.org/" && field.pendingSpaceID == second)
        field.finishSpaceTransition("https://example.com/", in: first, spaces: spaces)
        #expect(field.stringValue == "https://example.com/" && field.pendingSpaceID == nil)
        field.setAddress("https://example.org/", from: first, to: second, spaces: spaces, awaitingPublication: true)
        field.setAddress("https://example.org/", from: first, to: second, spaces: spaces)
        #expect(field.stringValue == "https://example.org/" && field.pendingSpaceID == nil)
    }

    @Test("Cached disk pixels are decoded before the first favorite and preview frame, across profile switches")
    func firstFrameCachedIcon() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("space-motion-icons-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic A")
        let other = await store.createProfile(name: "Synthetic B")
        let first = try await store.createSpace(name: "One", profileID: profile)
        let second = try await store.createSpace(name: "Two", profileID: profile)
        let third = try await store.createSpace(name: "Three", profileID: other)
        let window = try await store.createWindow(activeSpaceID: first)
        let home = URL(string: "https://www.wikipedia.org/")!
        let occurrence = try await store.openTab(url: home, from: store.captureContext(in: window), activate: true)
        let tabID = try #require(await store.sessionDocument().tabs.first { $0.occurrenceID == occurrence }?.id)
        _ = try await store.addToFavorites([tabID], from: store.captureContext(in: window))
        let document = await store.sessionDocument()
        let disk = FavoriteIconStore(directory: directory)
        let pixels = try #require(BrowserFaviconImage(sourceURL: URL(string: "https://www.wikipedia.org/favicon.png")!,
                                                       png: NativeFaviconReceiptTests.png()))
        await disk.put(pixels, profile: profile, home: home)
        let reopened = FavoriteIconStore(directory: directory)
        let memory = SidebarIconMemoryCache()
        await memory.preload(document: document, store: reopened)
        let image = try #require(memory.image(profile: profile, home: home))
        #expect(memory.image(profile: other, home: home) == nil)
        let lookup: (ProfileID, URL) -> NSImage? = { memory.image(profile: $0, home: $1) }
        let a = try #require(SpaceSwipePreview.favorites(document: document, spaceID: first, windowID: window, icon: lookup))
        let b = try #require(SpaceSwipePreview.favorites(document: document, spaceID: second, windowID: window, icon: lookup))
        #expect(a.items.first?.favicon === image && b.items.first?.favicon === image)
        #expect(SpaceSwipePreview.favorites(document: document, spaceID: third, windowID: window, icon: lookup)?.items.isEmpty == true)
        let pipeline = FavoriteIconPipeline<SiteSyntheticSurface>()
        pipeline.store = reopened; pipeline.memoryCache = memory
        let tab = try #require(a.items.first?.tab)
        #expect(pipeline.image(for: tab, surface: nil, isOwned: { _ in false }) === image)
        pipeline.clear()
        #expect(pipeline.image(for: tab, surface: nil, isOwned: { _ in false }) === image)
        let tile = FavoriteTileView(item: try #require(b.items.first))
        #expect(tile.item.favicon === image)
        memory.remove(profile: profile)
        #expect(memory.image(profile: profile, home: home) == nil)
    }
}
}
