import BrowserCore
import BrowserEngine
import BrowserShell
import Combine
import Foundation

enum BrowserSettingsPage { case extensions, extensionShortcuts, chromium }

struct BrowserSettingsSiteDataRequest: Identifiable {
    let id = UUID()
    let profileID: ProfileID
    let profileName: String
    let origin: BrowserSiteOrigin?
    let domains: [String]
}

struct BrowserSettingsPermissionRow: Identifiable {
    let origin: BrowserSiteOrigin
    let permission: BrowserSitePermission
    let setting: BrowserSitePermissionSetting
    var id: String { origin.value + "|" + permission.rawValue }
}

/// The settings window selects an explicit profile, independent of browser focus. Every callback
/// carries that identity; no delayed action consults the current browser window as a fallback.
@MainActor
final class BrowserSettingsModel<Engine: BrowserEngine>: ObservableObject {
    let environment: BrowserEnvironment<Engine>
    let runtime: BrowserSettingsRuntime
    let shortcuts: [BrowserCommandDefinition]
    let defaultBrowser: BrowserDefaultBrowserService
    @Published var focusNewProfile = false
    @Published var settingsSection: BrowserSettingsSection? = .general
    @Published private(set) var catalog = BrowserCatalogSnapshot(profiles: [], spaces: [])
    @Published private(set) var selectedProfileID: ProfileID?
    @Published private(set) var appearanceSpaceID: SpaceID?
    @Published private(set) var archivedSpaces: [BrowserArchivedSpace] = []
    @Published private(set) var permissionRows: [BrowserSettingsPermissionRow] = []
    @Published private(set) var archiveThreshold: BrowserAutoArchiveThreshold?
    @Published private(set) var defaultStatus: BrowserDefaultBrowserStatus?
    @Published private(set) var isBusy = false
    @Published private(set) var acceptsActions = true
    @Published private(set) var isRequestingDefaultBrowser = false
    @Published private(set) var pendingProfileRemovalCount = 0
    @Published var errorMessage: String?
    @Published var siteDataRequest: BrowserSettingsSiteDataRequest?
    /// Opens the theme editor of a Space over the Settings window (set by its window controller).
    var presentThemeEditor: ((SpaceID) -> Void)?
    var presentBrowserForProfile: ((ProfileID) async throws -> BrowserWindowController<Engine>)?
    var shortcutIsImplemented: ((BrowserCommandID) -> Bool)?
    var settingsShortcuts: [BrowserCommandDefinition] {
        shortcuts.filter { $0.owner != "OUT-OF-SCOPE-AI" && !OrbitCommandCatalog.structuralIDs.contains($0.id)
            && $0.scope == .browser && ($0.sources.contains(where: { $0.hasPrefix("menu.declaration.") }) || $0.owner == "ORG")
            && (shortcutIsImplemented?($0.id) ?? true) }
            .sorted { $0.localizedTitle.localizedStandardCompare($1.localizedTitle) == .orderedAscending }
    }
    private var pendingCount = 0
    private var pending: Task<Void, Never>?
    private var iconEdits: [UUID: BrowserSpaceSettingsAuthority] = [:]
    private var selectionGeneration = UUID() {
        willSet {
            for authority in iconEdits.values { authority.revoke() }
            iconEdits.removeAll()
        }
    }

    init(environment: BrowserEnvironment<Engine>, profileID: ProfileID?,
         shortcuts: [BrowserCommandDefinition], defaultBrowser: BrowserDefaultBrowserService = .init()) {
        self.environment = environment
        runtime = environment.settings
        selectedProfileID = profileID
        self.shortcuts = shortcuts
        self.defaultBrowser = defaultBrowser
    }

    var supportedPermissions: Set<BrowserSitePermission> {
        (environment.engine as? any BrowserSitePermissionAvailability)?.supportedSitePermissions ?? []
    }
    var supportsSiteData: Bool { environment.engine is any BrowserSiteDataAccess }
    var supportsProfileRemoval: Bool { environment.engine.capabilities.contains(.profileRemoval) && !runtime.isUnavailable }
    /// A working Safe Browsing service protects this build (CHROMIUM-APP-R3).
    var safeBrowsingAvailable: Bool { environment.engine.capabilities.contains(.safeBrowsing) }
    var permissionsUnavailable: Bool { environment.permissionsUnavailable }
    var canRequestDefaultBrowser: Bool { environment.engine.kind == .chromium && defaultBrowser.canRequest() }

    func canOpenChromiumSettings(profile: ProfileID) -> Bool {
        environment.engine.kind == .chromium && presentBrowserForProfile != nil
            && catalog.spaces.contains { $0.profileID == profile }
    }

    func canOpenExtensionSettings(profile: ProfileID) -> Bool {
        canOpenChromiumSettings(profile: profile) && environment.engine.extensionManagement != nil
    }

    func openBrowserSettings(_ page: BrowserSettingsPage, profile: ProfileID) async throws {
        try await requireProfile(profile)
        guard (page == .chromium ? canOpenChromiumSettings(profile: profile) : canOpenExtensionSettings(profile: profile)),
              let presentBrowserForProfile else {
            throw BrowserEngineError.unsupportedOperation
        }
        let controller = try await presentBrowserForProfile(profile)
        guard let tab = await controller.session.openTabForDelivery(url: URL(string: "about:blank")!, expectedProfileID: profile).value else {
            throw BrowserEngineError.unsupportedOperation
        }
        guard let surface = controller.session.selectedSurface, surface.profileID == profile,
              controller.session.snapshot?.selectedOccurrenceID == tab.occurrenceID else {
            throw BrowserEngineError.unsupportedOperation
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while !surface.isReady, !surface.isDisposed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard !surface.isDisposed, surface.isReady, controller.owns(surface),
              controller.session.selectedSurface === surface, surface.profileID == profile else {
            throw BrowserEngineError.unsupportedOperation
        }
        if page == .chromium {
            BrowserNavigationPolicy.authorizeChromiumSettings(for: surface)
            surface.navigate(to: URL(string: "chrome://settings/")!)
            return
        }
        guard let manager = environment.engine.extensionManagement else { throw BrowserEngineError.unsupportedOperation }
        switch page {
        case .chromium: break
        case .extensions: try manager.openManagement(on: surface)
        case .extensionShortcuts: try manager.openShortcuts(on: surface)
        }
    }

    func selectProfile(_ id: ProfileID) {
        selectedProfileID = id
        selectionGeneration = UUID()
        appearanceSpaceID = nil
        permissionRows = []
        perform { [self] in await reload() }
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard acceptsActions, !environment.isFinalizing else { return }
        let previous = pending
        pendingCount += 1
        isBusy = true
        pending = Task { [self] in
            await previous?.value
            errorMessage = nil
            do { try await action() }
            catch { errorMessage = Self.message(for: error) }
            await reload()
            pendingCount -= 1
            isBusy = pendingCount > 0
        }
    }

    func waitForPendingActions() async { await pending?.value }

    /// Accepted actions settle before the final session snapshot; a timeout cancels quitting,
    /// without cancelling a disk write or an outstanding system confirmation.
    func setMemorySaver(_ setting: BrowserMemorySaverSetting) async throws {
        try await environment.settings.store.setMemorySaver(setting)
        await environment.settings.refresh()
    }

    func suspendForTermination(timeout: Duration?) async throws {
        guard !isRequestingDefaultBrowser else { throw BrowserTerminationPreparationError.systemConfirmationPending }
        acceptsActions = false
        let deadline = timeout.map { ContinuousClock.now + $0 }
        while pendingCount > 0 {
            guard deadline.map({ ContinuousClock.now < $0 }) ?? true, !Task.isCancelled else {
                throw BrowserTerminationPreparationError.commandsDidNotSettle
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func resumeAfterCancelledTermination() { acceptsActions = true }

    func reload() async {
        let generation = selectionGeneration
        let updated = await environment.store.catalogSnapshot()
        pendingProfileRemovalCount = await environment.settingsProfileRemovals.pending().count
        guard generation == selectionGeneration else { return }
        catalog = updated
        if selectedProfileID == nil || !updated.profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = updated.profiles.first?.id
            permissionRows = []
        }
        guard let profile = selectedProfileID, updated.profiles.contains(where: { $0.id == profile }) else {
            selectedProfileID = nil
            permissionRows = []
            return
        }
        let profileSpaces = updated.spaces.filter { $0.profileID == profile }
        if !profileSpaces.contains(where: { $0.id == appearanceSpaceID }) {
            appearanceSpaceID = profileSpaces.first(where: { $0.id == runtime.document.lastActiveSpaceID })?.id
                ?? profileSpaces.first?.id
        }
        let document = await environment.store.sessionDocument()
        archivedSpaces = document.organization.archivedSpaces
        let threshold = document.organization.archivePolicy.threshold(for: profile)
        let origins = await environment.settingsPermissionOrigins(profile: profile)
        var rows: [BrowserSettingsPermissionRow] = []
        for origin in origins {
            let settings = await environment.settingsPermissions(origin: origin, profile: profile)
            for permission in BrowserSitePermission.allCases where supportedPermissions.contains(permission) {
                rows.append(.init(origin: origin, permission: permission, setting: settings[permission] ?? permission.defaultDecision))
            }
        }
        guard generation == selectionGeneration, selectedProfileID == profile else { return }
        permissionRows = rows
        archiveThreshold = threshold
        defaultStatus = defaultBrowser.status()
    }

    func selectAppearanceSpace(_ id: SpaceID) {
        guard catalog.spaces.contains(where: { $0.id == id && $0.profileID == selectedProfileID }) else { return }
        appearanceSpaceID = id
        selectionGeneration = UUID()
    }

    /// Capture identity and selection generation before entering the settings queue. A switched form
    /// cannot deliver a delayed slider value into a different Space or reassigned profile.
    func queueAppearanceSurfaceEdit(spaceID: SpaceID, profileID: ProfileID,
                                    material: BrowserThemeSurface.Material? = nil, transparency: Double? = nil) {
        let generation = selectionGeneration
        perform { [self] in
            guard generation == selectionGeneration, selectedProfileID == profileID,
                  appearanceSpaceID == spaceID else { throw BrowserSpaceThemeError.conflict }
            guard !runtime.isUnavailable else { throw BrowserSettingsError.unavailable }
            guard !environment.themeEditors.isFrozen else { throw BrowserTerminationPreparationError.commandsDidNotSettle }
            try await environment.themeEditors.withFinishedEditors(spaceID: spaceID, profileID: profileID) { [self] in
                guard generation == selectionGeneration, selectedProfileID == profileID,
                      appearanceSpaceID == spaceID else { throw BrowserSpaceThemeError.conflict }
                guard !runtime.isUnavailable else { throw BrowserSettingsError.unavailable }
                guard !environment.themeEditors.isFrozen else { throw BrowserTerminationPreparationError.commandsDidNotSettle }
                let fallback = runtime.document.space(spaceID).palette.themeModel ?? BrowserSpaceThemePresets.default
                try await environment.store.setSpaceThemeSurface(for: spaceID, profileID: profileID,
                    material: material, transparency: transparency, fallback: fallback)
                // Keep admission reserved until both browser and Settings editor inputs are current.
                await environment.refreshSettingsCatalog()
                await reload()
            }
        }
    }

    func updateProfile(_ id: ProfileID, _ edit: @Sendable (inout BrowserProfileSettings) -> Void) async throws {
        try await requireProfile(id)
        try await runtime.updateProfile(id, edit)
    }

    func setArchiveThreshold(_ threshold: BrowserAutoArchiveThreshold?, profile: ProfileID, allProfiles: Bool = false) async throws {
        try await requireProfile(profile)
        if allProfiles, let threshold {
            try await environment.store.setAutoArchiveThresholdForAllProfiles(threshold, fromProfile: profile)
        } else {
            try await environment.store.setAutoArchiveThreshold(threshold, forProfile: profile)
        }
        await environment.refreshSettingsCatalog()
    }

    func setWarnBeforeQuitting(_ value: Bool) async throws {
        try await runtime.updateInteraction { $0.warnBeforeQuitting = value }
    }

    func setPlaySoundEffects(_ value: Bool) async throws {
        try await runtime.updateInteraction { $0.playSoundEffects = value }
    }

    func setHapticFeedback(_ value: Bool) async throws {
        try await runtime.updateInteraction { $0.hapticFeedback = value }
    }

    func setReducedMotion(_ value: BrowserReducedMotionSetting) async throws {
        do { try await runtime.store.setReducedMotion(value) }
        catch { await runtime.refresh(); throw error }
        await runtime.refresh()
    }

    func createProfile(name: String) async throws {
        _ = try await environment.initialContext.value
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.rangeOfCharacter(from: .controlCharacters) == nil else { throw BrowserStoreError.invalidSpaceName }
        let id = try await environment.store.createSettingsProfile(name: name)
        selectedProfileID = id
        selectionGeneration = UUID()
        await environment.refreshSettingsCatalog()
    }

    func renameProfile(_ id: ProfileID, name: String) async throws {
        try await environment.store.renameSettingsProfile(id, name: name)
        await environment.refreshSettingsCatalog()
    }

    func deleteProfile(_ id: ProfileID) async throws {
        try await environment.removeProfileFromSettings(id)
        if selectedProfileID == id { selectedProfileID = nil; selectionGeneration = UUID() }
    }

    func createSpace(name: String, profile: ProfileID) async throws {
        _ = try await environment.store.createSpace(name: name, profileID: profile)
        await environment.refreshSettingsCatalog()
        await reload()
    }

    func deleteSpace(_ id: SpaceID, expectedProfileID: ProfileID? = nil) async throws {
        try await environment.removeSpaceFromSettings(id, expectedProfileID: expectedProfileID)
        await reload()
    }

    func restoreSpace(_ id: SpaceID, expectedProfileID: ProfileID? = nil) async throws {
        guard !environment.isFinalizing else { throw BrowserTerminationPreparationError.commandsDidNotSettle }
        try await environment.store.restoreSettingsSpace(id, expectedProfileID: expectedProfileID)
        await environment.refreshSettingsCatalog()
        await reload()
    }

    var profileRemovalUnavailableReason: String? {
        if runtime.isUnavailable { return settingsText("readOnly", "Saved settings are unavailable. The existing file is kept and changes cannot be saved.") }
        if !environment.engine.capabilities.contains(.profileRemoval) {
            return settingsText("profileRemovalUnavailable", "The current engine does not support deleting profiles.")
        }
        if catalog.profiles.count < 2 { return settingsText("lastProfile", "The last profile cannot be deleted.") }
        if selectedProfileID == catalog.profiles.first?.id { return uiText("The Default Profile cannot be deleted.") }
        if catalog.spaces.contains(where: { $0.profileID == selectedProfileID }) {
            return uiText("Only Profiles not assigned to any Spaces can be deleted.")
        }
        return nil
    }

    func renameSpace(_ id: SpaceID, name: String) async throws {
        try await environment.store.renameSpace(id, name: name)
        await environment.refreshSettingsCatalog()
    }

    func assignSpace(_ id: SpaceID, profile: ProfileID) async throws {
        try await environment.store.assignSettingsSpace(id, to: profile)
        await environment.refreshSettingsCatalog()
    }

    /// The form captures both identities and its selection generation before queuing an edit.
    func queueSpaceIconEdit(spaceID: SpaceID, profileID: ProfileID, icon: BrowserSpaceIcon) {
        guard acceptsActions, !environment.isFinalizing, icon.isValid,
              let authority = environment.store.captureSpaceSettingsAuthority(for: spaceID, profileID: profileID) else { return }
        let generation = selectionGeneration
        iconEdits[authority.id] = authority
        perform { [self] in
            defer { iconEdits.removeValue(forKey: authority.id) }
            guard generation == selectionGeneration, selectedProfileID == profileID, icon.isValid,
                  !runtime.isUnavailable else { throw BrowserSettingsError.invalidIcon }
            let latest = await environment.store.catalogSnapshot()
            guard generation == selectionGeneration, selectedProfileID == profileID,
                  latest.spaces.contains(where: { $0.id == spaceID && $0.profileID == profileID }) else {
                throw BrowserStoreError.spaceMissing
            }
            try await runtime.updateSpace(spaceID, authority: authority) { $0.iconSelection = icon }
        }
    }

    func updateSpace(_ id: SpaceID, _ edit: @Sendable (inout BrowserSpaceSettings) -> Void) async throws {
        guard await environment.store.catalogSnapshot().spaces.contains(where: { $0.id == id }) else { throw BrowserStoreError.spaceMissing }
        try await runtime.updateSpace(id, edit)
    }

    func changePermission(_ row: BrowserSettingsPermissionRow, setting: BrowserSitePermissionSetting, profile: ProfileID) async throws {
        try await environment.changeSettingsPermission(setting, permission: row.permission, origin: row.origin, profile: profile)
    }

    func reviewSiteData(origin: BrowserSiteOrigin?, profile: ProfileID) async throws {
        try await requireProfile(profile)
        guard let service = environment.engine as? any BrowserSiteDataAccess else { throw BrowserSettingsServiceError.siteDataUnavailable }
        let domains: [String]
        if let origin { domains = await service.siteData(origin: origin, profileID: profile).domains }
        else { domains = [] }
        guard let name = catalog.profiles.first(where: { $0.id == profile })?.name else { throw BrowserStoreError.profileMissing }
        siteDataRequest = BrowserSettingsSiteDataRequest(profileID: profile, profileName: name, origin: origin, domains: domains)
    }

    func clearSiteData(_ request: BrowserSettingsSiteDataRequest) async throws {
        try await requireProfile(request.profileID)
        guard let service = environment.engine as? any BrowserSiteDataAccess else { throw BrowserSettingsServiceError.siteDataUnavailable }
        if let origin = request.origin {
            try await service.clearSiteData(origin: origin, profileID: request.profileID, expectedDomains: request.domains)
        } else { try await service.clearSiteData(profileID: request.profileID) }
    }

    func clearSiteData(profile: ProfileID) async throws { try await environment.clearSettingsSiteData(profile: profile) }

    func retryProfileRemovals() async throws { try await environment.retrySettingsProfileRemovals() }

    func requestDefaultBrowser() async throws {
        guard canRequestDefaultBrowser else { throw BrowserDefaultBrowserError.unavailableProduct }
        isRequestingDefaultBrowser = true
        defer { isRequestingDefaultBrowser = false }
        try await defaultBrowser.request()
    }

    private func requireProfile(_ id: ProfileID) async throws {
        guard await environment.store.catalogSnapshot().profiles.contains(where: { $0.id == id }) else { throw BrowserStoreError.profileMissing }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case BrowserSettingsError.profileHasSpaces: uiText("Only Profiles not assigned to any Spaces can be deleted.")
        case BrowserSettingsError.defaultProfile: uiText("The Default Profile cannot be deleted.")
        case BrowserSettingsError.profileInUse: settingsText("profileInUse", "Close windows and tabs using this profile before deleting it.")
        case BrowserSettingsError.unavailable: settingsText("readOnly", "Saved settings are unavailable. The existing file is kept and changes cannot be saved.")
        case BrowserSettingsError.profileBeingDeleted: settingsText("profileDeleting", "This profile is being removed. Finish its pending cleanup before trying again.")
        case BrowserSettingsError.lastSpace: settingsText("lastSpace", "The last Space cannot be deleted.")
        case BrowserSettingsError.lastProfile: settingsText("lastProfile", "The last profile cannot be deleted.")
        case BrowserSettingsError.spaceNotEmpty: settingsText("spaceNotEmpty", "Close this Space and remove its tabs, folders and archived tabs before changing its profile.")
        case BrowserSettingsError.invalidIcon: settingsText("invalidIcon", "Choose a single character or emoji for the Space icon.")
        case BrowserStoreError.invalidSpaceName: settingsText("invalidName", "Enter a name without control characters.")
        case BrowserSiteDataError.removalIncomplete: settingsText("dataRemovalIncomplete", "The engine could not confirm removal of all requested website data. Review the site data and retry.")
        case BrowserSiteDataError.scopeChanged: settingsText("dataScopeChanged", "The website data scope changed. Review the affected domains again before clearing data.")
        case BrowserSettingsServiceError.siteDataUnavailable: settingsText("siteDataUnavailable", "The current engine does not expose website data management.")
        case BrowserSettingsServiceError.permissionUnavailable: settingsText("permissionUnavailable", "The current engine does not support changing this permission.")
        case BrowserDefaultBrowserError.unavailableProduct, BrowserDefaultBrowserError.invalidSignature:
            settingsText("defaultUnavailable", "This action requires the Orbit product with its stable local signature.")
        default: settingsText("failed", "The change could not be completed. Some cleanup or browser associations may have changed. Check the current values before retrying.")
        }
    }
}

func settingsText(_ key: String, _ value: String) -> String {
    // Keep feature keys as source identifiers; the shared resource bundle uses English defaults.
    uiText(value)
}
