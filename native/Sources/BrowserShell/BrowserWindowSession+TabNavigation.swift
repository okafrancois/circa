import BrowserCore

public extension BrowserWindowSession {
    /// Explicit recent-tab selection may load an occurrence restored without an engine view.
    /// Automatic document promotions continue to require the provided-surface selection API.
    func selectSidebarOccurrence(_ occurrenceID: TabOccurrenceID,
                                 ifContextMatches expected: BrowserContext) -> Task<Bool, Never> {
        if surfaces[occurrenceID] != nil { return selectOccurrence(occurrenceID, ifContextMatches: expected) }
        guard !isClosed else { return Task { false } }
        pendingCommandCount += 1
        let previous = pending
        let selection = Task<Bool, Never> { [self] in
            defer { pendingCommandCount -= 1 }
            await previous?.value
            guard !isClosed, activeContext == expected else { return false }
            do {
                let state = try await store.selectOccurrenceUpdating(occurrenceID, from: expected,
                    state: selectionState, index: organizationRuntime.metadataIndex)
                guard !isClosed else { return false }
                install(state)
                return !isClosed && snapshot?.selectedOccurrenceID == occurrenceID
            } catch { return false }
        }
        pending = Task { _ = await selection.value }
        return selection
    }

    /// Resolve in the session FIFO, after any preceding reorder or Space/profile switch.
    func selectSidebarTab(at index: Int? = nil, offset: Int? = nil, includeFavorites: Bool = true,
                          onSelect: @escaping @MainActor (Surface) -> Void = { _ in }) {
        enqueue { session in
            guard let context = try await session.organizationContext(), let organization = session.organization else { return }
            let tabs = organization.tabNavigationItems.filter { includeFavorites || $0.section != .favorites(context.profileID) }
            guard !tabs.isEmpty else { return }
            let ordinal: Int
            if let offset {
                let current = tabs.firstIndex { $0.isSelected } ?? (offset > 0 ? -1 : 0)
                ordinal = (current + offset + tabs.count) % tabs.count
            } else { ordinal = index == -1 ? tabs.count - 1 : (index ?? 0) }
            guard tabs.indices.contains(ordinal) else { return }
            let state = try await session.selectTabState(tabs[ordinal].id, from: context)
            guard !session.isClosed else { return }
            session.install(state)
            if let surface = session.selectedSurface { onSelect(surface) }
        }
    }
}
