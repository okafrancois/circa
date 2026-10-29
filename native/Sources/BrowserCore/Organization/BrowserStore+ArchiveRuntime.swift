import Foundation

public extension BrowserStore {
    /// Stable IDs only; no browsing content is needed by scheduler admission or diagnostics.
    func autoArchiveCandidates(includeUnexpired: Bool = false) -> Set<TabID> {
        let now = clock()
        let visible = Set(windows.values.flatMap(visibleTabIDs(in:)))
        var result: Set<TabID> = []
        for space in spaces.values {
            guard let interval = (organization.policy.threshold(for: space.profileID).interval ?? (includeUnexpired ? 0 : nil)) else { continue }
            for block in organization.todayBlocks(in: space.id) {
                guard includeUnexpired || block.allSatisfy({ id in
                    !visible.contains(id) && organization.tabs[id].map { now.timeIntervalSince($0.lastActiveAt) >= interval } == true
                }) else { continue }
                result.formUnion(block)
            }
        }
        return result
    }

    /// Activity metadata is not an undoable organization command. The caller schedules persistence.
    func touchArchiveProtectedTabs(_ ids: Set<TabID>) {
        let now = clock()
        for id in ids where organization.tabs[id] != nil { organization.touch(id, at: now) }
        recordSelectionActivity(ids)
    }

    /// Clear Today retains every window's visible tab, in addition to shell media protection.
    func clearTodayPreservingVisibleTabs(protecting ids: Set<TabID>, from context: BrowserContext) throws -> BrowserWindowState {
        let visible = Set(windows.values.flatMap(visibleTabIDs(in:)))
        return try clearTodayTabs(protecting: ids.union(visible), from: context)
    }
}
