import Foundation

extension BrowserStore {
    /// Copies stored folder contents as independent, dormant items in one undoable transaction.
    public func duplicateFolder(_ id: FolderID, from context: BrowserContext) throws -> (FolderID, BrowserWindowState) {
        _ = try organizationWindow(context)
        _ = try visibleSection(of: .folder(id), in: context)
        guard let placement = organization.placement(of: .folder(id)) else { throw BrowserOrganizationError.itemMissing }
        let original = organization
        let copyID = FolderID()
        let now = clock()
        try commitOrganization(.duplicateFolder, in: context) { state in
            func copy(_ node: BrowserOrganizationNode, into container: BrowserOrganizationContainer, at index: Int,
                      folderID: FolderID? = nil) throws {
                switch node {
                case let .tab(id):
                    guard let tab = original.tabs[id] else { throw BrowserOrganizationError.itemMissing }
                    state.addTab(.init(id: TabID(), url: tab.url, pageTitle: tab.pageTitle, customTitle: tab.customTitle,
                                       pinnedURL: tab.pinnedURL, createdAt: now, lastActiveAt: now, customIcon: tab.customIcon),
                                 into: container, at: index)
                case let .folder(id):
                    guard let folder = original.folders[id] else { throw BrowserOrganizationError.itemMissing }
                    let fresh = folderID ?? FolderID()
                    // A copied provider folder is a static snapshot, never a second subscription.
                    state.addFolder(.init(id: fresh, title: folder.title, isCollapsed: folder.isCollapsed, createdAt: now),
                                    into: container, at: index)
                    for (offset, child) in folder.children.enumerated() { try copy(child, into: .folder(fresh), at: offset) }
                case let .split(id):
                    guard let group = original.splits[id] else { throw BrowserOrganizationError.itemMissing }
                    let fresh = SplitGroupID()
                    state.splits[fresh] = BrowserSplitGroup(id: fresh, tabIDs: [], orientation: group.orientation)
                    state.changes.splits.insert(fresh)
                    state.insert(.split(fresh), into: container, at: index)
                    for (offset, tab) in group.tabIDs.enumerated() { try copy(.tab(tab), into: .split(fresh), at: offset) }
                    state.updateSplit(fresh) { $0.ratios = group.ratios }
                }
            }
            try copy(.folder(id), into: placement.container, at: placement.index + 1, folderID: copyID)
        }
        return (copyID, try captureWindowState(in: context.windowID))
    }
}
