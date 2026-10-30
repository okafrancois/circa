import Foundation

/// One recorded Space theme change. Undo replays `inverse`; both directions are guarded so a change
/// never lands on a Space that moved to another profile or whose theme changed in the meantime.
public struct BrowserSpaceThemeChange: Equatable, Sendable {
    public let spaceID: SpaceID
    public let profileID: ProfileID
    public let before: BrowserSpaceTheme?
    public let after: BrowserSpaceTheme?

    public init(spaceID: SpaceID, profileID: ProfileID, before: BrowserSpaceTheme?, after: BrowserSpaceTheme?) {
        self.spaceID = spaceID
        self.profileID = profileID
        self.before = before
        self.after = after
    }

    public var inverse: BrowserSpaceThemeChange {
        BrowserSpaceThemeChange(spaceID: spaceID, profileID: profileID, before: after, after: before)
    }

    public var isEmpty: Bool { before == after }
}

public enum BrowserSpaceThemeError: Error, Equatable, Sendable {
    /// The Space belongs to another profile, or its theme is no longer the recorded one.
    case conflict
}

public extension BrowserStore {
    func spaceTheme(_ spaceID: SpaceID) throws -> BrowserSpaceTheme? {
        guard let space = spaces[spaceID] else { throw BrowserStoreError.spaceMissing }
        return space.theme
    }

    /// Sets (nil clears) the theme of one Space, shared by every window showing it. `profileID`, when
    /// given, must still own the Space: an editor opened before a profile reassignment cannot write
    /// across the boundary. Validation precedes mutation; windows re-capture through the
    /// organization observers.
    @discardableResult
    func setSpaceTheme(_ theme: BrowserSpaceTheme?, for spaceID: SpaceID,
                       profileID: ProfileID? = nil) throws -> BrowserSpaceThemeChange {
        guard let space = spaces[spaceID] else { throw BrowserStoreError.spaceMissing }
        try requireAvailableProfile(space.profileID)
        if let profileID, profileID != space.profileID { throw BrowserSpaceThemeError.conflict }
        try theme?.validate()
        let change = BrowserSpaceThemeChange(spaceID: spaceID, profileID: space.profileID, before: space.theme, after: theme)
        guard !change.isEmpty else { return change }
        spaces[spaceID]?.theme = theme
        publishOrganizationChange()
        return change
    }

    /// Replays a recorded change; undo passes `change.inverse`. Nothing changes on conflict.
    func applySpaceThemeChange(_ change: BrowserSpaceThemeChange) throws {
        guard let space = spaces[change.spaceID] else { throw BrowserStoreError.spaceMissing }
        guard space.profileID == change.profileID, space.theme == change.before else {
            throw BrowserSpaceThemeError.conflict
        }
        try setSpaceTheme(change.after, for: change.spaceID, profileID: change.profileID)
    }

    /// One-time import bridge: each Space of IMPORT's appearance sidecar is considered once. A Space
    /// already themed by the user keeps its theme; an entry without a usable colour is only recorded.
    /// Returns the Spaces that received a theme, in sidecar order.
    @discardableResult
    func migrateImportedSpaceThemes(_ document: BrowserSpaceAppearanceDocument) -> [SpaceID] {
        var themed: [SpaceID] = []
        var recorded = false
        for entry in document.entries {
            guard let space = spaces[entry.spaceID], !deletingProfiles.contains(space.profileID) else { continue }
            let firstImport = themeImports.insert(entry.spaceID).inserted
            recorded = recorded || firstImport
            guard let theme = ArcSpaceThemeImport.theme(for: entry.appearance) else { continue }
            // Repair the previous decoder's exact output. A user edit or reset stays authoritative.
            let legacy = ArcSpaceThemeImport.theme(for: entry.appearance, decodeSingleColor: false)
            let repairsLegacy = !firstImport && legacy != theme && space.theme != nil && space.theme == legacy
            guard (firstImport && space.theme == nil) || repairsLegacy else { continue }
            recorded = true
            spaces[entry.spaceID]?.theme = theme
            themed.append(entry.spaceID)
        }
        if recorded { publishOrganizationChange() }
        return themed
    }

    /// Spaces already considered by the import bridge (tests and diagnostics).
    func importedThemeSpaces() -> Set<SpaceID> { themeImports.filter { spaces[$0] != nil } }
}
