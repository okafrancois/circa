import AppKit
import Testing
@testable import Orbit

@Suite("Theme grain strength")
@MainActor
struct ThemeGrainParityTests {
    @MainActor
    @Test("Translucent theme tints leave the grain dial at full calibrated strength")
    func translucentGrain() throws {
        let fill = OrbitThemeFillView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        for tint: Float in [0.12, OrbitThemeFillView.sidebarTintOpacity, 1] {
            fill.tintOpacity = tint
            for strength: CGFloat in [0, 0.5, 1] {
                fill.apply(.init(stops: [.gray], mode: .automatic, texture: .grain, textureIntensity: strength))
                let grain = try #require(fill.layer?.sublayers?.compactMap { $0 as? OrbitGrainLayer }.first)
                var opacity: Float = 1
                var current: CALayer? = grain
                while let layer = current { opacity *= layer.opacity; current = layer.superlayer }
                #expect(abs(CGFloat(opacity) - strength * OrbitGrainLayer.maximumOpacity) < 0.00001)
                #expect(grain.isHidden == (strength == 0))
            }
        }
    }

    @Test("The strength dial scales a stable, fine RGB texture linearly")
    func strength() throws {
        let tile = try #require(OrbitGrainLayer.tile)
        let bytes = try #require(tile.dataProvider?.data) as Data
        let base = [218.7, 196.7, 197.7]
        let expectedMeans = [207.7, 187.6, 188.1]
        let expectedDeviations = [10.1, 8.9, 8.9]
        let side = tile.width
        for channel in 0..<3 {
            let values = stride(from: channel, to: bytes.count, by: 4).map {
                base[channel] * 0.85 + Double(bytes[$0]) * 0.15
            }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
            #expect(abs(mean - expectedMeans[channel]) < 0.5)
            #expect(abs(sqrt(variance) - expectedDeviations[channel]) < 0.5)
            var covariance = 0.0
            for y in 0..<side {
                for x in 1..<side {
                    covariance += (values[y * side + x] - mean) * (values[y * side + x - 1] - mean)
                }
            }
            let correlation = covariance / Double(side * (side - 1)) / variance
            #expect(abs(correlation - 0.389) < 0.025)
        }
        let layer = OrbitGrainLayer()
        for strength in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            layer.intensity = strength
            #expect(abs(Double(layer.opacity) - Double(strength * OrbitGrainLayer.maximumOpacity)) < 1e-6)
        }
        layer.intensity = -1
        #expect(layer.opacity == 0)
        layer.intensity = 2
        #expect(abs(Double(layer.opacity) - 0.15) < 1e-6)
    }
}
