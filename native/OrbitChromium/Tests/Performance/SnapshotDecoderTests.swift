import BrowserEngine
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct SnapshotDecoderTests {
    static func main() async {
        let context = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let response = try! JSONSerialization.data(withJSONObject: ["data": (data as Data).base64EncodedString()])
        let thumbnail = ChromiumSnapshotDecoder.decode(response, width: 40, generation: 77)!
        precondition(thumbnail.snapshot.image.width == 40 && thumbnail.snapshot.image.height == 20)
        precondition(thumbnail.snapshot.documentGeneration == 77)
        precondition(thumbnail.decodedBytes <= 40 * 20 * 8)
        let original = ChromiumSnapshotDecoder.decode(response, width: nil, generation: 78)!
        precondition(original.snapshot.image.width == 100 && original.snapshot.image.height == 50)
        precondition(ChromiumSnapshotDecoder.decode(Data(), width: 40, generation: 0) == nil)
        let malformed = try! JSONSerialization.data(withJSONObject: ["data": "not-an-image"])
        precondition(ChromiumSnapshotDecoder.decode(malformed, width: 40, generation: 0) == nil)
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ChromiumSnapshotDecoder.decode(response, width: 40, generation: 0) == nil
        }.value
        precondition(cancelled, "cancelled work never enters ImageIO")
        let target = ChromiumSnapshotDecoder.nativeRequest(size: CGSize(width: 1000, height: 600), scale: 2, width: 200)!
        precondition(target.outputWidth == 200 && target.outputHeight == 120)
        precondition(ChromiumSnapshotDecoder.nativeRequest(size: CGSize(width: 1000, height: 600), scale: 2, width: nil)!.outputWidth == 2000)
        for width: CGFloat in [.nan, .infinity, 0, -1, 4097] {
            precondition(ChromiumSnapshotDecoder.nativeRequest(size: CGSize(width: 1000, height: 600), scale: 2, width: width) == nil)
        }
        precondition(ChromiumSnapshotDecoder.nativeRequest(size: CGSize(width: 1, height: 5000), scale: 1, width: nil) == nil)
        precondition(ChromiumSnapshotDecoder.nativeRequest(size: .zero, scale: 2, width: 200) == nil)
        let bgra = Data([30, 60, 90, 255, 12, 24, 36, 255])
        let native = BrowserNativeCapture(status: .captured, width: 2, height: 1, rowBytes: 8, pixels: bgra)
        let nativeImage = ChromiumSnapshotDecoder.nativeImage(native)!
        precondition(nativeImage.width == 2 && nativeImage.height == 1)
        precondition(nativeImage.colorSpace?.name == CGColorSpace.sRGB)
        let rgba = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        rgba.draw(nativeImage, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        let pixels = rgba.data!.assumingMemoryBound(to: UInt8.self)
        precondition(Array(UnsafeBufferPointer(start: pixels, count: 8)) == [90, 60, 30, 255, 36, 24, 12, 255], "BGRA must not swap red and blue")
        for invalid in [BrowserNativeCapture(status: .unavailable),
                        .init(status: .captured, width: 2, height: 1, rowBytes: 4, pixels: bgra),
                        .init(status: .captured, width: 2, height: 1, rowBytes: 8, pixels: Data([0])),
                        .init(status: .captured, width: 5000, height: 1, rowBytes: 20000)] {
            precondition(ChromiumSnapshotDecoder.nativeImage(invalid) == nil)
        }
        let nativeCancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return ChromiumSnapshotDecoder.nativeImage(native) == nil
        }.value
        precondition(nativeCancelled)
        print("PASS snapshot dimensions, generation, full resolution and invalid payload rejection")
    }
}
