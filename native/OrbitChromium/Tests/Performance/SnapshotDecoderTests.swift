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
        print("PASS snapshot dimensions, generation, full resolution and invalid payload rejection")
    }
}
