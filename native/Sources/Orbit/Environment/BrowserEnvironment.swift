import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation

enum BrowserTerminationPreparationError: Error, Equatable { case commandsDidNotSettle, systemConfirmationPending, themeCommitFailed }

enum BrowserRescueSplitState: Equatable {
    case waitingForMembers, waitingForWindow, adopting, adoptionRejected
}

/// Application-wide state shared by every window of one engine: the model store, session
/// persistence, the engine and its profiles, and downloads. Engine-independent.
@MainActor
final class BrowserEnvironment<Engine: BrowserEngine> {
    typealias WindowController = BrowserWindowController<Engine>
    let engine: Engine
    var isPrivate = false
    var quickWindows: [WindowID: BrowserQuickWindowWindowController<Engine>] = [:]
    var lastUsedSpaceID: SpaceID?
    var onQuickWindowDestinationChange: (() -> Void)?
    let store: BrowserStore
    let translationPages = BrowserTranslationPages()
    let themeEditors = OrbitThemeEditorRegistry()
    private var catalogObservation: Task<Void, Never>?
    private(set) var restoredWindowIDs: [WindowID]
    var pendingQuickWindowArchives: [TabID: BrowserArchivedTab] = [:]
    var quickWindowArchiveSave: Task<Void, Never>?
    var lastRecordedWindowActivity: (WindowID, SpaceID)?
    var windowActivitySave: Task<Void, Never>?
    var onPersistenceError: ((any Error) -> Void)?
    var onPersistenceSuccess: (() -> Void)?
    var onHistoryIssue: ((ProfileID, BrowserHistoryIssue?) -> Void)?
    var historyIssues: [ProfileID: BrowserHistoryIssue] { history.issues }

    let initialContext: Task<(SpaceID, ProfileID), Error>
    private let persistence: BrowserSessionPersistence?
    private var saveTask: Task<Void, Never>?
    private(set) var isFinalizing = false
    private let restoredSpaces: [UUID: SpaceID]
    private var retiringSessions: [ObjectIdentifier: BrowserWindowSession<Engine.Surface>] = [:]
    private var controllers: [UUID: WeakController] = [:]
    private(set) var publishedCatalog: BrowserCatalogSnapshot?
    private var archiveRuntime: BrowserArchiveRuntime<Engine.Surface>?
    var autoArchive: BrowserArchiveRuntime<Engine.Surface> {
        if let archiveRuntime { return archiveRuntime }
        let runtime = BrowserArchiveRuntime<Engine.Surface>(store: store, onMutation: { [weak self] in self?.scheduleSave() })
        archiveRuntime = runtime
        return runtime
    }
    private(set) var downloads = BrowserDownloadsController()
    /// Last-resort owner of live documents whose move failed while neither the receiver nor the
    /// source could take them back; `rehomeRescuedSurfaces` gives each a window of its profile.
    let rescue: BrowserSurfaceContainer<Engine.Surface>
    /// Asks the application for a new window showing a Space of the profile, for a rescued document.
    var onRescueNeedsWindow: ((ProfileID) -> Void)?
    var onRescueSplitNeedsWindow: ((ProfileID, SpaceID) -> Void)?
    private(set) var rescueSplitStates: [SplitGroupID: BrowserRescueSplitState] = [:]
    private var rescueSplitWindowRequests: Set<SpaceID> = []
    private var rescueRehomeTask: Task<Void, Never>?
    private var rescueRehomeRequested = false
    private var isPreparingRescueForTermination = false
    private var rescueWindowRequests: Set<ProfileID> = []
    var shortcutPreferences = BrowserShortcutPreferences()
    var settings = BrowserSettingsRuntime(store: try! BrowserSettingsStore())
    var boosts = BrowserBoostsRuntime()
    let sync = BrowserSyncRuntime()
    var lastBoostsEnabled = true
    private var history = BrowserHistoryRecorder()
    var favoriteIcons: FavoriteIconStore?
    let sidebarIconMemory = SidebarIconMemoryCache()
    /// The explicit session destination; nil for temporary sessions (no import target).
    private(set) var sessionFile: URL?
    private var dataDirectoryLock: OrbitDataDirectoryLock?
    var historyRecorder: BrowserHistoryRecorder { history }
    var permissions = BrowserSitePermissionStore.ephemeral()
    var sitePreferences = try! BrowserSitePreferenceStore()
    private(set) var permissionsUnavailable = false

    /// Tests and explicitly temporary sessions never access a default file.
    private var profileRemovalJournal = try! BrowserProfileRemovalStore()
    var settingsProfileRemovals: BrowserProfileRemovalStore { profileRemovalJournal }
    var settingsRemovalIsRunning = false

    convenience init(engine: Engine, history: BrowserHistoryRecorder? = nil,
                     permissions: BrowserSitePermissionStore? = nil) {
        self.init(engine: engine, store: BrowserStore(), document: nil, persistence: nil)
        if let history { self.history = history }
        if let permissions { self.permissions = permissions }
    }

    static func open(engine: Engine, sessionFile: URL?) async throws -> BrowserEnvironment {
        guard let sessionFile else { return BrowserEnvironment(engine: engine) }
        // Shared for the whole lifetime: an offline Orbit import or restore (exclusive) cannot write
        // this session while Orbit uses it, and Orbit does not open it during one. A restore
        // interrupted mid-swap is rolled back first.
        BrowserPerformance.mark(.environment)
        let location = ArcImportDataLocation(sessionFile: sessionFile)
        try ArcImportBackups.recoverInterruptedRestore(at: location)
        let lock = try OrbitDataDirectoryLock.acquire(location.dataDirectory, exclusive: false, validatingPath: false)
        let persistence = BrowserSessionPersistence(destination: sessionFile)
        BrowserPerformance.mark(.sessionRead)
        let document = try await persistence.load()
        BrowserPerformance.mark(.sessionDecoded)
        let store = try document.map { try BrowserStore(restoring: $0) } ?? BrowserStore()
        BrowserPerformance.mark(.modelRestored)
        let removals = try BrowserProfileRemovalStore(destination: sessionFile.appendingPathExtension("profile-removals.json"))
        let pendingRemovals = await removals.pending()
        // Quarantine durable intents before initialContext or restored windows can use a profile.
        for removal in pendingRemovals { await store.recoverSettingsProfileRemoval(removal.profileID) }
        // Space themes import bridge: imported Orbit appearances become Space themes once, before any window.
        let migratesThemes = await migrateImportedSpaceThemes(store: store, location: location)
        BrowserPerformance.mark(.themesLoaded)
        let effectiveDocument = pendingRemovals.isEmpty && !migratesThemes ? document : await store.sessionDocument()
        let environment = BrowserEnvironment(engine: engine, store: store, document: effectiveDocument, persistence: persistence)
        BrowserPerformance.mark(.environmentCreated)
        do {
            let history = try BrowserDownloadHistoryStore(destination: sessionFile.appendingPathExtension("downloads.json"))
            environment.downloads = BrowserDownloadsController(history: history)
        } catch {
            // Keep the session usable and leave unreadable/future history untouched.
            environment.onPersistenceError?(error)
        }
        environment.downloads.onHistoryError = { [weak environment] in environment?.onPersistenceError?($0) }
        environment.profileRemovalJournal = removals
        do {
            environment.settings = BrowserSettingsRuntime(store: try BrowserSettingsStore(destination: sessionFile.appendingPathExtension("settings.json")))
        } catch {
            // Settings damage never discards a healthy tab session or overwrites a future schema.
            environment.settings = BrowserSettingsRuntime(store: BrowserSettingsStore.unavailable())
        }
        environment.settings.onChange = { [weak environment] in environment?.settingsDidChange() }
        await environment.settings.refresh()
        BrowserPerformance.mark(.settingsLoaded)
        let activity = environment.settings.document
        if let active = activity.lastActiveWindowID, environment.restoredWindowIDs.contains(active) {
            environment.restoredWindowIDs.removeAll { $0 == active }
            environment.restoredWindowIDs.append(active)
        }
        if let lastSpace = activity.lastActiveSpaceID,
           await store.catalogSnapshot().spaces.contains(where: { $0.id == lastSpace }) {
            environment.lastUsedSpaceID = lastSpace
        }
        environment.shortcutPreferences = BrowserShortcutPreferences(destination: sessionFile.appendingPathExtension("shortcuts.json"))
        environment.sessionFile = sessionFile
        environment.boosts = BrowserBoostsRuntime(directory: sessionFile.deletingLastPathComponent()
            .appendingPathComponent("Boosts", isDirectory: true),
            hostOverride: Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true
                && ProcessInfo.processInfo.environment["ORBIT_SYNTHETIC_BOOST_HOST"] == "1" ? BrowserFakeBoostHost() : nil)
        environment.favoriteIcons = FavoriteIconStore(directory: sessionFile.deletingLastPathComponent()
            .appendingPathComponent("Favorite Icons", isDirectory: true))
        BrowserPerformance.mark(.iconPreload)
        if let effectiveDocument, let icons = environment.favoriteIcons {
            await environment.sidebarIconMemory.preload(document: effectiveDocument, store: icons)
        }
        BrowserPerformance.mark(.iconsLoaded)
        environment.dataDirectoryLock = lock
        environment.history = BrowserHistoryRecorder(directory: sessionFile.deletingLastPathComponent().appendingPathComponent("History", isDirectory: true), resolveProfile: engine.profile(for:))
        environment.history.onIssue = { [weak environment] profileID, issue in environment?.onHistoryIssue?(profileID, issue) }
        do {
            environment.sitePreferences = try BrowserSitePreferenceStore(destination: sessionFile.appendingPathExtension("site-preferences.json"))
        } catch {
            environment.sitePreferences = try BrowserSitePreferenceStore(writable: false)
        }
        do {
            environment.permissions = try BrowserSitePermissionStore(destination: sessionFile.appendingPathExtension("site-permissions.json"))
        } catch {
            // Keep a healthy tab session independent of damaged or inaccessible permissions.
            environment.permissions = BrowserSitePermissionStore.unavailable()
            environment.permissionsUnavailable = true
        }
        // Failure remains a visible, retryable cleanup job; it never resurrects the retired model.
        if !pendingRemovals.isEmpty { try? await environment.retrySettingsProfileRemovals() }
        environment.lastBoostsEnabled = environment.settings.document.enablesBoostsOnWebsites
        BrowserPerformance.mark(.profilesBegin)
        if environment.boosts.hostOverride != nil || engine.capabilities.contains(.boosts) {
            _ = try await environment.initialContext.value
            for profile in await store.catalogSnapshot().profiles {
                do {
                    try await environment.boosts.synchronize(profileID: profile.id,
                        enabled: environment.settings.document.enablesBoostsOnWebsites, engine: engine)
                } catch { environment.onPersistenceError?(error) }
            }
        }
        BrowserPerformance.mark(.profilesReady)
        do { try environment.sync.configure(environment, destination: sessionFile.appendingPathExtension("sync.json")) }
        catch { environment.onPersistenceError?(error) }
        if migratesThemes { environment.scheduleSave() }
        return environment
    }

    private init(engine: Engine, store: BrowserStore, document: BrowserSessionDocument?,
                 persistence: BrowserSessionPersistence?) {
        self.engine = engine
        self.store = store
        self.persistence = persistence
        rescue = BrowserSurfaceContainer()
        restoredWindowIDs = document?.windows.map(\.id) ?? []
        lastUsedSpaceID = document?.windows.last?.activeSpaceID
        restoredSpaces = Dictionary(uniqueKeysWithValues: document?.windows.map { ($0.id.rawValue, $0.activeSpaceID) } ?? [])
        let existingSpace = document?.spaces.first
        initialContext = Task {
            if let existingSpace { return (existingSpace.id, existingSpace.profileID) }
            let profileID = await store.createProfile(name: uiText("Personal"))
            let spaceID = try await store.createSpace(name: uiText("Personal"), profileID: profileID)
            return (spaceID, profileID)
        }
        catalogObservation = Task { [weak self, store] in
            let changes = await store.organizationChanges()
            // Include mutations made while subscribing, even before any browser window exists.
            self?.catalogDidChange(await store.catalogSnapshot())
            for await _ in changes {
                guard !Task.isCancelled else { return }
                self?.catalogDidChange(await store.catalogSnapshot())
            }
        }
        settings.onChange = { [weak self] in self?.settingsDidChange() }
        rescue.onRescue = { [weak self] _ in self?.rehomeRescuedSurfaces() }
        rescue.onRescueReadinessChange = { [weak self] in self?.rehomeRescuedSurfaces() }
    }

    deinit { catalogObservation?.cancel() }

    func makeWindow(
        id: UUID = UUID(),
        spaceID requestedSpaceID: SpaceID? = nil,
        opensInitialTab: Bool = true,
        standalone: Bool = false,
        onInput: ((@escaping @MainActor (WindowController) -> Void) -> Void)? = nil,
        onClose: @escaping () -> Void = {},
        onActivate: @escaping () -> Void = {}
    ) async throws -> WindowController {
        BrowserPerformance.mark(.windowBegin)
        var restoredID = restoredWindowIDs.first { $0.rawValue == id }
        if standalone, restoredID == nil, let home = requestedSpaceID {
            let context = await store.catalogSnapshot()
            guard let profile = context.spaces.first(where: { $0.id == home })?.profileID else { throw BrowserStoreError.spaceMissing }
            restoredID = try await store.createStandaloneWindow(profileID: profile, homeSpaceID: home)
        }
        let spaceID: SpaceID
        if let restoredID {
            let context = try await store.captureContext(in: restoredID)
            spaceID = context.spaceID
        } else if let requestedSpaceID {
            let document = await store.sessionDocument()
            guard let space = document.spaces.first(where: { $0.id == requestedSpaceID }) else {
                throw BrowserStoreError.spaceMissing
            }
            spaceID = space.id
        } else {
            let initial = try await initialContext.value.0
            let available = await store.catalogSnapshot().spaces
            guard let current = available.first(where: { $0.id == lastUsedSpaceID })
                ?? available.first(where: { $0.id == initial }) ?? available.first else { throw BrowserStoreError.spaceMissing }
            spaceID = current.id
        }
        let isSplitRescueWindow = rescueSplitWindowRequests.contains(spaceID)
            && rescue.readySplitRescues.contains { $0.spaceID == spaceID }
        let controller = WindowController(
            id: id, store: store, spaceID: spaceID, engine: engine,
            restoringWindowID: restoredID, opensInitialTab: opensInitialTab && !isSplitRescueWindow, savesSessionLocally: persistence != nil,
            isPrivateWindow: isPrivate,
            downloads: downloads, history: history, translationPages: translationPages, rescue: rescue,
            onInput: onInput,
            onCatalogChange: { [weak self] catalog in self?.catalogDidChange(catalog) },
            onStateChange: { [weak self] in
                if let controller = self?.controllers[id]?.controller, controller.window?.isKeyWindow == true {
                    self?.recordActiveWindow(controller)
                }
                self?.onQuickWindowDestinationChange?()
                self?.scheduleSave()
            },
            onRetire: { [weak self] session in self?.trackRetirement(session) },
            onClose: { [weak self] in
                self?.controllers[id] = nil
                onClose()
                self?.onQuickWindowDestinationChange?()
            }, onActivate: { [weak self] in
                if let controller = self?.controllers[id]?.controller {
                    self?.recordActiveWindow(controller)
                }
                onActivate()
                self?.onQuickWindowDestinationChange?()
            }
        )
        BrowserPerformance.mark(.windowBuilt)
        if let restoredID {
            let placement = await store.sessionDocument().windows.first { $0.id == restoredID }?.placement
            controller.restoreWindowPlacement(placement)
        }
        BrowserPerformance.mark(.windowPlacementReady)
        controller.onMoveSpaceToProfile = { [weak self] id, target, source in
            try await self?.moveSpaceToProfile(id, to: target, expectedProfileID: source)
        }
        controller.onCreateSpaceProfile = { [weak self] name in
            guard let self, !isFinalizing, !settingsRemovalIsRunning else { throw CancellationError() }
            return try await store.createSettingsProfile(name: name)
        }
        controller.onDeleteSpace = { [weak self] id, profile in try await self?.removeSpaceFromSettings(id, expectedProfileID: profile) }
        controller.themeEditors = themeEditors
        controller.settingsPreferences = BrowserWindowSettings(runtime: settings)
        controller.boostsRuntime = boosts
        controller.sidebar.resolveSpaceIcon = { [weak settings] id in
            settings?.document.space(id).iconSelection ?? .none
        }
        controller.favorites.icons.store = favoriteIcons
        controller.favorites.icons.memoryCache = sidebarIconMemory
        controller.sidebarIcons.store = favoriteIcons
        controller.sidebarIcons.memoryCache = sidebarIconMemory
        controller.sidebar.previewIcon = { [weak self] profile, home in
            self?.sidebarIconMemory.image(profile: profile, home: home)
        }
        controller.siteControls.policy.store = permissions
        controller.siteControls.preferences = sitePreferences
        controller.siteControls.onPreferencesChange = { [weak self] in
            guard let self else { return }
            for controller in liveControllers { controller.renderDeveloperToolbar() }
        }
        controller.siteControls.permissionsUnavailable = permissionsUnavailable
        controllers[id] = WeakController(controller)
        await controller.session.waitForPendingCommands()
        BrowserPerformance.mark(.windowSessionReady)
        guard controller.session.snapshot != nil else {
            controller.window?.close()
            throw PreviewEnvironmentError.windowInitializationFailed
        }
        controller.settingsPreferences?.apply(to: controller)
        controller.renderChrome()
        controller.settingsPreferences?.renderIcons(in: controller)
        controller.archive.collectProtection = { [weak self] in await self?.autoArchive.protectedTabs(forClearToday: true) ?? [] }
        autoArchive.register(controller.session)
        autoArchive.scheduler.start()
        if let profileID = controller.session.activeProfileID { rescueWindowRequests.remove(profileID) }
        if let spaceID = controller.session.snapshot?.activeSpaceID { rescueSplitWindowRequests.remove(spaceID) }
        if !rescue.surfaces.isEmpty { rehomeRescuedSurfaces() }
        BrowserPerformance.mark(.windowReady)
        return controller
    }

    var liveControllers: [WindowController] { controllers.values.compactMap(\.controller) }

    /// Moves rescued documents into a window of their profile, asking for one when none exists.
    /// A move that fails again returns the document to the rescue holder; nothing is disposed.
    func rehomeRescuedSurfaces() {
        guard !isFinalizing, !isPreparingRescueForTermination else { return }
        for surface in rescue.surfaces where !rescue.isGroupedRescue(surface) {
            let target = liveControllers.first {
                $0.acceptsCommands && !$0.session.isClosed && $0.session.activeProfileID == surface.profileID
            }
            guard let target else {
                if rescueWindowRequests.insert(surface.profileID).inserted { onRescueNeedsWindow?(surface.profileID) }
                continue
            }
            guard let transfer = rescue.release(surface, profileID: surface.profileID) else { continue }
            _ = target.acceptSurface(transfer, activate: true)
        }
        for id in rescue.groupedRescueIDs where rescueSplitStates[id] == nil {
            rescueSplitStates[id] = .waitingForMembers
        }
        guard rescueRehomeTask == nil else { rescueRehomeRequested = true; return }
        rescueRehomeTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                rescueRehomeRequested = false
                await rehomeRescuedSplits()
            } while rescueRehomeRequested && !isFinalizing
            rescueRehomeTask = nil
        }
    }

    /// Wait for in-flight members. Once settled, incomplete or changed groups become independent
    /// rescued tabs; obsolete metadata must never prevent a document from finding a home.
    private func rehomeRescuedSplits() async {
        let groups = rescue.settledSplitRescues
        guard !groups.isEmpty, !isFinalizing else { return }
        let document = await store.sessionDocument()
        guard !isFinalizing else { return }
        for rescued in groups {
            guard rescue.settledSplitRescues.contains(where: {
                $0.group.id == rescued.group.id && zip($0.surfaces, rescued.surfaces).allSatisfy { $0 === $1 }
            }) else { continue }
            guard rescued.surfaces.count == rescued.group.tabIDs.count,
                  rescueSplitStates[rescued.group.id] != .adoptionRejected,
                  document.spaces.contains(where: { $0.id == rescued.spaceID && $0.profileID == rescued.profileID }),
                  document.organization.splits.first(where: { $0.id == rescued.group.id }) == rescued.group,
                  splitIsPresent(rescued.group.id, in: rescued.spaceID, document: document.organization) else {
                if rescue.dissolveSplitRescue(rescued) {
                    rescueSplitStates[rescued.group.id] = nil
                    rehomeRescuedSurfaces()
                }
                continue
            }
            let target = liveControllers.first {
                $0.acceptsCommands && !$0.session.isClosed && $0.session.activeProfileID == rescued.profileID
                    && $0.session.snapshot?.activeSpaceID == rescued.spaceID
            }
            guard let target else {
                rescueSplitStates[rescued.group.id] = .waitingForWindow
                if rescueSplitWindowRequests.insert(rescued.spaceID).inserted {
                    onRescueSplitNeedsWindow?(rescued.profileID, rescued.spaceID)
                }
                continue
            }
            guard let transfers = rescue.releaseSplit(rescued) else { continue }
            rescueSplitStates[rescued.group.id] = .adopting
            let adoption = target.session.acceptSplitGroupTransfers(transfers, group: rescued.group,
                activating: rescued.group.tabIDs.first, bind: { [weak target] in target?.bindSurface($0) })
            for (index, surface) in rescued.surfaces.enumerated() {
                let member = Task<TabOccurrenceID?, Never> {
                    guard let ids = await adoption.value, ids.indices.contains(index) else { return nil }
                    return ids[index]
                }
                target.reconcileTransferredSurface(surface, after: member)
            }
            Task { [weak self] in
                _ = await adoption.value
                guard let self else { return }
                rescueSplitStates[rescued.group.id] = transfers.allSatisfy { $0.state == .completed } ? nil : .adoptionRejected
                if rescueSplitStates[rescued.group.id] == .adoptionRejected { rehomeRescuedSurfaces() }
            }
        }
    }

    private func splitIsPresent(_ id: SplitGroupID, in spaceID: SpaceID, document: BrowserOrganizationDocument) -> Bool {
        guard let section = document.spaces.first(where: { $0.spaceID == spaceID }) else { return false }
        let folders = Dictionary(uniqueKeysWithValues: document.folders.map { ($0.id, $0.children) })
        var nodes = section.pinned + section.today
        var visited: Set<FolderID> = []
        while let node = nodes.popLast() {
            if node == .split(id) { return true }
            if let folderID = node.folderID, visited.insert(folderID).inserted {
                nodes.append(contentsOf: folders[folderID] ?? [])
            }
        }
        return false
    }

    // MARK: Termination (see BrowserTermination)

    /// Step 1, with commands frozen and before saving: lets live moves settle so the saved model
    /// holds each document exactly once. Bounded.
    func settleTransfers(timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now + timeout
        _ = await BrowserTermination.withDeadline(timeout) { [self] in await rescueRehomeTask?.value }
        _ = await BrowserTermination.settleTransfers(in: liveControllers.map(\.session),
            timeout: max(.zero, ContinuousClock.now.duration(to: deadline)))
    }

    /// Drains accepted commands and final destination updates before the durable snapshot.
    /// Production Quit has no deadline for accepted mutations; tests can bound a stalled queue.
    func prepareToSaveForTermination(timeout: Duration? = .seconds(2)) async throws {
        isPreparingRescueForTermination = true
        defer { isPreparingRescueForTermination = false }
        let deadline = timeout.map { ContinuousClock.now + $0 }
        func remaining() -> Duration? { deadline.map { max(.zero, ContinuousClock.now.duration(to: $0)) } }
        let controllers = liveControllers
        for little in quickWindows.values { little.freezeForTermination() }
        let sessions = controllers.compactMap(\.session) + Array(retiringSessions.values)
        for controller in controllers { controller.freezeCommandsForTermination() }
        do {
            while settingsRemovalIsRunning {
                guard deadline.map({ ContinuousClock.now < $0 }) ?? true else { throw BrowserTerminationPreparationError.commandsDidNotSettle }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard await BrowserTermination.withDeadline(remaining(), { [self] in await rescueRehomeTask?.value }),
                  await BrowserTermination.settleTransfers(in: sessions, timeout: remaining()) else {
                throw BrowserTerminationPreparationError.commandsDidNotSettle
            }
            // Browser inputs accepted before the freeze may still route native theme Undo/Redo.
            // Drain those decisions before freezing the native manager; the editor barrier then
            // drains the asynchronous theme writes they reserved.
            var themesCommitted = false
            guard await BrowserTermination.withDeadline(remaining(), { [self] in
                themesCommitted = await themeEditors.finishAll()
            }) else { throw BrowserTerminationPreparationError.commandsDidNotSettle }
            guard themesCommitted else { throw BrowserTerminationPreparationError.themeCommitFailed }
            // No live transfer remains. Preserve an intact group's identities on Quit; degraded
            // survivors become standalone, reusing unowned identities rather than duplicating them.
            for surface in rescue.surfaces { surface.stopLoading() }
            var preserved: Set<ObjectIdentifier> = []
            var claimedTabs: Set<TabID> = []
            for group in rescue.settledSplitRescues {
                let urls = Dictionary(uniqueKeysWithValues: zip(group.group.tabIDs, group.surfaces).map {
                    ($0.0, $0.1.currentURL ?? URL(string: "about:blank")!)
                })
                if group.surfaces.count == group.group.tabIDs.count, claimedTabs.isDisjoint(with: group.group.tabIDs),
                   try await store.preserveRescuedSplit(group.group, spaceID: group.spaceID,
                                                       profileID: group.profileID, urls: urls) {
                    preserved.formUnion(group.surfaces.map(ObjectIdentifier.init))
                    claimedTabs.formUnion(group.group.tabIDs)
                    continue
                }
                _ = rescue.dissolveSplitRescue(group)
                rescueSplitStates[group.group.id] = nil
            }
            guard rescue.surfaces.allSatisfy({ !rescue.isGroupedRescue($0) || preserved.contains(ObjectIdentifier($0)) }) else {
                throw BrowserTerminationPreparationError.commandsDidNotSettle
            }
            for surface in rescue.surfaces where !preserved.contains(ObjectIdentifier(surface)) {
                let original = rescue.rescuedTabID(for: surface).flatMap { claimedTabs.contains($0) ? nil : $0 }
                let id = try await store.preserveRescuedTab(url: surface.currentURL ?? URL(string: "about:blank")!,
                    profileID: surface.profileID, existingTabID: original,
                    standalone: rescue.isStandaloneRescue(surface))
                claimedTabs.insert(id)
                rescue.recordRescuedTab(id, for: surface)
            }
            for little in quickWindows.values {
                if let surface = little.surface, little.owns(surface) { captureQuickWindowForReopening(little, surface: surface) }
            }
            try await flushQuickWindowArchives()
            for controller in controllers { controller.prepareForTermination() }
            guard await BrowserTermination.settleTransfers(in: sessions, timeout: remaining()) else {
                throw BrowserTerminationPreparationError.commandsDidNotSettle
            }
        } catch {
            for controller in controllers { controller.cancelTerminationPreparation() }
            terminationDidCancel()
            throw error
        }
    }

    /// Both preparation failures and final-save failures can abandon a window request. Retry
    /// after the application has thawed its controllers, keeping the exact live documents.
    func terminationDidCancel() {
        themeEditors.thaw()
        for little in quickWindows.values { little.cancelTerminationPreparation() }
        rescueWindowRequests.removeAll()
        rescueSplitWindowRequests.removeAll()
        for surface in rescue.surfaces { surface.cancelStoppedNavigationTracking() }
        Task { [weak self] in await Task.yield(); self?.rehomeRescuedSurfaces() }
    }

    /// Step 3, after `finalize()` succeeded: releases every live document without mutating the
    /// saved session (sessions retire with their model preserved), cancels downloads, then awaits
    /// the engine's native teardown within `timeout`. The caller quits whatever the outcome.
    func shutDown(timeout: Duration = .seconds(5)) async -> BrowserTermination.Outcome {
        let controllers = liveControllers
        retireQuickWindows()
        for controller in controllers { controller.retireForTermination() }
        translationPages.close()
        downloads.shutdown()
        let engine = engine
        return await BrowserTermination.detachAndShutDown(
            sessions: controllers.map(\.session), containers: [rescue], timeout: timeout
        ) { await engine.shutdown() }
    }

    private func catalogDidChange(_ catalog: BrowserCatalogSnapshot) {
        guard catalog != publishedCatalog else { return }
        let previousOwners = Dictionary(uniqueKeysWithValues: (publishedCatalog?.spaces ?? []).map { ($0.id, $0.profileID) })
        let profileMoved = catalog.spaces.contains { space in
            previousOwners[space.id].map { $0 != space.profileID } == true
        }
        publishedCatalog = catalog
        if let lastUsedSpaceID, !catalog.spaces.contains(where: { $0.id == lastUsedSpaceID }) {
            self.lastUsedSpaceID = nil
        }
        controllers = controllers.filter { $0.value.controller != nil }
        for entry in controllers.values {
            if profileMoved { entry.controller?.session.refreshAfterSpaceProfileMove() }
            else { entry.controller?.session.refreshCatalog() }
        }
        refreshQuickWindowThemes()
    }

    func restoredSpace(for id: UUID?) -> SpaceID? {
        id.flatMap { restoredSpaces[$0] }
    }

    private func trackRetirement(_ session: BrowserWindowSession<Engine.Surface>) {
        let key = ObjectIdentifier(session)
        retiringSessions[key] = session
        Task { [weak self] in
            await session.waitForPendingCommands()
            self?.retiringSessions.removeValue(forKey: key)
            self?.scheduleSave()
        }
    }

    private func waitForRetirements() async {
        while !retiringSessions.isEmpty {
            for (key, session) in retiringSessions {
                await session.waitForPendingCommands()
                retiringSessions.removeValue(forKey: key)
            }
        }
    }

    // Narrow Settings accessors keep ownership of history and permissions private.
    func settingsPermissionOrigins(profile: ProfileID) async -> [BrowserSiteOrigin] {
        await permissions.configuredOrigins(profileID: profile)
    }
    func settingsPermissions(origin: BrowserSiteOrigin, profile: ProfileID) async -> [BrowserSitePermission: BrowserSitePermissionSetting] {
        await permissions.snapshot(origin: origin, profileID: profile)
    }
    func persistSettingsPermission(_ setting: BrowserSitePermissionSetting, permission: BrowserSitePermission,
                                   origin: BrowserSiteOrigin, profile: ProfileID) async throws {
        try await permissions.set(setting, for: [permission], origin: origin, profileID: profile)
    }
    func removeSettingsPermissions(profile: ProfileID) async throws {
        try await boosts.removeProfile(profile, engine: engine)
        try await permissions.clear(profileID: profile)
        try sitePreferences.clear(profileID: profile)
    }
    func removeSettingsHistory(profile: ProfileID) async throws { try await history.removeProfileHistory(for: profile) }
    func cancelSettingsHistoryRemoval(profile: ProfileID) { history.cancelProfileRemoval(for: profile) }
    func persistSettingsRemovalSession() async throws {
        guard !isFinalizing else { throw BrowserTerminationPreparationError.commandsDidNotSettle }
        guard let persistence else { return }
        guard case .saved = try await persistence.saveCurrentState(from: store) else {
            throw BrowserTerminationPreparationError.commandsDidNotSettle
        }
    }

    private func captureWindowPlacements() async {
        guard persistence != nil else { return }
        let placements = Dictionary(uniqueKeysWithValues: liveControllers.compactMap { controller -> (WindowID, BrowserWindowPlacement)? in
            guard let id = controller.session.snapshot?.id, let placement = controller.windowPlacement else { return nil }
            return (id, placement)
        })
        await store.updateWindowPlacements(placements)
    }

    func scheduleSave() {
        guard persistence != nil, !isFinalizing else { return }
        BrowserPerformance.count(.savesScheduled)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self, !isFinalizing, let persistence else { return }
                await captureWindowPlacements()
                let result = try await persistence.saveCurrentState(from: store)
                if case .saved = result { onPersistenceSuccess?() }
            } catch is CancellationError {
                // A newer mutation or termination owns the next save.
            } catch {
                guard let self, !Task.isCancelled else { return }
                onPersistenceError?(error)
            }
        }
    }

    /// Saves now and returns once the current model is durably written (used by the Orbit import,
    /// which records its ledger only after the merged session is on disk).
    func saveNow() async throws {
        guard let persistence, !isFinalizing else { throw BrowserSessionPersistence.PersistenceError.finalizationInProgress }
        await captureWindowPlacements()
        for _ in 0..<5 {
            switch try await persistence.saveCurrentState(from: store) {
            case .saved: return
            case .superseded: continue
            case .stopped: throw BrowserSessionPersistence.PersistenceError.finalizationInProgress
            }
        }
        throw BrowserSessionPersistence.PersistenceError.loadInProgress
    }

    /// Call only after the windows have stopped publishing and their command queues are drained.
    func finalize() async throws {
        guard !settingsRemovalIsRunning else { throw BrowserTerminationPreparationError.commandsDidNotSettle }
        autoArchive.scheduler.stop()
        isFinalizing = true
        await sync.prepareForTermination()
        saveTask?.cancel()
        await saveTask?.value
        await waitForRetirements()
        await windowActivitySave?.value
        await settings.flushExtensionPinOrders()
        await history.flush()
        do {
            for controller in liveControllers { await controller.session.waitForPendingCommands() }
            guard await themeEditors.finishAll() else { throw BrowserTerminationPreparationError.themeCommitFailed }
            try await flushQuickWindowArchives()
            await captureWindowPlacements()
            if let persistence { try await persistence.finalize(from: store) }
        } catch {
            autoArchive.scheduler.start()
            themeEditors.thaw()
            isFinalizing = false
            sync.resumeAfterCancelledTermination()
            throw error
        }
        // Final save done: offline imports may use the session from now on.
        dataDirectoryLock?.release()
        dataDirectoryLock = nil
    }

    private final class WeakController {
        weak var controller: WindowController?
        init(_ controller: WindowController) { self.controller = controller }
    }
}
