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
        let saved = BrowserArchivedTab(tab: record.tab, profileID: record.profileID, spaceID: destination ?? record.spaceID,
                                       origin: .today, reason: .closed, archivedAt: record.archivedAt)
        try commitOrganization { state in
            state.archive.removeAll { $0.id == saved.id }
            state.insertArchive(saved)
        }
    }
}
