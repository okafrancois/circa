import Foundation

extension BrowserStore {
    /// Promotes the children, preserving their identities and hierarchy. The outer folder alone
    /// disappears; Today and shared Favorites stay with their existing owners.
    public func convertFolderToSpace(_ id: FolderID, from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        guard let folder = organization.folders[id], folder.liveFolder == nil,
              organization.section(of: .folder(id)) == .pinned(context.spaceID) else {
            throw BrowserOrganizationError.invalidDestination
        }
        let space = BrowserSpace(id: SpaceID(), profileID: context.profileID,
                                 name: try Self.validatedSpaceName(folder.title))
        return try commitSpaceConversion(.convertFolderToSpace, space: space, removing: false, from: context) { state in
            if !folder.children.isEmpty {
                try state.move(folder.children, to: .init(.pinned(space.id)), destinationSection: .pinned(space.id))
            }
            state.removeEmptyFolder(id)
        }
    }

    /// Exports into a collapsed folder at the start of the destination's pinned section.
    /// Today tabs are preserved inside it before retiring the source Space.
    public func exportSpace(_ id: SpaceID, to destination: SpaceID, from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        guard let source = spaces[id], source.profileID == context.profileID,
              let target = spaces[destination], target.profileID == source.profileID, id != destination else {
            throw BrowserOrganizationError.invalidDestination
        }
        let folder = BrowserOrganizedFolder(id: FolderID(), title: source.name, isCollapsed: true, children: [], createdAt: clock())
        return try commitSpaceConversion(.exportSpace, space: source, removing: true, activating: destination, from: context) { state in
            let contents = state.children(of: .pinned(id)) + state.children(of: .today(id))
            state.addFolder(folder, into: .pinned(destination), at: 0)
            if !contents.isEmpty {
                try state.move(contents, to: .init(.folder(folder.id)), destinationSection: .pinned(destination))
            }
            state.collapsedPinnedSections.remove(id)
        }
    }

    private func commitSpaceConversion(
        _ action: BrowserOrganizationAction, space: BrowserSpace, removing: Bool,
        activating destination: SpaceID? = nil, from context: BrowserContext,
        _ mutate: (inout BrowserOrganizationState) throws -> Void
    ) throws -> BrowserWindowState {
        var next = organization
        next.changes = .init()
        try mutate(&next)
        next.normalizeSplits()
        var patch = BrowserOrganizationPatch(from: organization, to: next, changes: next.changes)
        patch.spaceRecords[space.id] = .init(before: removing ? space : nil, after: removing ? nil : space)
        patch.spaceIndices[space.id] = removing ? spaceOrder.firstIndex(of: space.id) : spaceOrder.count
        if removing {
            patch.spaceSelection = windows[context.windowID].flatMap { visibleSelectedTabID(in: $0) }
            patch.collapsedSpaceSections[space.id] = .init(before: organization.collapsedPinnedSections.contains(space.id), after: false)
        }
        patch.activeSpace = .init(before: context.spaceID, after: destination ?? space.id)
        try validateOrganization(next, applying: patch)
        next.stampPlacements(&patch)
        let effects = windows[context.windowID].map { windowEffects(of: patch, in: $0) }
        next.changes = .init()
        organization = next
        applyCatalog(patch, in: context.windowID)
        reconcileOccurrences()
        recordUndo(.init(action: action, profileID: context.profileID, spaceID: context.spaceID,
                         patch: patch, liveTabs: effects?.liveTabs ?? [], selectedTab: effects?.selectedTab), in: context.windowID)
        publishOrganizationChange()
        return try captureWindowState(in: context.windowID)
    }

    func catalogApplying(_ patch: BrowserOrganizationPatch) -> [SpaceID: BrowserSpace] {
        var result = spaces
        for (id, change) in patch.spaceRecords { result[id] = change.after }
        return result
    }

    /// Validate the post-commit homes without changing live windows before the transaction succeeds.
    /// Local windows are rehomed by applyCatalog after their source Space is retired.
    func validateOrganization(_ state: BrowserOrganizationState, applying patch: BrowserOrganizationPatch) throws {
        let catalog = catalogApplying(patch)
        var candidate = state
        for (window, home) in state.standaloneHomes where catalog[home] == nil {
            guard let profile = windows[window]?.standaloneProfileID,
                  let destination = spaceOrder.first(where: { catalog[$0]?.profileID == profile })
                    ?? patch.activeSpace?.after else { throw BrowserSessionError.spaceMissing }
            candidate.standaloneHomes[window] = destination
        }
        try candidate.validate(profiles: Set(profiles.keys), spaces: catalog.mapValues(\.profileID))
    }

    func canApplyCatalog(_ patch: BrowserOrganizationPatch) -> Bool {
        for (id, change) in patch.spaceRecords {
            guard spaces[id] == change.before else { return false }
            // Do not remove content subsequently added by another command or window.
            if change.after == nil {
                let roots = organization.children(of: .pinned(id)) + organization.children(of: .today(id))
                guard roots.allSatisfy({ patch.placements[$0] != nil }) else { return false }
            }
        }
        for (id, change) in patch.collapsedSpaceSections where organization.collapsedPinnedSections.contains(id) != change.before { return false }
        let catalog = catalogApplying(patch)
        for change in patch.placements.values {
            switch change.after?.container {
            case .pinned(let id)?, .today(let id)?: if catalog[id] == nil { return false }
            default: break
            }
        }
        return patch.activeSpace.map { catalog[$0.after] != nil } ?? true
    }

    /// Relocate occurrences while both same-profile catalog identities are available. Keep their
    /// live documents and cached metadata, then retire the old identity and activate atomically.
    func applyCatalog(_ patch: BrowserOrganizationPatch, in windowID: WindowID) {
        guard !patch.spaceRecords.isEmpty else { return }
        for (id, change) in patch.spaceRecords where change.after != nil {
            spaces[id] = change.after
            if !spaceOrder.contains(id) { spaceOrder.insert(id, at: min(patch.spaceIndices[id] ?? spaceOrder.count, spaceOrder.count)) }
        }
        let retiredSelections = windows.compactMapValues { window -> TabOccurrenceID? in
            guard let change = patch.spaceRecords[window.activeSpaceID], change.after == nil else { return nil }
            return window.selectedOccurrenceBySpace[window.activeSpaceID]
        }
        reconcileOccurrences()
        for (id, change) in patch.collapsedSpaceSections {
            if change.after { organization.collapsedPinnedSections.insert(id) } else { organization.collapsedPinnedSections.remove(id) }
        }
        for (id, change) in patch.spaceRecords where change.after == nil {
            let fallback = patch.activeSpace?.after ?? spaceOrder.first { $0 != id }!
            rehomeStandaloneWindows(excluding: [id])
            for key in Array(windows.keys) {
                for occurrence in windows[key]?.occurrenceIDsBySpace[id] ?? [] {
                    relocateOccurrence(occurrence, to: fallback, in: key)
                }
                windows[key]?.occurrenceIDsBySpace[id] = nil
                windows[key]?.selectedOccurrenceBySpace[id] = nil
                if windows[key]?.activeSpaceID == id {
                    windows[key]?.activeSpaceID = fallback
                    if let selected = retiredSelections[key], tabs[selected]?.spaceID == fallback {
                        windows[key]?.selectedOccurrenceBySpace[fallback] = selected
                    }
                    windows[key]?.revision &+= 1
                }
            }
            spaces[id] = nil
            spaceOrder.removeAll { $0 == id }
        }
        if let active = patch.activeSpace {
            windows[windowID]?.activeSpaceID = active.after
            windows[windowID]?.revision &+= 1
            if let selected = patch.spaceSelection,
               let occurrence = windows[windowID]?.occurrenceIDsBySpace[active.after]?.first(where: { tabs[$0]?.id == selected }) {
                windows[windowID]?.selectedOccurrenceBySpace[active.after] = occurrence
            }
        }
    }
}
