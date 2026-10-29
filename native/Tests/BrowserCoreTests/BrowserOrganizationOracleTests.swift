import Foundation
import Testing
@testable import BrowserCore


private typealias Node = BrowserOrganizationNode
private typealias Container = BrowserOrganizationContainer
private typealias Section = BrowserOrganizationSection

private struct ModelTab: Equatable {
    var title: String?
    var pinnedURL: URL?
    var url: URL
}

private struct ModelArchiveRecord: Equatable {
    let id: TabID
    let profileID: ProfileID
    let spaceID: SpaceID
    let date: Date
    let reason: BrowserArchivedTab.Reason
    let title: String?
    let url: URL
}

private struct ModelPlacement: Equatable {
    let container: Container
    let index: Int
    let previous: Node?
    let next: Node?
}

/// Orientation and slot fractions of a group. The model computes fractions independently, so they
/// compare within a tolerance.
private struct ModelLayout: Equatable {
    var orientation: BrowserSplitOrientation
    var ratios: [Double]

    static func equal(_ count: Int, _ orientation: BrowserSplitOrientation) -> ModelLayout {
        ModelLayout(orientation: orientation, ratios: Array(repeating: 1 / Double(count), count: count))
    }

    static func == (left: ModelLayout, right: ModelLayout) -> Bool {
        left.orientation == right.orientation && left.ratios.count == right.ratios.count
            && zip(left.ratios, right.ratios).allSatisfy { abs($0 - $1) < 1e-9 }
    }
}

/// Everything a group record holds: ordered membership and layout.
private struct ModelSplit: Equatable {
    let members: [TabID]
    let layout: ModelLayout
}

private struct ModelState: Equatable {
    var lists: [Container: [Node]] = [:]
    var tabs: [TabID: ModelTab] = [:]
    var folders: [FolderID: String] = [:]
    /// Layout of each group; its ordered panes are `lists[.split(id)]`.
    var layouts: [SplitGroupID: ModelLayout] = [:]
    /// Newest first.
    var archive: [ModelArchiveRecord] = []

    init(_ document: BrowserOrganizationDocument) {
        for entry in document.favorites { lists[.favorites(entry.profileID)] = entry.items }
        for entry in document.spaces {
            lists[.pinned(entry.spaceID)] = entry.pinned
            lists[.today(entry.spaceID)] = entry.today
        }
        for folder in document.folders {
            lists[.folder(folder.id)] = folder.children
            folders[folder.id] = folder.title
        }
        for split in document.splits {
            lists[.split(split.id)] = split.tabIDs.map(Node.tab)
            layouts[split.id] = ModelLayout(orientation: split.orientation, ratios: split.ratios)
        }
        for tab in document.tabs { tabs[tab.id] = ModelTab(title: tab.customTitle, pinnedURL: tab.pinnedURL, url: tab.url) }
        archive = document.archive.map {
            ModelArchiveRecord(id: $0.id, profileID: $0.profileID, spaceID: $0.spaceID, date: $0.archivedAt,
                               reason: $0.reason, title: $0.tab.customTitle, url: $0.tab.url)
        }
        normalize()
    }

    mutating func normalize() { lists = lists.filter { !$0.value.isEmpty } }

    func children(_ container: Container) -> [Node] { lists[container] ?? [] }

    func contains(_ node: Node) -> Bool {
        switch node {
        case let .split(id): return layouts[id] != nil
        case let .tab(id): return tabs[id] != nil
        case let .folder(id): return folders[id] != nil
        }
    }

    static func owner(_ container: Container) -> Node? {
        switch container {
        case let .folder(id): return .folder(id)
        case let .split(id): return .split(id)
        default: return nil
        }
    }

    var parents: [Node: Container] {
        var result: [Node: Container] = [:]
        for (container, nodes) in lists { for node in nodes { result[node] = container } }
        return result
    }

    func section(of node: Node, _ parents: [Node: Container]) -> Section? {
        var current = parents[node]
        var steps = 0
        while let container = current, let owner = Self.owner(container), steps <= folders.count + layouts.count {
            steps += 1
            current = parents[owner]
        }
        return current?.rootSection
    }

    func placement(of node: Node, _ parents: [Node: Container]) -> ModelPlacement? {
        guard let container = parents[node], let list = lists[container], let index = list.firstIndex(of: node) else {
            return nil
        }
        return ModelPlacement(container: container, index: index, previous: index > 0 ? list[index - 1] : nil,
                              next: index + 1 < list.count ? list[index + 1] : nil)
    }

    /// Folders above a node, through a group row when the node is a pane.
    func ancestors(of node: Node, _ parents: [Node: Container]) -> [FolderID] {
        var result: [FolderID] = []
        var current = parents[node]
        var steps = 0
        while let container = current, let owner = Self.owner(container), steps <= folders.count + layouts.count {
            steps += 1
            if let id = owner.folderID { result.append(id) }
            current = parents[owner]
        }
        return result
    }

    /// Pre-order walk of a subtree, group panes included.
    func subtree(_ node: Node) -> [Node] {
        var result = [node]
        switch node {
        case let .folder(id): for child in children(.folder(id)) { result += subtree(child) }
        case let .split(id): result += children(.split(id))
        case .tab: break
        }
        return result
    }

    func group(of tab: TabID, _ parents: [Node: Container]) -> SplitGroupID? {
        if case let .split(id)? = parents[.tab(tab)] { return id }
        return nil
    }

    func members(_ id: SplitGroupID) -> [TabID] { children(.split(id)).compactMap(\.tabID) }

    func split(_ id: SplitGroupID) -> ModelSplit? { layouts[id].map { ModelSplit(members: members(id), layout: $0) } }

    /// The tabs a window shows when `tab` is its selection: the whole group for a pane.
    func shown(_ tab: TabID, _ parents: [Node: Container]) -> [TabID] {
        group(of: tab, parents).map(members) ?? [tab]
    }

    /// Row order: Favorites, Pinned, Today, each depth first.
    func sidebarSorted(_ nodes: [Node]) -> [Node] {
        var order: [Node: Int] = [:]
        var position = 0
        let roots = lists.keys.filter { $0.rootSection != nil }.sorted { rank($0) < rank($1) }
        for root in roots {
            for top in children(root) {
                for node in subtree(top) {
                    order[node] = position
                    position += 1
                }
            }
        }
        return nodes.sorted { (order[$0] ?? -1) < (order[$1] ?? -1) }
    }

    private func rank(_ container: Container) -> (Int, String) {
        switch container {
        case let .favorites(id): return (0, id.rawValue.uuidString)
        case let .pinned(id): return (1, id.rawValue.uuidString)
        case let .today(id): return (2, id.rawValue.uuidString)
        case let .folder(id): return (3, id.rawValue.uuidString)
        case let .split(id): return (4, id.rawValue.uuidString)
        }
    }

    mutating func remove(_ nodes: Set<Node>) {
        for container in lists.keys { lists[container]?.removeAll { nodes.contains($0) } }
    }

    mutating func insert(_ nodes: [Node], into container: Container, at index: Int) {
        var list = children(container)
        list.insert(contentsOf: nodes, at: min(max(index, 0), list.count))
        lists[container] = list
    }

    /// Replaces the group's row by its remaining panes, in pane order, and forgets the group.
    mutating func dissolve(_ id: SplitGroupID) {
        let panes = children(.split(id))
        if let container = parents[.split(id)], let index = lists[container]?.firstIndex(of: .split(id)) {
            lists[container]!.replaceSubrange(index...index, with: panes)
        }
        lists[.split(id)] = nil
        layouts[id] = nil
    }

    /// After panes left groups: a group with fewer than two panes dissolves in place; a group that
    /// lost panes keeps the survivors' sizes relative to each other, as they were in `before`.
    mutating func settleSplits(from before: ModelState) {
        for id in layouts.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            let current = members(id)
            if current.count < 2 {
                dissolve(id)
            } else if let old = before.split(id), old.members != current {
                let sizes = Dictionary(uniqueKeysWithValues: zip(old.members, old.layout.ratios))
                let kept = current.map { sizes[$0] ?? 0 }
                let total = kept.reduce(0, +)
                layouts[id]?.ratios = kept.map { $0 / total }
            }
        }
        normalize()
    }

    /// A pane leaving its group lands just after the group's row; the group then settles.
    mutating func separate(_ tab: TabID, from id: SplitGroupID) {
        let before = self
        guard let container = parents[.split(id)] else { return }
        remove([.tab(tab)])
        let index = children(container).firstIndex(of: .split(id))!
        insert([.tab(tab)], into: container, at: index + 1)
        settleSplits(from: before)
    }

    /// Records arrive newest first. At equal dates, arriving records precede existing ones. Then
    /// each profile keeps its newest `cap` records. Returns the evicted records.
    mutating func insertArchive(_ records: [ModelArchiveRecord], cap: Int) -> [ModelArchiveRecord] {
        let tagged = records.enumerated().map { ($1, 0, $0) } + archive.enumerated().map { ($1, 1, $0) }
        let merged = tagged.sorted { left, right in
            if left.0.date != right.0.date { return left.0.date > right.0.date }
            return (left.1, left.2) < (right.1, right.2)
        }.map(\.0)
        var counts: [ProfileID: Int] = [:]
        archive = []
        var evicted: [ModelArchiveRecord] = []
        for record in merged {
            counts[record.profileID, default: 0] += 1
            if counts[record.profileID]! <= cap { archive.append(record) } else { evicted.append(record) }
        }
        return evicted
    }

    /// A short, readable list of what differs from `other`, for failure messages.
    func difference(from other: ModelState) -> String {
        func short(_ node: Node) -> String {
            switch node {
            case let .tab(id): return "t" + id.rawValue.uuidString.prefix(4)
            case let .folder(id): return "f" + id.rawValue.uuidString.prefix(4)
            case let .split(id): return "s" + id.rawValue.uuidString.prefix(4)
            }
        }
        var lines: [String] = []
        for container in Set(lists.keys).union(other.lists.keys) where children(container) != other.children(container) {
            lines.append("\(container): \(children(container).map(short)) expected \(other.children(container).map(short))")
        }
        for id in Set(tabs.keys).union(other.tabs.keys) where tabs[id] != other.tabs[id] {
            lines.append("\(short(.tab(id))): \(String(describing: tabs[id])) expected \(String(describing: other.tabs[id]))")
        }
        for id in Set(layouts.keys).union(other.layouts.keys) where layouts[id] != other.layouts[id] {
            lines.append("\(short(.split(id))): \(String(describing: layouts[id])) expected \(String(describing: other.layouts[id]))")
        }
        if folders != other.folders { lines.append("folders \(folders) expected \(other.folders)") }
        if archive != other.archive {
            lines.append("archive \(archive.map { short(.tab($0.id)) }) expected \(other.archive.map { short(.tab($0.id)) })")
        }
        return lines.joined(separator: "\n")
    }

    /// The invariants a replay can break: folder cycles, folders outside Pinned, pinned URLs,
    /// groups outside Pinned/Today, groups with fewer than two or more than four panes.
    var isValid: Bool {
        let parents = self.parents
        for id in folders.keys {
            guard let section = section(of: .folder(id), parents), case .pinned = section else { return false }
            if ancestors(of: .folder(id), parents).contains(id) { return false }
        }
        for (container, _) in lists {
            if case let .split(id) = container, layouts[id] == nil { return false }
        }
        for (id, layout) in layouts {
            let panes = members(id)
            guard (2...BrowserSplitGroup.maximumPanes).contains(panes.count), Set(panes).count == panes.count,
                  panes.count == children(.split(id)).count, layout.ratios.count == panes.count,
                  let section = section(of: .split(id), parents) else { return false }
            if case .favorites = section { return false }
        }
        for (id, tab) in tabs {
            guard let section = section(of: .tab(id), parents) else { return false }
            if (tab.pinnedURL != nil) != section.keepsPinnedURL { return false }
        }
        return true
    }
}

private struct ModelArchiveChange {
    var pre: ModelArchiveRecord?
    var post: ModelArchiveRecord?
    var preIndex: Int?
    var postIndex: Int?
}

private struct ModelRecord {
    let window: WindowID
    let profileID: ProfileID
    let spaceID: SpaceID
    let action: BrowserOrganizationAction
    let pre: ModelState
    let post: ModelState
    let placements: Set<Node>
    let preStamps: [Node: Int]
    let postStamps: [Node: Int]
    var archive: [TabID: ModelArchiveChange]
    let displaced: TabID?
    let liveTabs: Set<TabID>
}

/// Window effects a command declares itself instead of deriving them from what it moved. A nil
/// `live` keeps the derived live tabs. Selection counts as displaced only by the organization
/// change itself: a selection the command makes afterwards (the new pane of a split) is not
/// undone by restoring the previous one.
private struct ModelEffects {
    var live: Set<TabID>? = nil
    let selected: TabID?
}

/// Live occurrences as saved: which tabs each window shows.
private struct ModelWindows {
    var activeSpace: [WindowID: SpaceID] = [:]
    var visible: [WindowID: TabID] = [:]
    var live: [WindowID: Set<TabID>] = [:]
    var claimed: [WindowID: Set<TabID>] = [:]

    init(_ document: BrowserSessionDocument, automatic: [WindowID: Set<TabOccurrenceID>] = [:]) {
        let logical = Dictionary(uniqueKeysWithValues: document.tabs.map { ($0.occurrenceID, $0.id) })
        for window in document.windows {
            activeSpace[window.id] = window.activeSpaceID
            if let selected = window.spaces.first(where: { $0.spaceID == window.activeSpaceID })?.selectedOccurrenceID {
                visible[window.id] = logical[selected]
            }
        }
        for tab in document.tabs {
            live[tab.windowID, default: []].insert(tab.id)
            if automatic[tab.windowID]?.contains(tab.occurrenceID) != true {
                claimed[tab.windowID, default: []].insert(tab.id)
            }
        }
    }
}

private enum ReplayPrediction {
    case nothing
    case conflict
    case applied(ModelState, ModelRecord)
}

private struct OrganizationModel {
    let cap: Int
    let spaceProfiles: [SpaceID: ProfileID]
    var stamps: [Node: Int] = [:]
    var lastStamp = 0
    var undo: [WindowID: [ModelRecord]] = [:]
    var redo: [WindowID: [ModelRecord]] = [:]

    func isVisible(_ section: Section, in space: SpaceID) -> Bool {
        switch section {
        case let .favorites(profileID): return spaceProfiles[space] == profileID
        case let .pinned(id), let .today(id): return id == space
        }
    }

    func profile(of section: Section) -> ProfileID? {
        switch section {
        case let .favorites(id): return id
        case let .pinned(id), let .today(id): return spaceProfiles[id]
        }
    }

    // MARK: Forward commands

    /// Nodes whose placement a command wrote: every parent change, plus explicitly moved nodes
    /// whose position or neighbors changed. Sibling shifts are not writes.
    mutating func recordWrites(pre: ModelState, post: ModelState, explicit: Set<Node>) -> Set<Node> {
        let before = pre.parents, after = post.parents
        var written: Set<Node> = []
        for node in Set(before.keys).union(after.keys) where before[node] != after[node] { written.insert(node) }
        for node in explicit where pre.placement(of: node, before) != post.placement(of: node, after) {
            written.insert(node)
        }
        for node in written {
            if after[node] == nil {
                stamps[node] = nil
            } else {
                lastStamp += 1
                stamps[node] = lastStamp
            }
        }
        return written
    }

    /// Journals a command exactly when it changed something undoable.
    mutating func journal(
        _ action: BrowserOrganizationAction, window: WindowID, space: SpaceID, pre: ModelState, post: ModelState,
        written: Set<Node>, preStamps: [Node: Int], windowsBefore: ModelWindows, windowsAfter: ModelWindows,
        effects: ModelEffects?
    ) {
        var archive: [TabID: ModelArchiveChange] = [:]
        let ids = Set(pre.archive.map(\.id)).union(post.archive.map(\.id))
        for id in ids {
            let preIndex = pre.archive.firstIndex { $0.id == id }
            let postIndex = post.archive.firstIndex { $0.id == id }
            let before = preIndex.map { pre.archive[$0] }, after = postIndex.map { post.archive[$0] }
            if before != after {
                archive[id] = ModelArchiveChange(pre: before, post: after, preIndex: preIndex, postIndex: postIndex)
            }
        }
        let fieldsChanged = pre.tabs.contains { id, tab in
            guard let other = post.tabs[id] else { return false }
            return tab.title != other.title || tab.pinnedURL != other.pinnedURL
        }
        let foldersChanged = pre.folders.contains { id, title in post.folders[id].map { $0 != title } ?? false }
        let splitsChanged = Set(pre.layouts.keys).union(post.layouts.keys).contains { pre.split($0) != post.split($0) }
        let existenceChanged = Set(pre.tabs.keys) != Set(post.tabs.keys) || Set(pre.folders.keys) != Set(post.folders.keys)
        guard !written.isEmpty || !archive.isEmpty || fieldsChanged || foldersChanged || splitsChanged
            || existenceChanged else { return }
        var affected = Set(written.compactMap(\.tabID)).union(Set(pre.tabs.keys).symmetricDifference(post.tabs.keys))
        for node in written where node.tabID == nil { affected.formUnion(pre.subtree(node).compactMap(\.tabID)) }
        let visibleBefore = windowsBefore.visible[window]
        let displaced = effects.map(\.selected) ?? visibleBefore.flatMap { tab in
            affected.contains(tab) && windowsAfter.visible[window] != tab ? tab : nil
        }
        let record = ModelRecord(
            window: window, profileID: spaceProfiles[space]!, spaceID: space, action: action, pre: pre, post: post,
            placements: written, preStamps: preStamps.filter { written.contains($0.key) },
            postStamps: stamps.filter { written.contains($0.key) }, archive: archive, displaced: displaced,
            liveTabs: effects?.live ?? affected.intersection(windowsBefore.live[window] ?? []))
        undo[window, default: []].append(record)
        if undo[window]!.count > BrowserOrganizationJournal.limit { undo[window]!.removeFirst() }
        redo[window] = []
    }

    /// `moveItems` to the start (or end) of `container`; nil when the store must refuse.
    func move(_ nodes: [Node], to container: Container, atEnd: Bool = false, in state: ModelState, space: SpaceID)
        -> (ModelState, BrowserOrganizationAction, Set<Node>)? {
        let parents = state.parents
        let profileID = spaceProfiles[space]!
        var sources: [Section] = []
        for node in nodes {
            guard state.contains(node), let section = state.section(of: node, parents),
                  isVisible(section, in: space) else { return nil }
            sources.append(section)
        }
        let target: Section
        switch container {
        case .split: return nil
        case let .favorites(id): target = .favorites(id)
        case let .pinned(id): target = .pinned(id)
        case let .today(id): target = .today(id)
        case let .folder(id):
            guard state.folders[id] != nil, let section = state.section(of: .folder(id), parents) else { return nil }
            target = section
        }
        guard profile(of: target) == profileID else { return nil }
        let requested = Set(nodes.compactMap(\.folderID))
        let requestedSplits = Set(nodes.compactMap(\.splitID))
        var seen: Set<Node> = []
        // A requested group carries its panes; a requested folder carries its descendants.
        let roots = state.sidebarSorted(nodes.filter { node in
            seen.insert(node).inserted
                && !(parents[node].flatMap(ModelState.owner)?.splitID.map(requestedSplits.contains) ?? false)
                && !state.ancestors(of: node, parents).contains(where: requested.contains)
        })
        if case .favorites = target, roots.contains(where: { $0.splitID != nil }) { return nil }
        if !target.acceptsFolders, roots.contains(where: { $0.folderID != nil }) { return nil }
        if case let .folder(id) = container {
            let chain = Set([id] + state.ancestors(of: .folder(id), parents))
            if roots.contains(where: { $0.folderID.map(chain.contains) ?? false }) { return nil }
        }
        var next = state
        next.remove(Set(roots))
        next.insert(roots, into: container, at: atEnd ? next.children(container).count : 0)
        for tab in roots.flatMap(state.subtree).compactMap(\.tabID) {
            if target.keepsPinnedURL {
                if let entry = next.tabs[tab], entry.pinnedURL == nil { next.tabs[tab]?.pinnedURL = entry.url }
            } else {
                next.tabs[tab]?.pinnedURL = nil
            }
        }
        next.settleSplits(from: state)
        return (next, Self.moveAction(sources, target), Set(roots))
    }

    static func moveAction(_ sources: [Section], _ target: Section) -> BrowserOrganizationAction {
        let allToday = sources.allSatisfy { if case .today = $0 { return true }; return false }
        let allFavorites = sources.allSatisfy { if case .favorites = $0 { return true }; return false }
        switch target {
        case .favorites: return allFavorites ? .moveItems : .addToFavorites
        case .pinned: return allToday ? .pinTabs : allFavorites ? .removeFromFavorites : .moveItems
        case .today: return allToday ? .moveItems : allFavorites ? .removeFromFavorites : .unpinTabs
        }
    }

    /// A batch naming every pane of a group stands for the group's row; a subset stays panes.
    func groupedNodes(_ ids: [TabID], in state: ModelState) -> [Node] {
        let parents = state.parents
        let named = Set(ids)
        var seen: Set<Node> = []
        return ids.compactMap { id in
            let node: Node = state.group(of: id, parents).flatMap { group in
                Set(state.members(group)).isSubset(of: named) ? .split(group) : nil
            } ?? .tab(id)
            return seen.insert(node).inserted ? node : nil
        }
    }

    /// Archives tabs as one batch: Today tabs are closed, others removed; the last named is newest.
    func archive(_ ids: [TabID], profileID: ProfileID, space: SpaceID, date: Date, in state: ModelState) -> ModelState? {
        let parents = state.parents
        var seen: Set<TabID> = []
        var records: [ModelArchiveRecord] = []
        for id in ids where seen.insert(id).inserted {
            guard let tab = state.tabs[id], let section = state.section(of: .tab(id), parents),
                  isVisible(section, in: space) else { return nil }
            let isToday: Bool = { if case .today = section { return true }; return false }()
            records.append(ModelArchiveRecord(id: id, profileID: profileID, spaceID: space, date: date,
                                              reason: isToday ? .closed : .removed, title: tab.title, url: tab.url))
        }
        var next = state
        next.remove(Set(records.map { .tab($0.id) }))
        for record in records { next.tabs[record.id] = nil }
        _ = next.insertArchive(Array(records.reversed()), cap: cap)
        next.settleSplits(from: state)
        return next
    }

    // MARK: Split commands

    /// Section of a node that a split command may address: visible here, never Favorites.
    func splitSection(_ node: Node, in state: ModelState, space: SpaceID) -> Section? {
        guard state.contains(node), let section = state.section(of: node, state.parents),
              isVisible(section, in: space) else { return nil }
        if case .favorites = section { return nil }
        return section
    }

    /// The group row takes the place of its first pane among the rows that remain.
    func createSplit(_ ids: [TabID], _ orientation: BrowserSplitOrientation, id: SplitGroupID, in state: ModelState,
                     space: SpaceID) -> ModelState? {
        guard (2...BrowserSplitGroup.maximumPanes).contains(ids.count), Set(ids).count == ids.count else { return nil }
        let parents = state.parents
        var shared: Section?
        for tab in ids {
            guard let section = splitSection(.tab(tab), in: state, space: space),
                  shared == nil || shared == section, state.group(of: tab, parents) == nil else { return nil }
            shared = section
        }
        let container = parents[.tab(ids[0])]!
        let list = state.children(container)
        let first = list.firstIndex(of: .tab(ids[0]))!
        let index = first - list[..<first].filter { $0.tabID.map(ids.contains) ?? false }.count
        var next = state
        next.remove(Set(ids.map(Node.tab)))
        next.insert([.split(id)], into: container, at: index)
        next.lists[.split(id)] = ids.map(Node.tab)
        next.layouts[id] = .equal(ids.count, orientation)
        next.normalize()
        return next
    }

    /// A new pane joins the selected tab's group, or forms a pair in place of the selected row.
    func splitWithNewTab(selected: TabID?, url: URL, orientation: BrowserSplitOrientation, tab: TabID,
                         group: SplitGroupID, in state: ModelState, space: SpaceID)
        -> (ModelState, BrowserOrganizationAction)? {
        guard let selected, let section = splitSection(.tab(selected), in: state, space: space) else { return nil }
        let parents = state.parents
        var next = state
        next.tabs[tab] = ModelTab(title: nil, pinnedURL: section.keepsPinnedURL ? url : nil, url: url)
        if let existing = state.group(of: selected, parents) {
            guard state.members(existing).count < BrowserSplitGroup.maximumPanes else { return nil }
            next.lists[.split(existing)]!.append(.tab(tab))
            next.layouts[existing] = .equal(next.members(existing).count, state.layouts[existing]!.orientation)
            return (next, .addSplitPane)
        }
        let container = parents[.tab(selected)]!
        let index = state.children(container).firstIndex(of: .tab(selected))!
        next.remove([.tab(selected)])
        next.insert([.split(group)], into: container, at: index)
        next.lists[.split(group)] = [.tab(selected), .tab(tab)]
        next.layouts[group] = .equal(2, orientation)
        next.normalize()
        return (next, .createSplit)
    }

    func addPane(_ tab: TabID, to id: SplitGroupID, at index: Int?, orientation: BrowserSplitOrientation?,
                 in state: ModelState, space: SpaceID) -> ModelState? {
        guard let layout = state.layouts[id], let section = splitSection(.split(id), in: state, space: space),
              state.members(id).count < BrowserSplitGroup.maximumPanes,
              splitSection(.tab(tab), in: state, space: space) == section,
              state.group(of: tab, state.parents) == nil else { return nil }
        var next = state
        next.remove([.tab(tab)])
        var panes = next.children(.split(id))
        panes.insert(.tab(tab), at: min(max(index ?? panes.count, 0), panes.count))
        next.lists[.split(id)] = panes
        next.layouts[id] = .equal(panes.count, orientation ?? layout.orientation)
        next.normalize()
        return next
    }

    func unsplit(_ id: SplitGroupID, in state: ModelState, space: SpaceID) -> ModelState? {
        guard splitSection(.split(id), in: state, space: space) != nil else { return nil }
        var next = state
        next.dissolve(id)
        next.normalize()
        return next
    }

    func separate(_ tab: TabID, in state: ModelState, space: SpaceID) -> ModelState? {
        guard state.contains(.tab(tab)), let section = state.section(of: .tab(tab), state.parents),
              isVisible(section, in: space), let id = state.group(of: tab, state.parents) else { return nil }
        var next = state
        next.separate(tab, from: id)
        return next
    }

    /// A Today pane is archived; a Pinned pane leaves the group, back at its pinned URL.
    func closePane(_ tab: TabID, profileID: ProfileID, space: SpaceID, date: Date, in state: ModelState) -> ModelState? {
        guard let id = state.group(of: tab, state.parents),
              let section = splitSection(.split(id), in: state, space: space), let entry = state.tabs[tab] else {
            return nil
        }
        var next = state
        if case .today = section {
            next.remove([.tab(tab)])
            next.tabs[tab] = nil
            _ = next.insertArchive([ModelArchiveRecord(id: tab, profileID: profileID, spaceID: space, date: date,
                                                       reason: .closed, title: entry.title, url: entry.url)], cap: cap)
            next.settleSplits(from: state)
        } else {
            next.separate(tab, from: id)
            next.tabs[tab]?.url = entry.pinnedURL ?? entry.url
        }
        return next
    }

    func orient(_ id: SplitGroupID, _ orientation: BrowserSplitOrientation, in state: ModelState,
                space: SpaceID) -> ModelState? {
        guard splitSection(.split(id), in: state, space: space) != nil else { return nil }
        var next = state
        next.layouts[id]?.orientation = orientation
        return next
    }

    /// Exchanges the tabs of two slots; the slots keep their sizes.
    func swap(_ id: SplitGroupID, _ first: Int, _ second: Int, in state: ModelState, space: SpaceID) -> ModelState? {
        let panes = state.children(.split(id))
        guard state.layouts[id] != nil, panes.indices.contains(first), panes.indices.contains(second),
              splitSection(.split(id), in: state, space: space) != nil else { return nil }
        var next = state
        next.lists[.split(id)]!.swapAt(first, second)
        return next
    }

    func resize(_ id: SplitGroupID, ratios: [Double], stale: Bool, in state: ModelState, space: SpaceID) -> ModelState? {
        guard !stale, state.layouts[id] != nil, ratios.count == state.members(id).count,
              ratios.allSatisfy({ $0.isFinite && $0 > 0 }), abs(ratios.reduce(0, +) - 1) < 1e-6,
              splitSection(.split(id), in: state, space: space) != nil else { return nil }
        var next = state
        next.layouts[id]?.ratios = ratios
        return next
    }

    // MARK: Replays

    /// The record a replay would run now, for the menu label.
    func preview(window: WindowID, undoing: Bool, state: ModelState, windows: ModelWindows) -> BrowserOrganizationAction? {
        let profileID = spaceProfiles[windows.activeSpace[window]!]!
        for record in (undoing ? undo[window] : redo[window])?.reversed() ?? [] {
            guard record.profileID == profileID else { return nil }
            // Only preconditions decide the label; a structural failure is reported when replayed.
            if case .precondition = attempt(record, undoing: undoing, state: state, windows: windows) { continue }
            return record.action
        }
        return nil
    }

    mutating func replay(window: WindowID, undoing: Bool, state: ModelState, windows: ModelWindows) -> ReplayPrediction {
        let profileID = spaceProfiles[windows.activeSpace[window]!]!
        var stack = (undoing ? undo[window] : redo[window]) ?? []
        defer { if undoing { undo[window] = stack } else { redo[window] = stack } }
        var discarded = false
        while let record = stack.last, record.profileID == profileID {
            stack.removeLast()
            switch attempt(record, undoing: undoing, state: state, windows: windows) {
            case .precondition:
                discarded = true
            case .invalid:
                return .conflict
            case let .applied(next, evicted):
                var replayed = record
                for (index, evictedRecord) in evicted {
                    replayed.archive[evictedRecord.id] = undoing
                        ? ModelArchiveChange(pre: nil, post: evictedRecord, preIndex: nil, postIndex: index)
                        : ModelArchiveChange(pre: evictedRecord, post: nil, preIndex: index, postIndex: nil)
                }
                let to = undoing ? record.pre : record.post
                let toParents = to.parents
                for node in record.placements {
                    stamps[node] = toParents[node] == nil ? nil : (undoing ? record.preStamps : record.postStamps)[node]
                }
                if undoing { redo[window, default: []].append(replayed) } else { undo[window, default: []].append(replayed) }
                return .applied(next, record)
            }
        }
        return discarded ? .conflict : .nothing
    }

    enum Attempt {
        case precondition
        case invalid
        case applied(ModelState, [(Int, ModelArchiveRecord)])
    }

    func attempt(_ record: ModelRecord, undoing: Bool, state current: ModelState, windows: ModelWindows) -> Attempt {
        let from = undoing ? record.post : record.pre
        let to = undoing ? record.pre : record.post
        let fromStamps = undoing ? record.postStamps : record.preStamps
        let fromParents = from.parents, toParents = to.parents, currentParents = current.parents
        for node in record.placements {
            guard currentParents[node] == fromParents[node] else { return .precondition }
            if fromParents[node] != nil {
                guard (stamps[node] ?? 0) == (fromStamps[node] ?? 0) else { return .precondition }
            } else if current.contains(node) {
                return .precondition
            }
        }
        // A group the command changed must still be exactly as the command left it: membership,
        // order, orientation and sizes. Its whole record is then restored at once.
        let changedSplits = Set(from.layouts.keys).union(to.layouts.keys).filter { from.split($0) != to.split($0) }
        for id in changedSplits where current.split(id) != from.split(id) { return .precondition }
        let removedTabs = Set(from.tabs.keys).subtracting(to.tabs.keys)
        let createdTabs = Set(to.tabs.keys).subtracting(from.tabs.keys)
        let removedFolders = Set(from.folders.keys).subtracting(to.folders.keys)
        let createdFolders = Set(to.folders.keys).subtracting(from.folders.keys)
        for id in removedTabs {
            guard let tab = current.tabs[id], tab.title == from.tabs[id]?.title,
                  tab.pinnedURL == from.tabs[id]?.pinnedURL else { return .precondition }
        }
        for id in createdTabs where current.tabs[id] != nil { return .precondition }
        for id in removedFolders {
            guard current.folders[id] == from.folders[id],
                  current.children(.folder(id)).allSatisfy(record.placements.contains) else { return .precondition }
        }
        for id in createdFolders where current.folders[id] != nil { return .precondition }
        let sharedTabs = Set(from.tabs.keys).intersection(to.tabs.keys)
        for id in sharedTabs {
            guard let old = from.tabs[id], let new = to.tabs[id] else { continue }
            if old.title != new.title || old.pinnedURL != new.pinnedURL {
                guard let tab = current.tabs[id] else { return .precondition }
                if old.title != new.title, tab.title != old.title { return .precondition }
                if old.pinnedURL != new.pinnedURL, tab.pinnedURL != old.pinnedURL { return .precondition }
            }
        }
        for (id, title) in from.folders where to.folders[id].map({ $0 != title }) ?? false {
            guard current.folders[id] == title else { return .precondition }
        }
        for (id, change) in record.archive {
            let expected = undoing ? change.post : change.pre
            guard current.archive.first(where: { $0.id == id }) == expected else { return .precondition }
        }
        for node in record.placements {
            guard case let .folder(target)? = toParents[node] else { continue }
            guard createdFolders.contains(target) || (current.folders[target] != nil && !removedFolders.contains(target)) else {
                return .precondition
            }
        }

        var next = current
        next.remove(record.placements)
        for id in removedTabs { next.tabs[id] = nil }
        for id in removedFolders {
            next.folders[id] = nil
            next.lists[.folder(id)] = nil
        }
        for id in createdTabs { next.tabs[id] = to.tabs[id] }
        for id in createdFolders { next.folders[id] = to.folders[id] }
        for id in sharedTabs {
            guard let old = from.tabs[id], let new = to.tabs[id] else { continue }
            if old.title != new.title { next.tabs[id]?.title = new.title }
            if old.pinnedURL != new.pinnedURL { next.tabs[id]?.pinnedURL = new.pinnedURL }
        }
        for (id, title) in to.folders where from.folders[id].map({ $0 != title }) ?? false { next.folders[id] = title }
        let targets = record.placements.compactMap { node in to.placement(of: node, toParents).map { (node, $0) } }
        for (container, entries) in Dictionary(grouping: targets, by: \.1.container) {
            let ordered = entries.sorted { left, right in
                left.1.index != right.1.index ? left.1.index < right.1.index : key(left.0) < key(right.0)
            }
            for (node, placement) in ordered {
                let list = next.children(container)
                let index: Int
                if let previous = placement.previous, let found = list.firstIndex(of: previous) {
                    index = found + 1
                } else if let following = placement.next, let found = list.firstIndex(of: following) {
                    index = found
                } else {
                    index = min(placement.index, list.count)
                }
                next.insert([node], into: container, at: index)
            }
        }
        for id in changedSplits {
            next.lists[.split(id)] = to.split(id).map { $0.members.map(Node.tab) }
            next.layouts[id] = to.layouts[id]
        }
        next.normalize()

        // Never remove a tab claimed in another window nor take its visible panes away.
        // Automatic archive fallback is live but remains revocable until explicitly selected.
        let nextParents = next.parents
        for (window, tabs) in windows.claimed where window != record.window && !tabs.isDisjoint(with: removedTabs) {
            return .precondition
        }
        for (window, selected) in windows.visible where window != record.window {
            guard let space = windows.activeSpace[window] else { continue }
            for tab in current.shown(selected, currentParents) where windows.claimed[window]?.contains(tab) == true {
                let before = current.section(of: .tab(tab), currentParents)
                let after = next.section(of: .tab(tab), nextParents)
                guard before != after, let before, isVisible(before, in: space) else { continue }
                guard let after, isVisible(after, in: space) else { return .precondition }
            }
        }

        let replaced = Set(record.archive.keys)
        next.archive.removeAll { replaced.contains($0.id) }
        let inserted = record.archive.values.compactMap { change -> (ModelArchiveRecord, Int)? in
            guard let target = undoing ? change.pre : change.post else { return nil }
            return (target, (undoing ? change.preIndex : change.postIndex) ?? .max)
        }.sorted { $0.1 < $1.1 }.map(\.0)
        let evicted = next.insertArchive(inserted, cap: cap)
        if evicted.contains(where: { record in inserted.contains { $0.id == record.id } }) { return .invalid }
        guard next.isValid else { return .invalid }
        let evictedWithIndex = evicted.compactMap { record in
            current.archive.firstIndex { $0.id == record.id }.map { ($0, record) }
        }
        return .applied(next, evictedWithIndex)
    }

    private func key(_ node: Node) -> String {
        switch node {
        case let .split(id): return "s" + id.rawValue.uuidString
        case let .tab(id): return "t" + id.rawValue.uuidString
        case let .folder(id): return "f" + id.rawValue.uuidString
        }
    }
}

@Suite("Organization reference model")
struct BrowserOrganizationOracleTests {
    @Test("Randomized commands across two windows, split groups included, match an independent reference model, undo and redo included",
          arguments: [UInt64(0xA5C1_2026), 0x0DD5_EED5, 0x5EED_0003, 0xC0FF_EE42])
    func randomizedCommandsMatchReferenceModel(seed: UInt64) async throws {
        let fixture = try await OrganizationFixture.make()
        let cap = 3
        try await fixture.store.setMaximumArchivedTabs(cap)
        var generator = SplitMix64(seed: seed)
        var model = OrganizationModel(cap: cap, spaceProfiles: [fixture.home: fixture.personal,
            fixture.leisure: fixture.personal, fixture.lab: fixture.work])
        let spaceOrder = [fixture.home, fixture.leisure, fixture.lab]
        var effective: [String: Int] = [:]
        /// Split groups meeting the other features: dissolved by a non-split command, moved across
        /// sections, nested in a folder, restored by a replay, handed to the other window.
        var interplay: [String: Int] = [:]
        var conflicts = 0
        /// Groups in order of first appearance, so seeded choices never depend on random UUIDs.
        var knownSplits: [SplitGroupID] = []
        /// The prelude's tabs and group, shared across its steps.
        var preludeTabs: [TabID] = []
        var preludeGroup: SplitGroupID?
        let preludeLength = 16

        for step in 0..<3_000 {
            // A scripted prelude first meets every split interplay the walk must cover, through the
            // same predictions and journal; the seeded walk then explores freely.
            let scripted = step < preludeLength
            let windowID = scripted || generator.next() % 3 != 0 ? fixture.window : fixture.other
            if !scripted, generator.next() % 7 == 0 {
                let before = ModelState(await fixture.store.sessionDocument().organization)
                try await fixture.activate(spaceOrder[Int(generator.next() % 3)], in: windowID)
                #expect(ModelState(await fixture.store.sessionDocument().organization) == before)
            }
            let preDocument = await fixture.store.sessionDocument()
            let pre = ModelState(preDocument.organization)
            let preParents = pre.parents
            // Live ownership is an input to this organization oracle, like selection and Space.
            // Keep the graph, journal and conflict predictions independent of the implementation.
            let automatic = await fixture.store.windows.mapValues(\.organizationFallbackOccurrences)
            let windowsBefore = ModelWindows(preDocument, automatic: automatic)
            let context = try await fixture.context(windowID)
            let space = context.spaceID
            let snapshot = try await fixture.store.organizationSnapshot(from: context)
            #expect(snapshot.undoAction == model.preview(window: windowID, undoing: true, state: pre, windows: windowsBefore),
                    "undo label, step \(step)")
            #expect(snapshot.redoAction == model.preview(window: windowID, undoing: false, state: pre, windows: windowsBefore),
                    "redo label, step \(step)")
            let tabs = snapshot.allTabs.map(\.id)
            let rows = snapshot.rows(includingCollapsed: true).map(\.node)
            let localFolders = rows.compactMap(\.folderID)
            let localSplits = rows.compactMap(\.splitID)
            let panes = tabs.filter { pre.group(of: $0, preParents) != nil }
            knownSplits += pre.layouts.keys.filter { !knownSplits.contains($0) }
                .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            let allSplits = knownSplits.filter { pre.layouts[$0] != nil }
            func pick<T>(_ values: [T]) -> T? { values.isEmpty ? nil : values[Int(generator.next() % UInt64(values.count))] }
            func chance(_ denominator: UInt64) -> Bool { generator.next() % denominator == 0 }
            let containers: [Container] = [.favorites(context.profileID), .pinned(space), .today(space),
                .pinned(fixture.leisure), .today(fixture.home)] + localFolders.map { .folder($0) }
                + localSplits.map { .split($0) }
            let preStamps = model.stamps

            /// After a forward command: `expected` is the model's prediction (nil: refused), `action`
            /// journals it, `explicit` lists the nodes it moved within their container.
            func finish(
                _ name: String, failed: Bool, expected: ModelState?, action: BrowserOrganizationAction?,
                explicit: Set<Node> = [], effects: ModelEffects? = nil
            ) async {
                let postDocument = await fixture.store.sessionDocument()
                let post = ModelState(postDocument.organization)
                #expect(failed == (expected == nil), "\(name) outcome, step \(step)")
                if let expected, !failed {
                    #expect(post == expected, "\(name) result, step \(step)\n\(post.difference(from: expected))")
                }
                if failed { #expect(post == pre, "\(name) refusal leaves the organization untouched, step \(step)") }
                let written = model.recordWrites(pre: pre, post: post, explicit: explicit)
                if let action, !failed {
                    model.journal(action, window: windowID, space: space, pre: pre, post: post, written: written,
                                  preStamps: preStamps, windowsBefore: windowsBefore,
                                  windowsAfter: ModelWindows(postDocument), effects: effects)
                }
                if post != pre { effective[name, default: 0] += 1 }
                notePlay(name, post)
            }

            func notePlay(_ name: String, _ post: ModelState) {
                let postParents = post.parents
                let splitCommands: Set<String> = ["unsplit", "separate", "closePane"]
                if !splitCommands.contains(name),
                   pre.layouts.keys.contains(where: { post.layouts[$0] == nil }) { interplay["dissolved by \(name)", default: 0] += 1 }
                for id in pre.layouts.keys where post.layouts[id] != nil {
                    if pre.section(of: .split(id), preParents) != post.section(of: .split(id), postParents) {
                        interplay["group moved across sections", default: 0] += 1
                    }
                }
                // Unequal sizes surviving a lost pane, or a swap, are where size rules differ.
                for (id, layout) in pre.layouts where Set(layout.ratios).count > 1 {
                    guard let after = post.split(id) else { continue }
                    if after.members.count < pre.members(id).count { interplay["resized group loses a pane", default: 0] += 1 }
                    if after.members.count == pre.members(id).count, after.members != pre.members(id) {
                        interplay["resized group reorders panes", default: 0] += 1
                    }
                }
                if post.layouts.keys.contains(where: { !post.ancestors(of: .split($0), postParents).isEmpty }) {
                    interplay["group inside a folder", default: 0] += 1
                }
            }

            func check(
                _ name: String, expected: ModelState?, action: BrowserOrganizationAction?, explicit: Set<Node> = [],
                effects: ModelEffects? = nil, _ run: () async throws -> Void
            ) async {
                var failed = false
                do { try await run() } catch { failed = true }
                await finish(name, failed: failed, expected: expected, action: action, explicit: explicit, effects: effects)
            }

            func replayStep(undoing: Bool) async {
                let prediction = model.replay(window: windowID, undoing: undoing, state: pre, windows: windowsBefore)
                var thrown: (any Error)?
                do {
                    if undoing {
                        _ = try await fixture.store.undoOrganization(from: context)
                    } else {
                        _ = try await fixture.store.redoOrganization(from: context)
                    }
                } catch { thrown = error }
                let postDocument = await fixture.store.sessionDocument()
                let post = ModelState(postDocument.organization)
                let name = undoing ? "undo" : "redo"
                switch prediction {
                case .nothing:
                    #expect((thrown as? BrowserOrganizationError) == (undoing ? .nothingToUndo : .nothingToRedo),
                            "\(name) on an empty journal, step \(step)")
                    #expect(post == pre)
                case .conflict:
                    #expect((thrown as? BrowserOrganizationError) == .undoConflict, "\(name) conflict, step \(step)")
                    #expect(post == pre, "\(name) conflict leaves the model untouched, step \(step)")
                    conflicts += 1
                case let .applied(expected, record):
                    #expect(thrown == nil, "\(name) applies, step \(step)")
                    #expect(post == expected, "\(name) result, step \(step)\n\(post.difference(from: expected))")
                    let windowsAfter = ModelWindows(postDocument)
                    if undoing, thrown == nil {
                        let parents = expected.parents
                        for tab in record.liveTabs {
                            guard let section = expected.section(of: .tab(tab), parents),
                                  model.spaceProfiles[section.spaceID ?? record.spaceID] == record.profileID else { continue }
                            #expect(windowsAfter.live[windowID]?.contains(tab) == true, "undo reopens, step \(step)")
                        }
                        if let displaced = record.displaced, windowsAfter.activeSpace[windowID] == record.spaceID,
                           let section = expected.section(of: .tab(displaced), parents),
                           model.isVisible(section, in: record.spaceID) {
                            #expect(windowsAfter.visible[windowID] == displaced, "undo reselects after \(record.action), step \(step)")
                        }
                    }
                    effective[name, default: 0] += 1
                    if Set(pre.layouts.keys).union(post.layouts.keys).contains(where: { pre.split($0) != post.split($0) }) {
                        interplay["replay restores a group", default: 0] += 1
                    }
                    notePlay(name, post)
                }
            }

            /// Hands a live group to the other window, then releases the source's occurrences.
            func transferStep(_ group: SplitGroupID, stale: Bool) async throws {
                guard let saved = preDocument.organization.splits.first(where: { $0.id == group }) else { return }
                let target = windowID == fixture.window ? fixture.other : fixture.window
                let targetContext = try await fixture.context(target)
                let claimed = stale
                    ? BrowserSplitGroup(id: group, tabIDs: saved.tabIDs.reversed(), orientation: saved.orientation,
                                        ratios: saved.ratios)
                    : saved
                let urls = Dictionary(uniqueKeysWithValues: saved.tabIDs.map { ($0, pre.tabs[$0]!.url) })
                let existing = Dictionary(uniqueKeysWithValues: preDocument.tabs
                    .filter { $0.windowID == target && saved.tabIDs.contains($0.id) }.map { ($0.id, $0.occurrenceID) })
                let activating = pick(saved.tabIDs)
                let admissible = !stale && (pre.section(of: .split(group), preParents)
                    .map { model.isVisible($0, in: targetContext.spaceID) } ?? false)
                var admitted = false
                do {
                    _ = try await fixture.store.openTransferredSplitOccurrences(
                        claimed, urlsByTabID: urls, expectedExistingOccurrences: existing, from: targetContext,
                        activating: activating)
                    admitted = true
                } catch {}
                #expect(admitted == admissible, "transfer admission, step \(step)")
                if admitted {
                    let sourceState = try await fixture.store.captureWindowState(in: windowID)
                    let leases = await fixture.store.sessionDocument().tabs
                        .filter { $0.windowID == windowID && saved.tabIDs.contains($0.id) }
                        .compactMap { sourceState.occurrenceAuthorities[$0.occurrenceID] }
                    if !leases.isEmpty {
                        _ = try await fixture.store.releaseOwnedOccurrencesAndCaptureState(leases, validating: context)
                    }
                    let after = ModelWindows(await fixture.store.sessionDocument())
                    #expect(Set(saved.tabIDs).isSubset(of: after.live[target] ?? []), "target holds every pane, step \(step)")
                    #expect((after.live[windowID] ?? []).isDisjoint(with: saved.tabIDs), "source keeps no pane, step \(step)")
                    #expect(after.visible[target] == activating, "target shows the activated pane, step \(step)")
                    #expect(after.visible[windowID].map { !saved.tabIDs.contains($0) } ?? true,
                            "source no longer shows the group, step \(step)")
                    effective["transfer", default: 0] += 1
                    interplay["group handed to the other window", default: 0] += 1
                }
                // A transfer, admitted or refused, never edits the shared group or the journals.
                let postDocument = await fixture.store.sessionDocument()
                #expect(ModelState(postDocument.organization) == pre, "transfer leaves the organization, step \(step)")
                #expect(postDocument.organization.splits.first { $0.id == group } == saved,
                        "transfer keeps group identity, order and sizes, step \(step)")
            }

            if scripted, step < 5 {
                let opened = try await fixture.open("prelude\(step)", in: windowID)
                preludeTabs.append(opened)
                var expected = pre
                expected.tabs[opened] = ModelTab(title: nil, pinnedURL: nil, url: organizationURL("prelude\(step)"))
                expected.insert([.tab(opened)], into: .today(space), at: 0)
                expected.normalize()
                await finish("open", failed: false, expected: expected, action: nil)
            } else if scripted, step == 5 {
                let ids = Array(preludeTabs[0..<4])
                let group = try await fixture.store.createSplit(ids, orientation: .vertical, from: context).0
                preludeGroup = group
                await finish("createSplit", failed: false,
                             expected: model.createSplit(ids, .vertical, id: group, in: pre, space: space),
                             action: .createSplit, effects: ModelEffects(selected: nil))
            } else if scripted, let group = preludeGroup {
                let panes = pre.members(group)
                switch step {
                case 6:
                    let sizes = [0.1, 0.2, 0.3, 0.4]
                    await check("resize", expected: model.resize(group, ratios: sizes, stale: false, in: pre, space: space),
                                action: .resizeSplit) {
                        _ = try await fixture.store.resizeSplit(group, ratios: sizes, from: context)
                    }
                case 7:
                    await check("swap", expected: model.swap(group, 0, 3, in: pre, space: space), action: .swapSplitPanes) {
                        _ = try await fixture.store.swapSplitPanes(group, first: 0, second: 3, from: context)
                    }
                case 8:
                    await check("separate", expected: model.separate(panes[1], in: pre, space: space), action: .unsplit) {
                        _ = try await fixture.store.separateSplitPane(panes[1], from: context)
                    }
                case 9: await replayStep(undoing: true)
                case 10: await replayStep(undoing: false)
                case 11:
                    let prediction = model.move(model.groupedNodes(panes, in: pre), to: .pinned(space), atEnd: true,
                                                in: pre, space: space)
                    await check("pinGroup", expected: prediction?.0, action: .pinTabs, explicit: prediction?.2 ?? []) {
                        _ = try await fixture.store.pinTabs(panes, from: context)
                    }
                case 12:
                    var created: FolderID?
                    do {
                        created = try await fixture.store.createFolder(title: "Prelude", at: .init(.pinned(space), position: .end),
                                                                       containing: [.split(group)], from: context).0
                    } catch {}
                    var expected = pre
                    var explicit: Set<Node> = []
                    if let created {
                        expected.folders[created] = "Prelude"
                        expected.insert([.folder(created)], into: .pinned(space), at: expected.children(.pinned(space)).count)
                        if let moved = model.move([.split(group)], to: .folder(created), in: expected, space: space) {
                            expected = moved.0
                            explicit = moved.2
                        }
                    }
                    await finish("createFolder", failed: created == nil, expected: expected, action: .createFolder,
                                 explicit: explicit)
                case 13:
                    try await transferStep(group, stale: false)
                case 14:
                    await check("addPane", expected: model.addPane(preludeTabs[4], to: group, at: 0, orientation: .horizontal,
                                                                   in: pre, space: space), action: .addSplitPane) {
                        _ = try await fixture.store.addPane(preludeTabs[4], to: group, at: 0, orientation: .horizontal,
                                                            from: context)
                    }
                default:
                    // Archiving all but one pane, outside any split command, dissolves the group.
                    let archived = Array(panes.dropFirst())
                    await check("archive", expected: model.archive(archived, profileID: context.profileID, space: space,
                                                                   date: fixture.clock.now, in: pre),
                                action: .archiveTabs) {
                        _ = try await fixture.store.archiveTabs(archived, from: context)
                    }
                }
            } else {
                switch generator.next() % 26 {
                case 0, 1:
                    let activate = chance(2)
                    var opened: TabID?
                    do { opened = try await fixture.open("step\(step)", in: windowID, activate: activate) } catch {}
                    var expected = pre
                    if let opened {
                        expected.tabs[opened] = ModelTab(title: nil, pinnedURL: nil, url: organizationURL("step\(step)"))
                        expected.insert([.tab(opened)], into: .today(space), at: 0)
                        expected.normalize()
                    }
                    await finish("open", failed: opened == nil, expected: expected, action: nil)
                case 2:
                    if chance(3), let split = pick(localSplits) {
                        await check("select", expected: pre, action: nil) {
                            _ = try await fixture.store.selectSplit(split, from: context)
                        }
                    } else if let tab = pick(tabs) {
                        await check("select", expected: pre, action: nil) {
                            _ = try await fixture.store.selectTab(tab, from: context)
                        }
                    }
                case 3, 4:
                    // Rows (tabs, folders, group rows) plus, sometimes, individual panes.
                    let nodes = rows.filter { _ in chance(3) } + panes.filter { _ in chance(5) }.map { Node.tab($0) }
                    guard let container = pick(containers), !nodes.isEmpty else { continue }
                    let prediction = model.move(nodes, to: container, in: pre, space: space)
                    await check("move", expected: prediction?.0, action: prediction?.1, explicit: prediction?.2 ?? []) {
                        _ = try await fixture.store.moveItems(nodes, to: .init(container, position: .start), from: context)
                    }
                case 5:
                    let target: Container = pick(localFolders).map { .folder($0) } ?? .pinned(space)
                    let contents = tabs.filter { _ in chance(4) }.map { Node.tab($0) }
                        + localSplits.filter { _ in chance(3) }.map { Node.split($0) }
                    var created: FolderID?
                    do {
                        created = try await fixture.store.createFolder(title: "F\(step)", at: .init(target),
                                                                       containing: contents, from: context).0
                    } catch {}
                    var expected = pre
                    var explicit: Set<Node> = []
                    if let created {
                        expected.folders[created] = "F\(step)"
                        expected.insert([.folder(created)], into: target, at: expected.children(target).count)
                        if !contents.isEmpty, let moved = model.move(contents, to: .folder(created), in: expected, space: space) {
                            // `move` inserts at the start; in an empty new folder start and end are equal.
                            expected = moved.0
                            explicit = moved.2
                        }
                        expected.normalize()
                    }
                    await finish("createFolder", failed: created == nil, expected: expected, action: .createFolder,
                                 explicit: explicit)
                case 6:
                    if chance(2) {
                        let ids = tabs.filter { _ in chance(4) } + panes.filter { _ in chance(3) }
                        guard !ids.isEmpty else { continue }
                        let expected = model.archive(ids, profileID: context.profileID, space: space,
                                                     date: fixture.clock.now, in: pre)
                        await check("archive", expected: expected, action: .archiveTabs) {
                            _ = try await fixture.store.archiveTabs(ids, from: context)
                        }
                    } else if let tab = pick(chance(4) ? panes : tabs) ?? pick(tabs) {
                    var expected = pre
                    var action: BrowserOrganizationAction?
                    if case .today? = pre.section(of: .tab(tab), preParents) {
                        expected = model.archive([tab], profileID: context.profileID, space: space,
                                                 date: fixture.clock.now, in: pre)!
                        action = .closeTabs
                    }
                        await check("close", expected: expected, action: action) {
                            _ = try await fixture.store.closeTabs([tab], from: context)
                        }
                    }
                case 7:
                    guard let folder = pick(localFolders) else { continue }
                    let keep = chance(2)
                    var expected = pre
                    if keep, let placement = pre.placement(of: .folder(folder), preParents) {
                        let children = pre.children(.folder(folder))
                        expected.remove(Set(children))
                        expected.insert(children, into: placement.container, at: placement.index + 1)
                        expected.remove([.folder(folder)])
                        expected.folders[folder] = nil
                        expected.lists[.folder(folder)] = nil
                    } else {
                        let subtree = pre.subtree(.folder(folder))
                        let records = subtree.compactMap(\.tabID).map { id in
                            ModelArchiveRecord(id: id, profileID: context.profileID, spaceID: space, date: fixture.clock.now,
                                               reason: .removed, title: pre.tabs[id]?.title, url: pre.tabs[id]!.url)
                        }
                        expected.remove(Set(subtree))
                        for node in subtree {
                            switch node {
                            case let .split(id): expected.layouts[id] = nil; expected.lists[.split(id)] = nil
                            case let .tab(id): expected.tabs[id] = nil
                            case let .folder(id): expected.folders[id] = nil; expected.lists[.folder(id)] = nil
                            }
                        }
                        _ = expected.insertArchive(Array(records.reversed()), cap: cap)
                    }
                    expected.normalize()
                    await check("deleteFolder", expected: expected, action: .deleteFolder) {
                        _ = try await fixture.store.deleteFolder(folder, contents: keep ? .keepContents : .archiveContents,
                                                                 from: context)
                    }
                case 8, 9, 10:
                    await replayStep(undoing: chance(2))
                case 11:
                    guard let record = pick(try await fixture.store.archivedTabs(from: context)) else { continue }
                    let activate = chance(2)
                    var expected = pre
                    expected.archive.removeAll { $0.id == record.id }
                    expected.tabs[record.id] = ModelTab(title: record.tab.customTitle, pinnedURL: nil, url: record.tab.url)
                    expected.insert([.tab(record.id)], into: .today(record.spaceID), at: 0)
                    expected.normalize()
                    await check("restore", expected: expected, action: .restoreArchivedTab) {
                        _ = try await fixture.store.restoreArchivedTab(record.id, activate: activate, from: context)
                    }
                case 12:
                    if chance(3), let folder = pick(localFolders) {
                        var expected = pre
                        expected.folders[folder] = "N\(step)"
                        await check("renameFolder", expected: expected, action: .renameFolder) {
                            _ = try await fixture.store.renameFolder(folder, to: "N\(step)", from: context)
                        }
                    } else if let tab = pick(tabs) {
                        let title = chance(4) ? nil : "R\(step % 5)"
                        var expected = pre
                        expected.tabs[tab]?.title = title
                        await check("renameTab", expected: expected, action: .renameTab) {
                            _ = try await fixture.store.renameTab(tab, to: title, from: context)
                        }
                    }
                case 13, 14:
                    fixture.clock.advance(by: 3_600 * Double(generator.next() % 30))
                    let now = fixture.clock.now
                    let lastActive = Dictionary(uniqueKeysWithValues: preDocument.organization.tabs.map { ($0.id, $0.lastActiveAt) })
                    // Every pane of a window's visible group is on screen.
                    let visible = Set(windowsBefore.visible.values.flatMap { pre.shown($0, preParents) })
                    var expected = pre
                    for sweptSpace in spaceOrder {
                        // A group expires as a unit: only when none of its panes is recent or visible.
                        let blocks = pre.children(.today(sweptSpace)).map { node in
                            node.splitID.map(pre.members) ?? node.tabID.map { [$0] } ?? []
                        }
                        let expired = blocks.filter { block in
                            block.allSatisfy { id in !visible.contains(id) && now.timeIntervalSince(lastActive[id]!) >= 12 * 3_600 }
                        }.flatMap { $0 }
                        guard !expired.isEmpty else { continue }
                        expected.remove(Set(expired.map { .tab($0) }))
                        let records = expired.map { id in
                            ModelArchiveRecord(id: id, profileID: model.spaceProfiles[sweptSpace]!, spaceID: sweptSpace,
                                               date: now, reason: .automatic, title: pre.tabs[id]?.title, url: pre.tabs[id]!.url)
                        }
                        for id in expired { expected.tabs[id] = nil }
                        _ = expected.insertArchive(Array(records.reversed()), cap: cap)
                    }
                    expected.settleSplits(from: pre)
                    await check("sweep", expected: expected, action: nil) {
                        _ = await fixture.store.archiveExpiredTabs()
                    }
                case 15, 16:
                    let pool: [TabID]
                    switch generator.next() % 4 {
                    case 0, 1: pool = tabs.filter { pre.section(of: .tab($0), preParents) == .today(space) }
                    case 2: pool = tabs.filter { pre.section(of: .tab($0), preParents) == .pinned(space) }
                    default: pool = tabs
                    }
                    // Mostly free tabs; sometimes panes, which nesting refuses.
                    var shuffled = chance(4) ? pool : pool.filter { pre.group(of: $0, preParents) == nil }
                    for index in shuffled.indices.reversed() where index > 0 {
                        shuffled.swapAt(index, Int(generator.next() % UInt64(index + 1)))
                    }
                    var ids = Array(shuffled.prefix([1, 2, 2, 3, 3, 3, 4, 4, 5][Int(generator.next() % 9)]))
                    if chance(10), let first = ids.first { ids.append(first) }
                    guard !ids.isEmpty else { continue }
                    let orientation: BrowserSplitOrientation = chance(2) ? .horizontal : .vertical
                    var created: SplitGroupID?
                    do { created = try await fixture.store.createSplit(ids, orientation: orientation, from: context).0 } catch {}
                    let expected = model.createSplit(ids, orientation, id: created ?? SplitGroupID(), in: pre, space: space)
                    await finish("createSplit", failed: created == nil, expected: expected, action: .createSplit,
                                 effects: ModelEffects(selected: nil))
                case 17:
                    if chance(2) {
                        let url = organizationURL("pane\(step)")
                        let orientation: BrowserSplitOrientation = chance(2) ? .horizontal : .vertical
                        var succeeded = false
                        do {
                            _ = try await fixture.store.splitWithNewTab(url: url, orientation: orientation, from: context)
                            succeeded = true
                        } catch {}
                        let probe = ModelState(await fixture.store.sessionDocument().organization)
                        let prediction = model.splitWithNewTab(
                            selected: windowsBefore.visible[windowID], url: url, orientation: orientation,
                            tab: Set(probe.tabs.keys).subtracting(pre.tabs.keys).first ?? TabID(),
                            group: Set(probe.layouts.keys).subtracting(pre.layouts.keys).first ?? SplitGroupID(),
                            in: pre, space: space)
                        await finish("splitWithNewTab", failed: !succeeded, expected: prediction?.0, action: prediction?.1,
                                     effects: ModelEffects(selected: nil))
                    } else {
                        // Mostly a free tab of the group's own section; otherwise anything, which may refuse.
                        guard let group = pick(chance(4) ? allSplits : localSplits) else { continue }
                        let section = pre.section(of: .split(group), preParents)
                        let compatible = tabs.filter {
                            pre.group(of: $0, preParents) == nil && pre.section(of: .tab($0), preParents) == section
                        }
                        guard let tab = pick(chance(4) ? tabs : compatible) ?? pick(tabs) else { continue }
                        let count = pre.members(group).count
                        let index: Int? = chance(3) ? nil : Int(generator.next() % UInt64(count + 1))
                        let orientation: BrowserSplitOrientation? = [nil, .horizontal, .vertical][Int(generator.next() % 3)]
                        let expected = model.addPane(tab, to: group, at: index, orientation: orientation, in: pre, space: space)
                        await check("addPane", expected: expected, action: .addSplitPane) {
                            _ = try await fixture.store.addPane(tab, to: group, at: index, orientation: orientation, from: context)
                        }
                    }
                case 18:
                    if chance(2) {
                        guard let group = pick(chance(4) ? allSplits : localSplits) else { continue }
                        await check("unsplit", expected: model.unsplit(group, in: pre, space: space), action: .unsplit) {
                            _ = try await fixture.store.unsplit(group, from: context)
                        }
                    } else {
                        guard let tab = pick(chance(4) ? tabs : panes) else { continue }
                        await check("separate", expected: model.separate(tab, in: pre, space: space), action: .unsplit) {
                            _ = try await fixture.store.separateSplitPane(tab, from: context)
                        }
                    }
                case 19, 25:
                    guard let group = pick(chance(5) ? allSplits : localSplits) else { continue }
                    if chance(3) {
                        let orientation: BrowserSplitOrientation = chance(2) ? .horizontal : .vertical
                        await check("orient", expected: model.orient(group, orientation, in: pre, space: space),
                                    action: .orientSplit) {
                            _ = try await fixture.store.setSplitOrientation(orientation, for: group, from: context)
                        }
                    } else {
                        // Slot indices include one past the end, which refuses.
                        let slots = UInt64(pre.members(group).count + 1)
                        let first = Int(generator.next() % slots), second = Int(generator.next() % slots)
                        await check("swap", expected: model.swap(group, first, second, in: pre, space: space),
                                    action: .swapSplitPanes) {
                            _ = try await fixture.store.swapSplitPanes(group, first: first, second: second, from: context)
                        }
                    }
                case 20, 24:
                    guard let group = pick(chance(5) ? allSplits : localSplits),
                          let saved = preDocument.organization.splits.first(where: { $0.id == group }) else { continue }
                    var weights = saved.tabIDs.map { _ in Double(generator.next() % 9 + 1) }
                    switch generator.next() % 8 {
                    case 0: weights.append(1)                       // one size too many
                    case 1: weights[0] = 0                          // an empty slot
                    default: break
                    }
                    let total = weights.reduce(0, +)
                    let ratios = chance(8) ? weights.map { $0 / (total * 0.9) } : weights.map { $0 / total }
                    // The caller may hold the layout it started dragging from; a newer one refuses.
                    let stale = chance(5)
                    let expectedGroup: BrowserSplitGroup? = chance(2) ? nil : stale
                        ? BrowserSplitGroup(id: group, tabIDs: saved.tabIDs,
                                            orientation: saved.orientation == .horizontal ? .vertical : .horizontal,
                                            ratios: saved.ratios)
                        : saved
                    let expected = model.resize(group, ratios: ratios, stale: stale && expectedGroup != nil, in: pre, space: space)
                    await check("resize", expected: expected, action: .resizeSplit) {
                        _ = try await fixture.store.resizeSplit(group, ratios: ratios, expectedGroup: expectedGroup, from: context)
                    }
                case 21:
                    guard let tab = pick(chance(5) ? tabs : panes) else { continue }
                    let selected = windowsBefore.visible[windowID]
                    await check("closePane", expected: model.closePane(tab, profileID: context.profileID, space: space,
                                                                       date: fixture.clock.now, in: pre),
                                action: .closeSplitPane,
                                effects: ModelEffects(live: [tab], selected: selected == tab ? tab : nil)) {
                        _ = try await fixture.store.closeSplitPane(tab, from: context)
                    }
                case 22:
                    guard let group = pick(localSplits) else { continue }
                    var ids = pre.members(group)
                    if chance(3) { ids.removeLast() }
                    if chance(3), let extra = pick(tabs) { ids.append(extra) }
                    let pin = chance(2)
                    let nodes = model.groupedNodes(ids, in: pre)
                    let prediction = model.move(nodes, to: pin ? .pinned(space) : .today(space), atEnd: pin, in: pre, space: space)
                    await check("pinGroup", expected: prediction?.0, action: pin ? .pinTabs : .unpinTabs,
                                explicit: prediction?.2 ?? []) {
                        if pin {
                            _ = try await fixture.store.pinTabs(ids, from: context)
                        } else {
                            _ = try await fixture.store.unpinTabs(ids, from: context)
                        }
                    }
                default:
                    guard let group = pick(localSplits) else { continue }
                    try await transferStep(group, stale: chance(5))
                }
            }
            let document = await fixture.store.sessionDocument()
            try document.validate()
            #expect(ModelState(document.organization).isValid, "model invariants, step \(step)")
            let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(document.encoded()))
            #expect(await restored.sessionDocument() == document)
        }
        // Only commands that changed the organization count; every family must have done so.
        let families = ["open", "move", "createFolder", "close", "archive", "deleteFolder", "undo", "redo", "restore",
                        "renameTab", "renameFolder", "sweep", "createSplit", "splitWithNewTab", "addPane", "unsplit",
                        "separate", "orient", "swap", "resize", "closePane", "pinGroup", "transfer"]
        for family in families { #expect(effective[family, default: 0] > 0, "\(family) never changed anything") }
        for situation in ["group moved across sections", "group inside a folder", "replay restores a group",
                          "group handed to the other window", "resized group loses a pane",
                          "resized group reorders panes"] {
            #expect(interplay[situation, default: 0] > 0, "\(situation) never happened")
        }
        #expect(interplay.keys.contains { $0.hasPrefix("dissolved by ") }, "no command outside Split dissolved a group")
        #expect(conflicts > 0, "no undo conflict was exercised")
    }

    @Test("Unequal sizes follow their panes through swap, separation, moves, closing and archive, and replays restore each layout")
    func sizeRulesAcrossCommands() async throws {
        let fixture = try await OrganizationFixture.make()
        let model = OrganizationModel(cap: 50, spaceProfiles: [fixture.home: fixture.personal,
            fixture.leisure: fixture.personal, fixture.lab: fixture.work])
        try await fixture.store.setMaximumArchivedTabs(50)
        var ids: [TabID] = []
        for index in 0..<5 { ids.append(try await fixture.open("size-\(index)")) }
        var history: [ModelState] = []
        func state() async -> ModelState { ModelState(await fixture.store.sessionDocument().organization) }
        /// Runs one command, compares it with the model's prediction, and keeps the state before it.
        func step(_ name: String, _ prediction: (ModelState) -> ModelState?, _ run: () async throws -> Void) async throws {
            let before = await state()
            let expected = try #require(prediction(before), "\(name) is refused by the model")
            try await run()
            let after = await state()
            #expect(after == expected, "\(name)\n\(after.difference(from: expected))")
            history.append(before)
            try await fixture.validate()
        }
        let context = { try await fixture.context() }
        let (group, _) = try await fixture.store.createSplit(Array(ids[0..<4]), orientation: .vertical, from: context())
        history.append(await state())
        let sizes = [0.1, 0.2, 0.3, 0.4]
        try await step("resize", { model.resize(group, ratios: sizes, stale: false, in: $0, space: fixture.home) }) {
            _ = try await fixture.store.resizeSplit(group, ratios: sizes, from: context())
        }
        try await step("swap", { model.swap(group, 0, 3, in: $0, space: fixture.home) }) {
            _ = try await fixture.store.swapSplitPanes(group, first: 0, second: 3, from: context())
        }
        #expect(await state().layouts[group]?.ratios == sizes, "swapping keeps the slot sizes")
        try await step("separate", { model.separate(ids[1], in: $0, space: fixture.home) }) {
            _ = try await fixture.store.separateSplitPane(ids[1], from: context())
        }
        try await step("addPane", { model.addPane(ids[4], to: group, at: 1, orientation: nil, in: $0, space: fixture.home) }) {
            _ = try await fixture.store.addPane(ids[4], to: group, at: 1, from: context())
        }
        let resized = [0.5, 0.25, 0.125, 0.125]
        try await step("resize again", { model.resize(group, ratios: resized, stale: false, in: $0, space: fixture.home) }) {
            _ = try await fixture.store.resizeSplit(group, ratios: resized, from: context())
        }
        try await step("move a pane", {
            model.move([.tab(ids[4])], to: .pinned(fixture.home), in: $0, space: fixture.home)?.0
        }) {
            _ = try await fixture.store.moveItems([.tab(ids[4])], to: .init(.pinned(fixture.home), position: .start),
                                                  from: context())
        }
        try await step("archive a pane", {
            model.archive([ids[2]], profileID: fixture.personal, space: fixture.home, date: fixture.clock.now, in: $0)
        }) {
            _ = try await fixture.store.archiveTabs([ids[2]], from: context())
        }
        try await step("close the last pair", {
            model.closePane(ids[3], profileID: fixture.personal, space: fixture.home, date: fixture.clock.now, in: $0)
        }) {
            _ = try await fixture.store.closeSplitPane(ids[3], from: context())
        }
        #expect(await state().layouts[group] == nil, "a single survivor dissolves the group")
        // Each undo restores the exact previous state, sizes included; redo replays forward again.
        let final = await state()
        for expected in history.dropFirst().reversed() {
            _ = try await fixture.store.undoOrganization(from: context())
            let after = await state()
            #expect(after == expected, "undo\n\(after.difference(from: expected))")
        }
        for _ in history.dropFirst() { _ = try await fixture.store.redoOrganization(from: context()) }
        let redone = await state()
        #expect(redone == final, "redo\n\(redone.difference(from: final))")
        try await fixture.validate()
    }
}
