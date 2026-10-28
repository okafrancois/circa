import AppKit
import Testing
@testable import Orbit
@testable import BrowserCore

extension NativeWebKitTests {
@Suite("Independent folder preview R3 installed images")
@MainActor
struct FolderPreviewIndependentR3Tests {
    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }

    private func resultButtons(_ view: NSView) -> [NSButton] {
        descendants(view, of: NSButton.self).filter { $0.action == NSSelectorFromString("choose:") }
    }

    private func warm(_ cache: BrowserSwitcherSnapshots<SwitcherSnapshotSurface>,
                      _ surface: SwitcherSnapshotSurface) async throws {
        let task = cache.request(surface)
        for _ in 0..<200 where surface.continuations.isEmpty { await Task.yield() }
        try #require(surface.continuations.count == 1)
        surface.complete(generation: surface.documentGeneration)
        await task?.value
        _ = try #require(cache.image(for: surface))
    }

    @Test("Same-document-address replacement retires installed bytes while retaining rows, selection and scroll")
    func independentInstalledImageRegression() async throws {
        let cache = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>(attachmentPolicy: .attachedOnly)
        let surface = SwitcherSnapshotSurface()
        cache.isAttached = { _ in true }
        defer { cache.shutdown() }
        try await warm(cache, surface)
        let fixture = SyntheticOrganization()
        let results = FolderPreviewResult.ordered((0..<18).map {
            fixture.tab(title: "Synthetic row \($0)", url: "https://preview.invalid/unchanged")
        })
        let view = FolderPreviewView(frame: NSRect(x: 0, y: 0, width: 320, height: 280))
        view.render(results, image: { _ in cache.image(for: surface) })
        view.search.stringValue = "Unchanged query"
        let editor = NSTextView()
        for _ in 0..<6 {
            #expect(view.control(view.search, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        }
        let scroll = try #require(descendants(view, of: NSScrollView.self).first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 204))
        let origin = scroll.contentView.bounds.origin
        let rows = resultButtons(view)
        let selected = rows.map(\.state)
        let before = try #require(rows.first?.image?.tiffRepresentation)
        let sourceImage = try #require(rows.first?.image)
        view.layout()
        #expect(rows.first?.image === sourceImage, "unchanged source must avoid another image copy")
        surface.findDocumentGeneration += 1
        #expect(cache.image(for: surface) == nil)
        view.needsLayout = true
        view.layout()
        let after = resultButtons(view)
        #expect(after.count == rows.count && zip(after, rows).allSatisfy { $0 === $1 })
        #expect(after.first?.image?.tiffRepresentation != before)
        #expect(after.map(\.state) == selected && selected.contains(.on))
        #expect(scroll.contentView.bounds.origin == origin && origin.y > 0)
        #expect(view.search.stringValue == "Unchanged query")
        #expect(surface.requests.count == 1)
    }

    @Test("Engine refresh retires loading, detached and disposed paint and permits fresh authorized paint")
    func independentInvalidSurfaceEvents() async throws {
        for reason in 0..<3 {
            let controller = FolderPreviewController<SwitcherSnapshotSurface>()
            defer { controller.shutdown() }
            let hooks = BrowserSurfaceEventHooks<SwitcherSnapshotSurface>()
            controller.observeImages(in: hooks)
            let host = NSView()
            let surface = SwitcherSnapshotSurface()
            var attached = true
            // Exercise only installed-image refresh; no key window/anchor is constructed.
            controller.snapshots.onChange = nil
            controller.snapshots.isAttached = { _ in attached }
            try await warm(controller.snapshots, surface)
            host.addSubview(controller.view)
            let results = FolderPreviewResult.ordered([SyntheticOrganization().tab()])
            controller.view.render(results, image: { _ in controller.snapshots.image(for: surface) })
            let row = try #require(resultButtons(controller.view).first)
            let before = try #require(row.image?.tiffRepresentation)
            if reason == 0 { surface.navigationState.isLoading = true }
            if reason == 1 { attached = false }
            if reason == 2 { surface.dispose() }
            hooks.emit(.stateChanged, for: surface)
            #expect(row.image?.tiffRepresentation != before)
            #expect(controller.snapshots.request(surface) == nil && surface.requests.count == 1)
            let fallback = try #require(row.image)
            hooks.emit(.navigationFailed, for: surface)
            #expect(row.image === fallback, "repeated fallback must not restore or recopy stale pixels")
            if reason != 2 {
                attached = true
                surface.navigationState.isLoading = false
                surface.findDocumentGeneration += 1
                try await warm(controller.snapshots, surface)
                hooks.emit(.navigationFinished, for: surface)
                #expect(row.image?.tiffRepresentation == before)
                #expect(resultButtons(controller.view).first === row && surface.requests.count == 2)
            }
        }
    }

    @Test("Resolver clearing and shutdown inside hook delivery release owners and prevent subsequent refreshes")
    func independentCallbackLifetime() throws {
        let hooks = BrowserSurfaceEventHooks<SwitcherSnapshotSurface>()
        let surface = SwitcherSnapshotSurface()
        var controller: FolderPreviewController<SwitcherSnapshotSurface>? = FolderPreviewController()
        weak var weakController = controller
        let host = NSView()
        host.addSubview(controller!.view)
        let results = FolderPreviewResult.ordered([SyntheticOrganization().tab()])
        var reads = 0
        controller!.view.render(results, image: { _ in reads += 1; return nil })
        // Cancel the feature registration from an earlier observer in the same emission.
        let cancellation = hooks.observe { [weak owner = controller] _, _ in owner?.shutdown() }
        controller!.observeImages(in: hooks)
        let before = reads
        hooks.emit(.stateChanged, for: surface)
        #expect(reads == before && controller!.view.superview == nil)
        #expect(resultButtons(controller!.view).isEmpty)
        cancellation.cancel()
        hooks.emit(.navigationFinished, for: surface)
        #expect(reads == before)
        controller = nil
        #expect(weakController == nil, "event hooks must not retain their controller")

        let view = FolderPreviewView()
        var retained: NSObject? = NSObject()
        weak var released = retained
        view.render(results, image: { [owner = retained!] _ in _ = owner; return nil })
        retained = nil
        #expect(released != nil)
        view.clear()
        #expect(released == nil, "clear must release the escaped live resolver")
        view.refreshImages()
        #expect(resultButtons(view).isEmpty)
    }
}
}
