import BrowserCore
import Foundation
import Testing

@Suite("Chromium page zoom policy")
struct BrowserPageZoomTests {
    @Test("Presets retain exact Chromium fractions and navigation is reversible")
    func presetsAndNavigation() throws {
        let expected: [Double] = [
            0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 0.75, 0.8, 0.9, 1,
            1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5
        ]
        let zoom = try BrowserPageZoom()
        #expect(BrowserPageZoom.presetFactors == expected)
        #expect(zoom.factors == expected && BrowserPageZoom.epsilon == 0.001)
        for index in expected.indices {
            #expect(try zoom.nextFactor(after: expected[index]) == expected[min(index + 1, expected.count - 1)])
            #expect(try zoom.previousFactor(before: expected[index]) == expected[max(index - 1, 0)])
        }
    }

    @Test("A custom default is a sorted intermediate step and the exact reset target")
    func customDefault() throws {
        let zoom = try BrowserPageZoom(defaultFactor: 1.17)
        #expect(zoom.factors == zoom.factors.sorted())
        #expect(zoom.factors.count == BrowserPageZoom.presetFactors.count + 1)
        #expect(try zoom.nextFactor(after: 1.1) == 1.17)
        #expect(try zoom.previousFactor(before: 1.25) == 1.17)
        #expect(try zoom.nextFactor(after: 1.17) == 1.25)
        #expect(try zoom.previousFactor(before: 1.17) == 1.1)
        #expect(zoom.resetFactor == 1.17)
    }

    @Test("Navigation skips candidates within epsilon in Chromium zoom-level space")
    func epsilonBoundaries() throws {
        let zoom = try BrowserPageZoom()
        let justBelow = try BrowserPageZoom.factor(forLevel: -0.0005)
        let below = try BrowserPageZoom.factor(forLevel: -0.0015)
        let justAbove = try BrowserPageZoom.factor(forLevel: 0.0005)
        let above = try BrowserPageZoom.factor(forLevel: 0.0015)
        #expect(try zoom.nextFactor(after: justBelow) == 1.1)
        #expect(try zoom.nextFactor(after: below) == 1)
        #expect(try zoom.previousFactor(before: justAbove) == 0.9)
        #expect(try zoom.previousFactor(before: above) == 1)
        let nearDefault = try BrowserPageZoom(defaultFactor: justAbove)
        #expect(nearDefault.factors == BrowserPageZoom.presetFactors)
        #expect(nearDefault.resetFactor == justAbove)
        let maximumLevel = try BrowserPageZoom.level(forFactor: 5)
        let nearMaximum = try BrowserPageZoom.factor(forLevel: maximumLevel - 0.0005)
        #expect(try zoom.nextFactor(after: nearMaximum) == nearMaximum)
    }

    @Test("Arbitrary current factors move to a strictly adjacent preset")
    func arbitraryFactors() throws {
        let zoom = try BrowserPageZoom()
        #expect(try zoom.nextFactor(after: 1.13) == 1.25)
        #expect(try zoom.previousFactor(before: 1.13) == 1.1)
        #expect(try zoom.nextFactor(after: 0.7) == 0.75)
        #expect(try zoom.previousFactor(before: 0.7) == 2.0 / 3.0)
    }

    @Test("Custom bounds constrain all steps and include their exact endpoints")
    func customBounds() throws {
        let zoom = try BrowserPageZoom(defaultFactor: 1.3, minimumFactor: 0.6, maximumFactor: 3.5)
        #expect(zoom.factors.first == 0.6 && zoom.factors.last == 3.5)
        #expect(zoom.factors.allSatisfy { (0.6...3.5).contains($0) })
        #expect(try zoom.previousFactor(before: 0.6) == 0.6)
        #expect(try zoom.nextFactor(after: 3.5) == 3.5)
        #expect(try zoom.previousFactor(before: 2.0 / 3.0) == 0.6)
        #expect(try zoom.nextFactor(after: 3) == 3.5)
        let fixed = try BrowserPageZoom(defaultFactor: 1.17, minimumFactor: 1.17, maximumFactor: 1.17)
        #expect(fixed.factors == [1.17])
        #expect(try fixed.nextFactor(after: 1.17) == 1.17)
        #expect(try fixed.previousFactor(before: 1.17) == 1.17)
        #expect(fixed.resetFactor == 1.17)
    }

    @Test("Factor and level conversions use base 1.2 without quantizing")
    func levelConversions() throws {
        #expect(try BrowserPageZoom.factor(forLevel: 0) == 1)
        #expect(try BrowserPageZoom.level(forFactor: 1) == 0)
        #expect(try BrowserPageZoom.factor(forLevel: 1) == 1.2)
        for factor in BrowserPageZoom.presetFactors + [0.31, 1.17, 4.82, Double.leastNonzeroMagnitude] {
            let level = try BrowserPageZoom.level(forFactor: factor)
            let restored = try BrowserPageZoom.factor(forLevel: level)
            #expect(abs(restored - factor) <= max(1e-12, factor * 1e-12))
        }
    }

    @Test("Nonfinite and nonpositive inputs fail with deterministic typed errors")
    func invalidInputs() throws {
        let zoom = try BrowserPageZoom()
        for factor in [Double.nan, .infinity, -.infinity, 0, -1] {
            #expect(throws: BrowserPageZoomError.invalidFactor) { try zoom.nextFactor(after: factor) }
            #expect(throws: BrowserPageZoomError.invalidFactor) { try zoom.previousFactor(before: factor) }
            #expect(throws: BrowserPageZoomError.invalidFactor) { try BrowserPageZoom.level(forFactor: factor) }
            #expect(throws: BrowserPageZoomError.invalidDefaultFactor) { try BrowserPageZoom(defaultFactor: factor) }
        }
        for level in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            #expect(throws: BrowserPageZoomError.invalidLevel) { try BrowserPageZoom.factor(forLevel: level) }
        }
        for bounds in [(0.0, 5.0), (-1.0, 5.0), (5.0, 0.25), (.nan, 5.0), (0.25, .infinity)] {
            #expect(throws: BrowserPageZoomError.invalidBounds) {
                try BrowserPageZoom(minimumFactor: bounds.0, maximumFactor: bounds.1)
            }
        }
        for factor in [0.24, 5.01] {
            #expect(throws: BrowserPageZoomError.factorOutOfBounds) { try zoom.nextFactor(after: factor) }
            #expect(throws: BrowserPageZoomError.factorOutOfBounds) { try zoom.previousFactor(before: factor) }
            #expect(throws: BrowserPageZoomError.defaultFactorOutOfBounds) { try BrowserPageZoom(defaultFactor: factor) }
        }
    }
}
