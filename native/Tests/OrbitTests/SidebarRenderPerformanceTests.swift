import AppKit
import Testing
@testable import BrowserCore
@testable import Orbit

extension NativeWebKitTests {
@Suite @MainActor struct SidebarRenderPerformanceTests {
    @Test("One hundred composite metadata updates visit only their affected row", arguments: [true, false])
    func compositeUpdates(favorite: Bool) throws {
        let fixture = SyntheticOrganization()
        let ids = (0..<30).map { _ in TabID() }
        let occurrences = ids.map { _ in TabOccurrenceID() }
        let group = BrowserSplitGroup(tabIDs: Array(ids.prefix(2)))
        func snapshot(_ title: String) -> BrowserOrganizationSnapshot {
            let tabs = ids.indices.map { fixture.tab(ids[$0], title: $0 == 0 ? title : "Other", occurrence: occurrences[$0]) }
            if favorite { return fixture.snapshot(today: Array(tabs.dropFirst()), favorites: [tabs[0]]) }
            let panes = tabs.prefix(2).compactMap { item -> BrowserOrganizationTabItem? in
                if case let .tab(tab) = item { return tab }; return nil
            }
            return fixture.snapshot(today: [.split(.init(group: group, tabs: panes))] + Array(tabs.dropFirst(2)))
        }
        let sidebar = BrowserSidebarView(frame: CGRect(x: 0, y: 0, width: 280, height: 700))
        var visits = 0
        sidebar.liveActivity = { _ in visits += 1; return .init() }
        sidebar.render(catalog: fixture.catalog, activeSpaceID: fixture.spaceID, organization: snapshot("Initial"))
        sidebar.layoutSubtreeIfNeeded()
        let rows = sidebar.listContent.entries.compactMap { entry in sidebar.page.list.row(for: entry.node).map { (entry.node, $0, $0.frame) } }
        visits = 0
        for step in 0..<100 { sidebar.applyMetadata([ids[0]], organization: snapshot("Title \(step)")) }
        print("Composite activity visits favorite=\(favorite): \(visits)")
        #expect(visits <= (favorite ? 100 : 400))
        #expect(sidebar.listContent == SidebarListContent(snapshot: snapshot("Title 99"), selection: sidebar.selection))
        for (node, row, frame) in rows {
            #expect(sidebar.page.list.row(for: node) === row)
            #expect(row.frame == frame)
        }
    }

    @Test("Indexed node lookups preserve nested folders, Split members and Favorites")
    func indexedNodes() {
        let fixture = SyntheticOrganization()
        let tabs = [fixture.tab(), fixture.tab()]
        let panes = tabs.compactMap { item -> BrowserOrganizationTabItem? in
            if case let .tab(tab) = item { return tab }; return nil
        }
        let split = BrowserSplitGroup(tabIDs: panes.map(\.id)), folder = FolderID()
        let snapshot = fixture.snapshot(pinned: [fixture.folder(folder, title: "Nested", [ .split(.init(group: split, tabs: panes)) ])],
            today: [fixture.tab()], favorites: [fixture.tab()])
        let index = BrowserOrganizationMetadataIndex(snapshot)
        let nodes = snapshot.allTabs.map { BrowserOrganizationNode.tab($0.id) } + [.folder(folder), .split(split.id)]
        for node in nodes { #expect(snapshot.item(for: node, using: index) == snapshot.item(for: node)) }
        for tab in snapshot.allTabs { #expect(snapshot.tab(tab.id, using: index) == tab) }
    }

    @Test("Clearing absent errand decorations does not schedule layout")
    func unchangedErrand() {
        let row = LayoutCountingRow(node: .tab(TabID()))
        row.frame = CGRect(x: 0, y: 0, width: 250, height: 44)
        row.layoutSubtreeIfNeeded()
        row.needsLayout = false
        row.layoutPasses = 0
        for _ in 0..<100 { row.setErrandMark(nil); row.layoutSubtreeIfNeeded() }
        #expect(row.layoutPasses == 0)
        #expect(!row.needsLayout)
    }
}
}

@MainActor private final class LayoutCountingRow: SidebarListRow {
    var layoutPasses = 0
    override func layout() { layoutPasses += 1; super.layout() }
}
