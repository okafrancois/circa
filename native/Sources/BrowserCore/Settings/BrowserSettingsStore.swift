import Foundation

public enum BrowserReducedMotionSetting: String, Codable, CaseIterable, Sendable {
    case system, reduce, full
    public var override: Bool? {
        switch self { case .system: nil; case .reduce: true; case .full: false }
    }
}

public enum BrowserMemorySaverSetting: String, Codable, CaseIterable, Sendable {
    case fiveMinutes, fifteenMinutes, thirtyMinutes, oneHour, twoHours, fourHours, sixHours, never
    public var interval: TimeInterval? {
        switch self {
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .thirtyMinutes: 1800
        case .oneHour: 3600
        case .twoHours: 7200
        case .fourHours: 14400
        case .sixHours: 21600
        case .never: nil
        }
    }
}

public struct BrowserProfileSettings: Codable, Equatable, Sendable {
    public var searchEngine: SearchEngine = .google
    public var showSearchSuggestions = true
    public var opensPinnedLinksInPeek = true
    public var shiftClickOpensPeek = true
    public var extensionPinOrder: [String] = []
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case showSearchSuggestions, searchEngine, opensPinnedLinksInPeek, shiftClickOpensPeek, extensionPinOrder
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        searchEngine = try values.decode(SearchEngine.self, forKey: .searchEngine)
        showSearchSuggestions = try values.decodeIfPresent(Bool.self, forKey: .showSearchSuggestions) ?? true
        opensPinnedLinksInPeek = try values.decode(Bool.self, forKey: .opensPinnedLinksInPeek)
        shiftClickOpensPeek = try values.decode(Bool.self, forKey: .shiftClickOpensPeek)
        extensionPinOrder = (try? values.decode([String].self, forKey: .extensionPinOrder)) ?? []
    }
}

/// Named palettes use the existing THEME resolver; arbitrary colours are not inferred from Orbit.
public enum BrowserSpacePalette: String, Codable, CaseIterable, Sendable {
    case automatic, amberCoral, lavender, rosePlum, limeCitrus
}

/// A Space has exactly one icon. SF Symbol identifiers are data, never grapheme strings.
public enum BrowserSpaceIcon: Codable, Equatable, Hashable, Sendable {
    case none
    case grapheme(String)
    case systemSymbol(String)

    public var isValid: Bool {
        switch self {
        case .none: true
        case .grapheme(let value): !value.isEmpty && BrowserSpaceSettings.isValidIcon(value)
        case .systemSymbol(let name): Self.isValidSymbolIdentifier(name)
        }
    }

    /// Bounded ASCII components. Availability on this OS is checked by the native picker.
    public static func isValidSymbolIdentifier(_ name: String) -> Bool {
        guard (1...96).contains(name.utf8.count), let first = name.utf8.first,
              (97...122).contains(first) else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
        }
    }

    public init(legacyIcon: String) { self = legacyIcon.isEmpty ? .none : .grapheme(legacyIcon) }
}

public struct BrowserSpaceSettings: Codable, Equatable, Sendable {
    private var grapheme = ""
    private var systemSymbol: String?
    private var invalidIconSelection: BrowserSpaceIcon?
    /// Compatibility field edits replace the whole choice, including when clearing an emoji.
    public var icon: String {
        get { grapheme }
        set { grapheme = newValue; systemSymbol = nil; invalidIconSelection = nil }
    }
    public var iconSelection: BrowserSpaceIcon {
        get { invalidIconSelection ?? systemSymbol.map(BrowserSpaceIcon.systemSymbol) ?? BrowserSpaceIcon(legacyIcon: grapheme) }
        set {
            invalidIconSelection = newValue.isValid ? nil : newValue
            switch newValue {
            case .none: grapheme = ""; systemSymbol = nil
            case .grapheme(let value): grapheme = value; systemSymbol = nil
            case .systemSymbol(let name): grapheme = ""; systemSymbol = name
            }
        }
    }
    public var palette: BrowserSpacePalette = .automatic
    public init() {}
    private enum CodingKeys: String, CodingKey { case icon, systemSymbol, palette }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        grapheme = try values.decode(String.self, forKey: .icon)
        palette = try values.decode(BrowserSpacePalette.self, forKey: .palette)
        // Optional future/malformed metadata must not quarantine otherwise usable preferences.
        // A recognized symbol takes precedence; load never writes the source file.
        if let name = try? values.decode(String.self, forKey: .systemSymbol),
           BrowserSpaceIcon.isValidSymbolIdentifier(name) {
            systemSymbol = name
            grapheme = ""
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(grapheme, forKey: .icon)
        try values.encodeIfPresent(systemSymbol, forKey: .systemSymbol)
        try values.encode(palette, forKey: .palette)
    }
    public static func isValidIcon(_ icon: String) -> Bool {
        icon.count <= 1 && icon.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value) && $0.value != 0x2028 && $0.value != 0x2029
        }
    }
}

public struct BrowserInteractionPreferences: Codable, Equatable, Sendable {
    public var warnBeforeQuitting = true
    public var playSoundEffects = true
    public var hapticFeedback = true
    public init() {}
}

/// Device-local download choices shared by normal and private windows.
public struct BrowserDownloadPreferences: Codable, Equatable, Sendable {
    public var folderPath: String?
    public var asksWhereToSave = false
    public init() {}
    public var folderURL: URL {
        folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
}

public struct BrowserSettingsDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public var version = Self.currentVersion
    public var reducedMotion: BrowserReducedMotionSetting = .system
    public var interaction = BrowserInteractionPreferences()
    public var downloads = BrowserDownloadPreferences()
    public var memorySaver: BrowserMemorySaverSetting = .oneHour
    public var safeBrowsingEnabled = false
    public var allowJavaScriptFromAppleEvents = false
    public var automaticPictureInPicture = true
    public var quickWindowArchiveThreshold: BrowserAutoArchiveThreshold = .sixHours
    /// Device-local domain/account choices, excluded from the sync projection.
    public var quickWindowProfilesByDomain: [String: ProfileID] = [:]
    public var enablesBoostsOnWebsites = true
    public var hasSeenBoostsIntroduction = false
    public var opensExternalLinksInQuickWindow = true {
        didSet {
            // Keep the legacy preference and ATC's destination consistent before encoding.
            if opensExternalLinksInQuickWindow != (linkRouting.defaultDestination == .quickWindow) {
                linkRouting.defaultDestination = opensExternalLinksInQuickWindow ? .quickWindow : .mostRecentSpace
            }
        }
    }
    public var linkRouting = BrowserLinkRouting() {
        didSet { opensExternalLinksInQuickWindow = linkRouting.defaultDestination == .quickWindow }
    }
    public var lastActiveWindowID: WindowID?
    public var lastActiveSpaceID: SpaceID?
    public var profiles: [ProfileID: BrowserProfileSettings] = [:]
    public var spaces: [SpaceID: BrowserSpaceSettings] = [:]
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case allowJavaScriptFromAppleEvents, safeBrowsingEnabled, quickWindowArchiveThreshold, quickWindowProfilesByDomain, downloads, automaticPictureInPicture, hasSeenBoostsIntroduction, enablesBoostsOnWebsites, interaction, memorySaver, linkRouting, version, reducedMotion, profiles, spaces, opensExternalLinksInQuickWindow, lastActiveWindowID, lastActiveSpaceID
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Retired secondary appearance fields are ignored and omitted on the next save.
        version = try values.decode(Int.self, forKey: .version)
        reducedMotion = try values.decode(BrowserReducedMotionSetting.self, forKey: .reducedMotion)
        interaction = try values.decodeIfPresent(BrowserInteractionPreferences.self, forKey: .interaction) ?? .init()
        downloads = try values.decodeIfPresent(BrowserDownloadPreferences.self, forKey: .downloads) ?? .init()
        memorySaver = (try? values.decode(BrowserMemorySaverSetting.self, forKey: .memorySaver)) ?? .oneHour
        // Version one did not record whether four hours was explicitly chosen.
        // Migrate that former default once; subsequent explicit choices survive.
        if version == 1 {
            if memorySaver == .fourHours { memorySaver = .oneHour }
            version = Self.currentVersion
        }
        quickWindowArchiveThreshold = try values.decodeIfPresent(BrowserAutoArchiveThreshold.self, forKey: .quickWindowArchiveThreshold) ?? .sixHours
        quickWindowProfilesByDomain = try values.decodeIfPresent([String: ProfileID].self, forKey: .quickWindowProfilesByDomain) ?? [:]
        safeBrowsingEnabled = try values.decodeIfPresent(Bool.self, forKey: .safeBrowsingEnabled) ?? false
        allowJavaScriptFromAppleEvents = try values.decodeIfPresent(Bool.self, forKey: .allowJavaScriptFromAppleEvents) ?? false
        automaticPictureInPicture = try values.decodeIfPresent(Bool.self, forKey: .automaticPictureInPicture) ?? true
        hasSeenBoostsIntroduction = try values.decodeIfPresent(Bool.self, forKey: .hasSeenBoostsIntroduction) ?? false
        enablesBoostsOnWebsites = try values.decodeIfPresent(Bool.self, forKey: .enablesBoostsOnWebsites) ?? true
        profiles = try values.decode([ProfileID: BrowserProfileSettings].self, forKey: .profiles)
        spaces = try values.decode([SpaceID: BrowserSpaceSettings].self, forKey: .spaces)
        lastActiveWindowID = try values.decodeIfPresent(WindowID.self, forKey: .lastActiveWindowID)
        lastActiveSpaceID = try values.decodeIfPresent(SpaceID.self, forKey: .lastActiveSpaceID)
        opensExternalLinksInQuickWindow = try values.decodeIfPresent(Bool.self, forKey: .opensExternalLinksInQuickWindow) ?? true
        if let routing = try values.decodeIfPresent(BrowserLinkRouting.self, forKey: .linkRouting) {
            linkRouting = routing
            opensExternalLinksInQuickWindow = routing.defaultDestination == .quickWindow
        } else {
            linkRouting.defaultDestination = opensExternalLinksInQuickWindow ? .quickWindow : .mostRecentSpace
        }
    }
    public func profile(_ id: ProfileID) -> BrowserProfileSettings { profiles[id] ?? .init() }
    public func space(_ id: SpaceID) -> BrowserSpaceSettings { spaces[id] ?? .init() }
}

public enum BrowserSettingsError: Error, Equatable {
    case unsupportedVersion, invalidIcon, profileInUse, lastProfile, spaceNotEmpty, unavailable, profileBeingDeleted, lastSpace, profileHasSpaces, defaultProfile
}

/// No implicit default destination: tests and private sessions stay in memory. Writes use the
/// same no-symlink, mode-0600 atomic replacement and durability policy as site permissions.
public actor BrowserSettingsStore {
    public nonisolated let isUnavailable: Bool
    private let destination: URL?
    var document: BrowserSettingsDocument

    /// Read-only startup snapshot, before an engine or the settings actor's executor exists.
    public static func safeBrowsingEnabledAtLaunch(destination: URL) throws -> Bool {
        guard let data = try BrowserPermissionFile.load(destination) else { return false }
        let header = try JSONDecoder().decode(Header.self, from: data)
        if header.version == 0 { return false }
        guard [1, BrowserSettingsDocument.currentVersion].contains(header.version) else {
            throw BrowserSettingsError.unsupportedVersion
        }
        let loaded = try JSONDecoder().decode(BrowserSettingsDocument.self, from: data)
        try validate(loaded)
        return loaded.safeBrowsingEnabled
    }

    public static func unavailable() -> BrowserSettingsStore { BrowserSettingsStore(unavailable: ()) }

    private init(unavailable: Void) {
        destination = nil
        document = .init()
        isUnavailable = true
    }

    public init(destination: URL? = nil) throws {
        isUnavailable = false
        self.destination = destination
        if let destination, let data = try BrowserPermissionFile.load(destination) {
            let header = try JSONDecoder().decode(Header.self, from: data)
            switch header.version {
            case 0:
                let legacy = try JSONDecoder().decode(LegacyDocument.self, from: data)
                var migrated = BrowserSettingsDocument()
                migrated.reducedMotion = legacy.reduceMotion.map { $0 ? .reduce : .full } ?? .system
                migrated.profiles = legacy.profiles ?? [:]
                document = migrated
            case 1, BrowserSettingsDocument.currentVersion:
                document = try JSONDecoder().decode(BrowserSettingsDocument.self, from: data)
            default: throw BrowserSettingsError.unsupportedVersion
            }
            try Self.validate(document)
        } else { document = .init() }
    }

    public func applySync(_ value: BrowserSettingsDocument, expected: BrowserSettingsDocument) throws {
        guard document == expected else { throw BrowserSyncError.localChange }
        try publish(value)
    }

    public func snapshot() -> BrowserSettingsDocument { document }

    public func updateInteraction(_ edit: @Sendable (inout BrowserInteractionPreferences) -> Void) throws {
        var next = document
        edit(&next.interaction)
        try publish(next)
    }

    public func updateDownloads(_ edit: @Sendable (inout BrowserDownloadPreferences) -> Void) throws {
        var next = document
        edit(&next.downloads)
        try publish(next)
    }

    public func setProfile(_ settings: BrowserProfileSettings, for id: ProfileID) throws {
        var next = document
        next.profiles[id] = settings
        try publish(next)
    }

    /// Apply a field edit to the latest profile and durably publish in one actor turn.
    public func updateProfile(_ id: ProfileID, _ edit: @Sendable (inout BrowserProfileSettings) -> Void) throws {
        var next = document
        var settings = next.profile(id)
        edit(&settings)
        next.profiles[id] = settings
        try publish(next)
    }

    public func setSpace(_ settings: BrowserSpaceSettings, for id: SpaceID) throws {
        var next = document
        next.spaces[id] = settings
        try publish(next)
    }

    /// Read, mutate and durably publish in one actor turn, retaining fields edited by other callers.
    public func updateSpace(_ id: SpaceID, _ edit: @Sendable (inout BrowserSpaceSettings) -> Void) throws {
        var next = document
        var settings = next.space(id)
        edit(&settings)
        next.spaces[id] = settings
        try publish(next)
    }

    /// Prepare the field edit before taking ownership admission. No caller
    /// callback or actor hop occurs inside the durable publication barrier.
    public func updateSpace(_ id: SpaceID, authority: BrowserSpaceSettingsAuthority,
                            _ edit: @Sendable (inout BrowserSpaceSettings) -> Void) throws {
        guard authority.spaceID == id else { throw BrowserStoreError.staleContext }
        var next = document
        var settings = next.space(id)
        edit(&settings)
        next.spaces[id] = settings
        try authority.publish { try publish(next) }
    }

    public func setLastActiveWindow(_ windowID: WindowID, spaceID: SpaceID) throws {
        var next = document
        next.lastActiveWindowID = windowID
        next.lastActiveSpaceID = spaceID
        try publish(next)
    }

    public func setOpensExternalLinksInQuickWindow(_ enabled: Bool) throws {
        var next = document
        next.opensExternalLinksInQuickWindow = enabled
        next.linkRouting.defaultDestination = enabled ? .quickWindow : .mostRecentSpace
        try publish(next)
    }

    func updateLinkRouting(_ edit: (inout BrowserLinkRouting) -> Void) throws {
        var next = document
        edit(&next.linkRouting)
        next.opensExternalLinksInQuickWindow = next.linkRouting.defaultDestination == .quickWindow
        try publish(next)
    }

    public func setReducedMotion(_ setting: BrowserReducedMotionSetting) throws {
        var next = document
        next.reducedMotion = setting
        try publish(next)
    }

    public func setMemorySaver(_ setting: BrowserMemorySaverSetting) throws {
        var next = document
        next.memorySaver = setting
        try publish(next)
    }

    public func setSafeBrowsingEnabled(_ enabled: Bool) throws {
        var next = document
        next.safeBrowsingEnabled = enabled
        try publish(next)
    }

    public func setAllowJavaScriptFromAppleEvents(_ enabled: Bool) throws {
        var next = document
        next.allowJavaScriptFromAppleEvents = enabled
        try publish(next)
    }

    public func setAutomaticPictureInPicture(_ enabled: Bool) throws {
        var next = document
        next.automaticPictureInPicture = enabled
        try publish(next)
    }

    public func markBoostsIntroductionSeen() throws {
        var next = document
        next.hasSeenBoostsIntroduction = true
        try publish(next)
    }

    public func setEnablesBoostsOnWebsites(_ enabled: Bool) throws {
        var next = document
        next.enablesBoostsOnWebsites = enabled
        try publish(next)
    }

    public func removeSpace(_ id: SpaceID) throws {
        var next = document
        next.spaces[id] = nil
        next.linkRouting.removeSpaces([id])
        next.opensExternalLinksInQuickWindow = next.linkRouting.defaultDestination == .quickWindow
        if next.lastActiveSpaceID == id { next.lastActiveSpaceID = nil; next.lastActiveWindowID = nil }
        try publish(next)
    }

    public func removeProfile(_ id: ProfileID, spaces: Set<SpaceID>) throws {
        var next = document
        next.profiles[id] = nil
        next.quickWindowProfilesByDomain = next.quickWindowProfilesByDomain.filter { $0.value != id }
        next.spaces = next.spaces.filter { !spaces.contains($0.key) }
        next.linkRouting.removeSpaces(spaces)
        next.opensExternalLinksInQuickWindow = next.linkRouting.defaultDestination == .quickWindow
        try publish(next)
    }

    func publish(_ next: BrowserSettingsDocument) throws {
        guard !isUnavailable else { throw BrowserSettingsError.unavailable }
        try Self.validate(next)
        if let destination {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do { try BrowserPermissionFile.save(encoder.encode(next), to: destination) }
            catch BrowserPermissionFile.Failure.committedButNotDurable {
                document = next
                throw BrowserPermissionFile.Failure.committedButNotDurable
            }
        }
        document = next
    }

    private static func validate(_ document: BrowserSettingsDocument) throws {
        guard document.version == BrowserSettingsDocument.currentVersion else { throw BrowserSettingsError.unsupportedVersion }
        guard document.quickWindowArchiveThreshold.isValid else { throw BrowserOrganizationError.invalidThreshold }
        guard document.linkRouting.rules.allSatisfy(\.isValid),
              Set(document.linkRouting.rules.map(\.id)).count == document.linkRouting.rules.count else {
            throw BrowserLinkRoutingError.invalidRule
        }
        for settings in document.spaces.values {
            guard BrowserSpaceSettings.isValidIcon(settings.icon), settings.iconSelection.isValid else {
                throw BrowserSettingsError.invalidIcon
            }
        }
    }
    private struct Header: Decodable { let version: Int }
    /// Compatibility schema for a boolean override, before the explicit system option.
    private struct LegacyDocument: Decodable {
        let reduceMotion: Bool?
        let profiles: [ProfileID: BrowserProfileSettings]?
    }
}
