import Foundation

public enum BrowserSessionError: Error, Equatable, Sendable {
    case unsupportedVersion
    case limitExceeded
    case duplicateIdentity
    case profileMissing
    case spaceMissing
    case occurrenceMissing
    case occurrenceOwnedByAnotherContainer
    case invalidSelection
    case orphanedOccurrence
    case invalidURL
    case organizationItemMissing
    case organizationDuplicateNode
    case organizationOrphanedItem
    case organizationInvalidSection
    case organizationInvalidPinnedURL
    case organizationInvalidTitle
    case organizationInvalidArchive
    case organizationInvalidPolicy
    /// An occurrence's logical tab is not in the sidebar.
    case invalidSplitGroup
    case occurrenceWithoutLogicalTab
    /// A Pinned/Today occurrence outside its tab's Space, or a Favorite outside its profile.
    case occurrenceOutsideLogicalTabSection
    /// A Space theme outside its bounds (stop count, components, angle, intensity, grain, preset ID).
    case invalidSpaceTheme
}

/// Stores model identities and destinations without serializing live engine state.
/// Version 3 adds split groups to the shared organization; version 4 adds Space themes and the record
/// of imported Orbit appearances already migrated (Space themes). Versions 1–3 migrate on decode; encoding
/// always writes the current version; later versions are refused (see BrowserSessionMigration.swift).
public struct BrowserSessionDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 4
    public static let defaultMaximumInputBytes = 16 * 1024 * 1024

    public struct SpaceTabs: Codable, Equatable, Sendable {
        public let spaceID: SpaceID
        public let occurrenceIDs: [TabOccurrenceID]
        public let selectedOccurrenceID: TabOccurrenceID?

        public init(spaceID: SpaceID, occurrenceIDs: [TabOccurrenceID], selectedOccurrenceID: TabOccurrenceID?) {
            self.spaceID = spaceID
            self.occurrenceIDs = occurrenceIDs
            self.selectedOccurrenceID = selectedOccurrenceID
        }
    }

    public struct Window: Codable, Equatable, Sendable {
        public let id: WindowID
        public let activeSpaceID: SpaceID
        public let spaces: [SpaceTabs]

        public init(id: WindowID, activeSpaceID: SpaceID, spaces: [SpaceTabs]) {
            self.id = id
            self.activeSpaceID = activeSpaceID
            self.spaces = spaces
        }
    }

    public let version: Int
    public let profiles: [BrowserProfile]
    public let spaces: [BrowserSpace]
    public let windows: [Window]
    /// Live occurrences per window. `BrowserTab.id` names their logical tab in `organization`.
    public let tabs: [BrowserTab]
    public let organization: BrowserOrganizationDocument
    /// Spaces whose `Import/space-appearance.json` entry was already considered, so an imported Orbit
    /// appearance becomes a theme once and never overrides a later user choice (version 4).
    public let themeImports: [SpaceID]

    /// Without an organization, every occurrence's logical tab is placed in Today of its Space,
    /// exactly as a version 1 document migrates.
    public init(
        version: Int = currentVersion,
        profiles: [BrowserProfile], spaces: [BrowserSpace], windows: [Window], tabs: [BrowserTab],
        organization: BrowserOrganizationDocument? = nil, themeImports: [SpaceID] = []
    ) {
        self.version = version
        self.profiles = profiles
        self.spaces = spaces
        self.windows = windows
        self.themeImports = themeImports
        if let organization {
            self.tabs = tabs
            self.organization = organization
        } else {
            let migrated = Self.migratedOrganization(spaces: spaces, windows: windows, tabs: tabs, date: Date())
            self.tabs = migrated.tabs
            self.organization = migrated.organization
        }
    }

    private enum CodingKeys: String, CodingKey { case version, profiles, spaces, windows, tabs, organization, themeImports }
    private enum OrganizationSchemaKeys: String, CodingKey { case splits }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(version) else { throw BrowserSessionError.unsupportedVersion }
        let profiles = try container.decode([BrowserProfile].self, forKey: .profiles)
        var spaces = try container.decode([BrowserSpace].self, forKey: .spaces)
        var themeImports: [SpaceID] = []
        if version >= 4 {
            // A version 4 writer always declares the migration record, even when empty.
            themeImports = try container.decode([SpaceID].self, forKey: .themeImports)
        } else {
            // Versions 1–3 had no Space theme: a stray field is not part of their schema.
            for index in spaces.indices { spaces[index].theme = nil }
        }
        let windows = try container.decode([Window].self, forKey: .windows)
        let tabs = try container.decode([BrowserTab].self, forKey: .tabs)
        if version >= 3 {
            // v2 omitted this field legitimately. v3 must declare its group inventory, even
            // when empty; a missing/null inventory must not silently erase split metadata.
            let schema = try container.nestedContainer(keyedBy: OrganizationSchemaKeys.self, forKey: .organization)
            guard schema.contains(.splits), try !schema.decodeNil(forKey: .splits) else {
                throw BrowserSessionError.invalidSplitGroup
            }
        }
        if version >= 2 {
            self.init(version: Self.currentVersion, profiles: profiles, spaces: spaces, windows: windows, tabs: tabs,
                      organization: try container.decode(BrowserOrganizationDocument.self, forKey: .organization),
                      themeImports: themeImports)
        } else {
            let date = decoder.userInfo[.browserSessionMigrationDate] as? Date ?? Date()
            let migrated = Self.migratedOrganization(spaces: spaces, windows: windows, tabs: tabs, date: date)
            self.init(version: Self.currentVersion, profiles: profiles, spaces: spaces, windows: windows,
                      tabs: migrated.tabs, organization: migrated.organization)
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Version 1 input is migrated; `migrationDate` stamps the migrated tabs' creation and last
    /// activity so auto-archiving starts counting from the migration, never earlier.
    public static func decode(
        _ data: Data, maximumBytes: Int = defaultMaximumInputBytes, migrationDate: Date? = nil
    ) throws -> BrowserSessionDocument {
        guard maximumBytes >= 0, data.count <= maximumBytes else { throw BrowserSessionError.limitExceeded }
        let decoder = JSONDecoder()
        if let migrationDate { decoder.userInfo[.browserSessionMigrationDate] = migrationDate }
        let document = try decoder.decode(Self.self, from: data)
        try document.validate()
        return document
    }

    public func validate() throws {
        guard version == Self.currentVersion else { throw BrowserSessionError.unsupportedVersion }
        let profileIndex = try Self.index(profiles, id: \.id)
        let spaceIndex = try Self.index(spaces, id: \.id)
        _ = try Self.index(windows, id: \.id)
        let tabIndex = try Self.index(tabs, id: \.occurrenceID)
        for space in spaces {
            guard profileIndex[space.profileID] != nil else { throw BrowserSessionError.profileMissing }
            try space.theme?.validate()
        }
        var migratedThemes: Set<SpaceID> = []
        for spaceID in themeImports {
            guard spaceIndex[spaceID] != nil else { throw BrowserSessionError.spaceMissing }
            guard migratedThemes.insert(spaceID).inserted else { throw BrowserSessionError.duplicateIdentity }
        }
        var ownedOccurrences: Set<TabOccurrenceID> = []
        for window in windows {
            guard spaceIndex[window.activeSpaceID] != nil,
                  window.spaces.contains(where: { $0.spaceID == window.activeSpaceID })
            else { throw BrowserSessionError.spaceMissing }
            _ = try Self.index(window.spaces, id: \.spaceID)
            for group in window.spaces {
                guard spaceIndex[group.spaceID] != nil else { throw BrowserSessionError.spaceMissing }
                var localOccurrences: Set<TabOccurrenceID> = []
                for occurrenceID in group.occurrenceIDs {
                    guard localOccurrences.insert(occurrenceID).inserted,
                          ownedOccurrences.insert(occurrenceID).inserted
                    else { throw BrowserSessionError.duplicateIdentity }
                    guard let tab = tabIndex[occurrenceID] else { throw BrowserSessionError.occurrenceMissing }
                    guard tab.windowID == window.id, tab.spaceID == group.spaceID else {
                        throw BrowserSessionError.occurrenceOwnedByAnotherContainer
                    }
                }
                if let selected = group.selectedOccurrenceID, !localOccurrences.contains(selected) {
                    throw BrowserSessionError.invalidSelection
                }
            }
        }
        guard ownedOccurrences.count == tabs.count else { throw BrowserSessionError.orphanedOccurrence }
        for tab in tabs {
            try Self.validateDestination(tab.url)
        }
        try validateOrganization(spaceIndex: spaceIndex, profiles: Set(profileIndex.keys))
    }

    /// Every occurrence names a logical tab of the sidebar, lives where that tab belongs, and a
    /// window holds at most one occurrence of each logical tab.
    private func validateOrganization(spaceIndex: [SpaceID: BrowserSpace], profiles: Set<ProfileID>) throws {
        let state = try BrowserOrganizationState(document: organization)
        try state.validate(profiles: profiles, spaces: spaceIndex.mapValues(\.profileID))
        var windowsByTab: [TabID: Set<WindowID>] = [:]
        for tab in tabs {
            guard let section = state.section(of: .tab(tab.id)) else {
                throw BrowserSessionError.occurrenceWithoutLogicalTab
            }
            switch section {
            case let .favorites(profileID):
                guard spaceIndex[tab.spaceID]?.profileID == profileID else {
                    throw BrowserSessionError.occurrenceOutsideLogicalTabSection
                }
            case let .pinned(spaceID), let .today(spaceID):
                guard tab.spaceID == spaceID else { throw BrowserSessionError.occurrenceOutsideLogicalTabSection }
            }
            guard windowsByTab[tab.id, default: []].insert(tab.windowID).inserted else {
                throw BrowserSessionError.duplicateIdentity
            }
        }
    }

    static func validateDestination(_ url: URL) throws {
        guard url.scheme != nil else { throw BrowserSessionError.invalidURL }
    }

    private static func index<Value, ID: Hashable>(_ values: [Value], id: KeyPath<Value, ID>) throws -> [ID: Value] {
        var result: [ID: Value] = [:]
        for value in values {
            guard result.updateValue(value, forKey: value[keyPath: id]) == nil else {
                throw BrowserSessionError.duplicateIdentity
            }
        }
        return result
    }
}
