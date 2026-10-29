import AppKit
import BrowserCore
import BrowserShell

@MainActor
enum ChromiumImportDiscovery {
    /// Explicit import action only. Installation presence never asserts that profile data exists.
    static func installed() -> [BrowserImportDescriptor] {
        ChromiumImportRegistry.installed { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
    }
    static func installedFirefoxFamily() -> [BrowserImportDescriptor] {
        FirefoxImportRegistry.installed { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
    }
    static func placement(browser: String, profile: String) -> ChromiumImportPlacement {
        .init(importedSpace: uiFormat("Imported from %@ — %@", browser, profile),
              bookmarkFolder: uiText("Imported Bookmarks"), windowName: uiText("Imported Window"))
    }
}
