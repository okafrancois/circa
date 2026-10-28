// Offline PDF rasterizer: no application, fonts, network or Keychain APIs.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let pdfURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let document = CGPDFDocument(pdfURL as CFURL), let page = document.page(at: 1) else {
    fatalError("Invalid icon PDF")
}
let box = page.getBoxRect(.mediaBox)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.scaleBy(x: CGFloat(size) / box.width, y: CGFloat(size) / box.height)
    context.drawPDFPage(page)
    let image = context.makeImage()!
    let url = destination.appendingPathComponent("\(size).png")
    let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, image, nil)
    precondition(CGImageDestinationFinalize(output))
    // Coordinate-independent samples: transparent corners, blue center, ivory detached dot.
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    try! Data(bytes: bytes, count: size * size * 4).write(to: destination.appendingPathComponent("\(size).rgba"))
    func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(UnsafeBufferPointer(start: bytes + (y * size + x) * 4, count: 4)) }
    precondition(pixel(0, 0)[3] == 0 && pixel(size - 1, size - 1)[3] == 0)
    if size == 1024 {
        precondition(pixel(512, 512) == [48, 75, 206, 255])
        // The PDF's visible top is at the bitmap's top (CoreGraphics device row order).
        precondition(pixel(853, 213) == [243, 240, 232, 255])
    }
}
