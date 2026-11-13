import AppKit
import Testing
@testable import Orbit

@Suite("Theme paper grain strength") @MainActor
struct ThemeGrainParityTests {
    @Test("The dial controls the same paper tile independently of tint opacity")
    func strength() throws {
        let fill = OrbitThemeFillView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        for tint: Float in [0.12, 1] {
            fill.tintOpacity = tint
            for strength: CGFloat in [0, 0.3, 0.5, 1] {
                fill.apply(.init(stops: [.gray], mode: .automatic, texture: .grain, textureIntensity: strength))
                #expect(fill.paperGrain.alphaValue == OrbitPaperGrainView.opacity(for: strength))
            }
        }
        #expect(OrbitPaperGrainView.opacity(for: 0.3) == 0.5)
        #expect(OrbitPaperGrainView.opacity(for: -1) == 0)
        #expect(OrbitPaperGrainView.opacity(for: 2) == 1)
        #expect(OrbitPaperGrainView.opacity(for: 0.7) > OrbitPaperGrainView.opacity(for: 0.6))
        fill.apply(.init(stops: [.gray], mode: .automatic, texture: .none, textureIntensity: 1))
        #expect(fill.paperGrain.alphaValue == 0)
    }
    @Test("Both appearances use daylight multiply without changing the stored strength")
    func appearance() throws {
        let fill = OrbitThemeFillView()
        fill.apply(.default)
        fill.appearance = NSAppearance(named: .darkAqua)
        fill.viewDidChangeEffectiveAppearance()
        #expect(fill.paperGrain.layer?.compositingFilter as? String == "multiplyBlendMode")
        #expect(fill.paperGrain.strength == 0.3)
        fill.appearance = NSAppearance(named: .aqua)
        fill.viewDidChangeEffectiveAppearance()
        #expect(fill.paperGrain.layer?.compositingFilter as? String == "multiplyBlendMode")
    }
}
