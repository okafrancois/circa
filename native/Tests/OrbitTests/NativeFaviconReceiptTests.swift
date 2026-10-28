import AppKit
@testable import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeFaviconReceiptTests {
    static func png(_ width: Int = 2) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return bitmap.representation(using: .png, properties: [:])!
    }

    @Test("Production default consumes engine PNG for a remote metadata URL without an injected resolver")
    func productionReceipt() async throws {
        let profile = ProfileID()
        let home = URL(string: "https://home.example.test/")!
        let remote = URL(string: "https://icons.example.test/exact.png")!
        let surface = SiteSyntheticSurface(profileID: profile, engine: nil, siteData: .init())
        let delegate = FaviconTestDelegate()
        surface.delegate = delegate
        surface.navigate(to: home)
        surface.faviconURL = remote
        let tab = BrowserOrganizationTabItem(id: TabID(), section: .favorites(profile), url: home,
            pinnedURL: home, pageTitle: nil, customTitle: nil, occurrenceID: nil,
            isLoadedInThisWindow: true, isSelected: false, isOpenInAnotherWindow: false)
        let pipeline = FavoriteIconPipeline<SiteSyntheticSurface>()
        var completions = 0
        pipeline.onChange = { completions += 1 }
        #expect(pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface }) == nil)
        for _ in 0..<100 where completions == 0 { try await Task.sleep(for: .milliseconds(2)) }
        // Same metadata URL and document, but the real owned bytes arrive later.
        surface.faviconImage = BrowserFaviconImage(sourceURL: remote, png: Self.png())
        _ = pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface })
        for _ in 0..<200 where completions < 2 { try await Task.sleep(for: .milliseconds(2)) }
        let image = pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface })
        #expect(image != nil)
        #expect(image?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 2)
        surface.navigate(to: URL(string: "https://away.example.test/")!)
        #expect(pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface }) === image)
        let other = SiteSyntheticSurface(profileID: ProfileID(), engine: nil, siteData: .init())
        #expect(pipeline.image(for: tab, surface: other, isOwned: { _ in true }) == nil)
        #expect(pipeline.image(for: tab, surface: nil, isOwned: { _ in false }) === image)
        other.dispose()
        pipeline.clear()
        #expect(pipeline.image(for: tab, surface: nil, isOwned: { _ in false }) === image)
        surface.dispose()
    }

    @Test("Production resolver requires the exact source URL and honors cancellation")
    func wrongSourceAndCancellation() async {
        let surface = SiteSyntheticSurface(profileID: ProfileID(), engine: nil, siteData: .init())
        let url = URL(string: "https://icons.example.test/owned.png")!
        surface.faviconImage = BrowserFaviconImage(sourceURL: url, png: Self.png())
        let pipeline = FavoriteIconPipeline<SiteSyntheticSurface>()
        #expect(await pipeline.resolve(surface, URL(string: "https://icons.example.test/other.png")!) == nil)
        let task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            return await surface.navigationState.faviconImage?.nativeImage()
        }
        task.cancel()
        #expect(await task.value == nil)
        surface.dispose()
    }

    @Test("Owned representation rejects corrupt and oversized images before pixel decompression")
    func imageBounds() async {
        let url = URL(string: "https://icons.example.test/exact.png")!
        #expect(BrowserFaviconImage(sourceURL: url, png: Data("not png".utf8)) == nil)
        #expect(BrowserFaviconImage(sourceURL: url, png: Self.png(129)) == nil)
        #expect(BrowserFaviconImage(sourceURL: url, png: Data(repeating: 0, count: 131_073)) == nil)
        #expect(await BrowserFaviconImage(sourceURL: url, png: Self.png())?.nativeImage() != nil)
    }
}
}

@MainActor
private final class FaviconTestDelegate: BrowserEngineSurfaceDelegate {
    func surfaceDidStartNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidCommitNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidFinishNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidFailNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidRequestClose(_ surface: SiteSyntheticSurface) {}
    func surface(_ surface: SiteSyntheticSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
    func surface(_ surface: SiteSyntheticSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> SiteSyntheticSurface) -> SiteSyntheticSurface? { nil }
    func surface(_ surface: SiteSyntheticSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
}
