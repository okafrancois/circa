import BrowserCore
import BrowserShell
import Foundation
import Testing

@MainActor
private final class PerfSurface: BrowserSurface {
    let currentURL: URL?
    var disposalCount = 0
    var suspension: BrowserSurfaceSuspensionResult = .unsupported
    var suspensionCount = 0
    func suspendInPlace() -> BrowserSurfaceSuspensionResult { suspensionCount += 1; return suspension }
    init(_ url: URL) { currentURL = url }
    func dispose() { disposalCount += 1 }
}

@Suite("Lazy restoration and background surface retirement")
@MainActor
struct PerfCoreTests {
    @Test("Sixty restored tabs across three Spaces create only one visible surface")
    func lazyRestore() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        var spaces: [SpaceID] = []
        for index in 0..<3 { spaces.append(try await store.createSpace(name: "Space \(index)", profileID: profile)) }
        let window = try await store.createWindow(activeSpaceID: spaces[0])
        for space in spaces {
            let context = try await store.captureContext(in: window)
            _ = try await store.activateSpace(space, from: context)
            for index in 0..<20 {
                let context = try await store.captureContext(in: window)
                _ = try await store.openTab(url: URL(string: "https://example.test/\(index)")!, from: context, activate: true)
            }
        }
        var created: [PerfSurface] = []
        let session = BrowserWindowSession(store: store, restoringWindowID: window, makeSurface: { _, url in
            let surface = PerfSurface(url); created.append(surface); return surface
        })
        session.surfaceLoadingPolicy = .visibleOnly
        await session.waitForQueuedCommands()
        #expect(created.count == 1)
        #expect(session.snapshot?.tabs.count == 20)
        #expect(await store.sessionDocument().tabs.count == 60)
        let tab = try #require(session.snapshot?.tabs.first)
        session.selectOccurrence(tab.occurrenceID)
        await session.waitForQueuedCommands()
        #expect(created.count == 2)
        session.activateSpace(spaces[0])
        await session.waitForQueuedCommands()
        #expect(created.count == 3)
        session.close()
        await session.waitForPendingCommands()
        #expect(created.allSatisfy { $0.disposalCount == 1 })
    }

    @Test("Retirement keeps sidebar identity and order; selection creates a fresh engine")
    func suspendAndReload() async throws {
        let store = BrowserStore()
        let session = BrowserWindowSession(store: store, makeSurface: { _, url in PerfSurface(url) })
        session.surfaceLoadingPolicy = .visibleOnly
        session.openTab(url: URL(string: "https://example.test/one")!)
        session.openTab(url: URL(string: "https://example.test/two")!)
        await session.waitForQueuedCommands()
        let snapshot = try #require(session.snapshot)
        let backgroundID = snapshot.tabs[0].occurrenceID
        let first = try #require(session.surface(for: backgroundID))
        let selected = try #require(session.selectedSurface)
        #expect(!session.suspendSurface(selected))
        #expect(session.suspendSurface(first))
        #expect(first.disposalCount == 1)
        #expect(session.snapshot == snapshot)
        #expect(session.surface(for: backgroundID) == nil)
        session.refreshCatalog()
        await session.waitForQueuedCommands()
        #expect(session.surface(for: backgroundID) == nil)
        session.selectOccurrence(backgroundID)
        await session.waitForQueuedCommands()
        let reloaded = try #require(session.selectedSurface)
        #expect(reloaded !== first)
        #expect(reloaded.currentURL == first.currentURL)
        #expect(session.snapshot?.tabs.map(\.occurrenceID) == snapshot.tabs.map(\.occurrenceID))
        session.selectOccurrence(snapshot.tabs[1].occurrenceID)
        #expect(!session.suspendSurface(reloaded), "Queued selection prevents a stale safety result from retiring a surface")
        await session.waitForQueuedCommands()
        session.close()
        await session.waitForPendingCommands()
    }

    @Test("Native discard keeps ownership and a refusal never disposes history", arguments: [false, true])
    func inPlaceSuspension(accepted: Bool) async throws {
        let session = BrowserWindowSession(store: BrowserStore(), makeSurface: { _, url in PerfSurface(url) })
        session.surfaceLoadingPolicy = .visibleOnly
        session.openTab(url: URL(string: "https://example.test/history")!)
        session.openTab(url: URL(string: "https://example.test/selected")!)
        await session.waitForQueuedCommands()
        let tabs = try #require(session.snapshot?.tabs)
        let first = try #require(session.surface(for: tabs[0].occurrenceID))
        first.suspension = accepted ? .suspended : .refused
        #expect(session.suspendSurface(first) == accepted)
        #expect(first.suspensionCount == 1 && first.disposalCount == 0)
        #expect(session.surface(for: tabs[0].occurrenceID) === first)
        session.selectOccurrence(tabs[0].occurrenceID)
        await session.waitForQueuedCommands()
        #expect(session.selectedSurface === first)
        #expect(!session.suspendSurface(first))
        #expect(first.suspensionCount == 1)
        session.close()
        await session.waitForPendingCommands()
        #expect(first.disposalCount == 1)
    }

    @Test("Every visible Split pane is created and protected from retirement")
    func lazySplit() async throws {
        let store = BrowserStore()
        let original = BrowserWindowSession(store: store, makeSurface: { _, url in PerfSurface(url) })
        for index in 0..<3 { original.openTab(url: URL(string: "https://example.test/\(index)")!) }
        await original.waitForQueuedCommands()
        let tabs = try #require(original.snapshot?.tabs)
        original.createSplit(Array(tabs.prefix(2).map(\.id)))
        await original.waitForQueuedCommands()
        let window = try #require(original.snapshot?.id)
        let restoredStore = try BrowserStore(restoring: await store.sessionDocument())
        original.close()
        await original.waitForPendingCommands()
        let session = BrowserWindowSession(store: restoredStore, restoringWindowID: window, makeSurface: { _, url in PerfSurface(url) })
        session.surfaceLoadingPolicy = .visibleOnly
        await session.waitForQueuedCommands()
        #expect(session.ownedSurfaces.count == 2)
        #expect(session.visibleOccurrenceIDs.count == 2)
        for surface in session.ownedSurfaces { #expect(!session.suspendSurface(surface)) }
        session.close()
        await session.waitForPendingCommands()
    }
}
