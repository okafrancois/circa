import Foundation

/// One undoable organization command, kept in the journal of the window that issued it.
struct BrowserOrganizationUndoRecord: Sendable {
    /// Stable within the issuing window, preserved by undo/redo and conflict skipping.
    var id: UInt64 = 0
    let action: BrowserOrganizationAction
    let profileID: ProfileID
    let spaceID: SpaceID
    /// Extended by replays with the records the archive cap evicted, so the opposite replay
    /// brings them back instead of losing them.
    var patch: BrowserOrganizationPatch
    /// Affected tabs that were live in the issuing window; undo reopens them there unselected.
    let liveTabs: Set<TabID>
    /// The window's visible tab when the command displaced it; undo selects it again.
    let selectedTab: TabID?
}

struct BrowserOrganizationJournal: Sendable {
    static let limit = 100
    var undo: [BrowserOrganizationUndoRecord] = []
    var redo: [BrowserOrganizationUndoRecord] = []
    /// New undoable commands recorded in this window (never decreases; undo/redo replays do not
    /// count). Lets the shell order organization actions against its other undo sources.
    var recordedCount: UInt64 = 0
}

struct BrowserOrganizationWindowEffects: Sendable {
    let liveTabs: Set<TabID>
    let selectedTab: TabID?
}

private struct BrowserOrganizationSelectionAnchor {
    let spaceID: SpaceID
    let orderedTabs: [TabID]
    let selectedTab: TabID?
}

/// A reset applied by the model; the shell navigates `occurrenceID`'s live surface to `url`.
public struct BrowserOrganizationReset: Equatable, Sendable {
    public let tabID: TabID
    public let url: URL
    public let occurrenceID: TabOccurrenceID?
}

extension BrowserStore {
    /// New Today tabs appear at the top, below the New Tab row.
    static let insertsNewTodayTabsAtTop = true

    // MARK: Observation

    /// Yields the organization revision after every change visible in some window's snapshot,
    /// including occurrences opened or closed by another window. Values may be coalesced.
    public func organizationChanges() -> AsyncStream<UInt64> {
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        organizationObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeOrganizationObserver(id) }
        }
        return stream
    }

    public func currentOrganizationRevision() -> UInt64 { organizationRevision }

    func removeOrganizationObserver(_ id: UUID) {
        organizationObservers.removeValue(forKey: id)
    }

    func publishOrganizationChange() {
        organization.normalizeArchivedSpaces()
        organizationRevision &+= 1
        for continuation in organizationObservers.values { continuation.yield(organizationRevision) }
    }

    // MARK: Queries

    public func organizationSnapshot(from context: BrowserContext) throws -> BrowserOrganizationSnapshot {
        guard isCurrent(context) else { throw BrowserStoreError.staleContext }
        return try organizationSnapshot(for: context.windowID)
    }

    /// Archived tabs of the context's profile, newest first, optionally filtered by title or URL.
    public func archivedTabs(from context: BrowserContext, matching query: String? = nil) throws -> [BrowserArchivedTab] {
        guard isCurrent(context) else { throw BrowserStoreError.staleContext }
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return organization.archive.filter { record in
            guard record.profileID == context.profileID else { return false }
            guard !needle.isEmpty else { return true }
            let fields = [record.tab.customTitle, record.tab.pageTitle, record.tab.url.absoluteString].compactMap { $0 }
            return fields.contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    public func archivePolicy() -> BrowserArchivePolicy { organization.policy }

    func organizationSnapshot(for windowID: WindowID) throws -> BrowserOrganizationSnapshot {
        guard let window = windows[windowID] else { throw BrowserStoreError.windowMissing }
        guard let space = spaces[window.activeSpaceID] else { throw BrowserStoreError.spaceMissing }
        var local: [TabID: BrowserTab] = [:]
        for occurrenceIDs in window.occurrenceIDsBySpace.values {
            for occurrenceID in occurrenceIDs { if let tab = tabs[occurrenceID] { local[tab.id] = tab } }
        }
        var remote: Set<TabID> = []
        for tab in tabs.values where tab.windowID != windowID { remote.insert(tab.id) }
        let selected = window.selectedOccurrenceBySpace[space.id]

        func items(_ nodes: [BrowserOrganizationNode], section: BrowserOrganizationSection) -> [BrowserOrganizationItem] {
            nodes.compactMap { node in
                switch node {
                case let .tab(id):
                    guard let entry = organization.tabs[id] else { return nil }
                    let live = local[id]
                    let occurrenceID = live?.spaceID == space.id ? live?.occurrenceID : nil
                    return .tab(BrowserOrganizationTabItem(
                        id: id, section: section, url: live?.url ?? entry.url, pinnedURL: entry.pinnedURL,
                        pageTitle: entry.pageTitle, customTitle: entry.customTitle, occurrenceID: occurrenceID,
                        isLoadedInThisWindow: live != nil,
                        isSelected: occurrenceID != nil && occurrenceID == selected,
                        isOpenInAnotherWindow: remote.contains(id), lastActiveAt: entry.lastActiveAt))
                case let .split(id):
                    guard let split = organization.splits[id] else { return nil }
                    let panes = items(split.tabIDs.map(BrowserOrganizationNode.tab), section: section).compactMap { item -> BrowserOrganizationTabItem? in
                        if case let .tab(tab) = item { return tab }; return nil
                    }
                    return .split(BrowserOrganizationSplitItem(group: split, tabs: panes))
                case let .folder(id):
                    guard let folder = organization.folders[id] else { return nil }
                    return .folder(BrowserOrganizationFolderItem(id: id, title: folder.title,
                        isCollapsed: folder.isCollapsed, children: items(folder.children, section: section)))
                }
            }
        }
        let journal = organizationJournals[windowID]
        let archived = organization.archiveSummary(of: space.profileID)
        let undo = journal.flatMap { replayCandidate(in: $0.undo, undoing: true,
                                                     profileID: space.profileID, windowID: windowID) }
        let redo = journal.flatMap { replayCandidate(in: $0.redo, undoing: false,
                                                     profileID: space.profileID, windowID: windowID) }
        return BrowserOrganizationSnapshot(
            organizationRevision: organizationRevision, windowID: windowID, spaceID: space.id, profileID: space.profileID,
            favorites: items(organization.favorites[space.profileID] ?? [], section: .favorites(space.profileID)),
            pinned: items(organization.pinned[space.id] ?? [], section: .pinned(space.id)),
            today: items(organization.today[space.id] ?? [], section: .today(space.id)),
            isPinnedSectionCollapsed: organization.collapsedPinnedSections.contains(space.id),
            archiveRevision: archived.revision,
            canRestoreArchivedTab: archived.canRestore,
            autoArchiveThreshold: organization.policy.threshold(for: space.profileID),
            inheritsAutoArchiveThreshold: organization.policy.profileThresholds[space.profileID] == nil,
            archivedTabCount: archived.count,
            undoAction: undo?.action, redoAction: redo?.action,
            undoRecordCount: journal?.recordedCount ?? 0,
            undoRecordID: undo?.id, redoRecordID: redo?.id)
    }

    // MARK: Selection and occurrences

    /// Activates a sidebar tab in the captured window: selects its live occurrence, moves a Favorite
    /// that is live in another Space of this window, or opens a new occurrence at its destination.
    public func selectTab(_ id: TabID, from context: BrowserContext,
                          expecting expected: BrowserOrganizationSnapshot? = nil,
                          admission: BrowserSidebarSelectionAdmission? = nil) throws -> BrowserWindowState {
        guard admission?.isValid != false else { return try captureWindowState(in: context.windowID) }
        if let expected, try organizationSnapshot(from: context) != expected {
            throw BrowserOrganizationError.notVisibleInContext
        }
        let window = try organizationWindow(context)
        let section = try visibleSection(of: .tab(id), in: context)
        if let local = occurrences(in: window).first(where: { $0.id == id }) {
            if local.spaceID != context.spaceID {
                guard case .favorites = section else { throw BrowserStoreError.occurrenceOwnedByAnotherWindow }
                relocateOccurrence(local.occurrenceID, to: context.spaceID, in: context.windowID)
                publishOrganizationChange()
            }
            try selectOccurrence(local.occurrenceID, in: context.windowID)
        } else {
            guard let entry = organization.tabs[id] else { throw BrowserOrganizationError.itemMissing }
            openOccurrence(of: id, url: entry.url, in: context.windowID, spaceID: context.spaceID, activate: true)
        }
        if case let .split(id)? = organization.container(of: .tab(id)) { ensureSplitOccurrences(id, in: context) }
        return try captureWindowState(in: context.windowID)
    }

    @discardableResult
    func openOccurrence(of tabID: TabID, url: URL, in windowID: WindowID, spaceID: SpaceID,
                        activate: Bool) -> TabOccurrenceID? {
        guard var window = windows[windowID] else { return nil }
        markViewed(window)
        let occurrenceID = TabOccurrenceID()
        tabs[occurrenceID] = BrowserTab(id: tabID, occurrenceID: occurrenceID, windowID: windowID,
                                        spaceID: spaceID, url: url)
        window.occurrenceIDsBySpace[spaceID, default: []].append(occurrenceID)
        if activate, window.selectedOccurrenceBySpace[spaceID] != occurrenceID {
            window.selectedOccurrenceBySpace[spaceID] = occurrenceID
            if spaceID == window.activeSpaceID { window.revision &+= 1 }
        }
        windows[windowID] = window
        markViewed(window)
        publishOrganizationChange()
        return occurrenceID
    }

    func occurrences(in window: WindowRecord) -> [BrowserTab] {
        window.occurrenceIDsBySpace.values.flatMap { $0.compactMap { tabs[$0] } }
    }

    func visibleSelectedTabID(in window: WindowRecord) -> TabID? {
        window.selectedOccurrenceBySpace[window.activeSpaceID].flatMap { tabs[$0]?.id }
    }

    /// Stamps the window's visible tab as viewed now. Called before and after selection changes so
    /// the inactivity clock measures time since a tab was last on screen.
    func markViewed(_ window: WindowRecord?) {
        guard let window else { return }
        for visible in visibleTabIDs(in: window) { organization.touch(visible, at: clock()) }
    }

    /// Removes an occurrence from its Space list. Selection moves to the next neighbor, or the
    /// previous one at the end (same rule as closing).
    func detachOccurrence(_ occurrenceID: TabOccurrenceID, from spaceID: SpaceID, in window: inout WindowRecord) {
        var occurrenceIDs = window.occurrenceIDsBySpace[spaceID, default: []]
        guard let index = occurrenceIDs.firstIndex(of: occurrenceID) else { return }
        occurrenceIDs.remove(at: index)
        window.organizationFallbackOccurrences.remove(occurrenceID)
        if window.selectedOccurrenceBySpace[spaceID] == occurrenceID {
            window.selectedOccurrenceBySpace[spaceID] = occurrenceIDs.isEmpty
                ? nil : occurrenceIDs[min(index, occurrenceIDs.count - 1)]
            if spaceID == window.activeSpaceID { window.revision &+= 1 }
        }
        window.occurrenceIDsBySpace[spaceID] = occurrenceIDs
    }

    func dropOccurrence(_ occurrenceID: TabOccurrenceID, in windowID: WindowID) {
        guard var window = windows[windowID], let tab = tabs[occurrenceID] else { return }
        markViewed(window)
        detachOccurrence(occurrenceID, from: tab.spaceID, in: &window)
        tabs.removeValue(forKey: occurrenceID)
        windows[windowID] = window
        markViewed(window)
    }

    /// Keeps the same live occurrence (and surface) when its tab changes Space within one profile.
    func relocateOccurrence(_ occurrenceID: TabOccurrenceID, to spaceID: SpaceID, in windowID: WindowID) {
        guard var window = windows[windowID], let tab = tabs[occurrenceID], tab.spaceID != spaceID else { return }
        markViewed(window)
        detachOccurrence(occurrenceID, from: tab.spaceID, in: &window)
        window.occurrenceIDsBySpace[spaceID, default: []].append(occurrenceID)
        tabs[occurrenceID] = BrowserTab(id: tab.id, occurrenceID: occurrenceID, windowID: windowID,
                                        spaceID: spaceID, url: tab.url)
        windows[windowID] = window
        markViewed(window)
    }

    /// Enforces the occurrence invariants after an organization change, in every window:
    /// an occurrence's logical tab exists; Pinned/Today occurrences live in that tab's Space (moved
    /// within a profile, dropped across profiles); Favorite occurrences stay in their profile; at most
    /// one occurrence per logical tab per window.
    func reconcileOccurrences() {
        let spaceRank = Dictionary(uniqueKeysWithValues: spaceOrder.enumerated().map { ($1, $0) })
        for windowID in windows.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            guard let window = windows[windowID] else { continue }
            var claimed: Set<TabID> = []
            var drops: [TabOccurrenceID] = []
            var moves: [(TabOccurrenceID, SpaceID)] = []
            let groups = window.occurrenceIDsBySpace.keys.sorted {
                (spaceRank[$0] ?? .max, $0.rawValue.uuidString) < (spaceRank[$1] ?? .max, $1.rawValue.uuidString)
            }
            for spaceID in groups {
                for occurrenceID in window.occurrenceIDsBySpace[spaceID] ?? [] {
                    guard let tab = tabs[occurrenceID] else { continue }
                    guard let section = organization.section(of: .tab(tab.id)), claimed.insert(tab.id).inserted else {
                        drops.append(occurrenceID)
                        continue
                    }
                    switch section {
                    case let .favorites(profileID):
                        if spaces[spaceID]?.profileID != profileID { drops.append(occurrenceID) }
                    case let .pinned(target), let .today(target):
                        guard target != spaceID else { break }
                        if spaces[target]?.profileID == spaces[spaceID]?.profileID {
                            moves.append((occurrenceID, target))
                        } else {
                            drops.append(occurrenceID)
                        }
                    }
                }
            }
            for occurrenceID in drops { dropOccurrence(occurrenceID, in: windowID) }
            for (occurrenceID, target) in moves { relocateOccurrence(occurrenceID, to: target, in: windowID) }
            ensureVisibleSplitOccurrences(in: windowID)
            if windows[windowID]?.revision != window.revision {
                windows[windowID]?.recordReconciliation(from: window.revision)
            }
        }
    }

    private func selectionAnchors(including windowID: WindowID?, displacedTab: TabID? = nil) -> [WindowID: BrowserOrganizationSelectionAnchor] {
        windows.compactMapValues { window in
            // A window that has never acquired a page in this Space stays dormant. Previously
            // populated windows participate even when the archive temporarily emptied them.
            guard window.id == windowID || window.occurrenceIDsBySpace[window.activeSpaceID] != nil else { return nil }
            guard let snapshot = try? organizationSnapshot(for: window.id) else { return nil }
            return BrowserOrganizationSelectionAnchor(spaceID: window.activeSpaceID,
                orderedTabs: snapshot.allTabs.map(\.id),
                selectedTab: window.id == windowID ? displacedTab ?? snapshot.selectedTab?.id : snapshot.selectedTab?.id)
        }
    }

    /// Archive edits may remove every live occurrence while leaving dormant sidebar tabs.
    /// Keep a surviving selection; otherwise load the next logical neighbour, then the previous
    /// one at the end. Replays restore their recorded selection before using this fallback.
    private func recoverSelections(_ anchors: [WindowID: BrowserOrganizationSelectionAnchor]) {
        for (windowID, anchor) in anchors {
            guard let window = windows[windowID], window.activeSpaceID == anchor.spaceID,
                  visibleSelectedTabID(in: window) == nil,
                  let snapshot = try? organizationSnapshot(for: windowID) else { continue }
            let available = Set(snapshot.allTabs.map(\.id))
            var candidates: [TabID] = []
            if let selected = anchor.selectedTab, let index = anchor.orderedTabs.firstIndex(of: selected) {
                candidates = Array(anchor.orderedTabs[index...]) + anchor.orderedTabs[..<index].reversed()
            }
            candidates += snapshot.allTabs.map(\.id)
            guard let target = candidates.first(where: available.contains),
                  let context = try? captureContext(in: windowID) else { continue }
            let previous = Set(occurrences(in: window).map(\.occurrenceID))
            _ = try? selectTab(target, from: context)
            if var recovered = windows[windowID] {
                let created = Set(occurrences(in: recovered).map(\.occurrenceID)).subtracting(previous)
                recovered.organizationFallbackOccurrences = window.organizationFallbackOccurrences.union(created)
                windows[windowID] = recovered
            }
            windows[windowID]?.recordReconciliation(from: window.revision)
        }
    }

    /// The window's current state when every change since `context` came from reconciling its
    /// occurrences after an organization change (another window's command, a replay, a sweep):
    /// same Space and profile, only selection and revision moved. Nil for any other change, such as
    /// an out-of-band selection or a Space round trip, which a session must keep refusing.
    /// `revision` replaces the context's when the caller's own mutation advanced it.
    public func windowState(
        adoptingOrganizationChangesSince context: BrowserContext, revision: UInt64? = nil
    ) throws -> BrowserWindowState? {
        let known = revision ?? context.revision
        guard context.storeGeneration == storeGeneration, let window = windows[context.windowID],
              window.activeSpaceID == context.spaceID, spaces[context.spaceID]?.profileID == context.profileID,
              let span = window.reconciledRevisions, span.upperBound == window.revision,
              span.lowerBound <= known, known < window.revision else { return nil }
        return try captureWindowState(in: context.windowID)
    }

    // MARK: Commit

    /// Mutates a copy, validates it, then commits in one actor turn: undo record, occurrence
    /// reconciliation and publication. A thrown error leaves the model untouched.
    @discardableResult
    func commitOrganization(
        _ action: BrowserOrganizationAction? = nil, in context: BrowserContext? = nil,
        effects explicitEffects: BrowserOrganizationWindowEffects? = nil, validating: Bool = true,
        _ mutate: (inout BrowserOrganizationState) throws -> Void
    ) throws -> BrowserOrganizationPatch? {
        var next = organization
        next.changes = BrowserOrganizationChangeSet()
        try mutate(&next)
        next.normalizeSplits()
        next.normalizeArchivedSpaces()
        let changes = next.changes
        guard !changes.isEmpty else { return nil }
        if validating { try validateOrganization(next) }
        var patch = BrowserOrganizationPatch(from: organization, to: next, changes: changes)
        next.stampPlacements(&patch)
        let effects = explicitEffects ?? context.flatMap { context in
            windows[context.windowID].map { windowEffects(of: patch, in: $0) }
        }
        next.changes = BrowserOrganizationChangeSet()
        let anchors = patch.archive.isEmpty ? [:] : selectionAnchors(including: context?.windowID,
            displacedTab: explicitEffects?.selectedTab)
        organization = next
        if !changes.nodes.isEmpty { reconcileOccurrences() }
        recoverSelections(anchors)
        if let action, let context, !patch.isEmpty {
            // Selection is restored only when this command displaced it, never stolen back later.
            var displaced = effects?.selectedTab
            if explicitEffects == nil, let window = windows[context.windowID],
               visibleSelectedTabID(in: window) == displaced {
                displaced = nil
            }
            recordUndo(BrowserOrganizationUndoRecord(action: action, profileID: context.profileID,
                spaceID: context.spaceID, patch: patch, liveTabs: effects?.liveTabs ?? [],
                selectedTab: displaced), in: context.windowID)
        }
        publishOrganizationChange()
        return patch
    }

    func validateOrganization(_ state: BrowserOrganizationState) throws {
        try state.validate(profiles: Set(profiles.keys), spaces: spaces.mapValues(\.profileID))
    }

    /// Computed against the state before the command, so a moved folder brings its descendants.
    func windowEffects(of patch: BrowserOrganizationPatch, in window: WindowRecord) -> BrowserOrganizationWindowEffects {
        let affected = patch.affectedTabIDs(in: organization)
        let live = Set(occurrences(in: window).map(\.id)).intersection(affected)
        let selected = visibleSelectedTabID(in: window).flatMap { affected.contains($0) ? $0 : nil }
        return BrowserOrganizationWindowEffects(liveTabs: live, selectedTab: selected)
    }

    func recordUndo(_ record: BrowserOrganizationUndoRecord, in windowID: WindowID) {
        var journal = organizationJournals[windowID] ?? BrowserOrganizationJournal()
        journal.recordedCount &+= 1
        var record = record
        record.id = journal.recordedCount
        journal.undo.append(record)
        if journal.undo.count > BrowserOrganizationJournal.limit { journal.undo.removeFirst() }
        journal.redo = []
        organizationJournals[windowID] = journal
    }

    // MARK: Hooks from the base store

    /// A freshly opened tab is a new logical tab in Today of its Space.
    func organizationDidOpen(_ tab: BrowserTab) {
        let now = clock()
        let entry = BrowserOrganizedTab(id: tab.id, url: tab.url, createdAt: now, lastActiveAt: now)
        _ = try? commitOrganization { state in
            state.addTab(entry, into: .today(tab.spaceID), at: Self.insertsNewTodayTabsAtTop ? 0 : .max)
        }
    }

    func organizationDidUpdateDestination(of tabID: TabID, to url: URL) {
        _ = try? commitOrganization(validating: false) { state in
            state.updateTab(tabID) { $0.url = url }
        }
    }

    func organizationDidClose(_ tab: BrowserTab, wasVisibleSelection: Bool, journalingIn context: BrowserContext?) {
        var published = false
        switch organization.section(of: .tab(tab.id)) {
        case let .today(spaceID)?:
            guard let profileID = spaces[spaceID]?.profileID else { break }
            let effects = BrowserOrganizationWindowEffects(liveTabs: [tab.id],
                                                           selectedTab: wasVisibleSelection ? tab.id : nil)
            let now = clock()
            published = (try? commitOrganization(.closeTabs, in: context, effects: effects) { state in
                state.archiveTab(tab.id, reason: .closed, origin: .today, profileID: profileID,
                                 spaceID: spaceID, at: now)
            }) != nil
        case .pinned?, .favorites?:
            published = (try? commitOrganization(validating: false) { state in
                state.updateTab(tab.id) { if let pinnedURL = $0.pinnedURL { $0.url = pinnedURL } }
            }) != nil
        case nil:
            break
        }
        if !published { publishOrganizationChange() }
    }

    /// For a future profile deletion, called before the profile and its Spaces leave the store:
    /// purges their Favorites, sections, auto-archive override and archive records, and every
    /// undo record of the profile, so the document stays valid (`profileThresholds`, Favorites and
    /// archive records may only name existing profiles). Not undoable.
    func organizationWillRemoveProfile(_ profileID: ProfileID) {
        let spaceIDs = Set(spaces.values.filter { $0.profileID == profileID }.map(\.id))
        _ = try? commitOrganization(validating: false) { $0.removeProfile(profileID, spaces: spaceIDs) }
        for (windowID, journal) in organizationJournals {
            organizationJournals[windowID] = BrowserOrganizationJournal(
                undo: journal.undo.filter { $0.profileID != profileID },
                redo: journal.redo.filter { $0.profileID != profileID },
                recordedCount: journal.recordedCount)
        }
        publishOrganizationChange()
    }

    func organizationDidCloseWindow(_ windowID: WindowID) {
        organizationJournals.removeValue(forKey: windowID)
        publishOrganizationChange()
    }

    // MARK: Moves

    public func moveItems(
        _ nodes: [BrowserOrganizationNode], to destination: BrowserOrganizationDestination,
        from context: BrowserContext
    ) throws -> BrowserWindowState {
        try performMove(nodes, to: destination, action: nil, from: context)
    }

    public func pinTabs(_ ids: [TabID], from context: BrowserContext) throws -> BrowserWindowState {
        try performMove(organization.groupedNodes(for: ids), to: .init(.pinned(context.spaceID), position: .end),
                        action: .pinTabs, from: context)
    }

    public func unpinTabs(_ ids: [TabID], from context: BrowserContext) throws -> BrowserWindowState {
        try performMove(organization.groupedNodes(for: ids), to: .init(.today(context.spaceID), position: .start),
                        action: .unpinTabs, from: context)
    }

    public func addToFavorites(_ ids: [TabID], from context: BrowserContext) throws -> BrowserWindowState {
        try performMove(organization.groupedNodes(for: ids), to: .init(.favorites(context.profileID), position: .end),
                        action: .addToFavorites, from: context)
    }

    public func removeFromFavorites(_ ids: [TabID], from context: BrowserContext) throws -> BrowserWindowState {
        try performMove(organization.groupedNodes(for: ids), to: .init(.today(context.spaceID), position: .start),
                        action: .removeFromFavorites, from: context)
    }

    public func togglePinSelectedTab(from context: BrowserContext) throws -> BrowserWindowState {
        let window = try organizationWindow(context)
        guard let tabID = visibleSelectedTabID(in: window) else { throw BrowserOrganizationError.itemMissing }
        let grouped = organization.container(of: .tab(tabID))?.owningNode?.splitID.flatMap { organization.splits[$0]?.tabIDs } ?? [tabID]
        if case .today = try visibleSection(of: .tab(tabID), in: context) {
            return try pinTabs(grouped, from: context)
        }
        return try unpinTabs(grouped, from: context)
    }

    func performMove(
        _ nodes: [BrowserOrganizationNode], to destination: BrowserOrganizationDestination,
        action explicitAction: BrowserOrganizationAction?, from context: BrowserContext
    ) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        guard !nodes.isEmpty else { throw BrowserOrganizationError.emptySelection }
        let sources = try nodes.map { try visibleSection(of: $0, in: context) }
        let target = try destinationSection(of: destination.container, in: context)
        let action = explicitAction ?? Self.moveAction(from: sources, to: target)
        try commitOrganization(action, in: context) { state in
            try state.move(nodes, to: destination, destinationSection: target)
        }
        return try captureWindowState(in: context.windowID)
    }

    static func moveAction(
        from sources: [BrowserOrganizationSection], to target: BrowserOrganizationSection
    ) -> BrowserOrganizationAction {
        func all(_ predicate: (BrowserOrganizationSection) -> Bool) -> Bool { sources.allSatisfy(predicate) }
        let isToday: (BrowserOrganizationSection) -> Bool = { if case .today = $0 { return true }; return false }
        let isFavorite: (BrowserOrganizationSection) -> Bool = { if case .favorites = $0 { return true }; return false }
        switch target {
        case .favorites: return all(isFavorite) ? .moveItems : .addToFavorites
        case .pinned: return all(isToday) ? .pinTabs : all(isFavorite) ? .removeFromFavorites : .moveItems
        case .today: return all(isToday) ? .moveItems : all(isFavorite) ? .removeFromFavorites : .unpinTabs
        }
    }

    // MARK: Folders

    /// Creates a folder in Pinned or inside another folder, optionally moving nodes into it, in one
    /// undoable transaction ("New Folder" from a selection).
    public func createFolder(
        title: String, at destination: BrowserOrganizationDestination,
        containing nodes: [BrowserOrganizationNode] = [], from context: BrowserContext
    ) throws -> (FolderID, BrowserWindowState) {
        _ = try organizationWindow(context)
        let title = try BrowserOrganizationState.validatedTitle(title)
        let target = try destinationSection(of: destination.container, in: context)
        guard target.acceptsFolders else { throw BrowserOrganizationError.invalidDestination }
        for node in nodes { _ = try visibleSection(of: node, in: context) }
        let folder = BrowserOrganizedFolder(id: FolderID(), title: title, createdAt: clock())
        try commitOrganization(.createFolder, in: context) { state in
            let index = try state.insertionIndex(in: destination.container, position: destination.position)
            state.addFolder(folder, into: destination.container, at: index)
            if !nodes.isEmpty {
                try state.move(nodes, to: .init(.folder(folder.id), position: .end), destinationSection: target)
            }
        }
        return (folder.id, try captureWindowState(in: context.windowID))
    }

    public func renameFolder(_ id: FolderID, to title: String, from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        _ = try visibleSection(of: .folder(id), in: context)
        let title = try BrowserOrganizationState.validatedTitle(title)
        try commitOrganization(.renameFolder, in: context) { $0.renameFolder(id, to: title) }
        return try captureWindowState(in: context.windowID)
    }

    /// Collapse state is view state: persisted and shared by the Space's windows, never undone.
    public func setFolderCollapsed(_ id: FolderID, _ collapsed: Bool, from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        _ = try visibleSection(of: .folder(id), in: context)
        try commitOrganization(validating: false) { $0.setFolderCollapsed(id, collapsed) }
        return try captureWindowState(in: context.windowID)
    }

    public func setAllFoldersCollapsed(_ collapsed: Bool, from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        try commitOrganization(validating: false) { state in
            for root in state.pinned[context.spaceID] ?? [] {
                for id in state.folderIDs(in: root) { state.setFolderCollapsed(id, collapsed) }
            }
        }
        return try captureWindowState(in: context.windowID)
    }

    public func setPinnedSectionCollapsed(_ collapsed: Bool, from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        try commitOrganization(validating: false) { $0.setPinnedSectionCollapsed(context.spaceID, collapsed) }
        return try captureWindowState(in: context.windowID)
    }

    public func deleteFolder(
        _ id: FolderID, contents disposition: BrowserFolderDeletion, from context: BrowserContext
    ) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        _ = try visibleSection(of: .folder(id), in: context)
        let now = clock()
        try commitOrganization(.deleteFolder, in: context) { state in
            switch disposition {
            case .keepContents:
                guard let placement = state.placement(of: .folder(id)) else { throw BrowserOrganizationError.itemMissing }
                let children = state.children(of: .folder(id))
                state.detach(all: children)
                state.insert(children, into: placement.container, at: placement.index + 1)
                state.removeEmptyFolder(id)
            case .archiveContents:
                state.archiveTabs(state.tabIDs(in: .folder(id)).map {
                    .init(id: $0, reason: .removed, origin: .pinned, profileID: context.profileID, spaceID: context.spaceID)
                }, at: now)
                for folderID in state.folderIDs(in: .folder(id)).reversed() { state.removeEmptyFolder(folderID) }
            }
        }
        return try captureWindowState(in: context.windowID)
    }

    // MARK: Titles and pinned URLs

    public func renameTab(_ id: TabID, to title: String?, from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        _ = try visibleSection(of: .tab(id), in: context)
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let customTitle = trimmed.isEmpty ? nil : try BrowserOrganizationState.validatedTitle(trimmed)
        try commitOrganization(.renameTab, in: context) { state in
            state.updateTab(id) { $0.customTitle = customTitle }
        }
        return try captureWindowState(in: context.windowID)
    }

    /// Updates the web title of an exact occurrence, like `updateDestination(to:from:validating:)`.
    @discardableResult
    public func updatePageTitle(
        _ title: String?, from authority: BrowserOccurrenceAuthority, validating context: BrowserContext? = nil
    ) throws -> Bool {
        guard authority.storeGeneration == storeGeneration,
              let window = windows[authority.windowID],
              spaces[authority.spaceID]?.profileID == authority.profileID else {
            throw BrowserStoreError.staleContext
        }
        if let context {
            guard context.windowID == authority.windowID, isCurrent(context) else { throw BrowserStoreError.staleContext }
        }
        guard let tab = tabs[authority.occurrenceID],
              window.occurrenceIDsBySpace[authority.spaceID, default: []].contains(authority.occurrenceID) else {
            throw BrowserStoreError.tabMissing
        }
        guard tab.windowID == authority.windowID, tab.spaceID == authority.spaceID else {
            throw BrowserStoreError.occurrenceOwnedByAnotherWindow
        }
        let pageTitle = BrowserOrganizationState.sanitizedPageTitle(title)
        return try commitOrganization(validating: false) { state in
            state.updateTab(tab.id) { $0.pageTitle = pageTitle }
        } != nil
    }

    public func resetTabToPinnedURL(
        _ id: TabID, from context: BrowserContext
    ) throws -> (BrowserOrganizationReset, BrowserWindowState) {
        let window = try organizationWindow(context)
        _ = try visibleSection(of: .tab(id), in: context)
        guard let reset = resetToPinnedURL(id, in: window) else { throw BrowserOrganizationError.notPinned }
        return (reset, try captureWindowState(in: context.windowID))
    }

    public func resetPinnedTabs(from context: BrowserContext) throws -> ([BrowserOrganizationReset], BrowserWindowState) {
        let window = try organizationWindow(context)
        let local = Dictionary(occurrences(in: window).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resets: [BrowserOrganizationReset] = []
        for root in organization.pinned[context.spaceID] ?? [] {
            for id in organization.tabIDs(in: root) {
                guard let entry = organization.tabs[id], let pinnedURL = entry.pinnedURL,
                      (local[id]?.url ?? entry.url) != pinnedURL,
                      let reset = resetToPinnedURL(id, in: window) else { continue }
                resets.append(reset)
            }
        }
        return (resets, try captureWindowState(in: context.windowID))
    }

    private func resetToPinnedURL(_ id: TabID, in window: WindowRecord) -> BrowserOrganizationReset? {
        guard let pinnedURL = organization.tabs[id]?.pinnedURL else { return nil }
        _ = try? commitOrganization(validating: false) { $0.updateTab(id) { $0.url = pinnedURL } }
        let local = occurrences(in: window).first { $0.id == id }
        if let local, local.url != pinnedURL {
            tabs[local.occurrenceID] = BrowserTab(id: local.id, occurrenceID: local.occurrenceID,
                windowID: local.windowID, spaceID: local.spaceID, url: pinnedURL)
        }
        return BrowserOrganizationReset(tabID: id, url: pinnedURL, occurrenceID: local?.occurrenceID)
    }

    // MARK: Archive

    /// Removes tabs from the sidebar into the archive: Today tabs with reason `.closed`, Favorites
    /// and Pinned tabs with reason `.removed`. Undoable as one transaction.
    public func archiveTabs(_ ids: [TabID], from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        let targets = try uniqueVisibleTabs(ids, in: context)
        let now = clock()
        try commitOrganization(.archiveTabs, in: context) { state in
            state.archiveTabs(targets.map { id, section in
                let isToday: Bool = { if case .today = section { return true }; return false }()
                return .init(id: id, reason: isToday ? .closed : .removed, origin: Self.origin(of: section),
                             profileID: context.profileID, spaceID: context.spaceID)
            }, at: now)
        }
        return try captureWindowState(in: context.windowID)
    }

    /// ⌘W on a multi-selection: Today tabs are archived (one undoable transaction); Favorite and
    /// Pinned tabs are unloaded from this window and return to their pinned URL.
    public func closeTabs(_ ids: [TabID], from context: BrowserContext) throws -> BrowserWindowState {
        let window = try organizationWindow(context)
        let targets = try uniqueVisibleTabs(ids, in: context)
        let todayTabs = targets.filter { if case .today = $0.1 { return true }; return false }.map(\.0)
        let otherTabs = targets.filter { if case .today = $0.1 { return false }; return true }.map(\.0)
        let now = clock()
        if !todayTabs.isEmpty {
            try commitOrganization(.closeTabs, in: context) { state in
                state.archiveTabs(todayTabs.map {
                    .init(id: $0, reason: .closed, origin: .today, profileID: context.profileID, spaceID: context.spaceID)
                }, at: now)
            }
        }
        for id in otherTabs {
            if let local = occurrences(in: window).first(where: { $0.id == id }) {
                dropOccurrence(local.occurrenceID, in: context.windowID)
            }
            _ = try? commitOrganization(validating: false) { state in
                state.updateTab(id) { if let pinnedURL = $0.pinnedURL { $0.url = pinnedURL } }
            }
        }
        if !otherTabs.isEmpty { publishOrganizationChange() }
        return try captureWindowState(in: context.windowID)
    }

    public func clearTodayTabs(protecting protected: Set<TabID> = [], from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        let now = clock()
        try commitOrganization(.clearToday, in: context) { state in
            let cleared = state.todayBlocks(in: context.spaceID).filter { Set($0).isDisjoint(with: protected) }.flatMap { $0 }
            state.archiveTabs(cleared.map {
                .init(id: $0, reason: .cleared, origin: .today, profileID: context.profileID, spaceID: context.spaceID)
            }, at: now)
        }
        return try captureWindowState(in: context.windowID)
    }

    /// Restores an archived tab of the context's profile to the top of Today in its original Space,
    /// or in the current Space if the original no longer belongs to the profile. With `activate`, the
    /// window switches to that Space and selects the tab. Identity and custom title are preserved.
    public func restoreArchivedTab(_ id: TabID, activate: Bool, from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        guard let record = organization.archivedTab(id) else { throw BrowserOrganizationError.archivedTabMissing }
        guard record.profileID == context.profileID else { throw BrowserOrganizationError.notVisibleInContext }
        let target = spaces[record.spaceID]?.profileID == record.profileID ? record.spaceID : context.spaceID
        var tab = record.tab
        tab.pinnedURL = nil
        tab.lastActiveAt = clock()
        try commitOrganization(.restoreArchivedTab, in: context) { state in
            state.removeArchive(id)
            state.addTab(tab, into: .today(target), at: Self.insertsNewTodayTabsAtTop ? 0 : .max)
        }
        if activate {
            if target != context.spaceID { try activateSpace(target, in: context.windowID) }
            _ = try selectTab(id, from: captureContext(in: context.windowID))
        }
        return try captureWindowState(in: context.windowID)
    }

    public func restoreMostRecentArchivedTab(from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        guard let record = organization.archive.first(where: {
            $0.profileID == context.profileID && $0.reason != .automatic
        }) else { throw BrowserOrganizationError.archivedTabMissing }
        return try restoreArchivedTab(record.id, activate: true, from: context)
    }

    public func deleteArchivedTabs(_ ids: [TabID], from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        for id in ids {
            guard let record = organization.archivedTab(id) else { throw BrowserOrganizationError.archivedTabMissing }
            guard record.profileID == context.profileID else { throw BrowserOrganizationError.notVisibleInContext }
        }
        try commitOrganization(.deleteArchivedTabs, in: context) { state in
            for id in ids { state.removeArchive(id) }
        }
        return try captureWindowState(in: context.windowID)
    }

    public func clearArchive(from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        let ids = organization.archive.filter { $0.profileID == context.profileID }.map(\.id)
        organization.archivedSpaces.removeAll { $0.space.profileID == context.profileID }
        publishOrganizationChange()
        guard !ids.isEmpty else { return try captureWindowState(in: context.windowID) }
        return try deleteArchivedTabs(ids, from: context)
    }

    /// Archives Today tabs whose last view is at least their profile's threshold old. Favorites and
    /// Pinned tabs are exempt by construction; the visible tab of every window and `protected`
    /// (media, Peek, split panes, as decided by the shell) are skipped. Not undoable.
    @discardableResult
    public func archiveExpiredTabs(protecting protected: Set<TabID> = []) -> [BrowserArchivedTab] {
        let now = clock()
        let visible = Set(windows.values.flatMap(visibleTabIDs(in:)))
        var archived: [BrowserArchivedTab] = []
        _ = try? commitOrganization { state in
            for spaceID in spaceOrder {
                guard let space = spaces[spaceID],
                      let interval = state.policy.threshold(for: space.profileID).interval else { continue }
                let expired = state.todayBlocks(in: spaceID).filter { block in
                    block.allSatisfy { id in
                        guard !protected.contains(id), !visible.contains(id), let tab = state.tabs[id] else { return false }
                        return now.timeIntervalSince(tab.lastActiveAt) >= interval
                    }
                }.flatMap { $0 }
                archived += state.archiveTabs(expired.map {
                    .init(id: $0, reason: .automatic, origin: .today, profileID: space.profileID, spaceID: spaceID)
                }, at: now)
            }
        }
        return archived
    }

    public func setDefaultAutoArchiveThreshold(_ threshold: BrowserAutoArchiveThreshold) throws {
        guard threshold.isValid else { throw BrowserOrganizationError.invalidThreshold }
        var policy = organization.policy
        policy.defaultThreshold = threshold
        try commitOrganization { $0.setPolicy(policy) }
    }

    /// A nil threshold makes the profile inherit the default again.
    public func setAutoArchiveThreshold(_ threshold: BrowserAutoArchiveThreshold?, forProfile profileID: ProfileID) throws {
        guard profiles[profileID] != nil else { throw BrowserStoreError.profileMissing }
        guard threshold?.isValid ?? true else { throw BrowserOrganizationError.invalidThreshold }
        var policy = organization.policy
        policy.profileThresholds[profileID] = threshold
        try commitOrganization { $0.setPolicy(policy) }
    }

    /// Applies one setting to every existing profile and to profiles created later, atomically.
    public func setAutoArchiveThresholdForAllProfiles(_ threshold: BrowserAutoArchiveThreshold, fromProfile profileID: ProfileID) throws {
        guard profiles[profileID] != nil else { throw BrowserStoreError.profileMissing }
        guard threshold.isValid else { throw BrowserOrganizationError.invalidThreshold }
        var policy = organization.policy
        policy.defaultThreshold = threshold
        policy.profileThresholds.removeAll()
        try commitOrganization { $0.setPolicy(policy) }
    }

    /// The cap applies to each profile. Lowering it purges each profile's oldest records immediately.
    public func setMaximumArchivedTabs(_ limit: Int) throws {
        guard limit >= 0 else { throw BrowserOrganizationError.invalidThreshold }
        var policy = organization.policy
        policy.maximumArchivedTabs = limit
        try commitOrganization { state in
            state.setPolicy(policy)
            state.capArchive()
        }
    }

    // MARK: Undo

    /// Undoes this window's latest organization command if it belongs to the context's profile.
    /// A conflicting record (its items changed since) is discarded and reported.
    public func undoOrganization(from context: BrowserContext) throws -> BrowserWindowState {
        try replayOrganization(from: context, undoing: true)
    }

    public func redoOrganization(from context: BrowserContext) throws -> BrowserWindowState {
        try replayOrganization(from: context, undoing: false)
    }

    /// The candidate comparison and replay share this actor turn. A changed candidate returns
    /// nil without modifying the organization, journal, occurrences or publication revision.
    public func undoOrganization(from context: BrowserContext, expectedRecordID: UInt64) throws -> BrowserWindowState? {
        try replayOrganization(from: context, undoing: true, ifCandidateIs: expectedRecordID)
    }

    public func redoOrganization(from context: BrowserContext, expectedRecordID: UInt64) throws -> BrowserWindowState? {
        try replayOrganization(from: context, undoing: false, ifCandidateIs: expectedRecordID)
    }

    private func replayOrganization(
        from context: BrowserContext, undoing: Bool, ifCandidateIs expectedRecordID: UInt64
    ) throws -> BrowserWindowState? {
        _ = try organizationWindow(context)
        let journal = organizationJournals[context.windowID] ?? BrowserOrganizationJournal()
        let records = undoing ? journal.undo : journal.redo
        guard replayCandidate(in: records, undoing: undoing, profileID: context.profileID,
                              windowID: context.windowID)?.id == expectedRecordID else { return nil }
        return try replayOrganization(from: context, undoing: undoing)
    }

    /// Replays the newest record of the context's profile whose preconditions hold. Newer records
    /// that conflict with a change made since (see `canReplay`) are discarded on the way: the menu
    /// already named the record that runs, so ⌘Z never silently overwrites another window's edit.
    /// A record that passes its preconditions but fails structural validation (e.g. a cycle formed
    /// by another window's move) is discarded and reported, without trying older records.
    private func replayOrganization(from context: BrowserContext, undoing: Bool) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        var journal = organizationJournals[context.windowID] ?? BrowserOrganizationJournal()
        var discarded = false
        while let record = undoing ? journal.undo.last : journal.redo.last, record.profileID == context.profileID {
            if undoing { journal.undo.removeLast() } else { journal.redo.removeLast() }
            let patch = undoing ? record.patch.reversed : record.patch
            guard canReplay(patch, issuedIn: context.windowID) else {
                discarded = true
                continue
            }
            var next = organization
            next.changes = BrowserOrganizationChangeSet()
            do {
                try next.apply(patch, preconditionsChecked: true)
                next.normalizeArchivedSpaces()
                try validateOrganization(next)
            } catch {
                discarded = true
                break
            }
            next.changes = BrowserOrganizationChangeSet()
            var replayed = record
            replayed.patch.recordEvictions(from: organization, to: next, replaying: patch, undoing: undoing)
            let anchors = record.patch.archive.isEmpty ? [:] : selectionAnchors(including: context.windowID)
            organization = next
            if undoing { journal.redo.append(replayed) } else { journal.undo.append(replayed) }
            organizationJournals[context.windowID] = journal
            reconcileOccurrences()
            if undoing { restoreWindowEffects(of: record, in: context.windowID) }
            recoverSelections(anchors)
            publishOrganizationChange()
            return try captureWindowState(in: context.windowID)
        }
        organizationJournals[context.windowID] = journal
        guard !discarded else {
            publishOrganizationChange()
            throw BrowserOrganizationError.undoConflict
        }
        throw undoing ? BrowserOrganizationError.nothingToUndo : BrowserOrganizationError.nothingToRedo
    }

    /// The record ⌘Z (or ⇧⌘Z) would replay now, for the snapshot's menu label.
    func replayCandidate(
        in records: [BrowserOrganizationUndoRecord], undoing: Bool, profileID: ProfileID, windowID: WindowID
    ) -> BrowserOrganizationUndoRecord? {
        for record in records.reversed() {
            guard record.profileID == profileID else { return nil }
            if canReplay(undoing ? record.patch.reversed : record.patch, issuedIn: windowID) { return record }
        }
        return nil
    }

    /// Replays only keys still holding this command’s values and preserves other windows’ live tabs.
    func canReplay(_ patch: BrowserOrganizationPatch, issuedIn windowID: WindowID) -> Bool {
        guard organization.canApply(patch) else { return false }
        let removed = Set(patch.removedTabIDs)
        for (otherID, window) in windows where otherID != windowID {
            let claimed = Set(occurrences(in: window).filter {
                !window.organizationFallbackOccurrences.contains($0.occurrenceID)
            }.map(\.id))
            if !removed.isDisjoint(with: claimed) { return false }
            guard let space = spaces[window.activeSpaceID] else { continue }
            for visible in visibleTabIDs(in: window) where claimed.contains(visible) {
                let before = organization.section(of: .tab(visible))
                let after = organization.section(of: .tab(visible), applying: patch)
                guard before != after, let before, Self.section(before, isVisibleIn: space) else { continue }
                guard let after, Self.section(after, isVisibleIn: space) else { return false }
            }
        }
        return true
    }

    static func section(_ section: BrowserOrganizationSection, isVisibleIn space: BrowserSpace) -> Bool {
        switch section {
        case let .favorites(profileID): return profileID == space.profileID
        case let .pinned(spaceID), let .today(spaceID): return spaceID == space.id
        }
    }

    /// Reopens tabs that were live in the issuing window and selects the one that was visible.
    private func restoreWindowEffects(of record: BrowserOrganizationUndoRecord, in windowID: WindowID) {
        guard let window = windows[windowID] else { return }
        let live = Set(occurrences(in: window).map(\.id))
        for id in record.liveTabs.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString })
        where !live.contains(id) {
            guard let entry = organization.tabs[id], let section = organization.section(of: .tab(id)) else { continue }
            let spaceID = section.spaceID ?? record.spaceID
            guard spaces[spaceID]?.profileID == record.profileID else { continue }
            openOccurrence(of: id, url: entry.url, in: windowID, spaceID: spaceID, activate: false)
        }
        guard let selected = record.selectedTab, let current = windows[windowID],
              current.activeSpaceID == record.spaceID,
              let occurrence = occurrences(in: current).first(where: { $0.id == selected }) else { return }
        if occurrence.spaceID != current.activeSpaceID {
            // Only a Favorite may follow the window into another Space of its profile.
            guard case .favorites? = organization.section(of: .tab(selected)) else { return }
            relocateOccurrence(occurrence.occurrenceID, to: current.activeSpaceID, in: windowID)
        }
        try? selectOccurrence(occurrence.occurrenceID, in: windowID)
    }

    // MARK: Live surface transfers

    /// A live document leaving this window for another owner (window, Peek, Little Orbit) takes its
    /// logical tab along: unlike closing, the tab is neither archived nor reset to its pinned URL.
    /// The occurrence is matched within its window and profile, even if it changed Space meanwhile.
    /// The context must still name the window's Space and profile; its selection may have been
    /// changed by the receiver moving the tab, which must not strand the released occurrence.
    public func releaseOwnedOccurrenceAndCaptureState(
        _ authority: BrowserOccurrenceAuthority, validating context: BrowserContext
    ) throws -> BrowserWindowState {
        guard context.storeGeneration == storeGeneration, authority.storeGeneration == storeGeneration,
              authority.windowID == context.windowID, let window = windows[context.windowID],
              window.activeSpaceID == context.spaceID,
              spaces[context.spaceID]?.profileID == context.profileID else { throw BrowserStoreError.staleContext }
        guard let tab = tabs[authority.occurrenceID] else { throw BrowserStoreError.tabMissing }
        guard tab.windowID == authority.windowID, spaces[tab.spaceID]?.profileID == authority.profileID else {
            throw BrowserStoreError.occurrenceOwnedByAnotherWindow
        }
        // A transferred pane must not leave a partly visible group or immediately reload the
        // released document. Retire that group's visible selection; its sidebar row stays shared.
        retireVisibleSplit(containing: tab.id, in: context.windowID)
        dropOccurrence(authority.occurrenceID, in: context.windowID)
        publishOrganizationChange()
        return try captureWindowState(in: context.windowID)
    }

    /// Reuses a same-profile occurrence when possible; otherwise creates a new Today tab.
    /// Replacements remove the old occurrence only after the transferred document can be recorded.
    public func openTransferredOccurrence(
        of tabID: TabID?, url: URL, from context: BrowserContext, activate: Bool,
        replacingExisting: Bool = false, expectedExistingOccurrenceID: TabOccurrenceID? = nil,
        movingTo destination: BrowserOrganizationDestination? = nil
    ) throws -> TabOccurrenceID {
        let window = try organizationWindow(context)
        try BrowserSessionDocument.validateDestination(url)
        guard let tabID, let section = organization.section(of: .tab(tabID)),
              profileID(of: section) == context.profileID else {
            if replacingExisting || destination != nil { throw BrowserStoreError.staleContext }
            return try openTab(url: url, from: context, activate: activate)
        }
        let existing = occurrences(in: window).first { $0.id == tabID }
        // A background occurrence can be replaced without changing selected context. Bind the
        // destructive opt-in to the exact occurrence (or absence) captured by the caller.
        if replacingExisting && existing?.occurrenceID != expectedExistingOccurrenceID {
            throw BrowserStoreError.staleContext
        }
        if existing != nil && !replacingExisting {
            return try openTab(url: url, from: context, activate: activate)
        }
        if let destination {
            let target = try destinationSection(of: destination.container, in: context)
            guard let space = spaces[context.spaceID], Self.section(target, isVisibleIn: space) else {
                throw BrowserOrganizationError.notVisibleInContext
            }
            // The live document is already reserved by the receiver. Commit placement and its
            // undo record before recording the new occurrence, without creating a second tab.
            try commitOrganization(.moveItems, in: context) { state in
                try state.move([.tab(tabID)], to: destination, destinationSection: target)
            }
        } else if (try? visibleSection(of: .tab(tabID), in: context)) == nil {
            try commitOrganization { state in
                try state.move([.tab(tabID)], to: .init(.today(context.spaceID), position: .start),
                               destinationSection: .today(context.spaceID))
            }
        }
        let replacesSelection = existing.map {
            $0.spaceID == context.spaceID && window.selectedOccurrenceBySpace[$0.spaceID] == $0.occurrenceID
        } ?? false
        if let existing { dropOccurrence(existing.occurrenceID, in: context.windowID) }
        organizationDidUpdateDestination(of: tabID, to: url)
        guard let occurrenceID = openOccurrence(of: tabID, url: url, in: context.windowID,
                                                spaceID: context.spaceID, activate: activate || replacesSelection) else {
            throw BrowserStoreError.windowMissing
        }
        return occurrenceID
    }

    // MARK: Context helpers

    func organizationWindow(_ context: BrowserContext) throws -> WindowRecord {
        guard isCurrent(context), let window = windows[context.windowID] else { throw BrowserStoreError.staleContext }
        return window
    }

    /// Only the active Space's Pinned/Today and the active profile's Favorites are addressable.
    func visibleSection(of node: BrowserOrganizationNode, in context: BrowserContext) throws -> BrowserOrganizationSection {
        guard organization.contains(node), let section = organization.section(of: node) else {
            throw BrowserOrganizationError.itemMissing
        }
        switch section {
        case let .favorites(profileID) where profileID == context.profileID: return section
        case let .pinned(spaceID) where spaceID == context.spaceID: return section
        case let .today(spaceID) where spaceID == context.spaceID: return section
        default: throw BrowserOrganizationError.notVisibleInContext
        }
    }

    func destinationSection(
        of container: BrowserOrganizationContainer, in context: BrowserContext
    ) throws -> BrowserOrganizationSection {
        let section: BrowserOrganizationSection
        switch container {
        case let .favorites(id):
            guard profiles[id] != nil else { throw BrowserStoreError.profileMissing }
            section = .favorites(id)
        case let .pinned(id):
            guard spaces[id] != nil else { throw BrowserStoreError.spaceMissing }
            section = .pinned(id)
        case let .today(id):
            guard spaces[id] != nil else { throw BrowserStoreError.spaceMissing }
            section = .today(id)
        case .split: throw BrowserOrganizationError.invalidDestination
        case let .folder(id):
            guard let found = organization.section(ofContainer: container), organization.folders[id] != nil else {
                throw BrowserOrganizationError.itemMissing
            }
            section = found
        }
        guard profileID(of: section) == context.profileID else { throw BrowserOrganizationError.crossProfileMove }
        return section
    }

    func profileID(of section: BrowserOrganizationSection) -> ProfileID? {
        switch section {
        case let .favorites(id): return id
        case let .pinned(id), let .today(id): return spaces[id]?.profileID
        }
    }

    private func uniqueVisibleTabs(
        _ ids: [TabID], in context: BrowserContext
    ) throws -> [(TabID, BrowserOrganizationSection)] {
        guard !ids.isEmpty else { throw BrowserOrganizationError.emptySelection }
        var seen: Set<TabID> = []
        return try ids.filter { seen.insert($0).inserted }.map { ($0, try visibleSection(of: .tab($0), in: context)) }
    }

    static func origin(of section: BrowserOrganizationSection) -> BrowserArchivedTab.Origin {
        switch section {
        case .favorites: return .favorites
        case .pinned: return .pinned
        case .today: return .today
        }
    }
}

extension BrowserOccurrenceAuthority {
    /// A live surface may follow its occurrence to another Space of the same profile and window.
    public func canRetainSurface(as next: BrowserOccurrenceAuthority) -> Bool {
        storeGeneration == next.storeGeneration && windowID == next.windowID
            && profileID == next.profileID && occurrenceID == next.occurrenceID
    }
}
