import AppKit
import Foundation
import Testing
@testable import Orbit
@testable import BrowserCore

/// Synthetic organization snapshots for the pure list rules (no store, no window).
@MainActor
struct SyntheticOrganization {
    let windowID = WindowID()
    let spaceID = SpaceID()
    let profileID = ProfileID()

    func tab(_ id: TabID = TabID(), pinned: Bool = false, title: String? = nil, custom: String? = nil,
             url: String = "https://site.test/", pinnedURL: String? = nil, occurrence: TabOccurrenceID? = nil,
             selected: Bool = false, elsewhere: Bool = false) -> BrowserOrganizationItem {
        let section: BrowserOrganizationSection = pinned ? .pinned(spaceID) : .today(spaceID)
        return .tab(BrowserOrganizationTabItem(
            id: id, section: section, url: URL(string: url)!,
            pinnedURL: pinned ? URL(string: pinnedURL ?? url) : nil, pageTitle: title, customTitle: custom,
            occurrenceID: occurrence, isLoadedInThisWindow: occurrence != nil, isSelected: selected,
            isOpenInAnotherWindow: elsewhere))
    }

    func folder(_ id: FolderID = FolderID(), title: String = "Folder", collapsed: Bool = false,
                _ children: [BrowserOrganizationItem] = []) -> BrowserOrganizationItem {
        .folder(BrowserOrganizationFolderItem(id: id, title: title, isCollapsed: collapsed, children: children))
    }

    func snapshot(pinned: [BrowserOrganizationItem] = [], today: [BrowserOrganizationItem] = [],
                  favorites: [BrowserOrganizationItem] = [], pinnedCollapsed: Bool = false) -> BrowserOrganizationSnapshot {
        BrowserOrganizationSnapshot(windowID: windowID, spaceID: spaceID, profileID: profileID, favorites: favorites,
                                    pinned: pinned, today: today, isPinnedSectionCollapsed: pinnedCollapsed,
                                    archiveRevision: 0, canRestoreArchivedTab: false,
                                    autoArchiveThreshold: .twelveHours, inheritsAutoArchiveThreshold: true,
                                    archivedTabCount: 0, undoAction: nil, redoAction: nil)
    }

    var catalog: BrowserCatalogSnapshot {
        BrowserCatalogSnapshot(profiles: [BrowserProfile(id: profileID, name: "Synthetic")],
                               spaces: [BrowserSpace(id: spaceID, profileID: profileID, name: "Synthetic")])
    }
}

private typealias Metrics = OrbitTokens.Metrics.Sidebar

extension NativeWebKitTests {
@Suite
@MainActor
struct SidebarListModelTests {
    @Test("Split rows keep group identity, pane order and cached icons across focus updates", arguments: [2, 3])
    func splitRowIdentityAndContent(count: Int) throws {
        let org = SyntheticOrganization()
        let first = TabID(), second = TabID(), third = TabID()
        let group = BrowserSplitGroup(tabIDs: count == 2 ? [first, second] : [first, second, third])
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let list = SidebarListView(frame: CGRect(x: 0, y: 0, width: 260, height: 500))
        for focused: TabID? in group.tabIDs.map(Optional.some) + [nil, first] {
            guard case let .tab(left) = org.tab(first, title: "First page", selected: focused == first),
                  case let .tab(right) = org.tab(second, title: "Second page", selected: focused == second) else { return }
            var tabs = [left, right]
            if count == 3, case let .tab(tab) = org.tab(third, title: "Third page", selected: focused == third) { tabs.append(tab) }
            let titles = count == 2 ? ["First page", "Live second"] : ["First page", "Live second", "Live second"]
            let snapshot = org.snapshot(today: [.split(.init(group: group, tabs: tabs))])
            let content = SidebarListContent(snapshot: snapshot, liveTitle: { $0.id == first ? "" : "Live second" },
                                             liveActivity: { _ in .init(favicon: icon) })
            list.apply(content, animated: false)
            list.layoutSubtreeIfNeeded()
            let row = try #require(list.row(for: .split(group.id)) as? SidebarSplitRow)
            #expect(row.node == .split(group.id))
            if focused != nil {
                #expect(row.titleLabel.isHidden)
                #expect(row.paneCells.map { $0.label.stringValue } == titles)
                #expect(row.paneCells.allSatisfy { $0.icon.image === icon })
                #expect(row.paneCells[0].frame.maxX + 4 == row.paneCells[1].frame.minX)
            } else {
                #expect(row.paneCells.isEmpty)
                #expect(!row.titleLabel.isHidden)
                #expect(row.titleLabel.stringValue == titles.joined(separator: " | "))
            }
            #expect(content.entries[0].tab?.id == (focused ?? first))
        }
    }

    @Test("Viewport row lookup includes boundaries across sections, gaps and empty ranges")
    func viewportRowLookup() {
        let org = SyntheticOrganization()
        let content = SidebarListContent(snapshot: org.snapshot(
            pinned: (0..<40).map { _ in org.tab(pinned: true) },
            today: (0..<160).map { _ in org.tab() }))
        let layout = SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: 28, width: 228)
        for minimum in stride(from: CGFloat(-100), through: layout.documentHeight + 100, by: 37) {
            for height in [CGFloat(0), 1, 200, 800] {
                let expected = layout.rows.filter { $0.centerY >= minimum && $0.centerY <= minimum + height }
                #expect(Array(layout.rows(from: minimum, through: minimum + height)) == expected)
            }
        }
        for row in layout.rows {
            #expect(Array(layout.rows(from: row.centerY, through: row.centerY)) == [row])
        }
        #expect(SidebarListLayout().rows(from: 0, through: 100).isEmpty)
    }

    @Test("The actual separator follows empty, Pinned-only, Today-only and combined content updates")
    func separatorVisibilityAcrossContentUpdates() {
        let org = SyntheticOrganization()
        let pinned = TabID(), today = TabID()
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 228, height: 500))
        let title: CGFloat = 27.5
        #expect(list.separator.isHidden)
        #expect(!SidebarListLayout().isSeparatorVisible)
        list.spaceTitleCenterY = title

        // Repeat the empty state between populated states to catch stale view visibility.
        for (pinnedItems, todayItems) in [
            ([], []), ([org.tab(pinned, pinned: true)], []), ([], []),
            ([], [org.tab(today)]), ([org.tab(pinned, pinned: true)], [org.tab(today)]), ([], [])
        ] as [([BrowserOrganizationItem], [BrowserOrganizationItem])] {
            list.apply(SidebarListContent(snapshot: org.snapshot(pinned: pinnedItems, today: todayItems)), animated: false)
            list.layoutSubtreeIfNeeded()
            let empty = pinnedItems.isEmpty && todayItems.isEmpty
            #expect(list.separator.isHidden == empty)
            #expect(list.displayedLayout.isSeparatorVisible == !empty)
            let expectedNodes: [BrowserOrganizationNode] = (pinnedItems.isEmpty ? [] : [.tab(pinned)])
                + (todayItems.isEmpty ? [] : [.tab(today)])
            #expect(list.displayedLayout.rows.map(\.node) == expectedNodes)
            #expect(!list.newTabRow.isHidden)
            if empty {
                #expect(list.newTabRow.frame.midY == title + 40.5)
            } else {
                #expect(list.displayedLayout.newTabCenterY == list.displayedLayout.separatorCenterY + 29.25)
                if !pinnedItems.isEmpty {
                    #expect(list.displayedLayout.rows(in: .pinned).last!.centerY < list.displayedLayout.newTabCenterY)
                }
                if !todayItems.isEmpty {
                    #expect(list.displayedLayout.rows(in: .today).first!.centerY > list.displayedLayout.newTabCenterY)
                }
            }
        }
    }

    @Test("Content lists Pinned then Today by logical tab, folders nested with depth, collapsed parts omitted")
    func contentOrderAndDepth() {
        let org = SyntheticOrganization()
        let a = TabID(), b = TabID(), c = TabID(), d = TabID(), e = TabID()
        let outer = FolderID(), inner = FolderID(), closed = FolderID()
        let snapshot = org.snapshot(
            pinned: [org.tab(a, pinned: true), org.folder(outer, [org.tab(b, pinned: true), org.folder(inner, [org.tab(c, pinned: true)])]),
                     org.folder(closed, collapsed: true, [org.tab(TabID(), pinned: true)])],
            today: [org.tab(d), org.tab(e)])
        let content = SidebarListContent(snapshot: snapshot)
        #expect(content.entries.map(\.node) == [.tab(a), .folder(outer), .tab(b), .folder(inner), .tab(c), .folder(closed), .tab(d), .tab(e)])
        #expect(content.entries.map(\.depth) == [0, 0, 1, 1, 2, 0, 0, 0])
        #expect(content.entry(for: .tab(c))?.ancestors == [outer, inner])
        #expect(content.entries.filter { $0.section == .pinned }.count == 6)
        #expect(content.entry(for: .folder(closed))?.folder?.childCount == 1)
        // The rows `BrowserOrganizationSnapshot.rows()` shows in the list group, in the same order.
        #expect(content.entries.map(\.node) == snapshot.rows().filter { $0.group == .list }.map(\.node))
        let collapsed = SidebarListContent(snapshot: org.snapshot(pinned: [org.tab(a, pinned: true)], today: [org.tab(d)], pinnedCollapsed: true))
        #expect(collapsed.entries.map(\.node) == [.tab(d)] && collapsed.isPinnedSectionCollapsed)
        #expect(SidebarListContent(snapshot: nil).entries.isEmpty)
    }

    @Test("Titles prefer the custom title, then the live title, the stored title, the host and New Tab")
    func titlePrecedence() {
        let org = SyntheticOrganization()
        let occurrence = TabOccurrenceID()
        let snapshot = org.snapshot(today: [
            org.tab(custom: "Custom", url: "https://custom.test/", occurrence: occurrence),
            org.tab(title: "Stored", url: "https://stored.test/", occurrence: occurrence),
            org.tab(title: "Stored", url: "https://stored.test/"),
            org.tab(url: "https://host.test/path"),
            org.tab(url: "about:blank")
        ])
        let content = SidebarListContent(snapshot: snapshot, liveTitle: { $0.occurrenceID == occurrence ? "Live" : nil })
        #expect(content.tabs.map(\.title) == ["Custom", "Live", "Stored", "host.test", "New Tab"])
        let emptyLive = SidebarListContent(snapshot: snapshot, liveTitle: { _ in "" })
        #expect(emptyLive.tabs[1].title == "Stored")
    }

    @Test("Rows carry pinned, away-from-pinned-URL, other-window and multi-selection states")
    func rowStates() {
        let org = SyntheticOrganization()
        let away = TabID(), home = TabID(), elsewhere = TabID(), here = TabID()
        let snapshot = org.snapshot(
            pinned: [org.tab(away, pinned: true, url: "https://site.test/deep", pinnedURL: "https://site.test/"),
                     org.tab(home, pinned: true)],
            today: [org.tab(elsewhere, elsewhere: true), org.tab(here, occurrence: TabOccurrenceID(), selected: true, elsewhere: true)])
        var selection = BrowserOrganizationSelection()
        selection.select(.tab(home), in: snapshot)
        var content = SidebarListContent(snapshot: snapshot, selection: selection)
        #expect(content.tabs.map(\.isAwayFromPinnedURL) == [true, false, false, false])
        #expect(content.tabs.map(\.isPinned) == [true, true, false, false])
        // Loaded here wins over "open in another window".
        #expect(content.tabs.map(\.isOpenInAnotherWindow) == [false, false, true, false])
        #expect(content.tabs.map(\.selected) == [false, false, false, true])
        // One selected row is the plain selection; two or more are a multi-selection.
        #expect(!content.tabs.contains { $0.isMultiSelected })
        selection.toggle(.tab(elsewhere), in: snapshot)
        content = SidebarListContent(snapshot: snapshot, selection: selection)
        #expect(content.tabs.map(\.isMultiSelected) == [false, true, true, false])
        // A selection bound to another Space is ignored.
        let other = SyntheticOrganization()
        var foreign = BrowserOrganizationSelection()
        let otherSnapshot = other.snapshot(today: [other.tab(), other.tab()])
        foreign.select(otherSnapshot.rows()[0].node, in: otherSnapshot)
        foreign.toggle(otherSnapshot.rows()[1].node, in: otherSnapshot)
        #expect(!SidebarListContent(snapshot: snapshot, selection: foreign).tabs.contains { $0.isMultiSelected })
    }

    @Test("The list layout reproduces the measured page rhythm with and without Favorites",
          arguments: [0, 2])
    func layoutMatchesGeometry(favoriteCount: Int) {
        let org = SyntheticOrganization()
        for (pinnedCount, todayCount) in [(0, 0), (0, 3), (4, 3), (2, 0)] {
            let snapshot = org.snapshot(pinned: (0..<pinnedCount).map { _ in org.tab(pinned: true) },
                                        today: (0..<todayCount).map { _ in org.tab() })
            let content = SidebarListContent(snapshot: snapshot)
            let geometry = OrbitSidebarGeometry.resolve(.init(height: 640, favoriteCount: favoriteCount,
                                                           pinnedRowCount: pinnedCount, todayRowCount: todayCount))
            let layout = SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: geometry.spaceTitleCenterY, width: 228)
            #expect(layout.rows(in: .pinned).map(\.centerY) == geometry.pinnedRowCenters)
            #expect(layout.rows(in: .today).map(\.centerY) == geometry.todayRowCenters)
            #expect(layout.separatorCenterY == geometry.separatorCenterY)
            #expect(layout.isSeparatorVisible == geometry.isSeparatorVisible)
            #expect(layout.newTabCenterY == geometry.newTabCenterY)
            #expect(layout.documentHeight == geometry.documentHeight)
            #expect(layout.pinnedSlotCount == pinnedCount && layout.todaySlotCount == todayCount)
        }
    }

    @Test("Lifting the last row and opening a drop gap use the empty and occupied page rhythms")
    func layoutEmptyDragTransitions() {
        let org = SyntheticOrganization()
        let tab = TabID()
        let content = SidebarListContent(snapshot: org.snapshot(today: [org.tab(tab)]))
        let title: CGFloat = 27.5
        let lifted = SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: title,
                                               width: 228, hidden: [.tab(tab)])
        #expect(lifted.rows.isEmpty && !lifted.isSeparatorVisible)
        #expect(lifted.newTabCenterY == title + 40.5)
        #expect(lifted.documentHeight == lifted.newTabCenterY + 26)
        for section in [SidebarListSection.pinned, .today] {
            let gapped = SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: title,
                                                   width: 228, hidden: [.tab(tab)],
                                                   gap: SidebarDropGap(section: section, index: 0, rows: 1))
            let geometry = OrbitSidebarGeometry.resolve(.init(height: 640,
                pinnedRowCount: section == .pinned ? 1 : 0, todayRowCount: section == .today ? 1 : 0))
            #expect(gapped.rows.isEmpty && gapped.isSeparatorVisible)
            #expect(gapped.newTabCenterY == geometry.newTabCenterY)
            #expect(gapped.documentHeight == geometry.documentHeight)
            #expect(gapped.gapFrame?.midY == (section == .pinned
                ? geometry.pinnedRowCenters.first : geometry.todayRowCenters.first))
        }
    }

    @Test("Hidden rows close up and a drop gap opens whole pitches with an indented placeholder")
    func layoutHiddenAndGap() {
        let org = SyntheticOrganization()
        let tabs = (0..<4).map { _ in TabID() }
        let snapshot = org.snapshot(pinned: tabs.prefix(2).map { org.tab($0, pinned: true) }, today: tabs.suffix(2).map { org.tab($0) })
        let content = SidebarListContent(snapshot: snapshot)
        let title: CGFloat = 20
        let base = SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: title, width: 228)
        let hidden = SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: title, width: 228, hidden: [.tab(tabs[0])])
        #expect(hidden.centerY(of: .node(.tab(tabs[1]))) == base.centerY(of: .node(.tab(tabs[0]))))
        #expect(hidden.separatorCenterY == base.separatorCenterY - Metrics.rowPitch)
        #expect(hidden.centerY(of: .node(.tab(tabs[0]))) == nil)
        let gap = SidebarDropGap(section: .pinned, index: 1, rows: 2, depth: 1)
        let gapped = SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: title, width: 228, gap: gap)
        #expect(gapped.centerY(of: .node(.tab(tabs[1]))) == base.centerY(of: .node(.tab(tabs[1])))! + 2 * Metrics.rowPitch)
        #expect(gapped.pinnedSlotCount == 4)
        let frame = try! #require(gapped.gapFrame)
        #expect(frame.minX == Metrics.paddingX + Metrics.folderChildIndent)
        #expect(frame.height == Metrics.rowPitch + Metrics.rowHeight)
        #expect(frame.midY == base.centerY(of: .node(.tab(tabs[1])))! + Metrics.rowPitch / 2)
        let todayGap = SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: title, width: 228,
                                                 gap: SidebarDropGap(section: .today, index: 0, rows: 1))
        #expect(todayGap.gapFrame?.midY == base.centerY(of: .node(.tab(tabs[2]))))
        #expect(todayGap.documentHeight == base.documentHeight + Metrics.rowPitch)
        // Pointer y over a gapped list maps back to the gap-free layout; inside the gap: no change.
        let gapFrame = try! #require(gapped.gapFrame)
        #expect(SidebarDropResolver.removingGap(gapFrame.minY - 10, gapFrame: gapFrame) == gapFrame.minY - 10)
        #expect(SidebarDropResolver.removingGap(gapFrame.midY, gapFrame: gapFrame) == nil)
        #expect(SidebarDropResolver.removingGap(gapFrame.maxY + 20, gapFrame: gapFrame) == gapFrame.maxY + 20 - 2 * Metrics.rowPitch)
    }

    @Test("Drops resolve to Today, Pinned, before/after rows, into folders and out of folders by the icon's x")
    func dropResolution() {
        let org = SyntheticOrganization()
        let p1 = TabID(), child1 = TabID(), child2 = TabID(), p2 = TabID(), t1 = TabID(), t2 = TabID()
        let folder = FolderID(), empty = FolderID()
        let snapshot = org.snapshot(
            pinned: [org.tab(p1, pinned: true), org.folder(folder, [org.tab(child1, pinned: true), org.tab(child2, pinned: true)]),
                     org.folder(empty), org.tab(p2, pinned: true)],
            today: [org.tab(t1), org.tab(t2)])
        let content = SidebarListContent(snapshot: snapshot)
        let layout = SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: 20, width: 228)
        func center(_ node: BrowserOrganizationNode) -> CGFloat { layout.centerY(of: .node(node))! }
        let iconAtDepth0: CGFloat = 18, iconAtDepth1: CGFloat = 34
        func resolve(_ y: CGFloat, icon: CGFloat = 18) -> SidebarDropProposal {
            SidebarDropResolver.resolve(y: y, iconX: icon, layout: layout, entries: content.entries, spaceID: org.spaceID, draggedRows: 1)
        }
        // Today: New Tab and above the first row land first; halves split the rows.
        #expect(resolve(layout.newTabCenterY).destination == .init(.today(org.spaceID), position: .start))
        #expect(resolve(center(.tab(t1)) + 5).destination == .init(.today(org.spaceID), position: .after(.tab(t1))))
        #expect(resolve(center(.tab(t2)) - 5).destination == .init(.today(org.spaceID), position: .after(.tab(t1))))
        #expect(resolve(center(.tab(t2)) + 100).gap == SidebarDropGap(section: .today, index: 2, rows: 1))
        // Pinned tab halves.
        #expect(resolve(center(.tab(p1)) - 5).destination == .init(.pinned(org.spaceID), position: .start))
        #expect(resolve(center(.tab(p1)) - 5).gap == SidebarDropGap(section: .pinned, index: 0, rows: 1))
        // Folder quarters: middle into (highlight, no gap), top before, bottom first child when open.
        let into = resolve(center(.folder(folder)))
        #expect(into.destination == .init(.folder(folder), position: .end) && into.folderTarget == folder && into.gap == nil)
        #expect(resolve(center(.folder(folder)) - 15).destination == .init(.pinned(org.spaceID), position: .after(.tab(p1))))
        let firstChild = resolve(center(.folder(folder)) + 15, icon: iconAtDepth0)
        #expect(firstChild.destination == .init(.folder(folder), position: .start))
        #expect(firstChild.gap?.depth == 1)
        // After the last child: inside by default (icon at its depth), out of the folder with the icon left.
        let below = center(.tab(child2)) + 10
        #expect(resolve(below, icon: iconAtDepth1).destination == .init(.folder(folder), position: .after(.tab(child2))))
        let out = resolve(below, icon: iconAtDepth0)
        #expect(out.destination == .init(.pinned(org.spaceID), position: .after(.folder(folder))))
        #expect(out.gap == SidebarDropGap(section: .pinned, index: 4, rows: 1, depth: 0))
        // An open empty folder accepts a first child by moving the icon right.
        let afterEmpty = center(.folder(empty)) + 15
        #expect(resolve(afterEmpty, icon: iconAtDepth1).destination == .init(.folder(empty), position: .start))
        #expect(resolve(afterEmpty, icon: iconAtDepth0).destination == .init(.pinned(org.spaceID), position: .after(.folder(empty))))
        // Below the last pinned row and above the separator: end of Pinned.
        #expect(resolve(layout.separatorCenterY - 1).destination == .init(.pinned(org.spaceID), position: .after(.tab(p2))))
        // Multi-row drags open as many pitches.
        #expect(SidebarDropResolver.resolve(y: center(.tab(t1)) + 5, iconX: 18, layout: layout, entries: content.entries,
                                            spaceID: org.spaceID, draggedRows: 3).gap?.rows == 3)
        // Empty Pinned: above the separator pins at the end; collapsed Pinned opens no placeholder.
        let todayOnly = SidebarListContent(snapshot: org.snapshot(today: [org.tab(t1)]))
        let todayLayout = SidebarListLayout.resolve(entries: todayOnly.entries, spaceTitleCenterY: 20, width: 228)
        let pin = SidebarDropResolver.resolve(y: todayLayout.separatorCenterY - 2, iconX: 18, layout: todayLayout,
                                              entries: todayOnly.entries, spaceID: org.spaceID, draggedRows: 1)
        #expect(pin.destination == .init(.pinned(org.spaceID), position: .end) && pin.gap?.section == .pinned)
        let collapsed = SidebarDropResolver.resolve(y: todayLayout.separatorCenterY - 2, iconX: 18, layout: todayLayout,
                                                    entries: todayOnly.entries, spaceID: org.spaceID, draggedRows: 1,
                                                    isPinnedCollapsed: true)
        #expect(collapsed.gap == nil)
    }

    @Test("Every resolved destination is accepted by the snapshot's validateMove for a Today tab")
    func resolvedDestinationsValidate() {
        let org = SyntheticOrganization()
        let dragged = TabID()
        let folder = FolderID()
        let snapshot = org.snapshot(
            pinned: [org.tab(pinned: true), org.folder(folder, [org.tab(pinned: true), org.folder(FolderID(), [org.tab(pinned: true)])]), org.tab(pinned: true)],
            today: [org.tab(dragged), org.tab(), org.tab()])
        let content = SidebarListContent(snapshot: snapshot)
        let layout = SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: 20, width: 228, hidden: [.tab(dragged)])
        var y: CGFloat = 0
        while y < layout.documentHeight + 40 {
            for icon in stride(from: CGFloat(0), through: 90, by: 15) {
                let proposal = SidebarDropResolver.resolve(y: y, iconX: icon, layout: layout, entries: content.entries,
                                                           spaceID: org.spaceID, draggedRows: 1)
                #expect(snapshot.validateMove([.tab(dragged)], to: proposal.destination, catalog: org.catalog) == nil,
                        "y \(y) icon \(icon) → \(proposal.destination)")
            }
            y += 3
        }
    }

    @Test("A drop back in place is a no-op; nested selections drag as their top-level folders")
    func noOpAndTopLevel() {
        let org = SyntheticOrganization()
        let a = TabID(), b = TabID(), c = TabID(), child = TabID()
        let folder = FolderID()
        let snapshot = org.snapshot(pinned: [org.folder(folder, [org.tab(child, pinned: true)])], today: [org.tab(a), org.tab(b), org.tab(c)])
        let today = BrowserOrganizationContainer.today(org.spaceID)
        #expect(SidebarDropResolver.isNoOp([.tab(b)], destination: .init(today, position: .after(.tab(a))), in: snapshot))
        #expect(SidebarDropResolver.isNoOp([.tab(b)], destination: .init(today, position: .before(.tab(c))), in: snapshot))
        #expect(SidebarDropResolver.isNoOp([.tab(a)], destination: .init(today, position: .start), in: snapshot))
        #expect(SidebarDropResolver.isNoOp([.tab(b), .tab(c)], destination: .init(today, position: .end), in: snapshot))
        #expect(!SidebarDropResolver.isNoOp([.tab(b)], destination: .init(today, position: .start), in: snapshot))
        #expect(!SidebarDropResolver.isNoOp([.tab(a), .tab(c)], destination: .init(today, position: .start), in: snapshot))
        #expect(!SidebarDropResolver.isNoOp([.tab(a)], destination: .init(.pinned(org.spaceID), position: .end), in: snapshot))
        #expect(snapshot.topLevelNodes([.folder(folder), .tab(child), .tab(a)]) == [.folder(folder), .tab(a)])
        #expect(snapshot.topLevelNodes([.tab(child), .tab(a)]) == [.tab(child), .tab(a)])
    }

    @Test("Auto-scroll steps grow towards the page edges and stop at the document ends")
    func autoScroll() {
        let visible = CGRect(x: 0, y: 100, width: 228, height: 300)
        let edge = Metrics.dragAutoScrollEdge, maximum = Metrics.dragAutoScrollMaximumStep
        #expect(SidebarAutoScroll.step(pointerY: 250, visible: visible, documentHeight: 1000) == 0)
        #expect(SidebarAutoScroll.step(pointerY: 100, visible: visible, documentHeight: 1000) == -maximum)
        let shallow = SidebarAutoScroll.step(pointerY: 100 + edge - 2, visible: visible, documentHeight: 1000)
        #expect(shallow < 0 && shallow > -maximum)
        #expect(SidebarAutoScroll.step(pointerY: 400, visible: visible, documentHeight: 1000) == maximum)
        #expect(SidebarAutoScroll.step(pointerY: 400, visible: visible, documentHeight: 400) == 0)
        #expect(SidebarAutoScroll.step(pointerY: 0, visible: CGRect(x: 0, y: 0, width: 228, height: 300), documentHeight: 1000) == 0)
        #expect(SidebarAutoScroll.step(pointerY: 6, visible: CGRect(x: 0, y: 5, width: 228, height: 100), documentHeight: 1000) == -5)
    }

    @Test("Row springs settle on their target and retarget mid-flight without a jump in value or velocity")
    func slotMotion() {
        let spring = OrbitTokens.Motion.rowReorder
        var motion = SidebarSlotMotion(from: 0, to: 100, at: 0, spring: spring)
        #expect(motion.value(at: 0) == 0)
        let mid = motion.state(at: 0.08)
        #expect(mid.value > 0 && mid.value < 100 && mid.velocity > 0)
        motion.retarget(to: -50, at: 0.08, spring: spring)
        let after = motion.state(at: 0.08)
        #expect(abs(after.value - mid.value) < 0.001 && abs(after.velocity - mid.velocity) < 0.001)
        #expect(motion.target == -50)
        #expect(motion.isSettled(at: 3) && motion.value(at: 3) == -50)
        let animator = SidebarListAnimator()
        var now: CFTimeInterval = 10
        animator.clock = { now }
        animator.move(.separator, from: 0, to: 0.1, at: now)
        #expect(!animator.isAnimating)
        animator.move(.separator, from: 0, to: 41, at: now)
        #expect(animator.isAnimating)
        now += 2
        animator.advance(to: now)
        #expect(!animator.isAnimating)
    }

    @Test("Drop validation refuses folders outside Pinned, other profiles and other Spaces, and picks the frontmost target")
    func dropValidation() {
        let org = SyntheticOrganization()
        let folder = FolderID(), today = TabID(), favorite = TabID()
        let favoriteItem = BrowserOrganizationItem.tab(BrowserOrganizationTabItem(
            id: favorite, section: .favorites(org.profileID), url: URL(string: "https://fav.test/")!,
            pinnedURL: URL(string: "https://fav.test/"), pageTitle: nil, customTitle: nil, occurrenceID: nil,
            isLoadedInThisWindow: false, isSelected: false, isOpenInAnotherWindow: false))
        let snapshot = org.snapshot(pinned: [org.folder(folder)], today: [org.tab(today)], favorites: [favoriteItem])
        func payload(_ nodes: [BrowserOrganizationNode], profile: ProfileID? = nil, space: SpaceID? = nil) -> SidebarDragPayload {
            SidebarDragPayload(sourceWindow: UUID(), spaceID: space ?? org.spaceID, profileID: profile ?? org.profileID,
                               nodes: nodes, rowCount: nodes.count, grabOffsetX: 0)
        }
        let todayEnd = BrowserOrganizationDestination(.today(org.spaceID))
        #expect(SidebarDropCoordinator.validate(payload([.folder(folder)]), to: todayEnd, snapshot: snapshot, catalog: org.catalog) == .invalidDestination)
        #expect(SidebarDropCoordinator.validate(payload([.folder(folder)]), to: .init(.favorites(org.profileID)), snapshot: snapshot, catalog: org.catalog) == .invalidDestination)
        #expect(SidebarDropCoordinator.validate(payload([.folder(folder)]), to: .init(.folder(folder)), snapshot: snapshot, catalog: org.catalog) == .cycle)
        #expect(SidebarDropCoordinator.validate(payload([.tab(today)], profile: ProfileID()), to: todayEnd, snapshot: snapshot, catalog: org.catalog) == .crossProfileMove)
        // A shared Favorite is visible from every Space of the profile, but a drag from a window of
        // another Space crosses the window boundary of the contract: refused, to Today or Favorites.
        let otherSpace = SpaceID()
        #expect(snapshot.validateMove([.tab(favorite)], to: todayEnd, catalog: org.catalog) == nil)
        #expect(SidebarDropCoordinator.validate(payload([.tab(favorite)], space: otherSpace), to: todayEnd, snapshot: snapshot, catalog: org.catalog) == .notVisibleInContext)
        #expect(SidebarDropCoordinator.validate(payload([.tab(favorite)], space: otherSpace), to: .init(.favorites(org.profileID)), snapshot: snapshot, catalog: org.catalog) == .notVisibleInContext)
        #expect(SidebarDropCoordinator.validate(payload([.tab(favorite)]), to: todayEnd, snapshot: snapshot, catalog: org.catalog) == nil)
        #expect(SidebarDropCoordinator.validate(payload([.tab(today)]), to: .init(.pinned(org.spaceID)), snapshot: snapshot, catalog: org.catalog) == nil)

        let container = SidebarFlippedView(frame: NSRect(x: 0, y: 0, width: 228, height: 400))
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        let back = RecordingDropTarget(frame: NSRect(x: 0, y: 0, width: 228, height: 400), destination: .init(.today(org.spaceID)))
        let front = RecordingDropTarget(frame: NSRect(x: 0, y: 0, width: 228, height: 100), destination: .init(.favorites(org.profileID)))
        container.addSubview(back.view)
        container.addSubview(front.view)
        let coordinator = SidebarDropCoordinator()
        let drag = payload([.tab(today)])
        let first = coordinator.update(payload: drag, at: NSPoint(x: 50, y: 50), in: container, targets: [front, back],
                                       snapshot: snapshot, catalog: org.catalog)
        #expect(first?.proposal.destination == .init(.favorites(org.profileID)) && first?.isValid == true)
        #expect(front.feedback.last?.valid == true)
        let second = coordinator.update(payload: drag, at: NSPoint(x: 50, y: 300), in: container, targets: [front, back],
                                        snapshot: snapshot, catalog: org.catalog)
        #expect(second?.proposal.destination == .init(.today(org.spaceID)))
        #expect(front.feedback.last?.cleared == true)
        let refused = coordinator.update(payload: payload([.folder(folder)]), at: NSPoint(x: 50, y: 300), in: container,
                                         targets: [front, back], snapshot: snapshot, catalog: org.catalog)
        #expect(refused?.isValid == false && refused?.error == .invalidDestination)
        #expect(coordinator.acceptedDrop() == nil)
        #expect(back.feedback.last?.valid == false)
        coordinator.clear()
        #expect(back.feedback.last?.cleared == true)
    }
}
}

/// A drop region that always proposes one destination and records its feedback.
@MainActor
final class RecordingDropTarget: SidebarDropTarget {
    let view: SidebarFlippedView
    let destination: BrowserOrganizationDestination
    private(set) var feedback: [(valid: Bool, cleared: Bool)] = []
    private(set) var accepted: [(BrowserOrganizationDestination, Bool)] = []
    private(set) var dragChanges: [SidebarDragPayload?] = []

    init(frame: NSRect, destination: BrowserOrganizationDestination) {
        view = SidebarFlippedView(frame: frame)
        self.destination = destination
    }

    var dropTargetView: NSView { view }

    func dropProposal(for payload: SidebarDragPayload, at point: NSPoint,
                      in snapshot: BrowserOrganizationSnapshot) -> SidebarDropProposal? {
        SidebarDropProposal(destination: destination, gap: nil, folderTarget: nil)
    }

    func showDropFeedback(_ proposal: SidebarDropProposal?, isValid: Bool, payload: SidebarDragPayload?) {
        feedback.append((isValid, proposal == nil))
    }

    func didAcceptDrop(_ proposal: SidebarDropProposal, payload: SidebarDragPayload, changesOrganization: Bool) -> Bool {
        accepted.append((proposal.destination, changesOrganization))
        return false
    }

    func sidebarDragDidChange(_ payload: SidebarDragPayload?) { dragChanges.append(payload) }
}
