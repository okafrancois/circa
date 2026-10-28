import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Folder preview R2 attachment authority")
@MainActor
struct FolderPreviewR2Tests {
    @Test("Strict preview reads retire completed pixels on detachment, including before a new request")
    func completedPreviewDetachment() async {
        let cache = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>(attachmentPolicy: .attachedOnly)
        let surface = SwitcherSnapshotSurface()
        var attached = true
        cache.isAttached = { _ in attached }
        let capture = cache.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        #expect(surface.continuations.count == 1)
        surface.complete(generation: 1)
        await capture?.value
        #expect(cache.image(for: surface) != nil)
        attached = false
        #expect(cache.image(for: surface) == nil)
        #expect(cache.request(surface) == nil)
        #expect(surface.requests.count == 1)
        attached = true
        #expect(cache.image(for: surface) == nil, "observed detachment retires the previous attachment's paint")
        cache.shutdown()
    }

    @Test("Strict preview request retires a detached pending capture before cached-request reuse")
    func pendingRequestDetachment() async {
        let cache = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>(attachmentPolicy: .attachedOnly)
        let surface = SwitcherSnapshotSurface()
        var attached = true, publications = 0
        cache.isAttached = { _ in attached }
        cache.onChange = { publications += 1 }
        let capture = cache.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        #expect(surface.continuations.count == 1)
        attached = false
        #expect(cache.request(surface) == nil)
        attached = true
        surface.complete(generation: 1)
        await capture?.value
        #expect(cache.image(for: surface) == nil && publications == 0)
        cache.shutdown()
    }

    @Test("Default switcher policy retains detached completion and cached paint without hidden recapture")
    func switcherDetachedReuseIsPreserved() async {
        let cache = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>()
        let surface = SwitcherSnapshotSurface()
        var attached = true, publications = 0
        cache.isAttached = { _ in attached }
        cache.onChange = { publications += 1 }
        let capture = cache.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        #expect(surface.continuations.count == 1)
        attached = false
        surface.complete(generation: 1)
        await capture?.value
        #expect(publications == 1 && cache.image(for: surface) != nil)
        #expect(cache.request(surface, force: true) == nil)
        #expect(cache.image(for: surface) != nil && surface.requests.count == 1)
        cache.shutdown()
    }
}
}
