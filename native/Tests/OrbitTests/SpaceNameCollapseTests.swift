import AppKit
@testable import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SpaceNameCollapseTests {
    @Test("Header press and keyboard disclosure toggle only pinned rows and survive Space changes and restoration")
    func toggleAndPersistence() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let first = try await store.createSpace(name: "First", profileID: profile)
        let second = try await store.createSpace(name: "Second", profileID: profile)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: first,
                                                engine: SiteSyntheticEngine(), onClose: {}, onActivate: {})
        defer { controller.session.close(); controller.window?.close() }
        func settle() async {
            await controller.session.waitForPendingCommands()
            controller.window?.contentView?.layoutSubtreeIfNeeded()
        }
        await settle()
        controller.session.openTab(url: URL(string: "https://pinned.test/")!)
        await settle()
        let pinned = try #require(controller.session.organization?.today.first?.node.tabID)
        controller.session.pinTabs([pinned])
        controller.session.openTab(url: URL(string: "https://today.test/")!)
        await settle()
        let original = try #require(controller.session.organization)
        let disclosure = controller.sidebar.page.disclosure
        #expect(disclosure.accessibilityRole() == .disclosureTriangle)
        #expect(disclosure.accessibilityLabel() == "First")
        #expect(disclosure.isAccessibilityExpanded())
        #expect(disclosure.accessibilityPerformPress())
        await settle()
        #expect(controller.session.organization?.isPinnedSectionCollapsed == true)
        #expect(!disclosure.isAccessibilityExpanded())
        #expect((disclosure.accessibilityValue() as? NSNumber)?.boolValue == false)
        #expect(controller.sidebar.page.list.tabRows.allSatisfy { !$0.item.isPinned })
        #expect(controller.session.organization?.pinned == original.pinned)
        #expect(controller.session.organization?.today == original.today)
        let collapsed = await store.sessionDocument()
        controller.session.activateSpace(second)
        await settle()
        #expect(controller.session.organization?.isPinnedSectionCollapsed == false)
        controller.session.activateSpace(first)
        await settle()
        let restoredHeader = controller.sidebar.page.disclosure
        #expect(!restoredHeader.isAccessibilityExpanded())
        restoredHeader.moveRight(nil)
        await settle()
        #expect(controller.session.organization?.isPinnedSectionCollapsed == false)
        restoredHeader.moveLeft(nil)
        await settle()
        #expect(controller.session.organization?.isPinnedSectionCollapsed == true)
        controller.sidebar.page.setCommandsEnabled(false)
        #expect(!restoredHeader.accessibilityPerformPress())
        #expect(!restoredHeader.accessibilityPerformShowMenu())
        #expect(controller.session.organization?.isPinnedSectionCollapsed == true)
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(collapsed.encoded()))
        let document = await restored.sessionDocument()
        #expect(document.organization.spaces.first { $0.spaceID == first }?.isPinnedCollapsed == true)
        #expect(document.organization.spaces.first { $0.spaceID == second }?.isPinnedCollapsed != true)
        let expanded = BrowserSessionDocument(profiles: collapsed.profiles, spaces: collapsed.spaces,
            windows: collapsed.windows, tabs: collapsed.tabs,
            organization: BrowserOrganizationDocument(tabs: collapsed.organization.tabs, folders: collapsed.organization.folders,
                favorites: collapsed.organization.favorites, spaces: collapsed.organization.spaces.map {
                    .init(spaceID: $0.spaceID, pinned: $0.pinned, today: $0.today, isPinnedCollapsed: false)
                }, archive: collapsed.organization.archive, archivePolicy: collapsed.organization.archivePolicy,
                splits: collapsed.organization.splits))
        #expect(try BrowserSyncMapping.project(session: collapsed, settings: .init()) == BrowserSyncMapping.project(session: expanded, settings: .init()))
        #expect(controller.window?.isVisible == false)
    }

    @Test("Hover reveals the chevron and menu without changing the Space menu or pinned content")
    func hoverAndMenu() {
        let page = SidebarSpacePageView(frame: NSRect(x: 0, y: 0, width: 260, height: 640))
        page.geometry = OrbitSidebarGeometry.resolve(.init(width: 260, height: 640))
        page.iconSelection = .systemSymbol("flask")
        page.render(title: "Synthetic", content: .empty, animated: false)
        page.layoutSubtreeIfNeeded()
        let menu = page.spaceContextMenu
        #expect(page.moreButton.alphaValue == 0 && page.iconButton.alphaValue == 1)
        page.disclosure.setHovered(true)
        page.layoutSubtreeIfNeeded()
        #expect(page.moreButton.alphaValue == 1 && page.iconButton.alphaValue == 0)
        #expect(page.titleFrame.minX == OrbitTokens.Metrics.Sidebar.titleOriginX)
        #expect(page.spaceContextMenu === menu)
        #expect(menu?.items.contains { $0.action != nil } == true)
        page.disclosure.setHovered(false)
        #expect(page.moreButton.alphaValue == 0 && page.iconButton.alphaValue == 1)
    }

    @Test("Section motion clips retained rows, reflows Today, reverses, and settles with no stale masks")
    func motion() throws {
        OrbitMotionPreferences.overrideReducedMotion = false
        defer { OrbitMotionPreferences.overrideReducedMotion = nil }
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 260, height: 640))
        list.spaceTitleCenterY = 28
        list.forcesAnimation = true
        var time = 10.0
        list.animator.clock = { time }
        let entries = (0..<7).map { index in
            let id = TabID()
            return SidebarListEntry(node: .tab(id), section: .pinned, ancestors: [],
                                    content: .tab(.init(id: id, title: "Synthetic \(index)", selected: false, isPinned: true)))
        }
        let todayID = TabID()
        let today = SidebarListEntry(node: .tab(todayID), section: .today, ancestors: [],
                                     content: .tab(.init(id: todayID, title: "Today", selected: false)))
        let expanded = SidebarListContent(entries: entries + [today])
        let collapsed = SidebarListContent(entries: [today], isPinnedSectionCollapsed: true)
        list.apply(expanded, animated: false)
        let row = try #require(list.row(for: entries[0].node))
        let before = list.newTabRow.frame.midY
        list.apply(collapsed, animated: true)
        time += 0.06
        list.animator.advance(to: time)
        #expect(list.newTabRow.frame.midY < before)
        #expect(row.layer?.mask != nil && row.titleLabel.alphaValue == 0)
        #expect(list.pinnedExpansion > 0 && list.pinnedExpansion < 1)
        list.apply(expanded, animated: true)
        #expect(list.row(for: entries[0].node) === row)
        time += 0.23
        list.animator.advance(to: time)
        #expect(list.pinnedExpansion == 1 && row.layer?.mask == nil && row.titleLabel.alphaValue == 1)
        #expect(list.newTabRow.frame.midY == before)
        OrbitMotionPreferences.overrideReducedMotion = true
        list.apply(collapsed, animated: true)
        #expect(!list.animator.isAnimating && list.tabRows.count == 1 && list.pinnedExpansion == 0)
    }
}
}
