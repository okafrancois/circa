import AppKit
import Testing
@testable import Orbit
@testable import BrowserCore

extension NativeWebKitTests {
@Suite("Folder preview displayed image lifecycle")
@MainActor
struct FolderPreviewR3Tests {
    private func button(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.action == NSSelectorFromString("choose:") { return button }
        return view.subviews.lazy.compactMap { button(in: $0) }.first
    }

    @Test("A copied row thumbnail clears when the same URL has a new live document generation")
    func sameURLDisplayedThumbnailRetirement() async throws {
        let surface = SwitcherSnapshotSurface()
        let cache = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>(attachmentPolicy: .attachedOnly)
        cache.isAttached = { _ in true }
        defer { cache.shutdown() }
        let capture = cache.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        #expect(surface.continuations.count == 1)
        surface.complete(generation: 1)
        await capture?.value
        _ = try #require(cache.image(for: surface))
        let fixture = SyntheticOrganization()
        let results = FolderPreviewResult.ordered([fixture.tab(title: "Synthetic unchanged title", url: "https://same-url.test/")])
        let view = FolderPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        view.render(results, image: { _ in cache.image(for: surface) })
        let row = try #require(button(in: view))
        let before = try #require(row.image?.tiffRepresentation)
        let requests = surface.requests.count
        surface.findDocumentGeneration += 1 // Same URL/title, no search, hover or result rerender.
        #expect(cache.image(for: surface) == nil)
        view.needsLayout = true
        view.layout()
        #expect(button(in: view) === row)
        #expect(row.image?.tiffRepresentation != before)
        #expect(surface.requests.count == requests, "image retirement must not load or paint a dormant page")
    }

    @Test("Autonomous engine events retire installed pixels without rebuilding results or editing search")
    func engineEventRefreshesInstalledRow() async throws {
        let controller = FolderPreviewController<SwitcherSnapshotSurface>()
        let hooks = BrowserSurfaceEventHooks<SwitcherSnapshotSurface>()
        controller.observeImages(in: hooks)
        let host = NSView() // An in-memory parent, never a window or browser host.
        let surface = SwitcherSnapshotSurface()
        controller.snapshots.isAttached = { _ in true }
        defer { controller.shutdown() }
        let capture = controller.snapshots.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        #expect(surface.continuations.count == 1)
        surface.complete(generation: 1)
        await capture?.value
        _ = try #require(controller.snapshots.image(for: surface))
        host.addSubview(controller.view)
        let results = FolderPreviewResult.ordered([SyntheticOrganization().tab(title: "Synthetic result")])
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        controller.view.render(results, image: { _ in controller.snapshots.image(for: surface) })
        controller.view.search.stringValue = "Retained search"
        let row = try #require(button(in: controller.view))
        let before = try #require(row.image?.tiffRepresentation)
        surface.findDocumentGeneration += 1
        hooks.emit(.stateChanged, for: surface) // Same owner route used by Chromium's document event.
        #expect(button(in: controller.view) === row)
        #expect(row.image?.tiffRepresentation != before)
        #expect(controller.view.search.stringValue == "Retained search")
        #expect(surface.requests.count == 1)

        // Rebinding the event registration retires old deliveries as well as old pixel providers.
        let successorHooks = BrowserSurfaceEventHooks<SwitcherSnapshotSurface>()
        controller.observeImages(in: successorHooks)
        var reads = 0
        controller.view.render(results, image: { _ in reads += 1; return nil })
        let beforeOldEvent = reads
        hooks.emit(.navigationFinished, for: surface)
        #expect(reads == beforeOldEvent)
        controller.view.clear()
        successorHooks.emit(.navigationCommitted, for: surface)
        #expect(reads == beforeOldEvent, "cleared results must release their old live image resolver")
    }

    @Test("A displayed strict-preview image retires on detachment without painting or loading a dormant tab")
    func detachedDisplayedImageRetirement() async throws {
        let cache = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>(attachmentPolicy: .attachedOnly)
        let surface = SwitcherSnapshotSurface()
        var attached = true
        cache.isAttached = { _ in attached }
        defer { cache.shutdown() }
        let capture = cache.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        #expect(surface.continuations.count == 1)
        surface.complete(generation: 1)
        await capture?.value
        _ = try #require(cache.image(for: surface))
        let view = FolderPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        view.render(FolderPreviewResult.ordered([SyntheticOrganization().tab()]), image: { _ in cache.image(for: surface) })
        let row = try #require(button(in: view))
        let before = try #require(row.image?.tiffRepresentation)
        attached = false
        view.needsLayout = true
        view.layout()
        #expect(button(in: view) === row && row.image?.tiffRepresentation != before)
        #expect(cache.request(surface) == nil && surface.requests.count == 1)
    }

}
}
