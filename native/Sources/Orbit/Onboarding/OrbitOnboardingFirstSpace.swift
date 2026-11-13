import BrowserCore
import BrowserShell

/// The identity promised by the first-Space preview, persisted before the browser opens.
@MainActor
enum OrbitOnboardingFirstSpace {
    static var name: String { uiText("Personal") }

    static func planet(for theme: BrowserSpaceTheme?) -> BrowserSpacePlanet? {
        guard let index = BrandPalette.spaceGradients.firstIndex(where: { "brand." + $0.id == theme?.presetID }) else { return nil }
        return BrowserSpacePlanet.selectable[index]
    }

    static func apply(_ theme: BrowserSpaceTheme?, spaceID: SpaceID, profileID: ProfileID,
                      store: BrowserStore, settings: BrowserSettingsStore) async throws {
        try theme?.validate()
        guard await store.catalogSnapshot().spaces.first(where: { $0.id == spaceID })?.profileID == profileID else {
            throw BrowserSpaceThemeError.conflict
        }
        try await store.renameSpace(spaceID, name: name)
        if let planet = planet(for: theme) {
            try await settings.updateSpace(spaceID) { $0.iconSelection = .planet(planet) }
        }
        try await store.setSpaceTheme(theme, for: spaceID, profileID: profileID)
    }
}
