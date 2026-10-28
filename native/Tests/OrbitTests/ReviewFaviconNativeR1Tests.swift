import AppKit
@testable import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct ReviewFaviconNativeR1Tests {
    private func png(width: Int) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return bitmap.representation(using: .png, properties: [:])!
    }

    @Test("Owned image boundary independently rejects privileged source URL schemes")
    func sourceSchemeBoundary() {
        for address in ["file:///synthetic/icon.png", "chrome://favicon/synthetic", "javascript:synthetic", "about:blank"] {
            #expect(BrowserFaviconImage(sourceURL: URL(string: address)!, png: png(width: 2)) == nil)
        }
        #expect(BrowserFaviconImage(sourceURL: URL(string: "https://fixture.example.test/icon.png")!, png: png(width: 2)) != nil)
    }

    @Test("Same URL new bytes replaces the native image; no-image metadata retains the last known home image")
    func replacementAndNoImage() async throws {
        let profile = ProfileID()
        let home = URL(string: "https://fixture.example.test/")!
        let icon = URL(string: "https://fixture.example.test/icon.png")!
        let surface = SiteSyntheticSurface(profileID: profile, engine: nil, siteData: .init())
        let delegate = ReviewFaviconDelegate()
        surface.delegate = delegate
        surface.navigate(to: home)
        let tab = BrowserOrganizationTabItem(id: TabID(), section: .favorites(profile), url: home,
            pinnedURL: home, pageTitle: nil, customTitle: nil, occurrenceID: nil,
            isLoadedInThisWindow: true, isSelected: false, isOpenInAnotherWindow: false)
        let pipeline = FavoriteIconPipeline<SiteSyntheticSurface>()
        var completions = 0
        pipeline.onChange = { completions += 1 }
        surface.faviconURL = icon
        surface.faviconImage = BrowserFaviconImage(sourceURL: icon, png: png(width: 2))
        _ = pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface })
        for _ in 0..<300 where completions < 1 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(completions == 1)
        #expect(pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface })?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 2)
        surface.faviconImage = BrowserFaviconImage(sourceURL: icon, png: png(width: 3))
        _ = pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface })
        for _ in 0..<300 where completions < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(completions == 2)
        #expect(pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface })?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 3)
        surface.faviconURL = nil
        surface.faviconImage = nil
        #expect(pipeline.image(for: tab, surface: surface, isOwned: { $0 === surface })?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 3)
        pipeline.clear()
        surface.dispose()
    }
}
}

@MainActor
private final class ReviewFaviconDelegate: BrowserEngineSurfaceDelegate {
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
