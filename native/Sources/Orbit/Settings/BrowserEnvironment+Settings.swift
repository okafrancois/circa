import BrowserCore
import BrowserEngine
import Foundation

extension BrowserEnvironment {
    func settingsDidChange() {
        for little in quickWindows.values {
            little.applyPreferences(searchEngine: settings.document.profile(little.profileID).searchEngine,
                theme: spaceTheme(for: little.sourceSpaceID))
        }
        for controller in liveControllers {
            controller.settingsPreferences?.apply(to: controller)
            controller.renderChrome()
            controller.settingsPreferences?.renderIcons(in: controller)
            controller.renderLibrary()
            controller.palette.renderContext()
            if controller.palette.isPresented {
                controller.palette.query(controller.palette.view.input.stringValue, preserveSelection: true, userInitiated: false)
            }
        }
    }

    func refreshSettingsCatalog() async {
        for controller in liveControllers { controller.session.refreshCatalog() }
        for controller in liveControllers { await controller.session.waitForQueuedCommands() }
        scheduleSave()
    }

    func removeSpaceFromSettings(_ id: SpaceID, expectedProfileID: ProfileID? = nil) async throws {
        guard !settingsRemovalIsRunning else { throw BrowserSettingsError.profileBeingDeleted }
        guard !isFinalizing else { throw BrowserTerminationPreparationError.commandsDidNotSettle }
        guard !settings.isUnavailable else { throw BrowserSettingsError.unavailable }
        settingsRemovalIsRunning = true
        defer { settingsRemovalIsRunning = false }
        // Settle existing native adoptions before revoking the Space's occurrence leases.
        for controller in liveControllers { await controller.session.waitForPendingCommands() }
        try await store.removeSettingsSpace(id, expectedProfileID: expectedProfileID)
        for little in Array(quickWindows.values) where little.sourceSpaceID == id {
            if let surface = little.surface { captureQuickWindowForReopening(little, surface: surface) }
            little.retire()
            little.window?.close()
        }
        for controller in liveControllers { controller.session.refreshAfterSpaceRemoval(id) }
        for controller in liveControllers { await controller.session.waitForPendingCommands() }
        try await flushQuickWindowArchives()
        try await persistSettingsRemovalSession()
        try await settings.store.removeSpace(id)
        await settings.refresh()
    }

    func removeProfileFromSettings(_ id: ProfileID) async throws {
        guard !settingsRemovalIsRunning else { throw BrowserSettingsError.profileBeingDeleted }
        guard !settings.isUnavailable else { throw BrowserSettingsError.unavailable }
        guard engine.capabilities.contains(.profileRemoval) else { throw BrowserEngineError.unsupportedOperation }
        settingsRemovalIsRunning = true
        defer { settingsRemovalIsRunning = false }
        if let pending = await settingsProfileRemovals.entry(id) {
            try await processSettingsProfileRemoval(pending)
            return
        }
        let removal = try await store.reserveSettingsProfileRemoval(id)
        do {
            try requireNoSettingsProfileSurfaces(id)
            try await settingsProfileRemovals.put(removal)
        } catch {
            // A committed-but-not-durable intent remains quarantined and retryable.
            if await settingsProfileRemovals.entry(id) == nil { await store.cancelSettingsProfileReservation(id) }
            throw error
        }
        try await processSettingsProfileRemoval(removal)
    }

    func retrySettingsProfileRemovals() async throws {
        guard !settingsRemovalIsRunning else { throw BrowserSettingsError.profileBeingDeleted }
        guard !settings.isUnavailable else { throw BrowserSettingsError.unavailable }
        settingsRemovalIsRunning = true
        defer { settingsRemovalIsRunning = false }
        for removal in await settingsProfileRemovals.pending() { try await processSettingsProfileRemoval(removal) }
    }

    private func requireNoSettingsProfileSurfaces(_ id: ProfileID) throws {
        guard !quickWindows.values.contains(where: { !$0.isClosed && $0.profileID == id }),
              !rescue.surfaces.contains(where: { $0.profileID == id }),
              !liveControllers.contains(where: { controller in
                  controller.session.ownedSurfaces.contains { $0.profileID == id }
                      || controller.peek.container.surfaces.contains { $0.profileID == id }
                      || controller.nativeCreations.values.contains { $0.surface.profileID == id }
              }) else { throw BrowserSettingsError.profileInUse }
    }

    private func processSettingsProfileRemoval(_ removal: BrowserProfileRemoval) async throws {
        var progress = removal
        do {
            try requireNoSettingsProfileSurfaces(removal.profileID)
            if progress.nextStep == .organization {
                try await store.commitSettingsProfileRemoval(removal.profileID)
            }
            // Also save recovered sessions when resuming a later step, before completing intent.
            try await persistSettingsRemovalSession()
            if progress.nextStep == .organization {
                progress.nextStep = .permissions
                try await settingsProfileRemovals.put(progress)
                await refreshSettingsCatalog()
            }
            if progress.nextStep == .permissions {
                try await removeSettingsPermissions(profile: removal.profileID)
                progress.nextStep = .history
                try await settingsProfileRemovals.put(progress)
            }
            if progress.nextStep == .history {
                try await removeSettingsHistory(profile: removal.profileID)
                try await favoriteIcons?.remove(profile: removal.profileID)
                sidebarIconMemory.remove(profile: removal.profileID)
                progress.nextStep = .engine
                try await settingsProfileRemovals.put(progress)
            }
            if progress.nextStep == .engine {
                try await engine.removeProfile(removal.profileID)
                progress.nextStep = .settings
                try await settingsProfileRemovals.put(progress)
            }
            if progress.nextStep == .settings {
                try await settings.store.removeProfile(removal.profileID, spaces: removal.spaceIDs)
                await settings.refresh()
            }
            try await settingsProfileRemovals.complete(removal.profileID)
            await store.finishSettingsProfileRemoval(removal.profileID)
        } catch {
            cancelSettingsHistoryRemoval(profile: removal.profileID)
            // Lifting the history tombstone makes recording available after a failed operation.
            // Retry recleans history before the engine, even if a late callback recreated a file.
            if progress.nextStep.rawValue >= BrowserProfileRemoval.Step.history.rawValue {
                progress.nextStep = .history
                try? await settingsProfileRemovals.put(progress)
            }
            throw error
        }
    }

    func changeSettingsPermission(_ setting: BrowserSitePermissionSetting, permission: BrowserSitePermission,
                                  origin: BrowserSiteOrigin, profile: ProfileID) async throws {
        guard await store.catalogSnapshot().profiles.contains(where: { $0.id == profile }) else { throw BrowserStoreError.profileMissing }
        guard let service = engine as? any BrowserSitePermissionAvailability,
              service.supportedSitePermissions.contains(permission) else { throw BrowserSettingsServiceError.permissionUnavailable }
        do {
            try await persistSettingsPermission(setting, permission: permission, origin: origin, profile: profile)
        } catch {
            if setting != .allow { await service.revokeSitePermission(permission, origin: origin, profileID: profile) }
            throw error
        }
        await service.setSitePermission(setting, permission: permission, origin: origin, profileID: profile)
        for controller in liveControllers { controller.siteControls.render() }
    }

    func clearSettingsSiteData(profile: ProfileID) async throws {
        guard await store.catalogSnapshot().profiles.contains(where: { $0.id == profile }) else { throw BrowserStoreError.profileMissing }
        guard let data = engine as? any BrowserSiteDataAccess else { throw BrowserSettingsServiceError.siteDataUnavailable }
        try await data.clearSiteData(profileID: profile)
    }
}

enum BrowserSettingsServiceError: Error { case siteDataUnavailable, permissionUnavailable }
