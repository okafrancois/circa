import Foundation

public extension BrowserStore {
    /// A Settings profile is visible in the catalog without implicitly creating a Space.
    func createSettingsProfile(name: String) throws -> ProfileID {
        let name = try Self.validatedSpaceName(name)
        let profileID = ProfileID()
        profiles[profileID] = BrowserProfile(id: profileID, name: name)
        profileOrder.append(profileID)
        publishOrganizationChange()
        return profileID
    }

    func renameSettingsProfile(_ id: ProfileID, name: String) throws {
        guard profiles[id] != nil else { throw BrowserStoreError.profileMissing }
        try requireAvailableProfile(id)
        profiles[id] = BrowserProfile(id: id, name: try Self.validatedSpaceName(name))
        publishOrganizationChange()
    }

    func validateSettingsProfileRemoval(_ id: ProfileID) throws {
        guard profiles[id] != nil else { throw BrowserStoreError.profileMissing }
        try requireAvailableProfile(id)
        guard profiles.keys.filter({ !deletingProfiles.contains($0) }).count > 1 else { throw BrowserSettingsError.lastProfile }
        guard id != profileOrder.first else { throw BrowserSettingsError.defaultProfile }
        let ids = Set(spaces.values.filter { $0.profileID == id }.map(\.id))
        guard ids.isEmpty else { throw BrowserSettingsError.profileHasSpaces }
        guard !windows.values.contains(where: { window in
            ids.contains(window.activeSpaceID) || window.occurrenceIDsBySpace.contains { ids.contains($0.key) && !$0.value.isEmpty }
        }), !tabs.values.contains(where: { ids.contains($0.spaceID) }) else { throw BrowserSettingsError.profileInUse }
    }

    /// Quarantine precedes every await outside the model. No switch, window or Space creation
    /// may target this identity while the durable removal intent is being written.
    func reserveSettingsProfileRemoval(_ id: ProfileID) throws -> BrowserProfileRemoval {
        try validateSettingsProfileRemoval(id)
        deletingProfiles.insert(id)
        return BrowserProfileRemoval(profileID: id, spaceIDs: Set(spaces.values.filter { $0.profileID == id }.map(\.id)))
    }

    func cancelSettingsProfileReservation(_ id: ProfileID) { deletingProfiles.remove(id) }
    func finishSettingsProfileRemoval(_ id: ProfileID) { deletingProfiles.remove(id) }
    func isSettingsProfileBeingRemoved(_ id: ProfileID) -> Bool { deletingProfiles.contains(id) }

    func commitSettingsProfileRemoval(_ id: ProfileID) throws {
        guard deletingProfiles.contains(id) else { throw BrowserSettingsError.profileBeingDeleted }
        retireSettingsProfile(id, recoveringSavedWindows: false)
    }

    /// Durable intent authorizes recovery even if the session predates a window closure. This
    /// runs before any engine surface exists, preserving other profiles' saved occurrences.
    func recoverSettingsProfileRemoval(_ id: ProfileID) {
        deletingProfiles.insert(id)
        retireSettingsProfile(id, recoveringSavedWindows: true)
    }

    /// Compatibility entry for model-only callers; application cleanup uses the durable journal.
    func removeSettingsProfile(_ id: ProfileID) throws {
        _ = try reserveSettingsProfileRemoval(id)
        try commitSettingsProfileRemoval(id)
        finishSettingsProfileRemoval(id)
    }

    func assignSettingsSpace(_ id: SpaceID, to profile: ProfileID) throws {
        guard let space = spaces[id] else { throw BrowserStoreError.spaceMissing }
        guard profiles[profile] != nil else { throw BrowserStoreError.profileMissing }
        try requireAvailableProfile(space.profileID)
        try requireAvailableProfile(profile)
        guard space.profileID != profile else { return }
        guard !tabs.values.contains(where: { $0.spaceID == id }),
              !windows.values.contains(where: { $0.activeSpaceID == id }),
              organization.pinned[id, default: []].isEmpty, organization.today[id, default: []].isEmpty,
              !organization.archive.contains(where: { $0.spaceID == id }) else { throw BrowserSettingsError.spaceNotEmpty }
        // Reversible patches can name a Space different from the issuing window's Space.
        // Purge both sides of those patches, in every window, before changing account identity.
        for key in Array(organizationJournals.keys) {
            guard var journal = organizationJournals[key] else { continue }
            journal.undo.removeAll { $0.touchesSettingsSpace(id) }
            journal.redo.removeAll { $0.touchesSettingsSpace(id) }
            organizationJournals[key] = journal
        }
        spaces[id] = BrowserSpace(id: id, profileID: profile, name: space.name, theme: space.theme)
        publishOrganizationChange()
    }
}

extension BrowserStore {
    func requireAvailableProfile(_ id: ProfileID) throws {
        guard !deletingProfiles.contains(id) else { throw BrowserSettingsError.profileBeingDeleted }
    }

    private func retireSettingsProfile(_ id: ProfileID, recoveringSavedWindows: Bool) {
        let ids = Set(spaces.values.filter { $0.profileID == id }.map(\.id))
        organizationWillRemoveProfile(id)
        let fallback = spaceOrder.first { !ids.contains($0) && spaces[$0].map { !deletingProfiles.contains($0.profileID) } == true }
        for key in Array(windows.keys) {
            guard var window = windows[key] else { continue }
            for space in ids {
                if recoveringSavedWindows {
                    for occurrence in window.occurrenceIDsBySpace[space] ?? [] { tabs[occurrence] = nil }
                }
                window.occurrenceIDsBySpace[space] = nil
                window.selectedOccurrenceBySpace[space] = nil
            }
            if ids.contains(window.activeSpaceID) {
                guard let fallback else { windows[key] = nil; organizationDidCloseWindow(key); continue }
                window.activeSpaceID = fallback
                window.revision &+= 1
            }
            windows[key] = window
        }
        for space in ids { spaces[space] = nil }
        spaceOrder.removeAll { ids.contains($0) }
        profiles[id] = nil
        profileOrder.removeAll { $0 == id }
        publishOrganizationChange()
    }
}

extension BrowserOrganizationUndoRecord {
    func touchesSettingsSpace(_ id: SpaceID) -> Bool {
        if spaceID == id || patch.spaceRecords[id] != nil { return true }
        func matches(_ container: BrowserOrganizationContainer?) -> Bool {
            switch container { case .pinned(let candidate)?, .today(let candidate)?: candidate == id; default: false }
        }
        return patch.placements.values.contains { matches($0.before?.container) || matches($0.after?.container) }
            || patch.archive.values.contains { $0.before?.spaceID == id || $0.after?.spaceID == id }
    }
}
