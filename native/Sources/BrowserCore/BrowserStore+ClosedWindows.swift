import Foundation

struct BrowserClosedWindow {
    let window: WindowRecord
    let tabs: [BrowserTab]
    let standalone: BrowserStandaloneWindow?
    let closedAt: Date
}

extension BrowserStore {
    public var lastClosedWindowDate: Date? { closedWindows.last?.closedAt }

    /// Restores only the retired container, leaving every other window and later edit intact.
    @discardableResult
    public func reopenLastClosedWindow() throws -> WindowID? {
        guard let saved = closedWindows.last else { return nil }
        let window = saved.window
        guard windows[window.id] == nil else { throw BrowserStoreError.staleContext }
        guard spaces[window.activeSpaceID] != nil else { throw BrowserStoreError.spaceMissing }
        for space in window.occurrenceIDsBySpace.keys {
            guard let profile = spaces[space]?.profileID else { throw BrowserStoreError.spaceMissing }
            try requireAvailableProfile(profile)
        }
        var restoredOrganization = organization
        if let standalone = saved.standalone {
            try restoredOrganization.restoreStandalone(standalone, windowID: window.id, home: window.activeSpaceID)
        }
        var restored = window
        for (space, ids) in window.occurrenceIDsBySpace {
            let valid = ids.filter { occurrence in
                guard let tab = saved.tabs.first(where: { $0.occurrenceID == occurrence }),
                      restoredOrganization.tabs[tab.id] != nil else { return false }
                if saved.standalone == nil {
                    switch restoredOrganization.section(of: .tab(tab.id)) {
                    case let .favorites(profile): guard spaces[space]?.profileID == profile else { return false }
                    case let .pinned(home), let .today(home): guard home == space else { return false }
                    case nil: return false
                    }
                }
                tabs[occurrence] = tab
                return true
            }
            restored.occurrenceIDsBySpace[space] = valid
            if let selected = restored.selectedOccurrenceBySpace[space], !valid.contains(selected) {
                restored.selectedOccurrenceBySpace[space] = valid.first
            }
        }
        organization = restoredOrganization
        restored.revision &+= 1
        windows[window.id] = restored
        closedWindows.removeLast()
        publishOrganizationChange()
        return window.id
    }
}
