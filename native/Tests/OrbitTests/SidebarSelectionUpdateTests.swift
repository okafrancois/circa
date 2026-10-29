import AppKit
import Testing
@testable import BrowserCore
@testable import Orbit

extension NativeWebKitTests {
@Suite @MainActor struct SidebarSelectionUpdateTests {
    @Test("Random selection deltas preserve full list content, row identity and geometry, including nested and Split rows")
    func randomizedRows() throws {
        let f = SyntheticOrganization()
        let ids = (0..<40).map { _ in TabID() }
        let occurrences = ids.map { _ in TabOccurrenceID() }
        let group = BrowserSplitGroup(tabIDs: Array(ids[2..<5]))
        let folderID = FolderID()
        func snapshot(_ selected: Int) -> BrowserOrganizationSnapshot {
            let tabs = ids.indices.map { f.tab(ids[$0], title: "Page \($0)", occurrence: occurrences[$0], selected: selected == $0) }
            let panes = tabs[2..<5].compactMap { item -> BrowserOrganizationTabItem? in
                if case let .tab(tab) = item { return tab }; return nil
            }
            return f.snapshot(pinned: [f.folder(folderID, title: "Nested", [tabs[0], tabs[1]])],
                today: [.split(.init(group: group, tabs: panes))] + Array(tabs.dropFirst(5)))
        }
        let sidebar = BrowserSidebarView(frame: CGRect(x: 0, y: 0, width: 280, height: 700))
        sidebar.render(catalog: f.catalog, activeSpaceID: f.spaceID, organization: snapshot(0))
        sidebar.layoutSubtreeIfNeeded()
        let rows = sidebar.listContent.entries.compactMap { entry in sidebar.page.list.row(for: entry.node).map { (entry.node, $0, $0.frame) } }
        var seed: UInt64 = 12, previous = 0
        for _ in 0..<250 {
            seed = seed &* 6364136223846793005 &+ 1
            let next = Int(seed % UInt64(ids.count)), state = snapshot(Int(seed % UInt64(ids.count)))
            sidebar.applySelection([ids[previous], ids[next]], organization: state)
            let full = SidebarListContent(snapshot: state, selection: sidebar.selection)
            #expect(sidebar.page.list.content == full)
            for (node, row, frame) in rows {
                #expect(sidebar.page.list.row(for: node) === row)
                #expect(row.frame == frame)
            }
            previous = next
        }
    }

    @Test("Selecting a cold Favorite retains the full presentation path when admitting its surface")
    func coldFavoriteAdmission() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.session.close(); owner.window?.close() }
        owner.session.openTab(url: URL(string: "https://selection.test/favorite")!)
        await owner.session.waitForPendingCommands()
        let favorite = try #require(owner.session.organization?.selectedTab?.id)
        let oldSurface = try #require(owner.session.selectedSurface)
        owner.session.openTab(url: URL(string: "https://selection.test/other")!)
        owner.session.addToFavorites([favorite])
        await owner.session.waitForPendingCommands()
        #expect(owner.session.suspendSurface(oldSurface))
        let publish = owner.session.onChange
        var admissionWasFull: Bool?
        owner.session.onChange = {
            if admissionWasFull == nil, owner.session.organization?.selectedTab?.id == favorite {
                admissionWasFull = owner.session.selectionChangeTabIDs == nil
            }
            publish?()
        }
        defer { owner.session.onChange = publish }
        owner.session.selectTab(favorite)
        await owner.session.waitForPendingCommands()
        #expect(admissionWasFull == true)
        #expect(owner.session.selectedSurface !== oldSurface)
        let incremental = owner.favorites.grid.items
        owner.favorites.render()
        #expect(owner.favorites.grid.items == incremental)
    }

    @Test("Window selection keeps full state, Favorites, Split focus and Peek behavior equivalent to full rendering")
    func windowEquivalence() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.session.close(); owner.window?.close() }
        for n in 0..<8 { owner.session.openTab(url: URL(string: "https://selection.test/\(n)")!) }
        await owner.session.waitForPendingCommands()
        let tabs = try #require(owner.session.snapshot?.tabs)
        owner.session.addToFavorites([tabs[0].id, tabs[1].id])
        owner.session.createSplit([tabs[2].id, tabs[3].id])
        await owner.session.waitForPendingCommands()
        let publish = owner.session.onChange
        var selectionPublications = 0
        owner.session.onChange = {
            if owner.session.selectionChangeTabIDs != nil { selectionPublications += 1 }
            publish?()
        }
        defer { owner.session.onChange = publish }
        var seed: UInt64 = 33
        for step in 0..<80 {
            seed = seed &* 6364136223846793005 &+ 1
            let index = Int(seed % UInt64(tabs.count))
            if step.isMultiple(of: 13) { _ = owner.openPeek(URL(string: "https://selection.test/peek")!) }
            owner.session.selectTab(tabs[index].id)
            await owner.session.waitForPendingCommands()
            owner.focusSelectedDocument()
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            let organization = try #require(owner.session.organization)
            let full = try await environment.store.captureWindowState(in: organization.windowID)
            #expect(organization == full.organization)
            #expect(owner.session.snapshot == full.snapshot)
            #expect(owner.sidebar.listContent == SidebarListContent(snapshot: organization, selection: owner.sidebar.selection,
                liveTitle: owner.sidebar.liveTitle, liveActivity: owner.sidebar.liveActivity))
            let content = owner.sidebar.listContent
            let favorites = owner.favorites.grid.items
            let panes = owner.split.view.panes
            let frames = panes.mapValues(\.frame)
            let responder = owner.window?.firstResponder
            let peek = owner.isPeekPresented
            owner.renderSession()
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(owner.sidebar.listContent == content)
            #expect(owner.favorites.grid.items == favorites)
            #expect(owner.isPeekPresented == peek)
            #expect(owner.window?.firstResponder === responder)
            for (id, pane) in panes {
                #expect(owner.split.view.panes[id] === pane)
                #expect(pane.frame == frames[id])
            }
        }
        #expect(selectionPublications >= 80)
        #expect(owner.session.selectionChangeTabIDs == nil)
    }
}
}
