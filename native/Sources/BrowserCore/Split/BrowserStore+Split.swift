import Foundation

extension BrowserStore {
    public func createSplit(_ ids: [TabID], orientation: BrowserSplitOrientation = .horizontal,
                            from context: BrowserContext) throws -> (SplitGroupID, BrowserWindowState) {
        _ = try organizationWindow(context)
        guard (2...BrowserSplitGroup.maximumPanes).contains(ids.count), Set(ids).count == ids.count else {
            throw BrowserSplitError.invalidPaneCount
        }
        guard let first = ids.first, let placement = organization.placement(of: .tab(first)) else {
            throw BrowserOrganizationError.itemMissing
        }
        let section = try splitSection(of: .tab(first), in: context)
        for id in ids {
            guard try splitSection(of: .tab(id), in: context) == section else { throw BrowserSplitError.incompatibleSection }
            if case .split? = organization.container(of: .tab(id)) { throw BrowserSplitError.nestedSplit }
        }
        let insertion = try organization.insertionIndex(in: placement.container, position: .before(.tab(first)),
            moving: Set(ids.map(BrowserOrganizationNode.tab)))
        let group = BrowserSplitGroup(tabIDs: ids, orientation: orientation)
        try commitOrganization(.createSplit, in: context) { next in
            next.detach(all: ids.map(BrowserOrganizationNode.tab))
            next.splits[group.id] = BrowserSplitGroup(id: group.id, tabIDs: [], orientation: orientation)
            next.insert(.split(group.id), into: placement.container, at: insertion)
            next.insert(ids.map(BrowserOrganizationNode.tab), into: .split(group.id), at: 0)
            next.updateSplit(group.id) { $0.ratios = group.ratios }
        }
        ensureSplitOccurrences(group.id, in: context)
        let preferred = context.selectedOccurrenceID.flatMap { tabs[$0]?.id }.flatMap { ids.contains($0) ? $0 : nil } ?? first
        if let occurrence = occurrences(in: windows[context.windowID]!).first(where: { $0.id == preferred }) {
            try selectOccurrence(occurrence.occurrenceID, in: context.windowID)
        }
        return (group.id, try captureWindowState(in: context.windowID))
    }

    /// Adds a new blank pane, in one undoable graph transaction; no orphan tab on refusal.
    public func splitWithNewTab(url: URL, orientation: BrowserSplitOrientation = .horizontal,
                                from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        try BrowserSessionDocument.validateDestination(url)
        guard let selected = context.selectedOccurrenceID.flatMap({ tabs[$0]?.id }) else {
            throw BrowserSplitError.paneMissing
        }
        let section = try splitSection(of: .tab(selected), in: context)
        let existing = organization.container(of: .tab(selected))?.owningNode?.splitID
        if let existing, organization.splits[existing]!.tabIDs.count >= BrowserSplitGroup.maximumPanes {
            throw BrowserSplitError.invalidPaneCount
        }
        guard let location = organization.placement(of: .tab(selected)) else { throw BrowserSplitError.paneMissing }
        let id = TabID(), groupID = existing ?? SplitGroupID(), date = clock()
        let entry = BrowserOrganizedTab(id: id, url: url, pinnedURL: section.keepsPinnedURL ? url : nil,
                                        createdAt: date, lastActiveAt: date)
        try commitOrganization(existing == nil ? .createSplit : .addSplitPane, in: context) { next in
            if existing == nil {
                next.detach(.tab(selected))
                next.splits[groupID] = BrowserSplitGroup(id: groupID, tabIDs: [], orientation: orientation)
                next.insert(.split(groupID), into: location.container, at: location.index)
                next.insert(.tab(selected), into: .split(groupID), at: 0)
            }
            next.addTab(entry, into: .split(groupID), at: next.children(of: .split(groupID)).count)
            next.updateSplit(groupID) { $0.ratios = Array(repeating: 1 / Double($0.tabIDs.count), count: $0.tabIDs.count) }
        }
        ensureSplitOccurrences(groupID, in: context)
        if let occurrence = occurrences(in: windows[context.windowID]!).first(where: { $0.id == id }) {
            try selectOccurrence(occurrence.occurrenceID, in: context.windowID)
        }
        return try captureWindowState(in: context.windowID)
    }

    public func addPane(_ tabID: TabID, to groupID: SplitGroupID, at index: Int? = nil, orientation: BrowserSplitOrientation? = nil,
                        from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        let section = try splitSection(of: .split(groupID), in: context)
        guard let group = organization.splits[groupID], group.tabIDs.count < BrowserSplitGroup.maximumPanes else {
            throw BrowserSplitError.invalidPaneCount
        }
        guard try splitSection(of: .tab(tabID), in: context) == section else { throw BrowserSplitError.incompatibleSection }
        if case .split? = organization.container(of: .tab(tabID)) { throw BrowserSplitError.nestedSplit }
        try commitOrganization(.addSplitPane, in: context) { next in
            next.detach(.tab(tabID))
            next.insert(.tab(tabID), into: .split(groupID), at: index ?? group.tabIDs.count)
            next.updateSplit(groupID) {
                $0.ratios = Array(repeating: 1 / Double($0.tabIDs.count), count: $0.tabIDs.count)
                if let orientation { $0.orientation = orientation }
            }
        }
        ensureSplitOccurrences(groupID, in: context)
        return try captureWindowState(in: context.windowID)
    }

    public func unsplit(_ id: SplitGroupID, from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        _ = try splitSection(of: .split(id), in: context)
        try commitOrganization(.unsplit, in: context) { try $0.dissolveSplit(id) }
        return try captureWindowState(in: context.windowID)
    }

    public func setSplitOrientation(_ orientation: BrowserSplitOrientation, for id: SplitGroupID,
                                    from context: BrowserContext) throws -> BrowserWindowState {
        try mutateSplit(id, action: .orientSplit, from: context) { $0.orientation = orientation }
    }

    public func resizeSplit(_ id: SplitGroupID, ratios: [Double], expectedGroup: BrowserSplitGroup? = nil,
                            from context: BrowserContext) throws -> BrowserWindowState {
        if let expectedGroup, organization.splits[id] != expectedGroup { throw BrowserSplitError.staleLayout }
        guard let group = organization.splits[id], BrowserSplitGroup(id: id, tabIDs: group.tabIDs,
            orientation: group.orientation, ratios: ratios).isValid else { throw BrowserSplitError.invalidRatios }
        return try mutateSplit(id, action: .resizeSplit, from: context) { $0.ratios = ratios }
    }

    public func swapSplitPanes(_ id: SplitGroupID, first: Int, second: Int,
                               from context: BrowserContext) throws -> BrowserWindowState {
        guard let group = organization.splits[id], group.tabIDs.indices.contains(first),
              group.tabIDs.indices.contains(second) else { throw BrowserSplitError.paneMissing }
        return try mutateSplit(id, action: .swapSplitPanes, from: context) { $0.tabIDs.swapAt(first, second) }
    }

    public func closeSplitPane(_ tabID: TabID, from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        guard case let .split(id)? = organization.container(of: .tab(tabID)),
              let group = organization.splits[id], let location = organization.placement(of: .split(id)) else {
            throw BrowserSplitError.paneMissing
        }
        let section = try splitSection(of: .split(id), in: context)
        let nextTab = group.tabIDs.first { $0 != tabID }!
        let selected = context.selectedOccurrenceID.flatMap { tabs[$0]?.id }
        let effects = BrowserOrganizationWindowEffects(liveTabs: [tabID], selectedTab: selected == tabID ? tabID : nil)
        try commitOrganization(.closeSplitPane, in: context, effects: effects) { next in
            if case .today = section {
                next.archiveTab(tabID, reason: .closed, origin: .today, profileID: context.profileID,
                                spaceID: context.spaceID, at: clock())
            } else {
                next.detach(.tab(tabID))
                next.insert(.tab(tabID), into: location.container, at: location.index + 1)
                next.updateTab(tabID) { if let home = $0.pinnedURL { $0.url = home } }
            }
        }
        if let closed = occurrences(in: windows[context.windowID]!).first(where: { $0.id == tabID }) {
            dropOccurrence(closed.occurrenceID, in: context.windowID)
        }
        if selected == tabID, let survivor = occurrences(in: windows[context.windowID]!).first(where: { $0.id == nextTab }) {
            try selectOccurrence(survivor.occurrenceID, in: context.windowID)
        }
        return try captureWindowState(in: context.windowID)
    }

    public func selectSplit(_ id: SplitGroupID, from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        _ = try splitSection(of: .split(id), in: context)
        guard let group = organization.splits[id] else { throw BrowserOrganizationError.itemMissing }
        ensureSplitOccurrences(id, in: context)
        let selected = context.selectedOccurrenceID.flatMap { tabs[$0]?.id }
        let destination = selected.flatMap { group.tabIDs.contains($0) ? $0 : nil } ?? group.tabIDs[0]
        return try selectTab(destination,
                             from: captureContext(in: context.windowID))
    }

    func ensureSplitOccurrences(_ id: SplitGroupID, in context: BrowserContext) {
        guard let group = organization.splits[id], let window = windows[context.windowID] else { return }
        let loaded = Set(occurrences(in: window).map(\.id))
        for tabID in group.tabIDs where !loaded.contains(tabID) {
            if let tab = organization.tabs[tabID] {
                openOccurrence(of: tabID, url: tab.url, in: context.windowID, spaceID: context.spaceID, activate: false)
            }
        }
    }

    private func mutateSplit(_ id: SplitGroupID, action: BrowserOrganizationAction, from context: BrowserContext,
                             _ body: (inout BrowserSplitGroup) -> Void) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        _ = try splitSection(of: .split(id), in: context)
        try commitOrganization(action, in: context) { $0.updateSplit(id, body) }
        return try captureWindowState(in: context.windowID)
    }

    private func splitSection(of node: BrowserOrganizationNode, in context: BrowserContext) throws -> BrowserOrganizationSection {
        let section = try visibleSection(of: node, in: context)
        if case .favorites = section { throw BrowserSplitError.incompatibleSection }
        return section
    }
}

extension BrowserStore {
    /// Replays and shared membership edits must materialize every pane of an already visible
    /// group in each window, not just the newly selected one.
    func ensureVisibleSplitOccurrences(in windowID: WindowID) {
        guard let window = windows[windowID], let selected = visibleSelectedTabID(in: window),
              case let .split(id)? = organization.container(of: .tab(selected)),
              let context = try? captureContext(in: windowID) else { return }
        ensureSplitOccurrences(id, in: context)
    }

    /// A live transfer leaves the source group's row dormant. Its surviving surfaces remain owned
    /// by the source until transferred or selected again; a later explicit selection can reload
    /// the missing occurrence as an independent document of that window.
    func retireVisibleSplit(containing tabID: TabID, in windowID: WindowID) {
        guard var window = windows[windowID],
              case let .split(id)? = organization.container(of: .tab(tabID)),
              let group = organization.splits[id],
              let selected = visibleSelectedTabID(in: window), group.tabIDs.contains(selected) else { return }
        markViewed(window)
        window.selectedOccurrenceBySpace[window.activeSpaceID] = window.occurrenceIDsBySpace[window.activeSpaceID]?.first {
            guard let tab = tabs[$0] else { return false }
            return !group.tabIDs.contains(tab.id)
        }
        window.revision &+= 1
        windows[windowID] = window
    }
}

public extension BrowserStore {
    /// Keeps an intact, unowned rescued group on Quit without adding duplicate Today tabs.
    /// All metadata and destinations are checked in this actor turn before the first write.
    func preserveRescuedSplit(_ group: BrowserSplitGroup, spaceID: SpaceID, profileID: ProfileID,
                              urls: [TabID: URL]) throws -> Bool {
        guard organization.splits[group.id] == group, spaces[spaceID]?.profileID == profileID,
              let section = organization.section(of: .split(group.id)),
              section == .today(spaceID) || section == .pinned(spaceID),
              Set(urls.keys) == Set(group.tabIDs),
              !tabs.values.contains(where: { group.tabIDs.contains($0.id) }) else { return false }
        for url in urls.values { try BrowserSessionDocument.validateDestination(url) }
        try commitOrganization { state in
            for id in group.tabIDs { state.updateTab(id) { $0.url = urls[id]! } }
        }
        return true
    }

    /// Reuse an unowned logical identity, including a degraded group member. Never overwrite a
    /// peer's live document or resurrect an archived tab; those need independent identities.
    func preserveRescuedTab(url: URL, profileID: ProfileID, existingTabID: TabID? = nil,
                            standalone: Bool = false, preferredSpaceID: SpaceID? = nil) throws -> TabID {
        try BrowserSessionDocument.validateDestination(url)
        guard profiles[profileID] != nil else { throw BrowserStoreError.profileMissing }
        let spaceID = preferredSpaceID.flatMap { spaces[$0]?.profileID == profileID ? $0 : nil }
            ?? spaceOrder.first(where: { spaces[$0]?.profileID == profileID })
        guard let spaceID else { throw BrowserStoreError.spaceMissing }
        if let id = existingTabID, let section = organization.section(of: .tab(id)),
           self.profileID(of: section) == profileID, !tabs.values.contains(where: { $0.id == id }) {
            try commitOrganization { state in
                if standalone {
                    if preferredSpaceID != nil {
                        // Live rehome follows its receiving window.
                        try state.move([.tab(id)], to: .init(.today(spaceID), position: .start), destinationSection: .today(spaceID))
                    } else if case let .split(groupID)? = state.container(of: .tab(id)),
                              let position = state.placement(of: .split(groupID)) {
                        // Quit has no receiving window: separate in place, keeping the Space,
                        // folder and pinned address instead of demoting an unowned Pinned tab.
                        state.detach(.tab(id))
                        state.insert(.tab(id), into: position.container, at: position.index)
                    }
                }
                state.updateTab(id) { $0.url = url }
            }
            return id
        }
        let now = clock()
        let tab = BrowserOrganizedTab(id: TabID(), url: url, createdAt: now, lastActiveAt: now)
        try commitOrganization { state in
            state.addTab(tab, into: .today(spaceID), at: Self.insertsNewTodayTabsAtTop ? 0 : .max)
        }
        return tab.id
    }

    /// A degraded cohort rehomes each live document atomically with its identity decision.
    func openStandaloneRescuedOccurrence(of tabID: TabID?, url: URL, from context: BrowserContext,
                                        activate: Bool) throws -> TabOccurrenceID {
        _ = try organizationWindow(context)
        let id = try preserveRescuedTab(url: url, profileID: context.profileID, existingTabID: tabID,
                                       standalone: true, preferredSpaceID: context.spaceID)
        guard let occurrence = openOccurrence(of: id, url: url, in: context.windowID,
                                              spaceID: context.spaceID, activate: activate) else {
            throw BrowserStoreError.windowMissing
        }
        publishOrganizationChange()
        return occurrence
    }

    /// Restoration admits dormant logical members, but the first shell publication must include
    /// every pane of its selected group.
    func materializeVisibleSplitAndCaptureState(in windowID: WindowID) throws -> BrowserWindowState {
        ensureVisibleSplitOccurrences(in: windowID)
        return try captureWindowState(in: windowID)
    }
}

public extension BrowserStore {
    /// Admits the complete live group in one actor transaction. The caller must name every
    /// existing target occurrence exactly; a peer-created occurrence is never silently copied.
    func openTransferredSplitOccurrences(
        _ expectedGroup: BrowserSplitGroup, urlsByTabID: [TabID: URL],
        expectedExistingOccurrences: [TabID: TabOccurrenceID], from context: BrowserContext,
        activating tabID: TabID?
    ) throws -> (occurrenceIDs: [TabID: TabOccurrenceID], state: BrowserWindowState) {
        let window = try organizationWindow(context)
        guard expectedGroup.isValid, organization.splits[expectedGroup.id] == expectedGroup else {
            throw BrowserSplitError.staleLayout
        }
        _ = try splitSection(of: .split(expectedGroup.id), in: context)
        let members = Set(expectedGroup.tabIDs)
        guard Set(urlsByTabID.keys) == members,
              Set(expectedExistingOccurrences.keys).isSubset(of: members),
              tabID.map(members.contains) ?? true else { throw BrowserSplitError.paneMissing }
        let existing = occurrences(in: window).filter { members.contains($0.id) }
        guard existing.count == expectedExistingOccurrences.count,
              existing.allSatisfy({ expectedExistingOccurrences[$0.id] == $0.occurrenceID && $0.spaceID == context.spaceID }) else {
            throw BrowserStoreError.staleContext
        }
        for id in expectedGroup.tabIDs { try BrowserSessionDocument.validateDestination(urlsByTabID[id]!) }
        // All rejection points precede the first write. The group and its logical TabIDs are
        // unchanged; every new occurrence exists before selection can materialize any sibling.
        for tab in existing { dropOccurrence(tab.occurrenceID, in: context.windowID) }
        var ids: [TabID: TabOccurrenceID] = [:]
        for id in expectedGroup.tabIDs {
            let url = urlsByTabID[id]!
            organization.updateTab(id) { $0.url = url }
            ids[id] = openOccurrence(of: id, url: url, in: context.windowID, spaceID: context.spaceID, activate: false)!
        }
        if let tabID { try selectOccurrence(ids[tabID]!, in: context.windowID) }
        publishOrganizationChange()
        return (ids, try captureWindowState(in: context.windowID))
    }

    /// Acknowledges one live group handoff. Validate every lease before removing any placeholder,
    /// then retire visible group selection and remove all members before peer reconciliation.
    func releaseOwnedOccurrencesAndCaptureState(
        _ authorities: [BrowserOccurrenceAuthority], validating context: BrowserContext
    ) throws -> BrowserWindowState {
        guard !authorities.isEmpty, Set(authorities.map(\.occurrenceID)).count == authorities.count,
              context.storeGeneration == storeGeneration, let window = windows[context.windowID],
              window.activeSpaceID == context.spaceID,
              spaces[context.spaceID]?.profileID == context.profileID else { throw BrowserStoreError.staleContext }
        var members: [BrowserTab] = []
        for authority in authorities {
            guard authority.storeGeneration == storeGeneration, authority.windowID == context.windowID else {
                throw BrowserStoreError.staleContext
            }
            guard let tab = tabs[authority.occurrenceID] else { throw BrowserStoreError.tabMissing }
            guard tab.windowID == authority.windowID, spaces[tab.spaceID]?.profileID == authority.profileID,
                  window.occurrenceIDsBySpace[tab.spaceID, default: []].contains(tab.occurrenceID) else {
                throw BrowserStoreError.occurrenceOwnedByAnotherWindow
            }
            members.append(tab)
        }
        for tab in members { retireVisibleSplit(containing: tab.id, in: context.windowID) }
        for tab in members { dropOccurrence(tab.occurrenceID, in: context.windowID) }
        publishOrganizationChange()
        return try captureWindowState(in: context.windowID)
    }
}
