import AppKit
@testable import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct FaviconNativeR2Tests {
    @Test("Allowed image source identities are bounded and never invoke a loader")
    func sourceIdentities() {
        let png = NativeFaviconReceiptTests.png()
        for value in ["http://fixture.test/icon.png", "https://fixture.test/icon.png", "data:image/png;base64,AA=="] {
            #expect(BrowserFaviconImage(sourceURL: URL(string: value)!, png: png) != nil)
        }
        for value in ["http:", "data:text/plain,icon", "data:image/png", "chrome-extension://synthetic/icon.png",
                      "file:///synthetic/icon.png", "data:image/png," + String(repeating: "a", count: 8_192)] {
            #expect(BrowserFaviconImage(sourceURL: URL(string: value)!, png: png) == nil)
        }
    }

    @Test("Home image survives loading, document reset, away metadata and dormancy and previously obtained pixels survive empty metadata")
    func retentionAndRemoval() async throws {
        let surface = SwitcherSnapshotSurface()
        let home = URL(string: "https://home.example.test/")!
        let icon = URL(string: "https://icons.example.test/owned.png")!
        let tab = BrowserOrganizationTabItem(id: TabID(), section: .favorites(surface.profileID), url: home,
            pinnedURL: home, pageTitle: nil, customTitle: nil, occurrenceID: nil,
            isLoadedInThisWindow: true, isSelected: false, isOpenInAnotherWindow: false)
        let pipeline = FavoriteIconPipeline<SwitcherSnapshotSurface>()
        surface.navigationState = BrowserNavigationState(url: home, committedURL: home, faviconURL: icon)
        surface.navigationState.faviconImage = BrowserFaviconImage(sourceURL: icon, png: NativeFaviconReceiptTests.png())
        var completions = 0
        pipeline.onChange = { completions += 1 }
        _ = pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface })
        for _ in 0..<300 where completions == 0 { try await Task.sleep(for: .milliseconds(2)) }
        let decoded = pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface })
        let image = try #require(decoded)
        surface.navigationState.faviconURL = nil
        surface.navigationState.faviconImage = nil
        surface.navigationState.isLoading = true
        #expect(pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface }) === image)
        surface.navigationState.isLoading = false
        surface.navigationState.faviconMetadataIsSettled = false
        surface.findDocumentGeneration += 1
        #expect(pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface }) === image)
        surface.navigationState.committedURL = URL(string: "https://away.example.test/")!
        surface.navigationState.faviconMetadataIsSettled = true
        #expect(pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface }) === image)
        #expect(pipeline.image(for: tab, surface: nil, isOwned: { _ in false }) === image)
        surface.navigationState.committedURL = home
        #expect(pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface }) != nil)
        // Missing metadata cannot erase pixels already obtained for this profile and home.
        surface.navigationState.faviconURL = icon
        surface.navigationState.faviconImage = BrowserFaviconImage(sourceURL: icon, png: NativeFaviconReceiptTests.png())
        _ = pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface })
        for _ in 0..<300 where completions < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface }) != nil)
        surface.navigationState.faviconImage = nil
        surface.navigationState.faviconRevision += 1
        _ = pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface })
        for _ in 0..<300 where completions < 3 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface }) != nil)
        pipeline.clear()
        surface.dispose()
    }

    @Test("An awaited resolver cannot erase a retained home image after navigation away")
    func lateEmptyResult() async throws {
        let surface = SwitcherSnapshotSurface()
        let home = URL(string: "https://home.example.test/")!
        let icon = URL(string: "https://icons.example.test/owned.png")!
        let tab = BrowserOrganizationTabItem(id: TabID(), section: .favorites(surface.profileID), url: home,
            pinnedURL: home, pageTitle: nil, customTitle: nil, occurrenceID: nil,
            isLoadedInThisWindow: true, isSelected: false, isOpenInAnotherWindow: false)
        let pipeline = FavoriteIconPipeline<SwitcherSnapshotSurface>()
        let image = NSImage(size: NSSize(width: 2, height: 2))
        var continuation: CheckedContinuation<NSImage?, Never>?
        pipeline.resolve = { _, _ in image }
        surface.navigationState = BrowserNavigationState(url: home, committedURL: home, faviconURL: icon)
        _ = pipeline.image(for: tab, surface: surface, isOwned: { _ in true })
        for _ in 0..<20 { await Task.yield() }
        #expect(pipeline.image(for: tab, surface: surface, isOwned: { _ in true }) === image)
        pipeline.resolve = { _, _ in await withCheckedContinuation { continuation = $0 } }
        surface.navigationState.faviconRevision += 1
        _ = pipeline.image(for: tab, surface: surface, isOwned: { _ in true })
        for _ in 0..<50 where continuation == nil { await Task.yield() }
        #expect(continuation != nil)
        surface.navigationState.committedURL = URL(string: "https://away.example.test/")!
        continuation?.resume(returning: nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(pipeline.image(for: tab, surface: surface, isOwned: { _ in true }) === image)
        pipeline.clear()
        surface.dispose()
    }
}
}
