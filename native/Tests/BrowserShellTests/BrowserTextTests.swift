import Foundation
import Testing
@testable import BrowserShell

struct BrowserTextTests {
    @Test("SwiftPM resources are available to tests and contain English defaults")
    func bundledEnglish() throws {
        let bundle = try #require(BrowserText.resourceBundle)
        #expect(bundle.localizations.contains("en"))
        #expect(bundle.developmentLocalization == "en")
        #expect(bundle.localizedString(forKey: "Downloads", value: "missing", table: nil) == "Downloads")
    }
}
