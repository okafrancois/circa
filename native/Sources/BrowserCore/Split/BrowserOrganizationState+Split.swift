import Foundation

extension BrowserOrganizationContainer {
    var owningNode: BrowserOrganizationNode? {
        switch self {
        case let .folder(id): return .folder(id)
        case let .split(id): return .split(id)
        default: return nil
        }
    }
}

extension BrowserOrganizationState {
    /// A removed/moved/archived pane dissolves a singleton at the group's former position.
    /// Archive records remain per-tab; undo restores group layout and membership atomically.
    mutating func normalizeSplits() {
        for id in Array(splits.keys) {
            guard var group = splits[id] else { continue }
            if group.tabIDs.count < 2 {
                let location = placement(of: .split(id))
                let survivors = group.tabIDs.map(BrowserOrganizationNode.tab)
                detach(all: survivors)
                detach(.split(id))
                splits[id] = nil
                changes.nodes.insert(.split(id))
                changes.splits.insert(id)
                if let location { insert(survivors, into: location.container, at: location.index) }
            } else if group.ratios.count != group.tabIDs.count {
                group.ratios = Array(repeating: 1 / Double(group.tabIDs.count), count: group.tabIDs.count)
                splits[id] = group
                changes.splits.insert(id)
            }
        }
    }

    mutating func updateSplit(_ id: SplitGroupID, _ body: (inout BrowserSplitGroup) -> Void) {
        guard var group = splits[id] else { return }
        body(&group)
        guard group != splits[id] else { return }
        splits[id] = group
        changes.splits.insert(id)
    }

    mutating func dissolveSplit(_ id: SplitGroupID) throws {
        guard let location = placement(of: .split(id)), let group = splits[id] else {
            throw BrowserOrganizationError.itemMissing
        }
        let panes = group.tabIDs.map(BrowserOrganizationNode.tab)
        detach(all: panes)
        detach(.split(id))
        splits[id] = nil
        changes.nodes.insert(.split(id))
        changes.splits.insert(id)
        insert(panes, into: location.container, at: location.index)
    }
}

extension BrowserOrganizationState {
    func todayBlocks(in space: SpaceID) -> [[TabID]] {
        (today[space] ?? []).map { tabIDs(in: $0) }
    }
}

extension BrowserStore {
    func visibleTabIDs(in window: WindowRecord) -> [TabID] {
        guard let selected = visibleSelectedTabID(in: window) else { return [] }
        if case let .split(id)? = organization.container(of: .tab(selected)), let group = organization.splits[id] {
            return group.tabIDs
        }
        return [selected]
    }
}

extension BrowserOrganizationState {
    /// A batch covering every pane moves its grouped row; an explicitly selected subset separates.
    func groupedNodes(for ids: [TabID]) -> [BrowserOrganizationNode] {
        let selected = Set(ids)
        var seen: Set<BrowserOrganizationNode> = []
        return ids.compactMap { id in
            let node: BrowserOrganizationNode
            if case let .split(groupID)? = container(of: .tab(id)),
               let group = splits[groupID], Set(group.tabIDs).isSubset(of: selected) {
                node = .split(groupID)
            } else { node = .tab(id) }
            return seen.insert(node).inserted ? node : nil
        }
    }
}
