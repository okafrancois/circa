import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

extension BrowserEnvironment {
    func makeQuickWindow(spaceID requestedSpaceID: SpaceID? = nil, url: URL? = nil,
                       startLoading: Bool = true, preferredProfileID: ProfileID? = nil) async throws -> BrowserQuickWindowWindowController<Engine> {
        _ = try await initialContext.value
        let document = await store.sessionDocument()
        let profileID = preferredProfileID ?? document.spaces.first { $0.id == requestedSpaceID }?.profileID
        let catalog = await store.catalogSnapshot()
        guard !isFinalizing, !settingsRemovalIsRunning else { throw BrowserSettingsError.profileBeingDeleted }
        let remembered = lastUsedSpaceID.flatMap { id in catalog.spaces.first { $0.id == id } }
        if remembered == nil { lastUsedSpaceID = nil }
        // A captured account is a boundary, including while quarantine hides it from the catalog.
        if let profileID {
            guard catalog.profiles.contains(where: { $0.id == profileID }) else {
                if await store.isSettingsProfileBeingRemoved(profileID) { throw BrowserSettingsError.profileBeingDeleted }
                throw BrowserStoreError.profileMissing
            }
        }
        let requested = requestedSpaceID.flatMap { id in catalog.spaces.first { $0.id == id } }.flatMap { space in
            profileID == nil || space.profileID == profileID ? space : nil
        }
        let matching = profileID.flatMap { profile in catalog.spaces.first { $0.profileID == profile } }
        let fallback = profileID == nil ? remembered ?? catalog.spaces.first : nil
        guard let space = requested ?? matching ?? fallback else { throw BrowserStoreError.spaceMissing }
        let controller = registerQuickWindow(spaceID: space.id, profileID: space.profileID, spaceName: space.name)
        // Use the snapshot read for this creation, even when an observer's publication is older.
        controller.applyPreferences(searchEngine: settings.document.profile(space.profileID).searchEngine,
                                    theme: spaceTheme(for: space.id, in: catalog))
        do {
            await controller.historyObserver.prepareSuggestions(for: space.profileID)
            let candidates = BrowserPaletteRanking.candidates(document: document, profileID: space.profileID,
                windowID: document.windows.first?.id ?? WindowID(), spaceID: space.id, windowIDs: Dictionary(uniqueKeysWithValues: document.windows.map { ($0.id, $0.id.rawValue) }))
            let history = controller.historyObserver.cachedSuggestions(for: space.profileID, query: "")
            let live = liveControllers.flatMap { $0.session.ownedSurfaces }.filter { $0.profileID == space.profileID }
            controller.inputCandidates = candidates.map { result in
                let pixels = live.first { $0.currentURL == result.url }?.navigationState.faviconImage
                let reference = pixels.flatMap { BrowserHistoryFavicon.reference(png: $0.png) } ?? result.faviconReference
                return BrowserPaletteResult(id: result.id, title: result.title, detail: result.detail,
                    section: result.section, action: result.action, searchAliases: result.searchAliases,
                    sourceURL: result.sourceURL, scopePriority: result.scopePriority, faviconReference: reference, shortcut: result.shortcut)
            }
            controller.inputHistory = history
            controller.suggestionProvider = { [weak controller] query in
                guard let controller else { return [] }
                return (try? await controller.historyObserver.suggestions(for: space.profileID, query: query)) ?? []
            }
        }
        controller.sourceSpaceBadge.image = (SpaceIconImages.view(settings.document.space(space.id).iconSelection, pointSize: 13) as? NSImageView)?.image
        if startLoading { controller.load(url) }
        if url == nil { await controller.prepareCompactPresentation() }
        return controller
    }

    func registerQuickWindow(spaceID: SpaceID, profileID: ProfileID, spaceName: String) -> BrowserQuickWindowWindowController<Engine> {
        let controller = BrowserQuickWindowWindowController(engine: engine, spaceID: spaceID,
            profileID: profileID, spaceName: spaceName, rescue: rescue,
            searchEngine: settings.document.profile(profileID).searchEngine, history: historyRecorder)
        controller.siteControls.policy.store = permissions
        controller.siteControls.preferences = sitePreferences
        controller.siteControls.permissionsUnavailable = permissionsUnavailable
        controller.applyPreferences(searchEngine: settings.document.profile(profileID).searchEngine,
            theme: spaceTheme(for: spaceID))
        if let previous = quickWindows.values.max(by: { $0.openedAt < $1.openedAt })?.window {
            _ = controller.window?.cascadeTopLeft(from: NSPoint(x: previous.frame.minX + OrbitTokens.Metrics.QuickWindow.cascadeOffset,
                                                              y: previous.frame.maxY - OrbitTokens.Metrics.QuickWindow.cascadeOffset))
        }
        quickWindows[controller.id] = controller
        controller.onArchive = { [weak self, weak controller] surface in
            guard let self, let controller else { return }
            captureQuickWindowForReopening(controller, surface: surface)
            scheduleQuickWindowArchiveSave()
        }
        controller.onClose = { [weak self, weak controller] in
            guard let controller else { return }
            self?.downloads.sourceWindowClosed(controller.id)
            self?.quickWindows[controller.id] = nil
        }
        controller.onDownload = { [weak self, weak controller] surface, download in
            guard let self, let controller else { download.cancel(); return }
            _ = downloads.adopt(download, owner: .init(profileID: surface.profileID, sourceWindowID: controller.id), sourceWindow: controller.window)
        }
        return controller
    }

    func retireQuickWindows() {
        for controller in Array(quickWindows.values) { controller.retire(); controller.window?.close() }
    }
}
