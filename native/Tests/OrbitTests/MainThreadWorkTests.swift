import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing
@testable import Orbit

@MainActor
private final class CacheTransfer: BrowserDownloadTransfer {
    var actions: [BrowserDownloadAction] = []
    func perform(_ action: BrowserDownloadAction, completion: @escaping @MainActor (Result<Void, BrowserDownloadError>) -> Void) { actions.append(action); completion(.success(())) }
    func invalidate() {}
}

@Suite("Bounded capture and asynchronous download metadata", .serialized)
@MainActor
struct MainThreadWorkTests {
    @Test("Fresh outgoing paint is reused briefly, pending captures coalesce, and SPA paint expires")
    func captures() async throws {
        let cache = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>()
        let surface = SwitcherSnapshotSurface()
        cache.isAttached = { _ in true }
        var now = 0.0
        cache.now = { now }
        defer { cache.shutdown() }
        let first = cache.request(surface, freshness: 0.3)
        while surface.continuations.isEmpty { await Task.yield() }
        let duplicate = cache.request(surface, force: true)
        #expect(surface.requests.count == 1)
        surface.complete(generation: 1)
        await first?.value; await duplicate?.value
        now = 0.2
        #expect(cache.request(surface, freshness: 0.3) == nil)
        #expect(cache.image(for: surface) != nil)
        now = 0.31
        let refresh = cache.request(surface, freshness: 0.3)
        while surface.continuations.isEmpty { await Task.yield() }
        #expect(surface.requests.count == 2)
        #expect(cache.image(for: surface) != nil, "known paint stays available while refreshing")
        cache.cancelPendingCapture(for: surface)
        #expect(cache.image(for: surface) != nil, "returning preserves the previous completed paint")
        cache.invalidate(surface)
        surface.complete(generation: 1)
        await refresh?.value
        #expect(cache.image(for: surface) == nil)
    }

    @Test("Displayed controls survive throttled bytes but reject intervening control/state changes")
    func displayedActions() throws {
        let controller = BrowserDownloadsController()
        defer { controller.shutdown() }
        let transfer = CacheTransfer()
        let item = try controller.coordinator.register(owner: .init(profileID: ProfileID()), transfer: transfer)
        item.report(.init(key: item.key, sequence: 1, state: .running, capabilities: [.pause, .cancel]))
        let displayed = try #require(controller.coordinator.snapshot(for: item.key)).context
        item.report(.init(key: item.key, sequence: 2, state: .running, receivedBytes: 100, capabilities: [.pause, .cancel]))
        controller.perform(.pause, in: displayed)
        #expect(transfer.actions == [.pause])
        controller.perform(.cancel, in: displayed)
        #expect(transfer.actions == [.pause], "the acknowledgement supersedes the displayed context")
    }

    @Test("Rendering never probes disk; a batch caches results and directory invalidation refreshes move/delete")
    func fileCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-file-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("item.bin")
        try Data([1]).write(to: file)
        let controller = BrowserDownloadsController()
        defer { controller.shutdown() }
        controller.fileCheck = { url in
            precondition(!Thread.isMainThread)
            Thread.sleep(forTimeInterval: 0.02)
            return BrowserDownloadPaths.regularFileSize(url) != nil
        }
        let profile = ProfileID()
        let item = try controller.coordinator.register(owner: .init(profileID: profile), transfer: CacheTransfer())
        item.report(.init(key: item.key, sequence: 1, state: .complete, destinationURL: file))
        #expect(controller.snapshots(profileID: profile).first?.fileAvailability == .unknown)
        for _ in 0..<100 where controller.coordinator.snapshot(for: item.key)?.fileAvailability != .available {
            try await Task.sleep(for: .milliseconds(5))
        }
        let checked = try #require(controller.coordinator.snapshot(for: item.key))
        for _ in 0..<20 { _ = controller.snapshots(profileID: profile) }
        #expect(controller.coordinator.snapshot(for: item.key)?.revision == checked.revision)
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("moved.bin"))
        for _ in 0..<100 where controller.coordinator.snapshot(for: item.key)?.fileAvailability != .missing {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.coordinator.snapshot(for: item.key)?.fileAvailability == .missing)
        try Data([2]).write(to: file)
        controller.invalidateFileChecks(in: root)
        let context = try #require(controller.coordinator.snapshot(for: item.key)).context
        try controller.coordinator.remove(in: context)
        try await Task.sleep(for: .milliseconds(60))
        #expect(controller.snapshots(profileID: profile).isEmpty, "a stale IO reply cannot resurrect a removed item")
    }
}
