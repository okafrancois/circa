import AppKit
import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

private final class ProductIconProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var image = Data()
        var succeeds = true
        var urls: [URL] = []
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let (image, succeeds) = Self.state.lock.withLock {
            Self.state.urls.append(url)
            return (Self.state.image, Self.state.succeeds)
        }
        let product = url.path == "/favicon.ico" && url.host == "mail.google.com"
            || url.path.hasSuffix("/calendar_31.ico")
        let home = url.path == "/"
        let final = home ? URL(string: "https://accounts.google.com/signin")! : url
        let html = Data("<link rel='icon' href='https://accounts.google.com/generic.png'>".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: final, statusCode: home || product && succeeds ? 200 : 404,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: product && succeeds ? image : html)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor
struct FavoriteProductIconTests {
    private func store(succeeds: Bool) throws -> FavoriteIconStore {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.bitmapData)
        bytes.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        ProductIconProtocol.state.lock.withLock {
            ProductIconProtocol.state.image = png
            ProductIconProtocol.state.succeeds = succeeds
            ProductIconProtocol.state.urls = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProductIconProtocol.self]
        return FavoriteIconStore(configuration: configuration)
    }

    @Test("Signed-out product homes resolve their own icon before requesting sign-in HTML",
          arguments: ["https://mail.google.com/", "https://gmail.com/", "https://calendar.google.com/"])
    func productIcon(home: String) async throws {
        let store = try store(succeeds: true), url = try #require(URL(string: home))
        let image = try #require(await store.image(profile: ProfileID(), home: url))
        #expect(image.sourceURL.host != "accounts.google.com")
        let requests = ProductIconProtocol.state.lock.withLock { ProductIconProtocol.state.urls }
        #expect(requests.count == 1)
        #expect(requests[0].path != "/")
        #expect(FavoriteIconStore.decode(image.png, source: image.sourceURL) != nil)
    }

    @Test("Missing product artwork never borrows the sign-in host's generic icon")
    func missingProduct() async throws {
        let store = try store(succeeds: false)
        #expect(await store.image(profile: ProfileID(), home: URL(string: "https://calendar.google.com/")!) == nil)
        let requests = ProductIconProtocol.state.lock.withLock { ProductIconProtocol.state.urls }
        #expect(!requests.contains { $0.host == "accounts.google.com" })
    }
}
