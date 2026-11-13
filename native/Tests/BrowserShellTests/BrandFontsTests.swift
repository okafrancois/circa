import AppKit
import CoreText
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
            let displayName = BrandTextStyle.title.font(size: size).fontName
            #expect(displayName.hasPrefix("BricolageGrotesque") && displayName.contains("ExtraBold"))
            #expect(BrandFonts.onboardingBody(size).fontName.hasPrefix("DMSans"))
            let bold = BrandFonts.onboardingBody(size, weight: .bold)
            #expect(bold.fontName.hasPrefix("DMSans"))
            #expect((CTFontCopyVariation(bold as CTFont) as? [NSNumber: NSNumber])?[NSNumber(value: 2_003_265_652)]?.intValue == 700)
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
