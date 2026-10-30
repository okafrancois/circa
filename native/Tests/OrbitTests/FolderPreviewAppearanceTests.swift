import AppKit
import Testing
import BrowserEngine
@testable import Orbit
@testable import BrowserCore

extension NativeWebKitTests {
@Suite("Folder preview compact appearance")
@MainActor
struct FolderPreviewAppearanceTests {
    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child -> [NSButton] in
            if let button = child as? NSButton, button.action == NSSelectorFromString("choose:") { return [button] }
            return buttons(in: child)
        }
    }

    @Test("Collapsed folder children restore their profile-local disk favicon before hover")
    func collapsedFolderDiskIcon() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folder-preview-icons-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let home = URL(string: "https://folder-preview.test/")!
        let occurrence = try await store.openTab(url: home, from: store.captureContext(in: window), activate: true)
        let tab = try #require(await store.sessionDocument().tabs.first { $0.occurrenceID == occurrence }?.id)
        let (folder, _) = try await store.createFolder(title: "Synthetic folder", at: .init(.pinned(space)),
            containing: [.tab(tab)], from: store.captureContext(in: window))
        _ = try await store.setFolderCollapsed(folder, true, from: store.captureContext(in: window))
        let document = await store.sessionDocument()
        #expect(!SpaceSwipePreview.content(document: document, spaceID: space).entries.contains { $0.node.tabID == tab })
        let disk = FavoriteIconStore(directory: directory)
        let pixels = try #require(BrowserFaviconImage(sourceURL: home, png: NativeFaviconReceiptTests.png()))
        await disk.put(pixels, profile: profile, home: home)
        let memory = SidebarIconMemoryCache()
        await memory.preload(document: document, store: FavoriteIconStore(directory: directory))
        #expect(memory.image(profile: profile, home: home) != nil)
        #expect(memory.image(profile: ProfileID(), home: home) == nil)
    }

    @Test("Rows keep a forty-point pitch and sixteen-point icons")
    func compactRows() {
        let fixture = SyntheticOrganization()
        let view = FolderPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        view.render(FolderPreviewResult.ordered([fixture.tab(), fixture.tab(), fixture.tab()]), image: { _ in nil })
        let rows = buttons(in: view)
        #expect(rows.count == 3)
        #expect(rows.map(\.frame.height) == [40, 40, 40])
        #expect(rows.map(\.frame.minY) == [0, 40, 80])
        #expect(rows.allSatisfy { $0.image?.size == NSSize(width: 16, height: 16) })
        #expect(rows.allSatisfy { !$0.attributedTitle.string.contains("Last access unavailable") })
    }

    @Test("A dormant tab uses the sidebar cache synchronously on its first render")
    func immediateCachedFavicon() throws {
        let fixture = SyntheticOrganization(), cache = SidebarIconMemoryCache()
        let url = URL(string: "https://folder-preview.test/page")!
        let icon = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.systemOrange.setFill(); rect.fill(); return true
        }
        cache.put(icon, profile: fixture.profileID, home: url)
        let results = FolderPreviewResult.ordered([fixture.tab(url: url.absoluteString)])
        #expect(results.first?.tab.occurrenceID == nil)
        let view = FolderPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        var reads = 0
        view.render(results, image: { result in
            reads += 1
            return cache.image(profile: fixture.profileID, home: result.tab.url)
        })
        let row = try #require(buttons(in: view).first)
        #expect(row.image?.tiffRepresentation == icon.tiffRepresentation)
        let firstImage = row.image
        view.refreshImages()
        #expect(row.image === firstImage, "unchanged cached icons must not be replaced between frames")
        #expect(reads > 0)
        #expect(cache.image(profile: ProfileID(), home: url) == nil)
    }

    @Test("The list uses an auto-hiding overlay scroller without an opaque scroll background")
    func overlayScroller() {
        let view = FolderPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        #expect(view.scroll.scrollerStyle == .overlay)
        #expect(view.scroll.autohidesScrollers)
        #expect(!view.scroll.drawsBackground)
        #expect((view.subviews.first as? OrbitFrostView)?.effect.material == .hudWindow)
        #expect((view.subviews.first as? OrbitFrostView)?.effect.blendingMode == .withinWindow)
    }
}
}
