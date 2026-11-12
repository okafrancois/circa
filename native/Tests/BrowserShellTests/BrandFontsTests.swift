import AppKit
import BrowserCore
import Testing
@testable import BrowserShell

@MainActor
struct BrandFontsTests {
    @Test("Native controls retain system typography")
    func nativeControls() {
        for size: CGFloat in [10, 13, 18] {
            #expect(BrandFonts.ui(size) == NSFont.systemFont(ofSize: size))
        }
    }

    @Test("Bundled roles resolve without a system fallback")
    func brandedRoles() {
        for size: CGFloat in [11, 15, 40, 84] {
            #expect(BrandTextStyle.title.font(size: size).fontName == "BricolageGrotesque-ExtraBold")
            #expect(BrandFonts.onboardingBody(size).fontName == "DMSans-Regular")
            #expect(BrandFonts.onboardingBody(size, weight: .bold).fontName == "DMSans-Bold")
            #expect(BrandFonts.mono(size).fontName == "DMMono-Regular")
            #expect(BrandTextStyle.title.tracking(size: size) == -0.045 * size)
        }
        #expect(BrandFonts.mark != nil)
    }

    @Test("Space presets preserve flat ink fills through persistence")
    func spaces() throws {
        #expect(BrandPalette.spaceGradients.map(\.name) == ["Work", "Home", "Reading", "Side project"])
        for preset in BrandPalette.spaceGradients {
            let theme = preset.theme()
            try theme.validate()
            #expect(Set(theme.light.stops).count == 1)
            let decoded = try JSONDecoder().decode(BrowserSpaceTheme.self, from: JSONEncoder().encode(theme))
            #expect(decoded == theme)
        }
    }
}
