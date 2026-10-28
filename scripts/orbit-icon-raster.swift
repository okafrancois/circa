// Offline vector rasterizer for the approved Orbit mark. No application is launched.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let vector = NSImage(contentsOf: source) else { fatalError("Invalid Orbit SVG") }
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    vector.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero,
                operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    let image = context.makeImage()!
    let output = CGImageDestinationCreateWithURL(destination.appendingPathComponent("\(size).png") as CFURL,
                                                UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, image, nil)
    precondition(CGImageDestinationFinalize(output))
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    try Data(bytes: bytes, count: size * size * 4).write(to: destination.appendingPathComponent("\(size).rgba"))
}
