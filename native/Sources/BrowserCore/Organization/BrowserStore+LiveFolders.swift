import Foundation

extension BrowserStore {
    public func liveFolderLocalStore(for profileID: ProfileID) -> BrowserLiveFolderLocalStore {
        liveFolderLocalStores[profileID] ?? .init(profileID: profileID)
    }

    /// The data layer may restore its separate local file; this never changes synced documents.
    public func restoreLiveFolderLocalStore(_ value: BrowserLiveFolderLocalStore) throws {
        guard profiles[value.profileID] != nil else { throw BrowserStoreError.profileMissing }
        liveFolderLocalStores[value.profileID] = value
    }

    @discardableResult
    public func advanceLiveFolderGeneration(for provider: BrowserLiveFolderProvider, profileID: ProfileID) throws -> UInt64 {
        guard profiles[profileID] != nil else { throw BrowserStoreError.profileMissing }
        var local = liveFolderLocalStore(for: profileID)
        let generation = local.advanceGeneration(for: provider)
        liveFolderLocalStores[profileID] = local
        return generation
    }

    public func reenableLiveFolders(for provider: BrowserLiveFolderProvider, profileID: ProfileID) throws {
        guard profiles[profileID] != nil else { throw BrowserStoreError.profileMissing }
        var local = liveFolderLocalStore(for: profileID)
        local.reenableAutomaticCreation(for: provider)
        liveFolderLocalStores[profileID] = local
    }

    func disableLiveFolderRecreation(_ provider: BrowserLiveFolderProvider, profileID: ProfileID) {
        var local = liveFolderLocalStore(for: profileID)
        local.disableAutomaticCreation(for: provider)
        liveFolderLocalStores[profileID] = local
    }

    /// Creates configuration only, empty until a provider supplies a snapshot. Automatic creation
    /// is refused after deletion; an explicit user enable is a separate local command.
    public func createLiveFolder(title: String, configuration: BrowserLiveFolderConfiguration,
                                 at destination: BrowserOrganizationDestination,
                                 from context: BrowserContext) throws -> FolderID {
        _ = try organizationWindow(context)
        guard try destinationSection(of: destination.container, in: context).acceptsFolders else {
            throw BrowserOrganizationError.invalidDestination
        }
        if configuration.creation == .automatic,
           !liveFolderLocalStore(for: context.profileID).allowsAutomaticCreation(for: configuration.provider) {
            throw BrowserOrganizationError.providerOwnedItem
        }
        let folder = BrowserOrganizedFolder(id: FolderID(), title: try BrowserOrganizationState.validatedTitle(title),
                                            createdAt: clock(), liveFolder: configuration)
        try commitOrganization { state in
            let index = try state.insertionIndex(in: destination.container, position: destination.position)
            state.addFolder(folder, into: destination.container, at: index)
        }
        if configuration.creation == .userEnabled { try reenableLiveFolders(for: configuration.provider, profileID: context.profileID) }
        return folder.id
    }

    /// Configuration edits invalidate outstanding results. Cached rows remain until the next
    /// complete fetch; changing provider requires a new folder.
    public func configureLiveFolder(_ id: FolderID, configuration: BrowserLiveFolderConfiguration,
                                    from context: BrowserContext) throws {
        _ = try organizationWindow(context)
        _ = try visibleSection(of: .folder(id), in: context)
        guard let old = organization.folders[id]?.liveFolder, old.provider == configuration.provider else {
            throw BrowserOrganizationError.invalidDestination
        }
        guard old != configuration else { return }
        try commitOrganization { state in
            state.folders[id]?.liveFolder = configuration
            state.changes.metadata = true
        }
        try advanceLiveFolderGeneration(for: configuration.provider, profileID: context.profileID)
    }

    /// Atomically reconciles provider-owned rows and live occurrences. Safe for data-layer calls
    /// without a UI context; profile/folder authority is checked before any mutation.
    @discardableResult
    public func reconcileLiveFolder(_ id: FolderID, profileID: ProfileID,
                                    fetched: BrowserLiveFolderFetch) throws -> Bool {
        guard let folder = organization.folders[id], let config = folder.liveFolder,
              case let .pinned(space)? = organization.section(of: .folder(id)), spaces[space]?.profileID == profileID else {
            return false
        }
        let result = try BrowserLiveFolderReconciler.reconcile(folder,
            children: folder.children.compactMap { $0.tabID.flatMap { organization.tabs[$0] } },
            fetched: fetched, generation: liveFolderLocalStore(for: profileID).generation(for: config.provider),
            preserving: Set(tabs.values.map(\.id)),
            occupiedTabIDs: Set(organization.tabs.keys).subtracting(folder.children.compactMap(\.tabID))
                .union(organization.archive.map(\.id)), now: clock())
        guard result.accepted else { return false }
        try commitOrganization { state in
            state.detach(all: folder.children)
            for child in folder.children.compactMap(\.tabID) { state.tabs[child] = nil }
            for tab in result.children { state.addTab(tab, into: .folder(id), at: .max) }
            for tab in result.preserved { state.addTab(tab, into: .today(space), at: .max) }
            state.changes.metadata = true
        }
        return true
    }

    func acknowledgeLiveFolderTab(_ id: TabID, profileID: ProfileID) {
        guard let child = organization.tabs[id]?.liveFolderChild else { return }
        var local = liveFolderLocalStore(for: profileID)
        local.acknowledge(child.identity, fingerprint: child.fingerprint)
        liveFolderLocalStores[profileID] = local
    }

    func requireOrdinaryTabs(_ ids: [TabID]) throws {
        guard ids.allSatisfy({ organization.tabs[$0]?.liveFolderChild == nil }) else {
            throw BrowserOrganizationError.providerOwnedItem
        }
    }

    /// Pinning a generated row makes an independent ordinary copy; provider membership is intact.
    func pinLiveFolderCopies(_ ids: [TabID], from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        let targets = try uniqueVisibleTabs(ids, in: context)
        let copies = targets.compactMap { id, _ -> BrowserOrganizedTab? in
            guard let original = organization.tabs[id], original.liveFolderChild != nil else { return nil }
            return BrowserOrganizedTab(id: TabID(), url: original.url, pageTitle: original.pageTitle,
                pinnedURL: original.pinnedURL ?? original.url, createdAt: clock(), lastActiveAt: clock())
        }
        try commitOrganization(.pinTabs, in: context) { state in
            let ordinary = targets.filter { state.tabs[$0.0]?.liveFolderChild == nil }.map { BrowserOrganizationNode.tab($0.0) }
            if !ordinary.isEmpty { try state.move(state.groupedNodes(for: ordinary.compactMap(\.tabID)),
                to: .init(.pinned(context.spaceID)), destinationSection: .pinned(context.spaceID)) }
            for tab in copies { state.addTab(tab, into: .pinned(context.spaceID), at: .max) }
        }
        return try captureWindowState(in: context.windowID)
    }

    /// Provider deletion never feeds cached rows into the ordinary archive/undo commands.
    func deleteLiveFolder(_ id: FolderID, contents: BrowserFolderDeletion, from context: BrowserContext) throws -> BrowserWindowState {
        guard let folder = organization.folders[id], let config = folder.liveFolder else { throw BrowserOrganizationError.itemMissing }
        let open = Set(tabs.values.map(\.id))
        try commitOrganization { state in
            for node in folder.children {
                guard let tabID = node.tabID, var tab = state.tabs[tabID] else { continue }
                state.detach(node); state.tabs[tabID] = nil
                if contents == .keepContents || open.contains(tabID) {
                    tab.liveFolderChild = nil; tab.pinnedURL = nil
                    state.addTab(tab, into: .today(context.spaceID), at: .max)
                }
            }
            state.removeEmptyFolder(id)
        }
        disableLiveFolderRecreation(config.provider, profileID: context.profileID)
        return try captureWindowState(in: context.windowID)
    }
}
