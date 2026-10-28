import Foundation

public extension BrowserStore {
    /// Removes one captured identity, closing every occurrence across windows. Favorites belong
    /// to the profile and stay shared; Pinned and Today tabs remain recoverable in its archive.
    /// The final global Space is protected, even when other profiles have no Spaces.
    func removeSettingsSpace(_ id: SpaceID, expectedProfileID: ProfileID? = nil) throws {
        guard let space = spaces[id] else { throw BrowserStoreError.spaceMissing }
        if let expectedProfileID, expectedProfileID != space.profileID { throw BrowserStoreError.staleContext }
        try requireAvailableProfile(space.profileID)
        guard let fallback = spaceOrder.first(where: {
            $0 != id && spaces[$0].map { !deletingProfiles.contains($0.profileID) } == true
        }) else { throw BrowserSettingsError.lastSpace }
        organization.removeSpace(space, at: clock())
        for key in Array(organizationJournals.keys) {
            guard var journal = organizationJournals[key] else { continue }
            journal.undo.removeAll { $0.touchesSettingsSpace(id) }
            journal.redo.removeAll { $0.touchesSettingsSpace(id) }
            organizationJournals[key] = journal
        }
        let sameProfile = spaceOrder.first { $0 != id && spaces[$0]?.profileID == space.profileID }
        for key in Array(windows.keys) {
            guard var window = windows[key] else { continue }
            let occurrences = window.occurrenceIDsBySpace.removeValue(forKey: id) ?? []
            for occurrence in occurrences { tabs[occurrence] = nil }
            window.selectedOccurrenceBySpace[id] = nil
            if window.activeSpaceID == id {
                window.activeSpaceID = sameProfile ?? fallback
                window.revision &+= 1
            } else if !occurrences.isEmpty { window.revision &+= 1 }
            windows[key] = window
        }
        spaces[id] = nil
        spaceOrder.removeAll { $0 == id }
        themeImports.remove(id)
        reconcileOccurrences()
        for key in windows.keys { ensureVisibleSplitOccurrences(in: key) }
        publishOrganizationChange()
    }
    func restoreSettingsSpace(_ id: SpaceID, expectedProfileID: ProfileID? = nil) throws {
        guard let saved = organization.archivedSpaces.first(where: { $0.id == id }) else { throw BrowserStoreError.spaceMissing }
        if let expectedProfileID, expectedProfileID != saved.space.profileID { throw BrowserStoreError.staleContext }
        guard spaces[id] == nil else { throw BrowserSettingsError.spaceNotEmpty }
        try requireAvailableProfile(saved.space.profileID)
        let available = Set(organization.archive.filter { $0.profileID == saved.space.profileID }.map(\.id))
        let recovery = saved.retainingTabs(available)
        guard recovery.contents.tabs.allSatisfy({ organization.tabs[$0.id] == nil }),
              recovery.contents.folders.allSatisfy({ organization.folders[$0.id] == nil }),
              recovery.contents.splits.allSatisfy({ organization.splits[$0.id] == nil }) else { throw BrowserSettingsError.spaceNotEmpty }
        let restored = try BrowserOrganizationState(document: recovery.contents)
        try restored.validate(profiles: [saved.space.profileID], spaces: [id: saved.space.profileID])
        for tab in restored.tabs.values { organization.tabs[tab.id] = tab }
        for folder in restored.folders.values { organization.folders[folder.id] = folder }
        for split in restored.splits.values { organization.splits[split.id] = split }
        organization.pinned[id] = restored.pinned[id]
        organization.today[id] = restored.today[id]
        if restored.collapsedPinnedSections.contains(id) { organization.collapsedPinnedSections.insert(id) }
        let recoveredIDs = Set(restored.tabs.keys)
        organization.archive.removeAll { recoveredIDs.contains($0.id) }
        organization.archivedSpaces.removeAll { $0.id == id }
        organization.rebuildParents()
        spaces[id] = saved.space
        spaceOrder.append(id)
        publishOrganizationChange()
    }

}
