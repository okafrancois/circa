import AppKit
@testable import BrowserCore
import BrowserEngine
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Orbit

@MainActor
@Suite("Untrusted favicons and IDN rows in the shell")
struct SecImageIDNTests {
    private static func encode(_ type: UTType) -> Data {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test("The palette decodes engine PNG references and refuses a TIFF disguised as a PNG data URL")
    func paletteFavicons() async throws {
        let cache = BrowserPaletteFaviconCache()
        let engine = try #require(BrowserFaviconImage(sourceURL: URL(string: "https://site.test/favicon.ico")!, png: Self.encode(.png)))
        #expect(cache.image(for: engine) == nil)
        let tiff = URL(string: "data:image/png;base64," + Self.encode(.tiff).base64EncodedString())!
        let typed = URL(string: "data:image/x-icon;base64," + Self.encode(.png).base64EncodedString())!
        #expect(cache.image(for: tiff) == nil)
        #expect(cache.image(for: typed) == nil)
        #expect(cache.cacheStatistics["pending"] == 1) // only the engine image was queued
        await cache.waitForPendingImages()
        #expect(cache.image(for: engine) != nil)
        #expect(cache.image(for: tiff) == nil)
    }

    @Test("History stores engine pixels or a never-fetched web URL, never a page data URL")
    func historyFallback() async throws {
        let png = Self.encode(.png)
        let pageData = URL(string: "data:image/png;base64," + png.base64EncodedString())!
        #expect(await BrowserHistoryRecorder.encodeFavicon(nil, fallback: pageData) == nil)
        let web = URL(string: "https://site.test/favicon.ico")!
        #expect(await BrowserHistoryRecorder.encodeFavicon(nil, fallback: web) == web)
        let engine = try #require(BrowserFaviconImage(sourceURL: pageData, png: png))
        #expect(await BrowserHistoryRecorder.encodeFavicon(engine, fallback: pageData) == BrowserHistoryFavicon.reference(png: png))
    }

    @Test("Network favicon discovery accepts web formats and refuses TIFF")
    func networkDecode() {
        let source = URL(string: "https://site.test/favicon.ico")!
        #expect(FavoriteIconStore.decode(Self.encode(.jpeg), source: source) != nil)
        #expect(FavoriteIconStore.decode(Self.encode(.gif), source: source) != nil)
        #expect(FavoriteIconStore.decode(Self.encode(.ico), source: source) != nil)
        #expect(FavoriteIconStore.decode(Self.encode(.tiff), source: source) == nil)
    }

    @Test("Palette rows show lookalike hosts in ASCII and never host-match an ASCII query")
    func paletteHosts() {
        #expect(BrowserPaletteRanking.displayURL(URL(string: "https://xn--pple-43d.com/")!) == "xn--pple-43d.com")
        #expect(BrowserPaletteRanking.displayURL(URL(string: "https://www.münchen.de/")!) == "münchen.de")
        let lookalike = BrowserPaletteResult(id: "tab:1", title: "Search", detail: "", section: .tabs,
                                             action: .navigate(URL(string: "https://göögle.com/")!))
        let real = BrowserPaletteResult(id: "tab:2", title: "Search", detail: "", section: .tabs,
                                        action: .navigate(URL(string: "https://google.com/")!))
        #expect(!BrowserPaletteRanking.isStrongMatch(lookalike, query: "google", destination: nil))
        #expect(BrowserPaletteRanking.isStrongMatch(real, query: "google", destination: nil))
        let rows = BrowserPaletteRanking.results(query: "google", mode: .newTab, resolver: .init(),
                                                 candidates: [lookalike, real], history: [], actions: [])
        #expect(rows.contains { $0.id == "tab:2" } && !rows.contains { $0.id == "tab:1" })
    }
}
