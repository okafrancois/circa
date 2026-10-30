import AppKit
import BrowserCore
import Testing
@testable import BrowserShell

@MainActor
struct BrandFontsTests {
    @Test("Font roles fall back without changing point size or registration state")
    func fallback() {
        for style in BrandTextStyle.allCases {
            let fallback = style.resolvedFont(size: 14, weight: .semibold, registrationAvailable: false)
            let expected = style == .mono ? NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
                                         : NSFont.systemFont(ofSize: 14, weight: .semibold)
            #expect(fallback == expected)
        }
        for style in [BrandTextStyle.title, .mono] {
            let missing = style.resolvedFont(size: 13, registrationAvailable: true, lookup: { _, _ in nil })
            #expect(missing.pointSize == 13)
            #expect(missing.familyName != "Gloock" && missing.familyName != "Geist Mono")
        }
    }

    @Test("Repeated role lookups reuse one process registration")
    func once() {
        let attempts = BrandFonts.registrationAttempts
        #expect(attempts == 3)
        for _ in 0..<20 {
            for style in BrandTextStyle.allCases { _ = style.font(size: 14) }
        }
        #expect(BrandFonts.registrationAttempts == attempts)
    }

    @Test("Shortcut modifier glyphs use the system font inside mono text")
    func modifiers() {
        let text = BrandTextStyle.mono.attributedString("⌘⇧⌥⌃T12", size: 13)
        for index in 0..<7 {
            let font = text.attribute(.font, at: index, effectiveRange: nil) as? NSFont
            if index < 4 { #expect(font == NSFont.systemFont(ofSize: 13)) }
            else { #expect(font?.familyName == "Geist Mono") }
        }
    }

    @Test("The three shared OFL fonts register and the final mark is one bundled asset")
    func registration() {
        #expect(BrandFonts.filenames == ["intertight.ttf", "geistmono.ttf", "gloock.ttf"])
        #expect(BrandFonts.registered)
        #expect(BrandFonts.ui(15).familyName?.contains("Inter Tight") == true)
        #expect(BrandFonts.mono(12).familyName?.contains("Geist Mono") == true)
        #expect(BrandTextStyle.title.font(size: 40).familyName == "Gloock")
        #expect(BrandFonts.mark != nil)
        for name in ["intertight-OFL", "geistmono-OFL", "gloock-OFL"] {
            #expect(BrowserText.resourceBundle?.url(forResource: name, withExtension: "txt", subdirectory: "BrandFonts")
                ?? BrowserText.resourceBundle?.url(forResource: name, withExtension: "txt") != nil)
        }
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
