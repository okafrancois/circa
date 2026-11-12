import AppKit
import Testing
@testable import Orbit

@Suite @MainActor struct GrainBackingTests {
    @Test("Grain shares one image and never retains a view-sized backing")
    func backing() {
        let grain = OrbitGrainLayer()
        grain.frame = CGRect(x: 0, y: 0, width: 1400, height: 900)
        grain.contentsScale = 2
        grain.intensity = 1
        grain.layoutIfNeeded()
        #expect(grain.contents == nil)
        #expect(!grain.needsDisplayOnBoundsChange)
        let rows = grain.sublayers!.first as! CAReplicatorLayer
        let columns = rows.sublayers!.first as! CAReplicatorLayer
        let tile = columns.sublayers!.first!
        #expect(rows.instanceCount == 4)
        #expect(columns.instanceCount == 6)
        #expect(tile.bounds.size == CGSize(width: 256, height: 256))
        #expect(!tile.isHidden)
        grain.intensity = 0
        #expect(tile.contents == nil)
        #expect(tile.isHidden)
    }
}

private final class RasterGrainReference: CALayer {
    override init() { super.init(); needsDisplayOnBoundsChange = true }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }
    override func draw(in context: CGContext) {
        let side = CGFloat(OrbitGrainLayer.tileSide) / max(1, contentsScale)
        context.draw(OrbitGrainLayer.tile!, in: CGRect(x: 0, y: 0, width: side, height: side), byTiling: true)
    }
}

extension GrainBackingTests {
    @Test("Replicated grain matches raster tiling at both backing scales and clipped tile edges", arguments: [CGFloat(1), 2])
    func pixels(scale: CGFloat) throws {
        func raster(_ layer: CALayer) throws -> Data {
            let width = 731, height = 517
            let context = try #require(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            layer.frame = CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
            layer.contentsScale = scale
            context.scaleBy(x: scale, y: scale)
            layer.layoutIfNeeded(); layer.displayIfNeeded(); layer.render(in: context)
            return Data(bytes: context.data!, count: width * height * 4)
        }
        let reference = RasterGrainReference()
        reference.opacity = Float(OrbitGrainLayer.maximumOpacity)
        let grain = OrbitGrainLayer(); grain.intensity = 1
        #expect(try raster(reference) == raster(grain))
    }
}
