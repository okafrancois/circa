import AppKit
import BrowserCore
import Testing
@testable import BrowserShell

@MainActor
struct BrandFontsTests {
    @Test("Browser roles match the system face at every requested size and weight")
    func systemRoles() {
        for style in [BrandTextStyle.ui, .body, .caption, .mono] {
            for size: CGFloat in [10, 13, 14, 18] {
                for weight: NSFont.Weight in [.regular, .medium, .semibold, .bold] {
                    let expected = NSFont.systemFont(ofSize: size, weight: weight)
                    #expect(style.font(size: size, weight: weight) == expected)
                }
            }
        }
        #expect(BrandFonts.ui(15) == NSFont.systemFont(ofSize: 15))
        #expect(BrandFonts.mono(12) == NSFont.systemFont(ofSize: 12))
    }

    @Test("Display titles always use bold system type and minus two percent tracking")
    func displayTitles() {
        for size: CGFloat in [28, 36, 40, 72, 84] {
            #expect(BrandTextStyle.title.font(size: size) == NSFont.systemFont(ofSize: size, weight: .bold))
            #expect(BrandTextStyle.title.font(size: size, weight: .regular) == NSFont.systemFont(ofSize: size, weight: .bold))
            let title = BrandTextStyle.title.attributedString("Circa", size: size)
            #expect(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == NSFont.systemFont(ofSize: size, weight: .bold))
            #expect(title.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat == -0.02 * size)
        }
    }

    @Test("Shortcut digits and modifier glyphs retain one system font")
    func modifiers() {
        let text = BrandTextStyle.mono.attributedString("⌘⇧⌥⌃T12", size: 13, weight: .medium)
        for index in 0..<text.length {
            #expect(text.attribute(.font, at: index, effectiveRange: nil) as? NSFont
                == NSFont.systemFont(ofSize: 13, weight: .medium))
        }
    }

    @Test("The mark is preserved and no custom font is bundled")
    func resources() throws {
        #expect(BrandFonts.onboardingBody(15) == NSFont.systemFont(ofSize: 15))
        #expect(BrandFonts.mark != nil)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BrowserShell/Resources/BrandFonts")
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path) == ["mark.pdf"])
    }

}

extension BrandFontsTests {
    @Test("Six onboarding gradients retain exact positions without replacing the product palette")
    func gradients() throws {
        let presets = BrandPalette.spaceGradients
        #expect(presets.map(\.name) == ["Coral", "Cobalt", "Sunset", "Mint", "Night", "Lilac"])
        #expect(presets.map { $0.locations[1] } == [0.45, 0.45, 0.5, 0.5, 0.55, 0.5])
        for preset in presets {
            let theme = preset.theme()
            try theme.validate()
            let decoded = try JSONDecoder().decode(BrowserSpaceTheme.self, from: JSONEncoder().encode(theme))
            #expect(decoded == theme)
            #expect(decoded.light.locations == preset.locations)
            #expect(decoded.colors.count == 2)
        }
        #expect(BrowserSpaceThemePresets.families.count == 4)
    }
}


extension BrandFontsTests {
    @Test("Onboarding copy and controls use the system face at all shipped sizes and weights")
    func onboardingSystemCopy() {
        for size: CGFloat in [11, 12, 13, 14, 15, 18] {
            for weight: NSFont.Weight in [.regular, .medium, .semibold, .bold] {
                #expect(BrandFonts.onboardingBody(size, weight: weight) == NSFont.systemFont(ofSize: size, weight: weight))
            }
        }
    }
}
