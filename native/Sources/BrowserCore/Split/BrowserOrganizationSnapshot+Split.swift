import Foundation

public extension BrowserOrganizationSnapshot {
    func split(containing id: TabID) -> BrowserOrganizationSplitItem? {
        var stack = pinned + today
        while let item = stack.popLast() {
            if case let .split(split) = item, split.group.tabIDs.contains(id) { return split }
            if case let .folder(folder) = item { stack.append(contentsOf: folder.children) }
        }
        return nil
    }

    /// One selection row represents the group while page commands retain the individual tab.
    func rowNode(for id: TabID) -> BrowserOrganizationNode {
        split(containing: id).map { .split($0.group.id) } ?? .tab(id)
    }
}

public extension BrowserStore {
    func separateSplitPane(_ tabID: TabID, from context: BrowserContext) throws -> BrowserWindowState {
        _ = try organizationWindow(context)
        _ = try visibleSection(of: .tab(tabID), in: context)
        guard case let .split(id)? = organization.container(of: .tab(tabID)),
              let location = organization.placement(of: .split(id)) else { throw BrowserSplitError.paneMissing }
        try commitOrganization(.unsplit, in: context) { next in
            next.detach(.tab(tabID))
            next.insert(.tab(tabID), into: location.container, at: location.index + 1)
        }
        return try captureWindowState(in: context.windowID)
    }
}
