import Foundation
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Folder preview capture cancellation")
@MainActor
struct FolderPreviewCaptureTests {
    @Test("A detached folder tab reuses its recent visible paint without another engine capture")
    func previouslyVisibleDocumentPaint() async throws {
        let controller = FolderPreviewController<SwitcherSnapshotSurface>()
        let outgoing = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>()
        let surface = SwitcherSnapshotSurface()
        var attached = true
        var now: TimeInterval = 100
        outgoing.now = { now }
        outgoing.isAttached = { _ in attached }
        controller.snapshots.isAttached = { _ in attached }
        controller.previouslyVisibleSnapshots = outgoing
        defer { controller.shutdown(); outgoing.shutdown() }
        let capture = outgoing.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        surface.complete(generation: 1)
        await capture?.value
        attached = false
        #expect(controller.previewImage(for: surface) != nil)
        #expect(surface.requests.count == 1)
        #expect(controller.previewImage(for: SwitcherSnapshotSurface()) == nil)
        surface.findDocumentGeneration += 1
        #expect(controller.previewImage(for: surface) == nil)
        surface.findDocumentGeneration -= 1
        now += outgoing.maximumAge + 1
        #expect(controller.previewImage(for: surface) == nil)
        #expect(surface.requests.count == 1)
        now = 100
        #expect(controller.previewImage(for: surface) != nil)
        surface.dispose()
        #expect(controller.previewImage(for: surface) == nil)
    }

    @Test("A preview capture detached before completion cannot publish pixels")
    func independentDetachedCompletionRegression() async {
        let controller = FolderPreviewController<SwitcherSnapshotSurface>()
        let surface = SwitcherSnapshotSurface()
        var attached = true
        var publications = 0
        controller.snapshots.isAttached = { _ in attached }
        controller.snapshots.onChange = { publications += 1 }
        let capture = controller.snapshots.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        #expect(surface.continuations.count == 1)
        attached = false // Host detached without disposal or a document-generation change.
        surface.complete(generation: 1)
        await capture?.value
        #expect(publications == 0)
        #expect(controller.snapshots.image(for: surface) == nil)
        controller.shutdown()
    }

    @Test("Search retirement cancels old captures and late pixels cannot replace the successor")
    func searchCancellationAndSuccessor() async {
        let controller = FolderPreviewController<SwitcherSnapshotSurface>()
        let surface = SwitcherSnapshotSurface()
        let cache = controller.snapshots
        cache.isAttached = { _ in true } // No window, engine or page is launched.
        let first = cache.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        #expect(surface.continuations.count == 1)
        controller.view.onSearch?("synthetic")
        let successor = cache.request(surface)
        for _ in 0..<100 where surface.continuations.count < 2 { await Task.yield() }
        #expect(surface.continuations.count == 2)
        surface.complete(generation: 1)
        await first?.value
        #expect(cache.image(for: surface) == nil)
        surface.complete(generation: 1)
        await successor?.value
        #expect(cache.image(for: surface) != nil)
        controller.shutdown()
        #expect(cache.image(for: surface) == nil)
    }

    @Test("The shared memory LRU stays bounded and revokes evicted pending captures")
    func boundedCache() async {
        let cache = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>()
        cache.isAttached = { _ in true }
        let surfaces = (0..<(cache.capacity + 1)).map { _ in SwitcherSnapshotSurface() }
        var tasks: [Task<Void, Never>?] = []
        for surface in surfaces {
            tasks.append(cache.request(surface))
            for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        }
        for (surface, task) in zip(surfaces, tasks) {
            #expect(surface.continuations.count == 1)
            surface.complete(generation: 1)
            await task?.value
        }
        #expect(cache.image(for: surfaces[0]) == nil)
        #expect(surfaces.filter { cache.image(for: $0) != nil }.count == cache.capacity)
        surfaces[1].findDocumentGeneration += 1
        #expect(cache.image(for: surfaces[1]) == nil)
        cache.shutdown()
        #expect(surfaces.allSatisfy { cache.image(for: $0) == nil })
    }
}
}
