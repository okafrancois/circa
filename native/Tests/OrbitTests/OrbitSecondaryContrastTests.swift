import AppKit
import SwiftUI
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Secondary Orbit control contrast", .serialized)
@MainActor
struct OrbitSecondaryContrastTests {
    private struct RGB {
        let red: Double, green: Double, blue: Double, alpha: Double
        func over(_ background: RGB) -> RGB {
            .init(red: red * alpha + background.red * (1 - alpha),
                  green: green * alpha + background.green * (1 - alpha),
                  blue: blue * alpha + background.blue * (1 - alpha), alpha: 1)
        }
        var luminance: Double {
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        func contrast(_ other: RGB) -> Double {
            (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
        }
    }

    private func rgb(_ color: NSColor) throws -> RGB {
        let resolved = try #require(color.usingColorSpace(.sRGB))
        return .init(red: resolved.redComponent, green: resolved.greenComponent,
                     blue: resolved.blueComponent, alpha: resolved.alphaComponent)
    }

    @Test("Resolved secondary tint, category labels and explicit focus outline meet intended adjacent-color thresholds")
    func secondaryTokens() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var outcome: Result<Void, Error> = .success(())
            appearance.performAsCurrentDrawingAppearance {
                outcome = Result {
                    let surface = try rgb(NSColor(OrbitSecondaryIdentity.surface))
                    let foreground = try rgb(NSColor(OrbitSecondaryIdentity.foreground))
                    let tint = try rgb(NSColor(OrbitSecondaryIdentity.controlTint))
                    let selected = try rgb(NSColor(OrbitSecondaryIdentity.categorySelectionBackground)).over(surface)
                    let selectionText = try rgb(NSColor(OrbitSecondaryIdentity.selection))
                    #expect(foreground.contrast(surface) >= 7)
                    #expect(tint.contrast(surface) >= 4.5)
                    #expect(selectionText.contrast(selected) >= 4.5)
                    // Retained token contrast bound. Native preferences toolbar focus is drawn by AppKit.
                    #expect(tint.contrast(selected) >= 3)
                    // If a native control uses the tint as fill, the inverse palette text is legible.
                    #expect(surface.contrast(tint) >= 4.5)
                    // Record native semantic colors as bounds, not a claim about rendered SwiftUI pixels.
                    let nativeFace = try rgb(NSColor.controlBackgroundColor).over(surface)
                    let nativeDisabled = try rgb(NSColor.disabledControlTextColor).over(nativeFace)
                    let nativeFocus = try rgb(NSColor.keyboardFocusIndicatorColor).over(surface)
                    print("ORBIT-CONTRAST \(name.rawValue) text=\(foreground.contrast(surface)) tint=\(tint.contrast(surface)) selectedText=\(selectionText.contrast(selected)) categoryFocus=\(tint.contrast(selected)) nativeFaceTint=\(tint.contrast(nativeFace)) nativeDisabledText=\(nativeDisabled.contrast(nativeFace)) nativeFocus=\(nativeFocus.contrast(surface))")
                }
            }
            try outcome.get()
        }
    }
}
}
