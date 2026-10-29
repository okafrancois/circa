import Foundation

extension BrowserStore {
    /// History covers activity changes that deliberately do not publish organization revisions.
    /// Structural/catalog changes and missing history retain the full capture path.
    func selectionMetadata(since state: BrowserWindowState, context: BrowserContext,
                           including ids: Set<TabID> = []) throws -> BrowserOrganizationMetadata? {
        guard state.activityRevision >= selectionActivityFloor,
              state.activityRevision <= selectionActivityRevision,
              let metadata = try organizationMetadata(since: state.organization.organizationRevision,
                  from: context, catalogRevision: state.catalogRevision) else { return nil }
        var changed = ids.union(metadata.tabs.keys)
        for entry in selectionActivityHistory where entry.revision > state.activityRevision {
            changed.formUnion(entry.tabs)
        }
        var values = metadata.tabs
        for id in changed { values[id] = organization.tabs[id] }
        return BrowserOrganizationMetadata(revision: metadata.revision, tabs: values,
            localDestinations: metadata.localDestinations, destinations: metadata.destinations)
    }

    /// Runs the same mutation and admission as full selection. A delta is returned only across
    /// unchanged occurrence inventory, including inactive Spaces and all Split members.
    public func selectTabUpdating(_ id: TabID, from context: BrowserContext,
                                  state: BrowserWindowState?, index: BrowserOrganizationMetadataIndex?,
                                  expecting expected: BrowserOrganizationSnapshot? = nil,
                                  admission: BrowserSidebarSelectionAdmission? = nil) throws -> BrowserWindowState {
        guard let state, state.context == context, isCurrent(context),
              let before = try selectionMetadata(since: state, context: context),
              let window = windows[context.windowID] else {
            return try selectTab(id, from: context, expecting: expected, admission: admission)
        }
        let projection = state.organization.applying(before, index: index)
        try performTabSelection(id, from: context, expecting: expected, admission: admission,
                                currentProjection: projection)
        let nextContext = try captureContext(in: context.windowID)
        guard let nextWindow = windows[context.windowID],
              window.occurrenceIDsBySpace == nextWindow.occurrenceIDsBySpace,
              nextContext.spaceID == context.spaceID, nextContext.profileID == context.profileID,
              let delta = try selectionMetadata(since: state, context: nextContext,
                  including: Set([context.selectedOccurrenceID, nextContext.selectedOccurrenceID].compactMap { $0 }.compactMap { tabs[$0]?.id })) else {
            return try captureWindowState(in: context.windowID)
        }
        let snapshot = state.snapshot.applying(delta)
        return BrowserWindowState(context: nextContext,
            snapshot: BrowserWindowSnapshot(id: snapshot.id, activeSpaceID: snapshot.activeSpaceID,
                selectedOccurrenceID: nextContext.selectedOccurrenceID, tabs: snapshot.tabs,
                revision: nextContext.revision, isStandalone: snapshot.isStandalone),
            catalog: state.catalog, catalogRevision: state.catalogRevision, activityRevision: selectionActivityRevision,
            selectionTabIDs: Set(delta.tabs.keys), occurrenceAuthorities: state.occurrenceAuthorities,
            occurrenceTabIDs: state.occurrenceTabIDs,
            organization: state.organization.applying(delta, index: index,
                selection: nextContext.selectedOccurrenceID, updatingSelection: true))
    }
}

public extension BrowserStore {
    func selectOccurrenceUpdating(_ id: TabOccurrenceID, from context: BrowserContext,
                                  state: BrowserWindowState?, index: BrowserOrganizationMetadataIndex?) throws -> BrowserWindowState {
        if let state, let tabID = state.occurrenceTabIDs[id],
           index?.tab(tabID, in: state.organization)?.occurrenceID == id {
            return try selectTabUpdating(tabID, from: context, state: state, index: index)
        }
        try selectOccurrence(id, from: context)
        return try captureWindowState(in: context.windowID)
    }
}
