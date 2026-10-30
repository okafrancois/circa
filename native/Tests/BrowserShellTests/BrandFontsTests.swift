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
                    #expect(style.resolvedFont(size: size, weight: weight, registrationAvailable: true,
                        lookup: { _, _ in Issue.record("System roles must not look up bundled faces"); return nil }) == expected)
                }
            }
        }
        #expect(BrandFonts.ui(15) == NSFont.systemFont(ofSize: 15))
        #expect(BrandFonts.mono(12) == NSFont.systemFont(ofSize: 12))
    }

    @Test("Missing display resources fall back without changing point size or weight")
    func fallback() {
        for style in BrandTextStyle.allCases {
            #expect(style.resolvedFont(size: 14, weight: .semibold, registrationAvailable: false)
                == NSFont.systemFont(ofSize: 14, weight: .semibold))
        }
        #expect(BrandTextStyle.title.resolvedFont(size: 13, registrationAvailable: true, lookup: { _, _ in nil })
            == NSFont.systemFont(ofSize: 13))
    }

    @Test("Repeated role lookups reuse one process registration")
    func once() {
        let attempts = BrandFonts.registrationAttempts
        #expect(attempts == 1)
        for _ in 0..<20 {
            for style in BrandTextStyle.allCases { _ = style.font(size: 14) }
        }
        #expect(BrandFonts.registrationAttempts == attempts)
    }

    @Test("Shortcut digits and modifier glyphs retain one system font")
    func modifiers() {
        let text = BrandTextStyle.mono.attributedString("⌘⇧⌥⌃T12", size: 13, weight: .medium)
        for index in 0..<text.length {
            #expect(text.attribute(.font, at: index, effectiveRange: nil) as? NSFont
                == NSFont.systemFont(ofSize: 13, weight: .medium))
        }
    }

    @Test("Only branded titles need bundled fonts")
    func registration() {
        #expect(BrandFonts.filenames == ["gloock.ttf"])
        #expect(BrandFonts.registered)
        #expect(BrandFonts.onboardingBody(15) == NSFont.systemFont(ofSize: 15))
        #expect(BrandTextStyle.title.font(size: 40).familyName == "Gloock")
        #expect(BrandFonts.mark != nil)
        for name in ["gloock-OFL"] {
            #expect(BrowserText.resourceBundle?.url(forResource: name, withExtension: "txt", subdirectory: "BrandFonts")
                ?? BrowserText.resourceBundle?.url(forResource: name, withExtension: "txt") != nil)
        }
        #expect(BrowserText.resourceBundle?.url(forResource: "geistmono", withExtension: "ttf") == nil)
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
