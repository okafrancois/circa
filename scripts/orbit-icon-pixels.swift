// Offscreen roundtrip pixel comparison; no application, workspace, network or Keychain APIs.
import CoreGraphics
import Foundation
import ImageIO

func pixels(_ url: URL, size: Int) -> [UInt8] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == size, image.height == size else {
        fatalError("Invalid image dimensions: \(url.lastPathComponent), expected \(size)")
    }
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                     count: size * size * 4))
}

let reference = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let decoded = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
var failures = 0
for logicalSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = logicalSize * scale
        let name = "icon_\(logicalSize)x\(logicalSize)\(scale == 2 ? "@2x" : "").png"
        let expected = pixels(reference.appendingPathComponent("\(size).png"), size: size)
        let actual = pixels(decoded.appendingPathComponent(name), size: size)
        let differences = zip(expected, actual).filter { $0 != $1 }.count
        let maximum = zip(expected, actual).map { abs(Int($0) - Int($1)) }.max()!
        print("\(name): \(differences) differing RGBA bytes, max delta \(maximum)")
        if differences != 0 { failures += 1 }
    }
}
exit(failures == 0 ? 0 : 1)
