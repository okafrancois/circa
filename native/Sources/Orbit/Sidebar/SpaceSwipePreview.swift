import AppKit
import BrowserCore

/// Metadata-only adjacent list, in document order. No page image, engine work or selection mutation.
enum SpaceSwipePreview {
    static func content(document: BrowserSessionDocument, spaceID: SpaceID, windowID: WindowID? = nil,
                        icon: (ProfileID, URL) -> NSImage? = { _, _ in nil }) -> SidebarListContent {
        guard let sections = document.organization.spaces.first(where: { $0.spaceID == spaceID }) else { return .empty }
        let selectedOccurrence = document.windows.first { $0.id == windowID }?.spaces.first { $0.spaceID == spaceID }?.selectedOccurrenceID
        let selectedTab = document.tabs.first { $0.occurrenceID == selectedOccurrence && $0.windowID == windowID && $0.spaceID == spaceID }?.id
        let tabs = Dictionary(uniqueKeysWithValues: document.organization.tabs.map { ($0.id, $0) })
        let folders = Dictionary(uniqueKeysWithValues: document.organization.folders.map { ($0.id, $0) })
        let splits = Dictionary(uniqueKeysWithValues: document.organization.splits.map { ($0.id, $0) })
        var entries: [SidebarListEntry] = []
        var visited: Set<BrowserOrganizationNode> = []
        func tab(_ id: TabID, pinned: Bool) -> SidebarTabItem? {
            guard let item = tabs[id] else { return nil }
            let image = document.spaces.first { $0.id == spaceID }.flatMap { icon($0.profileID, item.pinnedURL ?? item.url) }
            return SidebarTabItem(id: id, title: item.resolvedTitle ?? item.url.host ?? SidebarListStrings.newTab,
                                  selected: id == selectedTab, favicon: image, isPinned: pinned)
        }
        func append(_ nodes: [BrowserOrganizationNode], section: SidebarListSection, ancestors: [FolderID]) {
            for node in nodes where visited.insert(node).inserted {
                let content: SidebarListEntry.Content
                switch node {
                case let .tab(id):
                    guard let row = tab(id, pinned: section == .pinned) else { continue }
                    content = .tab(row)
                case let .folder(id):
                    guard let folder = folders[id] else { continue }
                    content = .folder(.init(id: id, title: folder.title, isCollapsed: folder.isCollapsed,
                                            childCount: folder.children.count))
                case let .split(id):
                    guard let split = splits[id], var row = split.tabIDs.first.flatMap({ tab($0, pinned: section == .pinned) }) else { continue }
                    row.favicon = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
                    let title = split.tabIDs.compactMap { tab($0, pinned: section == .pinned)?.title }.joined(separator: " | ")
                    row = SidebarTabItem(id: row.id, title: title, selected: false, favicon: row.favicon, isPinned: section == .pinned)
                    row = SidebarTabItem(id: row.id, title: row.title, selected: split.tabIDs.contains { $0 == selectedTab },
                                         favicon: row.favicon, isPinned: section == .pinned)
                    content = .split(row, split.tabIDs)
                }
                entries.append(.init(node: node, section: section, ancestors: ancestors, content: content))
                if case let .folder(id) = node, let folder = folders[id], !folder.isCollapsed {
                    append(folder.children, section: section, ancestors: ancestors + [id])
                }
            }
        }
        if !sections.isPinnedCollapsed { append(sections.pinned, section: .pinned, ancestors: []) }
        append(sections.today, section: .today, ancestors: [])
        return SidebarListContent(entries: entries, isPinnedSectionCollapsed: sections.isPinnedCollapsed)
    }
}

struct SpaceSwipeFavoritesPreview: Equatable {
    let profileID: ProfileID
    let items: [FavoriteTileItem]
}

extension SpaceSwipePreview {
    /// Destination profile root only. No source-grid borrowing, icon fetch, surface or mutation.
    static func favorites(document: BrowserSessionDocument, spaceID: SpaceID, windowID: WindowID?,
                          icon: (ProfileID, URL) -> NSImage? = { _, _ in nil }) -> SpaceSwipeFavoritesPreview? {
        guard let space = document.spaces.first(where: { $0.id == spaceID }),
              document.profiles.contains(where: { $0.id == space.profileID }) else { return nil }
        let roots = document.organization.favorites.filter { $0.profileID == space.profileID }
        guard roots.count <= 1 else { return nil }
        let selected = document.windows.first { $0.id == windowID }?.spaces.first { $0.spaceID == spaceID }?.selectedOccurrenceID
        let selectedTab = document.tabs.first { $0.occurrenceID == selected && $0.spaceID == spaceID && $0.windowID == windowID }?.id
        var seen: Set<TabID> = []
        let items = (roots.first?.items ?? []).compactMap { node -> FavoriteTileItem? in
            guard case let .tab(id) = node, seen.insert(id).inserted,
                  !document.organization.favorites.contains(where: { $0.profileID != space.profileID && $0.items.contains(node) }) else { return nil }
            let records = document.organization.tabs.filter { $0.id == id }
            guard records.count == 1, let tab = records.first else { return nil }
            return FavoriteTileItem(tab: .favoritePreview(tab, profileID: space.profileID, selected: id == selectedTab),
                                    favicon: icon(space.profileID, tab.pinnedURL ?? tab.url))
        }
        return .init(profileID: space.profileID, items: items)
    }
}
