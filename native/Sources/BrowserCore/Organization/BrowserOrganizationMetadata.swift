import Foundation

/// An atomic, nonstructural update. Missing history is represented by a full-resync result,
/// never by a partial delta. These revisions do not replace context/ownership admission.
public struct BrowserOrganizationMetadata: Sendable {
    public let revision: UInt64
    public let tabs: [TabID: BrowserOrganizedTab]
    public let localDestinations: [TabID: URL]
    public let destinations: [TabOccurrenceID: URL]
}

extension BrowserStore {
    func metadataIsVisible(_ id: TabID, in windowID: WindowID) -> Bool {
        guard let window = windows[windowID] else { return false }
        var root = organization.container(of: .tab(id))
        var remaining = organization.folders.count + organization.splits.count + 1
        while let parent = root?.owningNode, remaining > 0 {
            root = organization.container(of: parent)
            remaining -= 1
        }
        if case let .standalone(owner) = root { return owner == windowID }
        if window.standaloneProfileID != nil {
            return organization.container(of: .tab(id)) == .standalone(windowID)
                || organization.standalone[windowID, default: []].contains { organization.tabIDs(in: $0).contains(id) }
        }
        switch organization.section(of: .tab(id)) {
        case let .favorites(profile): return spaces[window.activeSpaceID]?.profileID == profile
        case let .pinned(space), let .today(space): return window.activeSpaceID == space
        case nil: return false
        }
    }

    /// The journal covers skipped notifications too, including updates to inactive Spaces.
    /// Any structural/catalog publication forces the established full capture path.
    public func organizationMetadata(since revision: UInt64, from context: BrowserContext, catalogRevision expectedCatalogRevision: UInt64) throws -> BrowserOrganizationMetadata? {
        guard isCurrent(context), metadataOccurrences[context.windowID] != nil,
              expectedCatalogRevision == catalogRevision else { return nil }
        guard revision >= organizationMetadataFloor, revision <= organizationRevision else { return nil }
        var changed: Set<TabID> = []
        for entry in organizationMetadataHistory where entry.revision > revision { changed.formUnion(entry.tabs) }
        var values: [TabID: BrowserOrganizedTab] = [:]
        for id in changed { values[id] = organization.tabs[id] }
        var destinations: [TabOccurrenceID: URL] = [:]
        var localDestinations: [TabID: URL] = [:]
        for id in changed {
            if let occurrence = metadataOccurrences[context.windowID]?[id], let tab = tabs[occurrence] {
                destinations[occurrence] = tab.url
                localDestinations[id] = tab.url
            }
        }
        return BrowserOrganizationMetadata(revision: organizationRevision, tabs: values, localDestinations: localDestinations, destinations: destinations)
    }
}

/// Paths are rebuilt only with a structural snapshot. Metadata replacement follows the changed
/// paths; unchanged subtrees remain shared value storage.
public struct BrowserOrganizationMetadataIndex: Sendable {
    struct Path: Sendable {
        let section: Int
        let offsets: [Int]
        let pane: Int?
        let row: BrowserOrganizationNode
    }
    var paths: [TabID: Path] = [:]

    public init(_ snapshot: BrowserOrganizationSnapshot) {
        func walk(_ items: [BrowserOrganizationItem], section: Int, offsets: [Int]) {
            for (i, item) in items.enumerated() {
                let path = offsets + [i]
                switch item {
                case let .tab(tab): paths[tab.id] = Path(section: section, offsets: path, pane: nil, row: item.node)
                case let .folder(folder): walk(folder.children, section: section, offsets: path)
                case let .split(split):
                    for (pane, tab) in split.tabs.enumerated() {
                        paths[tab.id] = Path(section: section, offsets: path, pane: pane, row: item.node)
                    }
                }
            }
        }
        walk(snapshot.favorites, section: 0, offsets: [])
        walk(snapshot.pinned, section: 1, offsets: [])
        walk(snapshot.today, section: 2, offsets: [])
    }

    public func tab(_ id: TabID, in snapshot: BrowserOrganizationSnapshot) -> BrowserOrganizationTabItem? {
        guard let path = paths[id] else { return nil }
        var items = path.section == 0 ? snapshot.favorites : path.section == 1 ? snapshot.pinned : snapshot.today
        for (depth, offset) in path.offsets.enumerated() {
            guard items.indices.contains(offset) else { return nil }
            switch items[offset] {
            case let .tab(tab): return tab.id == id ? tab : nil
            case let .folder(folder): items = folder.children
            case let .split(split):
                guard depth == path.offsets.count - 1, let pane = path.pane, split.tabs.indices.contains(pane),
                      split.tabs[pane].id == id else { return nil }
                return split.tabs[pane]
            }
        }
        return nil
    }

    public func row(for id: TabID) -> BrowserOrganizationNode? { paths[id]?.row }

    public func requiresCompositeProjection(_ id: TabID) -> Bool {
        paths[id].map { $0.section == 0 || $0.pane != nil } ?? false
    }
}

public extension BrowserOrganizationSnapshot {
    func applying(_ delta: BrowserOrganizationMetadata, index: BrowserOrganizationMetadataIndex? = nil,
                  selection: TabOccurrenceID? = nil, updatingSelection: Bool = false) -> Self {
        let index = index ?? BrowserOrganizationMetadataIndex(self)
        func replace(_ items: inout [BrowserOrganizationItem], path: BrowserOrganizationMetadataIndex.Path,
                     depth: Int, value: BrowserOrganizationTabItem) {
            let offset = path.offsets[depth]
            switch items[offset] {
            case .tab: items[offset] = .tab(value)
            case var .folder(folder):
                replace(&folder.children, path: path, depth: depth + 1, value: value)
                items[offset] = .folder(folder)
            case var .split(split):
                if let pane = path.pane { split.tabs[pane] = value }
                items[offset] = .split(split)
            }
        }
        var next = self
        next.organizationRevision = delta.revision
        for (id, value) in delta.tabs {
            guard let path = index.paths[id], var tab = index.tab(id, in: next) else { continue }
            if updatingSelection { tab.isSelected = tab.occurrenceID != nil && tab.occurrenceID == selection }
            tab.pageTitle = value.pageTitle
            if let url = delta.localDestinations[id] { tab.url = url }
            else if !tab.isLoadedInThisWindow { tab.url = value.url }
            tab.lastActiveAt = value.lastActiveAt
            switch path.section {
            case 0: replace(&next.favorites, path: path, depth: 0, value: tab)
            case 1: replace(&next.pinned, path: path, depth: 0, value: tab)
            default: replace(&next.today, path: path, depth: 0, value: tab)
            }
        }
        return next
    }
}

public extension BrowserWindowSnapshot {
    func applying(_ delta: BrowserOrganizationMetadata, indices: [TabOccurrenceID: Int]? = nil) -> Self {
        let indices = indices ?? Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($0.element.occurrenceID, $0.offset) })
        var next = self
        for (occurrence, url) in delta.destinations {
            guard let index = indices[occurrence] else { continue }
            let tab = tabs[index]
            guard url != tab.url else { continue }
            next.tabs[index] = BrowserTab(id: tab.id, occurrenceID: tab.occurrenceID, windowID: tab.windowID,
                                         spaceID: tab.spaceID, url: url)
        }
        return next
    }
}
