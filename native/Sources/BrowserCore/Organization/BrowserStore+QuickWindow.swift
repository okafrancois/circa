import Foundation

public extension BrowserStore {
    /// A recoverable URL snapshot, not a live tab or a serialization of the engine document.
    /// Idempotent across a cancelled quit. A deleted Space falls back within the same profile.
    func archiveQuickWindow(_ record: BrowserArchivedTab) throws {
        try BrowserSessionDocument.validateDestination(record.tab.url)
        try requireAvailableProfile(record.profileID)
        let destination = spaces[record.spaceID]?.profileID == record.profileID ? record.spaceID
            : spaceOrder.first { spaces[$0]?.profileID == record.profileID }
        guard profiles[record.profileID] != nil else { throw BrowserStoreError.profileMissing }
        // Engine metadata follows the same normalization as ordinary tab navigation. Empty,
        // control-bearing or oversized titles must never prevent archival or the final save.
        var tab = record.tab
        tab.pageTitle = BrowserOrganizedTab.normalizedPageTitle(tab.pageTitle)
        var saved = BrowserArchivedTab(tab: tab, profileID: record.profileID, spaceID: destination ?? record.spaceID,
                                       origin: .quickWindow, reason: record.reason, archivedAt: record.archivedAt)
        if destination == nil, let owner = spaces[record.spaceID]?.profileID, owner != record.profileID {
            saved.spaceProfileWasChanged = true
        }
        try commitOrganization { state in
            state.archive.removeAll { $0.id == saved.id }
            state.insertArchive(saved)
        }
    }
}
