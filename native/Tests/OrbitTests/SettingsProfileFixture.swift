import BrowserCore

extension BrowserStore {
    /// Explicit fixture setup; a profile alone no longer implies a Space.
    func createSettingsFixtureProfileWithSpace(name: String) throws -> ProfileID {
        let profile = try createSettingsProfile(name: name)
        _ = try createSpace(name: name, profileID: profile)
        return profile
    }
}
