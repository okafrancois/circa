import Testing
@testable import Orbit
@testable import BrowserCore

extension NativeWebKitTests {
@Suite("Independent folder preview R2 cache boundaries")
@MainActor
struct FolderPreviewIndependentR2Tests {
    @Test("Preview retirement cannot retire ordinary switcher paint of the same surface")
    func independentCachePolicyIsolation() async throws {
        let controller = FolderPreviewController<SwitcherSnapshotSurface>()
        let preview = controller.snapshots
        let switcher = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>()
        defer { controller.shutdown(); switcher.shutdown() }
        let surface = SwitcherSnapshotSurface()
        var attached = true
        var previewChanges = 0, switcherChanges = 0
        preview.isAttached = { _ in attached }
        switcher.isAttached = { _ in attached }
        preview.onChange = { previewChanges += 1 }
        switcher.onChange = { switcherChanges += 1 }
        let first = preview.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        try #require(surface.continuations.count == 1)
        let second = switcher.request(surface)
        for _ in 0..<100 where surface.continuations.count < 2 { await Task.yield() }
        try #require(surface.continuations.count == 2)
        attached = false
        surface.complete(generation: 1)
        await first?.value
        surface.complete(generation: 1)
        await second?.value
        #expect(previewChanges == 0 && preview.image(for: surface) == nil)
        #expect(switcherChanges == 1 && switcher.image(for: surface) != nil)
        #expect(switcher.request(surface, force: true) == nil)
        attached = true
        #expect(preview.image(for: surface) == nil)
        let successor = preview.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        try #require(surface.continuations.count == 1)
        surface.complete(generation: 1)
        await successor?.value
        #expect(previewChanges == 1 && preview.image(for: surface) != nil)
        controller.shutdown()
        #expect(preview.image(for: surface) == nil)
        #expect(switcher.image(for: surface) != nil && switcherChanges == 1)
        #expect(surface.requests.count == 3)
    }

    @Test("New document and retired context never expose or revive predecessor pixels")
    func independentDocumentAndContextSuccessor() async throws {
        let controller = FolderPreviewController<SwitcherSnapshotSurface>()
        defer { controller.shutdown() }
        let cache = controller.snapshots, surface = SwitcherSnapshotSurface()
        cache.isAttached = { _ in true }
        var publications = 0
        cache.onChange = { publications += 1 }
        let first = cache.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        try #require(surface.continuations.count == 1)
        surface.complete(generation: 1)
        await first?.value
        #expect(cache.image(for: surface) != nil && publications == 1)
        surface.findDocumentGeneration = 2
        #expect(cache.image(for: surface) == nil)
        let stale = cache.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        try #require(surface.continuations.count == 1)
        controller.view.onSearch?("new synthetic context")
        surface.findDocumentGeneration = 3
        let successor = cache.request(surface)
        for _ in 0..<100 where surface.continuations.count < 2 { await Task.yield() }
        try #require(surface.continuations.count == 2)
        #expect(cache.image(for: surface) == nil)
        surface.complete(generation: 2)
        await stale?.value
        #expect(cache.image(for: surface) == nil && publications == 1)
        surface.complete(generation: 3)
        await successor?.value
        #expect(cache.image(for: surface) != nil && publications == 2)
        surface.findDocumentGeneration = 4
        #expect(cache.image(for: surface) == nil)
    }

    @Test("Profile-only and occurrence-only replacements reject old activation authority")
    func independentExactContextIdentity() {
        let fixture = SyntheticOrganization(), folder = FolderID(), tab = TabID()
        let occurrence = TabOccurrenceID()
        func snapshot(profile: ProfileID, occurrence: TabOccurrenceID) -> BrowserOrganizationSnapshot {
            BrowserOrganizationSnapshot(windowID: fixture.windowID, spaceID: fixture.spaceID,
                profileID: profile, favorites: [],
                pinned: [fixture.folder(folder, [fixture.tab(tab, occurrence: occurrence)])], today: [],
                isPinnedSectionCollapsed: false, archiveRevision: 0, canRestoreArchivedTab: false,
                autoArchiveThreshold: .twelveHours, inheritsAutoArchiveThreshold: true,
                archivedTabCount: 0, undoAction: nil, redoAction: nil)
        }
        let original = snapshot(profile: fixture.profileID, occurrence: occurrence)
        for replacement in [snapshot(profile: ProfileID(), occurrence: occurrence),
                            snapshot(profile: fixture.profileID, occurrence: TabOccurrenceID())] {
            let intent = FolderPreviewIntent()
            var scheduled: (@MainActor () -> Void)?
            intent.schedule = { _, action in scheduled = action; return IndependentPreviewTicket() }
            intent.arm(folder: folder, snapshot: original)
            scheduled?()
            let epoch = intent.epoch, admission = intent.admission
            #expect(intent.permits(tab, epoch: epoch, current: original))
            #expect(!intent.permits(tab, epoch: epoch, current: replacement))
            intent.reconcile(replacement)
            #expect(intent.phase == .idle && intent.results.isEmpty && !admission.isValid)
        }
    }

    @Test("Strict completion rejects changed documents and mismatched snapshot generations")
    func independentCompletionGeneration() async throws {
        let controller = FolderPreviewController<SwitcherSnapshotSurface>()
        defer { controller.shutdown() }
        let cache = controller.snapshots, surface = SwitcherSnapshotSurface()
        cache.isAttached = { _ in true }
        var publications = 0
        cache.onChange = { publications += 1 }
        let old = cache.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        try #require(surface.continuations.count == 1)
        surface.findDocumentGeneration = 2
        surface.complete(generation: 1)
        await old?.value
        #expect(cache.image(for: surface) == nil && publications == 0)
        let mismatched = cache.request(surface)
        for _ in 0..<100 where surface.continuations.isEmpty { await Task.yield() }
        try #require(surface.continuations.count == 1)
        surface.complete(generation: 1)
        await mismatched?.value
        #expect(cache.image(for: surface) == nil && publications == 0)
        #expect(surface.requests.map(\.documentGeneration) == [1, 2])
    }

}
}


@MainActor
private final class IndependentPreviewTicket: OrbitCancellable {
    func cancel() {}
}
