import BrowserCore
import Foundation

/// The reserved input was not replayed after repeated atomic candidate mismatches.
public enum BrowserOrganizationReplayError: Error, Equatable, Sendable {
    case candidateChangedRepeatedly
}

/// Per-session organization state. A class, so the base session needs one stored property only.
@MainActor
final class BrowserOrganizationSessionRuntime {
    var snapshot: BrowserOrganizationSnapshot?
    var metadataIndex: BrowserOrganizationMetadataIndex?
    var catalogRevision: UInt64 = 0
    var activityRevision: UInt64 = 0
    var occurrenceIndices: [TabOccurrenceID: Int] = [:]
    var observation: Task<Void, Never>?
    var isObservationRequested = false
    var isRefreshQueued = false

    func retire() {
        observation?.cancel()
        observation = nil
        isObservationRequested = false
        metadataIndex = nil
        occurrenceIndices.removeAll()
        snapshot = nil
        isRefreshQueued = false
    }
}

/// Sidebar organization commands (Favorites, Pinned, Today, folders, archive, undo). Every command
/// joins the window's command queue, runs against the window's context at execution time and
/// installs the exact state the store returns, so `organization`, `snapshot` and live surfaces
/// change together in one publication.
public extension BrowserWindowSession {
    /// The active Space as the sidebar shows it, published with `onChange`.
    var organization: BrowserOrganizationSnapshot? { organizationRuntime.snapshot }

    func organizationTab(_ id: TabID) -> BrowserOrganizationTabItem? {
        guard let organization else { return nil }
        return organizationRuntime.metadataIndex?.tab(id, in: organization)
    }

    func observeOrganizationChanges() {
        guard !isClosed, !organizationRuntime.isObservationRequested else { return }
        organizationRuntime.isObservationRequested = true
        // Reserve setup after initial adoption, so waiting for the session also waits for its
        // subscription. A late initial refresh must not jump ahead of the next user command.
        enqueue { session in
            defer {
                if session.organizationRuntime.observation == nil {
                    session.organizationRuntime.isObservationRequested = false
                }
            }
            guard let windowID = session.windowID else { return }
            let changes = await session.store.organizationChanges(in: windowID)
            guard !session.isClosed else { return }
            try await session.refreshOrganizationState()
            guard !session.isClosed else { return }
            session.organizationRuntime.observation = Task { [weak session] in
                for await _ in changes {
                    guard let session, !session.isClosed else { return }
                    BrowserPerformance.count(.organizationDeliveries)
                    session.queueOrganizationRefresh()
                }
            }
        }
    }

    /// Inserts a refresh in command order; its completion is observable with `waitForPendingCommands`.
    func synchronizeOrganization() {
        enqueue { session in try await session.refreshOrganizationState() }
    }

    /// Creates and positions a new tab in one session command; existing rows remain untouched.
    func openTab(url: URL, at destination: BrowserOrganizationDestination) {
        enqueue { session in
            guard let initial = try await session.validatedContext() else { return }
            var created: BrowserTab?
            try await session.createTab(url: url, activate: true, from: initial, onCreate: { created = $0 })
            guard let created, let context = try await session.validatedContext() else { return }
            let state = try await session.store.moveItems([.tab(created.id)], to: destination, from: context)
            session.install(state)
        }
    }

    // MARK: Selection

    /// Clicking a sidebar tab: selects, moves (a Favorite from another Space) or loads it here.
    func selectTab(_ id: TabID, expecting expected: BrowserOrganizationSnapshot? = nil,
                   admission: BrowserSidebarSelectionAdmission? = nil,
                   isCurrent: @escaping @MainActor () -> Bool = { true }) {
        BrowserSidebarInputDiagnostics.record("session-select", tab: id, window: windowID, reason: isClosed ? "closed" : "queued")
        enqueue { session in
            do {
                guard let state = try await session.runOrganizationCommand({ session, context in
                    guard isCurrent() else {
                        BrowserSidebarInputDiagnostics.record("selection", tab: id, window: context.windowID, reason: "superseded")
                        return try await session.store.captureWindowState(in: context.windowID)
                    }
                    return try await session.selectTabState(id, from: context, expecting: expected, admission: admission)
                }), !session.isClosed else {
                    BrowserSidebarInputDiagnostics.record("selection", tab: id, window: session.windowID, reason: "context-unavailable")
                    return
                }
                session.install(state)
                let selected = session.snapshot?.selectedOccurrenceID
                let matches = selected != nil && session.tabID(for: selected!) == id
                BrowserSidebarInputDiagnostics.record("selection", tab: id, window: session.windowID,
                    reason: admission?.isValid == false ? "admission-revoked" : !matches ? "refused"
                        : session.selectedSurface == nil ? "surface-unavailable" : "selected")
            } catch {
                let reason: String
                switch error {
                case BrowserStoreError.staleContext: reason = "stale-context"
                case BrowserStoreError.occurrenceOwnedByAnotherWindow: reason = "foreign-occurrence"
                case BrowserOrganizationError.itemMissing: reason = "missing-tab"
                case BrowserOrganizationError.notVisibleInContext: reason = "not-visible"
                default: reason = "selection-error"
                }
                BrowserSidebarInputDiagnostics.record("selection", tab: id, window: session.windowID, reason: reason)
                if !session.isClosed { session.onError?(error) }
            }
        }
    }


    @discardableResult
    func moveItems(_ nodes: [BrowserOrganizationNode], to destination: BrowserOrganizationDestination) -> Task<Bool?, Never> {
        enqueueOrganizationValue { session, context in
            let state = try await session.store.moveItems(nodes, to: destination, from: context)
            return (true, state)
        }
    }

    func convertFolderToSpace(_ id: FolderID) {
        enqueueOrganization { session, context in try await session.store.convertFolderToSpace(id, from: context) }
    }

    func exportSpace(_ id: SpaceID, to destination: SpaceID) {
        enqueueOrganization { session, context in try await session.store.exportSpace(id, to: destination, from: context) }
    }

    func pinTabs(_ ids: [TabID]) {
        enqueueOrganization { session, context in try await session.store.pinTabs(ids, from: context) }
    }

    func unpinTabs(_ ids: [TabID]) {
        enqueueOrganization { session, context in try await session.store.unpinTabs(ids, from: context) }
    }

    func addToFavorites(_ ids: [TabID]) {
        enqueueOrganization { session, context in try await session.store.addToFavorites(ids, from: context) }
    }

    func removeFromFavorites(_ ids: [TabID]) {
        enqueueOrganization { session, context in try await session.store.removeFromFavorites(ids, from: context) }
    }

    /// ⌘D on the tab visible when the command runs.
    func togglePinSelectedTab() {
        enqueueOrganization { session, context in try await session.store.togglePinSelectedTab(from: context) }
    }


    /// The task resolves to the new folder, e.g. to start editing its title; nil on failure.
    @discardableResult
    func createFolder(
        title: String, at destination: BrowserOrganizationDestination,
        containing nodes: [BrowserOrganizationNode] = []
    ) -> Task<FolderID?, Never> {
        enqueueOrganizationValue { session, context in
            try await session.store.createFolder(title: title, at: destination, containing: nodes, from: context)
        }
    }

    @discardableResult
    func duplicateFolder(_ id: FolderID) -> Task<FolderID?, Never> {
        enqueueOrganizationValue { session, context in
            try await session.store.duplicateFolder(id, from: context)
        }
    }

    func renameFolder(_ id: FolderID, to title: String) {
        enqueueOrganization { session, context in try await session.store.renameFolder(id, to: title, from: context) }
    }

    func setFolderCollapsed(_ id: FolderID, _ collapsed: Bool) {
        enqueueOrganization { session, context in
            try await session.store.setFolderCollapsed(id, collapsed, from: context)
        }
    }

    func setAllFoldersCollapsed(_ collapsed: Bool) {
        enqueueOrganization { session, context in try await session.store.setAllFoldersCollapsed(collapsed, from: context) }
    }

    func setPinnedSectionCollapsed(_ collapsed: Bool) {
        enqueueOrganization { session, context in
            try await session.store.setPinnedSectionCollapsed(collapsed, from: context)
        }
    }

    func deleteFolder(_ id: FolderID, contents: BrowserFolderDeletion) {
        enqueueOrganization { session, context in
            try await session.store.deleteFolder(id, contents: contents, from: context)
        }
    }


    /// A nil or blank title restores the web title.
    func renameTab(_ id: TabID, to title: String?) {
        enqueueOrganization { session, context in try await session.store.renameTab(id, to: title, from: context) }
    }

    func changeTabIcon(_ id: TabID, to icon: BrowserSpaceIcon?) {
        enqueueOrganization { session, context in try await session.store.changeTabIcon(id, to: icon, from: context) }
    }

    func editPinnedURL(_ id: TabID, to url: URL) {
        enqueueOrganization { session, context in try await session.store.editPinnedURL(id, to: url, from: context) }
    }

    /// Records the engine's title for this exact live occurrence; unchanged titles cost no command.
    /// Late callbacks for a surface this session no longer owns are ignored: its tab may have been
    /// archived by another window.
    func updatePageTitle(for surface: Surface, to title: String?,
                         isCurrent: @escaping @MainActor () -> Bool = { true }) {
        guard !isClosed, let occurrenceID = occurrenceID(for: surface) else { return }
        let pageTitle = BrowserOrganizedTab.normalizedPageTitle(title)
        if let id = occurrenceTabIDs[occurrenceID], let item = organizationTab(id),
           item.pageTitle == pageTitle { return }
        enqueue { session in
            guard isCurrent(),
                  let occurrenceID = session.occurrenceID(for: surface),
                  let authority = session.authorities[occurrenceID] else { return }
            do {
                guard try await session.store.updatePageTitle(pageTitle, from: authority) else { return }
            } catch BrowserStoreError.staleContext, BrowserStoreError.tabMissing,
                    BrowserStoreError.occurrenceOwnedByAnotherWindow {
                return
            }
            try await session.refreshOrganizationState(allowMetadata: true)
        }
    }

    /// Returns the tab to its pinned URL; `navigate` loads it into this window's live surface.
    func resetTabToPinnedURL(_ id: TabID, navigate: @escaping @MainActor (Surface, URL) -> Void) {
        enqueue { session in
            guard let context = try await session.organizationContext() else { return }
            let (reset, state) = try await session.store.resetTabToPinnedURL(id, from: context)
            guard !session.isClosed else { return }
            session.install(state)
            session.navigate([reset], with: navigate)
        }
    }

    /// "Reset all tabs in this Space".
    func resetPinnedTabs(navigate: @escaping @MainActor (Surface, URL) -> Void) {
        enqueue { session in
            guard let context = try await session.organizationContext() else { return }
            let (resets, state) = try await session.store.resetPinnedTabs(from: context)
            guard !session.isClosed else { return }
            session.install(state)
            session.navigate(resets, with: navigate)
        }
    }


    func archiveTabs(_ ids: [TabID]) {
        enqueueOrganization { session, context in try await session.store.archiveTabs(ids, from: context) }
    }

    /// ⌘W on a multi-selection.
    func closeTabs(_ ids: [TabID]) {
        enqueueOrganization { session, context in try await session.store.closeTabs(ids, from: context) }
    }

    /// ⇧⌘K. `protecting` comes from the shell, e.g. tabs playing media.
    func clearTodayTabs(protecting: Set<TabID> = []) {
        enqueueOrganization { session, context in
            try await session.store.clearTodayTabs(protecting: protecting, from: context)
        }
    }

    func restoreArchivedTab(_ id: TabID, activate: Bool = true) {
        enqueueOrganization { session, context in
            try await session.store.restoreArchivedTab(id, activate: activate, from: context, routing: session.archiveLinkRouting())
        }
    }

    /// Archive-backed ⇧⌘T.
    func restoreMostRecentArchivedTab(preferAlternative: @escaping @MainActor (Date?) -> Bool = { _ in false }) {
        enqueueOrganization { session, context in
            let records = try await session.store.archivedTabs(from: context)
            let newest = records.first { $0.reason != .automatic }
            guard !preferAlternative(newest?.archivedAt), newest != nil else {
                return try await session.store.captureWindowState(from: context)
            }
            return try await session.store.restoreMostRecentArchivedTab(from: context, routing: session.archiveLinkRouting())
        }
    }

    func deleteArchivedTabs(_ ids: [TabID]) {
        enqueueOrganization { session, context in try await session.store.deleteArchivedTabs(ids, from: context) }
    }

    func clearArchive() {
        enqueueOrganization { session, context in try await session.store.clearArchive(from: context) }
    }

    /// A read boundary in command order, limited to this window's profile.
    func archivedTabs(matching query: String? = nil) -> Task<[BrowserArchivedTab], Never> {
        let task = enqueueOrganizationRead { session, context in
            try await session.store.archivedTabs(from: context, matching: query)
        }
        return Task { await task.value ?? [] }
    }

    // MARK: Undo (UX-UNDO)

    /// Resolves after publication with the record actually replayed (possibly past conflicts).
    /// Nil means the replay failed or the session retired; callers never have to predict success.
    @discardableResult
    func undoOrganization() -> Task<UInt64?, Never> {
        routeOrganizationReplay(undoing: true)
    }

    @discardableResult
    func redoOrganization() -> Task<UInt64?, Never> {
        routeOrganizationReplay(undoing: false)
    }

    /// Reserves the input's place immediately, then chooses organization or an external undo
    /// source after earlier session commands have published. Completion runs after install and
    /// before the next reserved input; it must not wait for this session's queue to drain.
    @discardableResult
    func routeOrganizationReplay(
        undoing: Bool,
        choosingOrganization: @escaping @MainActor () -> Bool = { true },
        completion: @escaping @MainActor (UInt64?) -> Void = { _ in }
    ) -> Task<UInt64?, Never> {
        guard !isClosed else { completion(nil); return Task { nil } }
        let diagnostic = trackCommand(kind: #function)
        let previous = pending
        pendingCommandCount += 1
        let replay = Task<UInt64?, Never> { [self] in
            defer { diagnostic.finish() }
            await previous?.value
            activeCommandDiagnostic = diagnostic
            diagnostic.step = "model-or-surface-publication"
            var replayedID: UInt64?
            defer {
                pendingCommandCount -= 1
                completion(replayedID)
            }
            guard !isClosed else { return nil }
            do {
                for _ in 0..<maximumOrganizationAdoptions {
                    // Metadata can change a candidate without changing BrowserContext. Resolve
                    // again after an atomic mismatch, keeping this input's reserved queue slot.
                    try await refreshOrganizationState()
                    let result: (BrowserWindowState?, UInt64?)? = try await runOrganizationCommand { session, context in
                        let expected = undoing ? session.organization?.undoRecordID : session.organization?.redoRecordID
                        guard choosingOrganization() else { return (nil, nil) }
                        guard let expected else {
                            throw undoing ? BrowserOrganizationError.nothingToUndo : BrowserOrganizationError.nothingToRedo
                        }
                        let state = try await undoing
                            ? session.store.undoOrganization(from: context, expectedRecordID: expected)
                            : session.store.redoOrganization(from: context, expectedRecordID: expected)
                        return (state, expected)
                    }
                    guard let (state, expected) = result, !isClosed else { return nil }
                    guard let expected else { return nil } // External source handled the input.
                    guard let state else { continue } // No mutation: refresh and resolve again.
                    install(state)
                    replayedID = expected
                    return expected
                }
                throw BrowserOrganizationReplayError.candidateChangedRepeatedly
            } catch {
                if !isClosed { onError?(error) }
                return nil
            }
        }
        pending = Task { _ = await replay.value }
        return replay
    }
}

extension BrowserWindowSession {
    func enqueueOrganization(kind: String = #function,
        _ command: @escaping @MainActor (BrowserWindowSession, BrowserContext) async throws -> BrowserWindowState
    ) {
        enqueue(kind: kind) { session in
            guard let state = try await session.runOrganizationCommand(command) else { return }
            guard !session.isClosed else { return }
            session.install(state)
        }
    }

    /// Preserve command order and profile authority without installing or saving a read.
    func enqueueOrganizationRead<Value: Sendable>(
        _ read: @escaping @MainActor (BrowserWindowSession, BrowserContext) async throws -> Value
    ) -> Task<Value?, Never> {
        guard !isClosed else { return Task { nil } }
        pendingCommandCount += 1
        let diagnostic = trackCommand(kind: #function)
        let previous = pending
        let task = Task<Value?, Never> { [self] in
            defer { pendingCommandCount -= 1 }
            defer { diagnostic.finish() }
            await previous?.value
            activeCommandDiagnostic = diagnostic
            diagnostic.step = "model-or-surface-publication"
            guard !isClosed, var context = activeContext else { return nil }
            do {
                for attempt in 0..<maximumOrganizationAdoptions {
                    do {
                        let value = try await read(self, context)
                        return isClosed ? nil : value
                    } catch BrowserStoreError.staleContext where attempt + 1 < maximumOrganizationAdoptions {
                        guard let refreshed = try await organizationContext(publish: false) else { return nil }
                        context = refreshed
                    }
                }
                return nil
            } catch {
                if !isClosed { onError?(error) }
                return nil
            }
        }
        pending = Task { _ = await task.value }
        return task
    }

    func enqueueOrganizationValue<Value: Sendable>(
        _ command: @escaping @MainActor (BrowserWindowSession, BrowserContext) async throws -> (Value, BrowserWindowState)
    ) -> Task<Value?, Never> {
        guard !isClosed else { return Task { nil } }
        pendingCommandCount += 1
        let diagnostic = trackCommand(kind: #function)
        let previous = pending
        let task = Task<Value?, Never> { [self] in
            defer { pendingCommandCount -= 1 }
            defer { diagnostic.finish() }
            await previous?.value
            activeCommandDiagnostic = diagnostic
            diagnostic.step = "model-or-surface-publication"
            guard !isClosed else { return nil }
            do {
                guard let (value, state) = try await runOrganizationCommand(command) else { return nil }
                guard !isClosed else { return nil }
                install(state)
                return value
            } catch {
                if !isClosed { onError?(error) }
                return nil
            }
        }
        pending = Task { _ = await task.value }
        return task
    }

    func runOrganizationCommand<Value>(
        _ command: (BrowserWindowSession, BrowserContext) async throws -> Value
    ) async throws -> Value? {
        var attempt = 1
        while true {
            guard let context = try await organizationContext() else { return nil }
            do {
                return try await command(self, context)
            } catch BrowserStoreError.staleContext where attempt < maximumOrganizationAdoptions {
                attempt += 1
                // `organizationContext()` installs the refreshed state on the next attempt.
                guard !isClosed, try await store.windowState(adoptingOrganizationChangesSince: context) != nil else {
                    throw BrowserStoreError.staleContext
                }
            }
        }
    }

    /// Organization commands of other windows can change this window's selection (archiving or
    /// moving its tab) without changing its Space or profile. Organization commands target stable
    /// IDs, so they first adopt such a change instead of failing as stale.
    func organizationContext(publish: Bool = true) async throws -> BrowserContext? {
        guard !isClosed, let windowID else { return nil }
        let currentContext = try await store.captureContext(in: windowID)
        guard !isClosed, let activeContext else { return nil }
        if currentContext == activeContext { return currentContext }
        let state = try await store.captureWindowState(in: windowID)
        guard state.context.storeGeneration == activeContext.storeGeneration else { throw BrowserStoreError.staleContext }
        guard canAdoptOrganizationContext(state, from: activeContext) else {
            throw BrowserWindowSessionError.contextChangeRequiresNewSession
        }
        if publish, state.context != activeContext { install(state) }
        guard !isClosed else { return nil }
        return state.context
    }

    func queueOrganizationRefresh() {
        guard !isClosed, !organizationRuntime.isRefreshQueued else { return }
        organizationRuntime.isRefreshQueued = true
        enqueue { session in
            session.organizationRuntime.isRefreshQueued = false
            try await session.refreshOrganizationState(allowMetadata: true)
        }
    }

    /// Publishes only when something visible to this window changed.
    func refreshOrganizationState(allowMetadata: Bool = false) async throws {
        BrowserPerformance.count(.organizationRefreshes)
        guard !isClosed, let windowID else { return }
        if allowMetadata, let context = activeContext, let current = organizationRuntime.snapshot,
           let delta = try await store.organizationMetadata(since: current.organizationRevision, from: context,
                                                           catalogRevision: organizationRuntime.catalogRevision) {
            guard !isClosed else { return }
            installMetadata(delta)
            return
        }
        let state = try await store.captureWindowState(in: windowID)
        guard !isClosed, let activeContext else { return }
        guard canAdoptOrganizationContext(state, from: activeContext) else { return }
        let hasRevokedSurface = surfaceOrder.contains { authorities[$0] != state.occurrenceAuthorities[$0] }
        guard state.context != activeContext || state.snapshot != snapshot || state.catalog != catalog
                || state.organization != organizationRuntime.snapshot || hasRevokedSurface else { return }
        install(state)
    }

    /// A retired Space can rehome this window within its profile. An external switch between
    /// surviving Spaces still requires explicit adoption and cannot redirect queued input.
    private func canAdoptOrganizationContext(_ state: BrowserWindowState, from previous: BrowserContext) -> Bool {
        state.context.storeGeneration == previous.storeGeneration
            && state.context.profileID == previous.profileID
            && (state.context.spaceID == previous.spaceID || !state.catalog.spaces.contains { $0.id == previous.spaceID })
    }

    func navigate(_ resets: [BrowserOrganizationReset], with navigate: @MainActor (Surface, URL) -> Void) {
        for reset in resets {
            guard !isClosed, let occurrenceID = reset.occurrenceID, let surface = surfaces[occurrenceID] else { continue }
            navigate(surface, reset.url)
        }
    }
}

extension BrowserWindowSession {
    var selectionState: BrowserWindowState? {
        guard usesScopedSelectionUpdates, let context = activeContext, let snapshot, let catalog,
              let organization else { return nil }
        return BrowserWindowState(context: context, snapshot: snapshot, catalog: catalog,
            catalogRevision: organizationRuntime.catalogRevision, activityRevision: organizationRuntime.activityRevision,
            occurrenceAuthorities: modelOccurrenceAuthorities, occurrenceTabIDs: occurrenceTabIDs, organization: organization)
    }

    func selectTabState(_ id: TabID, from context: BrowserContext,
                        expecting expected: BrowserOrganizationSnapshot? = nil,
                        admission: BrowserSidebarSelectionAdmission? = nil) async throws -> BrowserWindowState {
        try await store.selectTabUpdating(id, from: context, state: selectionState,
            index: organizationRuntime.metadataIndex, expecting: expected, admission: admission)
    }
}
