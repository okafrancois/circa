import AppKit
import BrowserCore
import BrowserEngine

/// Space themes outside a browser window: the import bridge at launch and Little Orbit.
extension BrowserEnvironment {
    /// One-time migration of IMPORT's `space-appearance.json` into the session's Space themes. Runs
    /// before any window exists; returns whether the session changed (it must then be saved).
    static func migrateImportedSpaceThemes(store: BrowserStore, location: ArcImportDataLocation) async -> Bool {
        guard let appearance = BrowserSpaceAppearanceDocument.load(at: location) else { return false }
        let before = await store.importedThemeSpaces()
        await store.migrateImportedSpaceThemes(appearance)
        return await store.importedThemeSpaces() != before
    }

    /// Theme of a Space for surfaces without a window session (Little Orbit): stored theme, legacy
    /// Settings palette, default.
    func spaceTheme(for spaceID: SpaceID, in catalog: BrowserCatalogSnapshot? = nil) -> OrbitTokens.SpaceTheme {
        OrbitSpaceThemes.theme(forSpace: spaceID, in: catalog ?? publishedCatalog,
                             legacy: BrowserWindowSettings(runtime: settings).theme(for: spaceID))
    }

    /// A theme edited in any window repaints the Little Orbit windows opened from that Space.
    func refreshQuickWindowThemes() {
        for little in quickWindows.values where !little.isClosed {
            little.applyPreferences(searchEngine: settings.document.profile(little.profileID).searchEngine,
                                    theme: spaceTheme(for: little.sourceSpaceID))
        }
    }
}
