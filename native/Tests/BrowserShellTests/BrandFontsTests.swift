import AppKit
import BrowserCore
import Testing
@testable import BrowserShell

@MainActor
struct BrandFontsTests {
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
