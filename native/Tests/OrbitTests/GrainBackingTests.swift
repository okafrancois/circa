import AppKit
import Testing
@testable import Orbit

@Suite @MainActor struct GrainBackingTests {
    @Test("Onboarding and Space fills share one immutable paper tile")
    func backing() throws {
        let tile = try #require(OrbitPaperGrainView.tile)
        #expect(tile.size == NSSize(width: 220, height: 220))
        let fill = OrbitThemeFillView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        #expect(fill.subviews.filter { $0 is OrbitPaperGrainView }.count == 1)
        #expect(fill.layer?.sublayers?.contains { $0 is CAReplicatorLayer } == false)
        fill.offsetInWindowFill = CGPoint(x: 48, y: 20)
        fill.layout()
        #expect(fill.paperGrain.patternOffset == CGPoint(x: 48, y: 20))
    }
}
