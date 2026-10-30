import AppKit
import BrowserCore
import Testing
@testable import Orbit

@Suite(.serialized)
@MainActor
struct FloatingMaterialTests {
    @Test func appearanceSelectsVariant() throws {
        #expect(OrbitFloatingMaterial.style(for: try #require(NSAppearance(named: .aqua)), reduceTransparency: false).variant == .light)
        #expect(OrbitFloatingMaterial.style(for: try #require(NSAppearance(named: .darkAqua)), reduceTransparency: false).variant == .dark)
    }

    @Test func opaqueFallbackPreservesTextTokens() {
        for variant in OrbitFloatingMaterial.Variant.allCases {
            let transparent = OrbitFloatingMaterial.Style(variant: variant, reducesTransparency: false)
            let opaque = OrbitFloatingMaterial.Style(variant: variant, reducesTransparency: true)
            #expect(opaque.tintOpacity == 1)
            #expect(opaque.body == transparent.body)
            #expect(opaque.secondary == transparent.secondary)
            #expect(opaque.background(over: .white) == opaque.background(over: .black))
            let view = OrbitFrostView()
            view.fixedVariant = variant
            view.refresh(reduceTransparency: true)
            #expect(view.effect.isHidden)
            #expect(view.style.tintOpacity == 1)
            view.refresh(reduceTransparency: false)
            #expect(!view.effect.isHidden)
            #expect(view.effect.state == .active)
        }
    }

    @Test func contrastCalculationUsesLinearSRGB() {
        #expect(abs(OrbitFloatingMaterial.contrast(.black, .white) - 21) < 0.0001)
        #expect(OrbitFloatingMaterial.contrast(.white, .white) == 1)
    }

    @Test func contrastAcrossGradientSamplesAndPageExtremes() {
        var samples: [NSColor] = [.black, .white]
        for family in BrowserSpaceThemePresets.families {
            for index in family.swatches.indices {
                guard let theme = BrowserSpaceThemePresets.theme(family: family, index: index) else { continue }
                for gradient in [theme.light, theme.dark] {
                    samples += gradient.stops.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
                }
            }
        }
        for gradient in [BrowserSpaceThemePresets.default.light, BrowserSpaceThemePresets.default.dark] {
            samples += gradient.stops.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
        }
        // Multicolour gradients, including near-black and yellow, plus their interpolants.
        let gradients: [[UInt32]] = [
            [0xFF8A7A, 0xFF5A5F, 0x7B4DFF], [0x6E9BFF, 0x2D5BFF, 0x1B2C8F],
            [0xFFE27A, 0xFF9F45, 0xFF5A5F], [0xA7F3D6, 0x3DCCA0, 0x2D5BFF],
            [0x3A3550, 0x1C1A26, 0x0E0E11], [0xF4ECFF, 0xD9C6FF, 0xB79BFF]
        ]
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        for stops in gradients {
            for pair in zip(stops, stops.dropFirst()) {
                for step in 0...20 {
                    samples.append(OrbitFloatingMaterial.composite(color(pair.1), opacity: CGFloat(step) / 20, over: color(pair.0)))
                }
            }
        }
        for variant in OrbitFloatingMaterial.Variant.allCases {
            for reduced in [false, true] {
                let style = OrbitFloatingMaterial.Style(variant: variant, reducesTransparency: reduced)
                for backdrop in samples {
                    for highlighted in [false, true] {
                        let background = style.background(over: backdrop, highlight: highlighted)
                        #expect(OrbitFloatingMaterial.contrast(style.body, background) >= 4.5)
                        #expect(OrbitFloatingMaterial.contrast(style.secondary, background) >= 4.5)
                    }
                }
            }
        }
    }

    @Test func accentInkRemainsReadableForBrightAndDarkSystemAccents() {
        for accent in [NSColor.systemBlue, .systemPurple, .systemPink, .systemRed, .systemOrange, .systemYellow, .systemGreen, .gray, .black, .white] {
            let fill = accent.resolved(for: NSAppearance(named: .aqua)!)
            #expect(OrbitFloatingMaterial.contrast(OrbitFloatingMaterial.contrastingInk(on: fill), fill) >= 4.5)
        }
    }

    @Test func sharedInstallationIsIdempotentAndPrecedesContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let label = NSTextField(labelWithString: "")
        content.addSubview(label)
        let first = OrbitFloatingMaterial.install(in: content)
        #expect(OrbitFloatingMaterial.install(in: content) === first)
        #expect(content.subviews.first === first)
        #expect(content.subviews.last === label)
        #expect(first.effect.material == .hudWindow)
        #expect(first.hitTest(.zero) == nil)
    }

    @Test func tintIsSizedBeforeFirstDisplayAndAboveTheSystemEffect() throws {
        let view = OrbitFrostView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        view.refresh(reduceTransparency: false)
        #expect(view.subviews.first === view.effect)
        let tint = try #require(view.subviews.last)
        #expect(tint !== view.effect)
        #expect(tint.frame == view.bounds)
        #expect(tint.layer?.backgroundColor?.alpha == view.style.tintOpacity)
    }

    @Test func compactTitleMaterialCoversItsOpaqueThemeFill() {
        let toolbar = BrowserQuickWindowToolbarView(frame: NSRect(x: 0, y: 0, width: 680, height: 48))
        #expect(toolbar.subviews.first === toolbar.fill)
        #expect(toolbar.subviews.last is OrbitFrostView)
    }

    @Test func themeEditorIsOpaqueAndDoesNotInstallFrost() {
        let editor = OrbitThemeEditorView(state: .init(theme: BrowserSpaceThemePresets.default))
        _ = editor.makePickerViewport()
        #expect(!editor.material.isHidden)
        #expect(editor.material.layer?.backgroundColor?.alpha == 1)
        #expect(!editor.subviews.contains { $0 is OrbitFrostView })
    }
}

extension NativeWebKitTests {
@Suite("Floating alert material", .serialized)
@MainActor
struct FloatingAlertMaterialTests {
    @Test func nativeLayoutRetainsTheInstalledMaterial() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = "Synthetic alert"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "Synthetic name")
        field.frame.size = NSSize(width: 440, height: 24)
        alert.accessoryView = field
        alert.showsSuppressionButton = true
        _ = try #require(alert as? OrbitFrostAlert).preparedWindow()
        let content = try #require(alert.window.contentView)
        let frost = try #require(content.subviews.first as? OrbitFrostView)
        #expect(frost.effect.blendingMode == .behindWindow)
        #expect(!alert.window.isOpaque)
        #expect(alert.window.backgroundColor == .clear)
        #expect(frost.frame == content.bounds)
        #expect(field.isDescendant(of: content))
        #expect(try #require(alert.suppressionButton).isDescendant(of: content))
        #expect(content.bounds.width >= 480)
        #expect(alert.buttons.allSatisfy { $0.target === alert })
        #expect(alert.buttons.map(\.tag) == [0, 1])
    }
}
}
