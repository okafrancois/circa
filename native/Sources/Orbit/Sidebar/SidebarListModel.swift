import AppKit
import BrowserCore

private typealias Metrics = OrbitTokens.Metrics.Sidebar

/// Live presentation of this window's occurrence, never inferred from playback alone.
struct SidebarTabActivity: Equatable {
    var favicon: NSImage?
    var isLoading = false
    var isAudible: Bool?
    var isAudioMuted: Bool?
}

// Pure model of the Pinned/Today list (SB-LIST): what each row shows, where it sits, and where a
// drag would land. No AppKit view state lives here, so the rules are tested without a window.

/// One tab row. Identity is the logical tab (`TabID`), stable across windows, moves and restarts;
/// `occurrenceID` is this window's live document in the active Space, when there is one.
struct SidebarTabItem: Equatable {
    let id: TabID
    var occurrenceID: TabOccurrenceID?
    let title: String
    let selected: Bool
    /// Nil until the engine publishes favicons; the row shows a placeholder glyph.
    var favicon: NSImage? = nil
    /// Part of a ⌘/⇧-click selection of two rows or more (`tabMultiselected`).
    var isMultiSelected = false
    var isPinned = false
    var isAwayFromPinnedURL = false
    /// Open in another window and not here: selecting it opens a second occurrence here.
    var isOpenInAnotherWindow = false
    var isLoadedInThisWindow = false
    var activity = SidebarTabActivity()
}

struct SidebarFolderItem: Equatable {
    let id: FolderID
    let title: String
    let isCollapsed: Bool
    let childCount: Int
    var isMultiSelected = false
}

enum SidebarListSection: Equatable, Sendable {
    case pinned
    case today
}

/// A visible row of the list, in display order.
struct SidebarListEntry: Equatable {
    enum Content: Equatable {
        case tab(SidebarTabItem)
        case folder(SidebarFolderItem)
        case split(SidebarTabItem, [TabID])
    }

    let node: BrowserOrganizationNode
    let section: SidebarListSection
    /// Folders containing the row, outermost first; `depth == ancestors.count`.
    let ancestors: [FolderID]
    let content: Content

    var depth: Int { ancestors.count }
    var parentFolderID: FolderID? { ancestors.last }

    var tab: SidebarTabItem? {
        if case let .tab(item) = content { return item }
        if case let .split(item, _) = content { return item }
        return nil
    }

    var folder: SidebarFolderItem? {
        if case let .folder(item) = content { return item }
        return nil
    }

    var title: String {
        switch content {
        case let .tab(item), let .split(item, _): return item.title
        case let .folder(item): return item.title
        }
    }

    /// An expanded folder: a drop just below it lands inside, as its first child.
    var opensInside: Bool { folder.map { !$0.isCollapsed } ?? false }
}

/// Everything the list renders for one Space, built from the window's organization snapshot.
struct SidebarListContent: Equatable {
    var entries: [SidebarListEntry] = []
    var isPinnedSectionCollapsed = false

    static let empty = SidebarListContent()

    init(entries: [SidebarListEntry] = [], isPinnedSectionCollapsed: Bool = false) {
        self.entries = entries
        self.isPinnedSectionCollapsed = isPinnedSectionCollapsed
    }

    var hasTodayTabs: Bool { entries.contains { $0.section == .today } }
    var tabs: [SidebarTabItem] { entries.compactMap(\.tab) }

    func entry(for node: BrowserOrganizationNode) -> SidebarListEntry? {
        entries.first { $0.node == node }
    }

    init(snapshot: BrowserOrganizationSnapshot?, selection: BrowserOrganizationSelection = .init(),
         liveTitle: (BrowserOrganizationTabItem) -> String? = { _ in nil },
         liveActivity: (BrowserOrganizationTabItem) -> SidebarTabActivity = { _ in .init() }) {
        guard let snapshot else { return }
        isPinnedSectionCollapsed = snapshot.isPinnedSectionCollapsed
        let multi = selection.nodes.count >= 2 && selection.spaceID == snapshot.spaceID
            && selection.profileID == snapshot.profileID ? selection.nodes : []
        var result: [SidebarListEntry] = []
        result.reserveCapacity(snapshot.pinned.count + snapshot.today.count)
        func append(_ items: [BrowserOrganizationItem], section: SidebarListSection, ancestors: [FolderID]) {
            for item in items {
                switch item {
                case let .tab(tab):
                    let title = tab.customTitle ?? liveTitle(tab).flatMap { $0.isEmpty ? nil : $0 }
                        ?? tab.pageTitle ?? tab.url.host ?? SidebarListStrings.newTab
                    let row = SidebarTabItem(
                        id: tab.id, occurrenceID: tab.occurrenceID, title: title, selected: tab.isSelected,
                        isMultiSelected: multi.contains(.tab(tab.id)), isPinned: section == .pinned,
                        isAwayFromPinnedURL: section == .pinned && tab.isAwayFromPinnedURL,
                        isOpenInAnotherWindow: tab.isOpenInAnotherWindow && !tab.isLoadedInThisWindow,
                        isLoadedInThisWindow: tab.isLoadedInThisWindow, activity: liveActivity(tab))
                    result.append(SidebarListEntry(node: .tab(tab.id), section: section, ancestors: ancestors,
                                                   content: .tab(row)))
                case let .split(split):
                    guard let active = split.activeTab ?? split.tabs.first else { continue }
                    let title = split.tabs.map { $0.customTitle ?? liveTitle($0) ?? $0.pageTitle ?? $0.url.host ?? SidebarListStrings.newTab }.joined(separator: " | ")
                    let row = SidebarTabItem(id: active.id, occurrenceID: active.occurrenceID, title: title,
                        selected: split.activeTab != nil, favicon: NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: uiText("Split View")),
                        isMultiSelected: multi.contains(.split(split.group.id)), isPinned: section == .pinned,
                        isLoadedInThisWindow: split.tabs.contains { $0.isLoadedInThisWindow }, activity: liveActivity(active))
                    result.append(SidebarListEntry(node: .split(split.group.id), section: section, ancestors: ancestors,
                                                   content: .split(row, split.group.tabIDs)))
                case let .folder(folder):
                    let row = SidebarFolderItem(id: folder.id, title: folder.title, isCollapsed: folder.isCollapsed,
                                                childCount: folder.children.count,
                                                isMultiSelected: multi.contains(.folder(folder.id)))
                    result.append(SidebarListEntry(node: .folder(folder.id), section: section, ancestors: ancestors,
                                                   content: .folder(row)))
                    if !folder.isCollapsed {
                        append(folder.children, section: section, ancestors: ancestors + [folder.id])
                    }
                }
            }
        }
        if !snapshot.isPinnedSectionCollapsed { append(snapshot.pinned, section: .pinned, ancestors: []) }
        append(snapshot.today, section: .today, ancestors: [])
        entries = result
    }
}

/// Interface strings of the list. Orbit's interface is English whatever the system language
/// (THEME-R2 BL-VIS1-LOCALE): English defaults, shared shell strings from `OrbitShellText`, the rest
/// through the "Sidebar" table so a later localization overrides them without touching the views.
enum SidebarListStrings {
    static func string(_ key: String, _ english: String) -> String {
        uiText(english)
    }

    static var newTab: String { OrbitShellText.newTab }
    static var newFolder: String { string("list.newFolder", "New Folder") }
    static var clear: String { string("list.clear", "Clear") }
    static var selected: String { OrbitShellText.selected }
    static var expanded: String { string("list.expanded", "Expanded") }
    static var collapsed: String { string("list.collapsed", "Collapsed") }
    static var otherWindow: String { string("list.otherWindow", "Open in Another Window") }
    static var resetPinned: String { string("list.resetPinned", "Reset Tab to Original URL") }
    static func close(_ title: String) -> String { OrbitShellText.closeTab(title) }
    static func reset(_ title: String) -> String { String(format: string("list.resetTab", "Reset %@ to Original URL"), title) }
    static func folder(_ title: String) -> String { String(format: string("list.folder", "Folder %@"), title) }
    static var renameField: String { string("list.renameField", "Name") }
}

// MARK: - Layout

/// Something positioned in the list document.
enum SidebarListSlot: Hashable {
    case node(BrowserOrganizationNode)
    case separator
    case newTab
}

struct SidebarDropGap: Equatable {
    let section: SidebarListSection
    let index: Int
    let rows: Int
    /// Indentation of the placeholder, in folder levels.
    var depth: Int = 0
}

struct SidebarListLayout: Equatable {
    struct Placement: Equatable {
        let node: BrowserOrganizationNode
        let section: SidebarListSection
        let centerY: CGFloat
        let depth: Int
    }

    var rows: [Placement] = []
    var separatorCenterY: CGFloat = 0
    var isSeparatorVisible = false
    var newTabCenterY: CGFloat = 0
    /// Placeholder of the drag gap, in document coordinates (row box, full width before indent).
    var gapFrame: CGRect?
    /// Pinned and Today rows including gap pitches (the counts `OrbitSidebarGeometry` expects).
    var pinnedSlotCount = 0
    var todaySlotCount = 0
    var documentHeight: CGFloat = 0
    private(set) var centers: [BrowserOrganizationNode: CGFloat] = [:]

    func centerY(of slot: SidebarListSlot) -> CGFloat? {
        switch slot {
        case let .node(node): return centers[node]
        case .separator: return separatorCenterY
        case .newTab: return newTabCenterY
        }
    }

    func rows(in section: SidebarListSection) -> [Placement] { rows.filter { $0.section == section } }

    static func resolve(entries: [SidebarListEntry], spaceTitleCenterY title: CGFloat, width: CGFloat,
                        hidden: Set<BrowserOrganizationNode> = [], gap: SidebarDropGap? = nil) -> SidebarListLayout {
        var layout = SidebarListLayout()
        let pitch = Metrics.rowPitch
        let visible = hidden.isEmpty ? entries : entries.filter { !hidden.contains($0.node) }
        let pinned = visible.filter { $0.section == .pinned }
        let today = visible.filter { $0.section == .today }
        // Slots per section: rows in order, the gap's pitches inserted at its index.
        func slots(_ rows: [SidebarListEntry], section: SidebarListSection) -> (rows: [Int], gapSlot: Int?, count: Int) {
            var result: [Int] = []
            result.reserveCapacity(rows.count)
            var slot = 0
            var gapSlot: Int?
            for index in rows.indices {
                if let gap, gap.section == section, gap.index == index {
                    gapSlot = slot
                    slot += gap.rows
                }
                result.append(slot)
                slot += 1
            }
            if let gap, gap.section == section, gap.index >= rows.count {
                gapSlot = slot
                slot += gap.rows
            }
            return (result, gapSlot, slot)
        }
        let pinnedSlots = slots(pinned, section: .pinned)
        let todaySlots = slots(today, section: .today)
        let rhythm = OrbitSidebarGeometry.PageRhythm.resolve(pinnedRowCount: pinnedSlots.count, todayRowCount: todaySlots.count)
        let offset = title - rhythm.spaceTitleCenterY
        let firstRow = title + Metrics.firstRowCenterFromSpaceTitle
        layout.separatorCenterY = rhythm.separatorCenterY + offset
        layout.isSeparatorVisible = rhythm.isSeparatorVisible
        layout.newTabCenterY = rhythm.newTabCenterY + offset
        let todayFirst = layout.newTabCenterY + pitch
        layout.rows.reserveCapacity(visible.count)
        layout.centers.reserveCapacity(visible.count)
        for (entry, slot) in zip(pinned, pinnedSlots.rows) {
            let center = firstRow + CGFloat(slot) * pitch
            layout.rows.append(Placement(node: entry.node, section: .pinned, centerY: center, depth: entry.depth))
            layout.centers[entry.node] = center
        }
        for (entry, slot) in zip(today, todaySlots.rows) {
            let center = todayFirst + CGFloat(slot) * pitch
            layout.rows.append(Placement(node: entry.node, section: .today, centerY: center, depth: entry.depth))
            layout.centers[entry.node] = center
        }
        layout.pinnedSlotCount = pinnedSlots.count
        layout.todaySlotCount = todaySlots.count
        let gapStart = pinnedSlots.gapSlot.map { firstRow + CGFloat($0) * pitch }
            ?? todaySlots.gapSlot.map { todayFirst + CGFloat($0) * pitch }
        if let gap, let gapStart {
            let indent = OrbitSidebarGeometry.contentIndent(depth: gap.depth)
            let height = CGFloat(gap.rows - 1) * pitch + Metrics.rowHeight
            layout.gapFrame = CGRect(x: Metrics.paddingX + indent, y: gapStart - Metrics.rowHeight / 2,
                                     width: max(0, width - 2 * Metrics.paddingX - indent), height: height)
        }
        let lastCenter = todaySlots.count == 0 ? layout.newTabCenterY : todayFirst + CGFloat(todaySlots.count - 1) * pitch
        layout.documentHeight = lastCenter + Metrics.rowHeight / 2 + Metrics.paddingX
        return layout
    }
}


/// Where a drag hovering the list would land, and how to show it.
struct SidebarDropProposal: Equatable {
    let destination: BrowserOrganizationDestination
    /// Insertion: the gap to open. Nil when dropping into a folder.
    let gap: SidebarDropGap?
    /// "Into folder": the folder row to highlight.
    let folderTarget: FolderID?
}

enum SidebarDropResolver {
    /// - Parameters:
    ///   - y: pointer in document coordinates of `layout` (resting, or presented positions).
    ///   - iconX: where the dragged row's icon would sit (pointer x minus the grab offset).
    static func resolve(y: CGFloat, iconX: CGFloat, layout: SidebarListLayout, entries: [SidebarListEntry],
                        spaceID: SpaceID, draggedRows: Int, isPinnedCollapsed: Bool = false) -> SidebarDropProposal {
        let rows = max(1, draggedRows)
        let byNode = Dictionary(entries.map { ($0.node, $0) }, uniquingKeysWith: { first, _ in first })
        if y >= layout.separatorCenterY {
            let today = layout.rows(in: .today)
            let index = insertionIndex(y: y, rows: today)
            let position: BrowserOrganizationPosition = index == 0 ? .start : .after(today[index - 1].node)
            return SidebarDropProposal(destination: .init(.today(spaceID), position: position),
                                       gap: SidebarDropGap(section: .today, index: index, rows: rows), folderTarget: nil)
        }
        let pinned = layout.rows(in: .pinned)
        guard !pinned.isEmpty else {
            // A collapsed section keeps its rows hidden: no placeholder opens above the separator.
            return SidebarDropProposal(destination: .init(.pinned(spaceID), position: .end),
                                       gap: isPinnedCollapsed ? nil : SidebarDropGap(section: .pinned, index: 0, rows: rows),
                                       folderTarget: nil)
        }
        let half = Metrics.rowPitch / 2
        // Folder rows: quarters around, middle into.
        if let hit = pinned.firstIndex(where: { y >= $0.centerY - half && y < $0.centerY + half }),
           case let .folder(folderID) = pinned[hit].node {
            let top = pinned[hit].centerY - Metrics.rowHeight / 2
            let fraction = (y - top) / Metrics.rowHeight
            let edge = Metrics.folderDropEdgeFraction
            if fraction > edge && fraction < 1 - edge {
                return SidebarDropProposal(destination: .init(.folder(folderID), position: .end), gap: nil,
                                           folderTarget: folderID)
            }
            let index = fraction <= edge ? hit : hit + 1
            return insertion(at: index, iconX: iconX, rows: pinned, byNode: byNode, spaceID: spaceID, count: rows)
        }
        let index = insertionIndex(y: y, rows: pinned)
        return insertion(at: index, iconX: iconX, rows: pinned, byNode: byNode, spaceID: spaceID, count: rows)
    }

    /// Converts a pointer y over the displayed list (gap open) to the gap-free resting layout. Nil
    /// while the pointer is inside the gap. The list resolves against presented positions instead
    /// (`SidebarListView.presentedDropLayout`); kept for resting-layout callers.
    static func removingGap(_ y: CGFloat, gapFrame: CGRect?) -> CGFloat? {
        guard let gapFrame else { return y }
        let top = gapFrame.minY - Metrics.rowSpacing / 2
        let height = gapFrame.height + Metrics.rowSpacing
        if y < top { return y }
        if y > top + height { return y - height }
        return nil
    }

    /// Slot boundaries are row centres: the upper half of a row inserts before it. A linear scan:
    /// presented centres can be briefly out of order while rows cross during a reorder.
    private static func insertionIndex(y: CGFloat, rows: [SidebarListLayout.Placement]) -> Int {
        rows.firstIndex { $0.centerY > y } ?? rows.count
    }

    private static func insertion(at index: Int, iconX: CGFloat, rows: [SidebarListLayout.Placement],
                                  byNode: [BrowserOrganizationNode: SidebarListEntry], spaceID: SpaceID,
                                  count: Int) -> SidebarDropProposal {
        let previous = index > 0 ? byNode[rows[index - 1].node] : nil
        let next = index < rows.count ? byNode[rows[index].node] : nil
        let upper = previous.map { $0.opensInside ? $0.depth + 1 : $0.depth } ?? 0
        let lower = min(next?.depth ?? 0, upper)
        let base = Metrics.paddingX + Metrics.rowInsetX
        let wanted = Int(((iconX - base) / Metrics.folderChildIndent).rounded())
        let depth = min(upper, max(lower, wanted))
        let gap = SidebarDropGap(section: .pinned, index: index, rows: count, depth: depth)
        guard let previous else {
            return SidebarDropProposal(destination: .init(.pinned(spaceID), position: .start), gap: gap, folderTarget: nil)
        }
        let chain = previous.ancestors + (previous.folder.map { [$0.id] } ?? [])
        if depth == 0 {
            let anchor = previous.depth == 0 ? previous.node : .folder(previous.ancestors[0])
            return SidebarDropProposal(destination: .init(.pinned(spaceID), position: .after(anchor)), gap: gap,
                                       folderTarget: nil)
        }
        let container = chain[depth - 1]
        let position: BrowserOrganizationPosition
        if previous.depth == depth {
            position = .after(previous.node)
        } else if previous.depth > depth {
            position = .after(.folder(previous.ancestors[depth]))
        } else {
            position = .start
        }
        return SidebarDropProposal(destination: .init(.folder(container), position: position), gap: gap, folderTarget: nil)
    }

    /// True when dropping `nodes` at `destination` would leave the organization unchanged (the
    /// rows dropped back where they were). Such drops are accepted without a command.
    static func isNoOp(_ nodes: [BrowserOrganizationNode], destination: BrowserOrganizationDestination,
                       in snapshot: BrowserOrganizationSnapshot) -> Bool {
        guard let first = nodes.first, let (container, siblings) = snapshot.sidebarContainer(of: first),
              container == destination.container else { return false }
        let ids = siblings.map(\.node)
        guard let start = ids.firstIndex(of: first), start + nodes.count <= ids.count,
              Array(ids[start..<start + nodes.count]) == nodes else { return false }
        let end = start + nodes.count
        switch destination.position {
        case .start: return start == 0
        case .end: return end == ids.count
        case let .before(anchor): return end < ids.count && ids[end] == anchor
        case let .after(anchor): return start > 0 && ids[start - 1] == anchor
        }
    }
}

extension BrowserOrganizationSnapshot {
    /// The container directly holding `node` in the active Space or the profile's Favorites, with
    /// its children in order.
    func sidebarContainer(of node: BrowserOrganizationNode) -> (BrowserOrganizationContainer, [BrowserOrganizationItem])? {
        func search(_ items: [BrowserOrganizationItem], in container: BrowserOrganizationContainer)
            -> (BrowserOrganizationContainer, [BrowserOrganizationItem])? {
            for item in items {
                if item.node == node { return (container, items) }
                if case let .folder(folder) = item, let found = search(folder.children, in: .folder(folder.id)) {
                    return found
                }
            }
            return nil
        }
        return search(favorites, in: .favorites(profileID)) ?? search(pinned, in: .pinned(spaceID))
            ?? search(today, in: .today(spaceID))
    }

    /// Drops nodes whose folder is also listed: they move with it. Order is preserved.
    func topLevelNodes(_ nodes: [BrowserOrganizationNode]) -> [BrowserOrganizationNode] {
        let folders = Set(nodes.compactMap(\.folderID))
        guard !folders.isEmpty else { return nodes }
        var inside: Set<BrowserOrganizationNode> = []
        func collect(_ items: [BrowserOrganizationItem], within: Bool) {
            for item in items {
                if within { inside.insert(item.node) }
                if case let .folder(folder) = item {
                    collect(folder.children, within: within || folders.contains(folder.id))
                }
            }
        }
        collect(favorites + pinned + today, within: false)
        return nodes.filter { !inside.contains($0) }
    }
}


enum SidebarAutoScroll {
    /// Scroll step for one dragging update: proportional to the pointer's depth into the edge band,
    /// negative upwards; zero when the document cannot move further.
    static func step(pointerY: CGFloat, visible: CGRect, documentHeight: CGFloat) -> CGFloat {
        let edge = Metrics.dragAutoScrollEdge
        let maximum = Metrics.dragAutoScrollMaximumStep
        if pointerY < visible.minY + edge, visible.minY > 0 {
            let depth = min(1, (visible.minY + edge - pointerY) / edge)
            return -min(visible.minY, (maximum * depth).rounded(.up))
        }
        if pointerY > visible.maxY - edge, visible.maxY < documentHeight {
            let depth = min(1, (pointerY - (visible.maxY - edge)) / edge)
            return min(documentHeight - visible.maxY, (maximum * depth).rounded(.up))
        }
        return 0
    }
}
