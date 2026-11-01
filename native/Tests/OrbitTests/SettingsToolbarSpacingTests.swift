import AppKit
import BrowserShell
import Testing
@testable import Orbit

@Suite(.serialized)
@MainActor
struct SettingsToolbarSpacingTests {
    @Test func labelsFitInsideEveryCategoryButton() {
        for section in BrowserSettingsSection.allCases {
            let button = BrowserSettingsToolbarButton(section: section)
            button.setFrameSize(button.intrinsicContentSize)
            let labelHeight = (section.toolbarTitle as NSString).size(withAttributes: [
                .font: BrandFonts.ui(11, weight: .medium)
            ]).height
            // The icon starts 5 pt down, occupies 24 pt and has a 4 pt gap to the label.
            let labelBottom = 5 + 24 + 4 + labelHeight
            #expect(button.bounds.height - labelBottom >= 4,
                    "Each category label needs its bottom inset inside the selection pill")
        }
    }
}
