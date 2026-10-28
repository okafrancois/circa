import Foundation

public extension BrowserStore {
    func moveSpaceToProfile(_ id: SpaceID, to profile: ProfileID, expectedProfileID: ProfileID) throws {
        guard let space = spaces[id] else { throw BrowserStoreError.spaceMissing }
        guard space.profileID == expectedProfileID else { throw BrowserStoreError.staleContext }
        guard profiles[profile] != nil else { throw BrowserStoreError.profileMissing }
        try requireAvailableProfile(space.profileID)
        try requireAvailableProfile(profile)
        guard space.profileID != profile else { return }

        for index in organization.archive.indices where organization.archive[index].spaceID == id {
            organization.archive[index].spaceProfileWasChanged = true
        }

        for key in Array(windows.keys) {
            guard var window = windows[key] else { continue }
            let previous = window.occurrenceIDsBySpace[id, default: []]
            var replacements: [TabOccurrenceID: TabOccurrenceID] = [:]
            for oldID in previous {
                guard let tab = tabs.removeValue(forKey: oldID) else { continue }
                // An open Favorite stays in its original profile, independently of this Space.
                guard organization.section(of: .tab(tab.id))?.spaceID == id else { continue }
                let newID = TabOccurrenceID()
                replacements[oldID] = newID
                tabs[newID] = BrowserTab(id: tab.id, occurrenceID: newID, windowID: key, spaceID: id, url: tab.url)
            }
            if !previous.isEmpty {
                window.occurrenceIDsBySpace[id] = previous.compactMap { replacements[$0] }
                window.selectedOccurrenceBySpace[id] = window.selectedOccurrenceBySpace[id].flatMap { replacements[$0] }
                    ?? window.occurrenceIDsBySpace[id]?.first
            }
            if window.activeSpaceID == id || !previous.isEmpty {
                window.revision &+= 1
                window.reconciledRevisions = nil
            }
            windows[key] = window
        }
        // Patches can reach nested containers or tabs that have since left this Space.
        // Retire both affected profiles' journals rather than permit cross-account replay.
        for key in Array(organizationJournals.keys) {
            organizationJournals[key]?.undo.removeAll { $0.profileID == space.profileID || $0.profileID == profile }
            organizationJournals[key]?.redo.removeAll { $0.profileID == space.profileID || $0.profileID == profile }
        }
        spaces[id] = BrowserSpace(id: id, profileID: profile, name: space.name, theme: space.theme)
        publishOrganizationChange()
    }
}
