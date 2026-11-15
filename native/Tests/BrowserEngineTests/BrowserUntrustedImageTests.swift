@testable import BrowserEngine
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

enum UntrustedImageFixture {
    static func image(width: Int = 16, height: Int = 16) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func encode(_ type: String, width: Int = 16, height: Int = 16, frames: Int = 1) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, frames, nil) else { return nil }
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image(width: width, height: height), nil) }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static var png: Data { encode(UTType.png.identifier)! }
    static var jpeg: Data { encode(UTType.jpeg.identifier)! }
    static var gif: Data { encode(UTType.gif.identifier)! }
    static var tiff: Data { encode(UTType.tiff.identifier)! }
    static var psd: Data? { encode("com.adobe.photoshop-image") }

    /// A single-entry ICO that embeds a PNG, as modern favicon.ico files do.
    static var ico: Data {
        let payload = png
        var data = Data([0, 0, 1, 0, 1, 0])
        data += [16, 16, 0, 0, 1, 0, 32, 0]
        data += withUnsafeBytes(of: UInt32(payload.count).littleEndian) { Data($0) }
        data += withUnsafeBytes(of: UInt32(22).littleEndian) { Data($0) }
        return data + payload
    }
}

@Suite("Untrusted image gate")
struct BrowserUntrustedImageTests {
    typealias Gate = BrowserUntrustedImage
    let all = BrowserUntrustedImage.webIconFormats

    @Test("PNG, JPEG, GIF and ICO decode through the gate and are bounded to the requested size")
    func acceptsWebIconFormats() throws {
        for (data, format) in [(UntrustedImageFixture.png, Gate.Format.png), (UntrustedImageFixture.jpeg, .jpeg),
                               (UntrustedImageFixture.gif, .gif), (UntrustedImageFixture.ico, .ico)] {
            #expect(Gate.sniff(data) == format)
            let image = try #require(Gate.thumbnail(data, allowing: all, maximumBytes: 1 << 20, maximumPixelSize: 8), "\(format)")
            #expect(max(image.width, image.height) <= 8)
        }
        let large = try #require(UntrustedImageFixture.encode(UTType.png.identifier, width: 512, height: 512))
        let thumbnail = try #require(Gate.thumbnail(large, allowing: [.png], maximumBytes: 1 << 20, maximumPixelSize: 32))
        #expect(thumbnail.width == 32 && thumbnail.height == 32)
    }

    @Test("TIFF, PSD and garbage are refused before ImageIO can sniff them")
    func refusesOtherFormats() throws {
        #expect(Gate.sniff(UntrustedImageFixture.tiff) == nil)
        #expect(Gate.thumbnail(UntrustedImageFixture.tiff, allowing: all, maximumBytes: 1 << 20, maximumPixelSize: 64) == nil)
        let psd = try #require(UntrustedImageFixture.psd)
        #expect(Gate.thumbnail(psd, allowing: all, maximumBytes: 1 << 20, maximumPixelSize: 64) == nil)
        #expect(Gate.thumbnail(Data("not an image".utf8), allowing: all, maximumBytes: 1 << 20, maximumPixelSize: 64) == nil)
        #expect(Gate.thumbnail(Data(), allowing: all, maximumBytes: 1 << 20, maximumPixelSize: 64) == nil)
        #expect(Gate.favicon(UntrustedImageFixture.tiff, sourceURL: URL(string: "https://icon.test/i.tif")!, maximumBytes: 1 << 20) == nil)
    }

    @Test("A format outside the caller's allow-list or a mismatched body is refused")
    func refusesTypeMismatch() {
        #expect(Gate.thumbnail(UntrustedImageFixture.jpeg, allowing: [.png], maximumBytes: 1 << 20, maximumPixelSize: 64) == nil)
        // PNG signature followed by a TIFF body: the hinted PNG decoder must not accept it.
        let disguised = UntrustedImageFixture.png.prefix(8) + UntrustedImageFixture.tiff
        #expect(Gate.thumbnail(disguised, allowing: all, maximumBytes: 1 << 20, maximumPixelSize: 64) == nil)
        // ICO signature followed by a TIFF body.
        let icoTIFF = Data([0, 0, 1, 0]) + UntrustedImageFixture.tiff
        #expect(Gate.thumbnail(icoTIFF, allowing: all, maximumBytes: 1 << 20, maximumPixelSize: 64) == nil)
    }

    @Test("Byte, frame and dimension limits are enforced")
    func limits() throws {
        let png = UntrustedImageFixture.png
        #expect(Gate.thumbnail(png, allowing: [.png], maximumBytes: png.count - 1, maximumPixelSize: 64) == nil)
        #expect(Gate.thumbnail(png, allowing: [.png], maximumBytes: png.count, maximumPixelSize: 64) != nil)
        let animated = try #require(UntrustedImageFixture.encode(UTType.gif.identifier, frames: 3))
        #expect(Gate.thumbnail(animated, allowing: [.gif], maximumBytes: 1 << 20, maximumPixelSize: 64, maximumFrames: 2) == nil)
        #expect(Gate.thumbnail(animated, allowing: [.gif], maximumBytes: 1 << 20, maximumPixelSize: 64, maximumFrames: 3) != nil)
        let wide = try #require(UntrustedImageFixture.encode(UTType.png.identifier, width: 300, height: 10))
        #expect(Gate.thumbnail(wide, allowing: [.png], maximumBytes: 1 << 20, maximumPixelSize: 64, maximumDimension: 256) == nil)
    }

    @Test("Favicons re-encode allowed formats as owned PNGs and engine PNGs stay PNG-only")
    func faviconReencoding() throws {
        let source = URL(string: "https://icon.test/favicon.ico")!
        for data in [UntrustedImageFixture.jpeg, UntrustedImageFixture.gif, UntrustedImageFixture.ico] {
            let favicon = try #require(Gate.favicon(data, sourceURL: source, maximumBytes: 1 << 20))
            #expect(favicon.png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        }
        #expect(BrowserFaviconImage(sourceURL: source, png: UntrustedImageFixture.png) != nil)
        #expect(BrowserFaviconImage(sourceURL: source, png: UntrustedImageFixture.jpeg) == nil)
        #expect(BrowserFaviconImage(sourceURL: source, png: UntrustedImageFixture.png.prefix(8) + UntrustedImageFixture.tiff) == nil)
    }

    @Test("Streamed downloads stop at the byte cap")
    func collectCap() async throws {
        let bytes = AsyncStream<UInt8> { continuation in
            for _ in 0..<100 { continuation.yield(1) }
            continuation.finish()
        }
        #expect(try await Gate.collect(bytes, expectedLength: -1, maximumBytes: 99) == nil)
        let exact = AsyncStream<UInt8> { continuation in
            for _ in 0..<100 { continuation.yield(1) }
            continuation.finish()
        }
        #expect(try await Gate.collect(exact, expectedLength: 100, maximumBytes: 100)?.count == 100)
        let declared = AsyncStream<UInt8> { $0.finish() }
        #expect(try await Gate.collect(declared, expectedLength: 101, maximumBytes: 100) == nil)
    }
}
