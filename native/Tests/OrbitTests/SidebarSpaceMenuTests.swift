import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SidebarSpaceMenuTests {
    private func fixture() -> (SidebarFooterView, [BrowserSpace]) {
        let profile = ProfileID()
        let spaces = [BrowserSpace(id: SpaceID(), profileID: profile, name: "First"), BrowserSpace(id: SpaceID(), profileID: profile, name: "Second")]
        let footer = SidebarFooterView()
        footer.render(spaces: spaces, activeSpaceID: spaces[0].id)
        return (footer, spaces)
    }
    private func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    @Test("First right-click and Control-click open once without selecting the inactive Space")
    func routing() {
        let (footer, _) = fixture()
        let button = footer.spaceButtons[1]
        var openings = 0, selections = 0
        footer.onSelectSpace = { _ in selections += 1 }
        button.onContextMenu = { openings += 1; footer.showContextMenu(for: button, present: false) }
        #expect(button.acceptsFirstMouse(for: event(.rightMouseDown)))
        button.rightMouseDown(with: event(.rightMouseDown))
        #expect(openings == 1 && selections == 0 && footer.contextMenu != nil)
        footer.cancelContextMenu()
        button.mouseDown(with: event(.leftMouseDown, flags: .control))
        #expect(openings == 2 && selections == 0)
        footer.cancelContextMenu()
        #expect(button.accessibilityPerformShowMenu())
        #expect(openings == 3 && selections == 0)
        footer.setCommandsEnabled(false)
        button.rightMouseDown(with: event(.rightMouseDown))
        #expect(!button.accessibilityPerformShowMenu() && openings == 3)
    }
    @Test("Composition exposes icon editing, fixed order, disabled boundaries and spacious icon rows")
    func composition() throws {
        let (footer, spaces) = fixture()
        let actions = footer.actions(for: spaces[0].id)
        #expect(actions.map(\.kind) == [.rename, .icon, .theme, .moveLeft, .moveRight, .delete])
        #expect(actions.map(\.startsGroup) == [false, false, false, true, false, true])
        #expect(!actions[3].enabled && actions[4].enabled && actions[5].destructive)
        for action in actions { #expect(NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil) != nil) }
        let menu = SidebarSpaceMenu(actions: actions, accent: .defaultSpace)
        let rows = menu.view.subviews.compactMap { $0 as? CreationMenuRow }
        #expect(rows.count == 6 && rows.allSatisfy { $0.frame.height == 40 })
        #expect(menu.popup.usesGlass)
        var iconChanges = 0
        footer.onEditSpaceIcon = { id in if id == spaces[1].id { iconChanges += 1 } }
        footer.showContextMenu(for: footer.spaceButtons[1], present: false)
        let shown = try #require(footer.contextMenu)
        shown.activate(1)
        shown.activate(1)
        #expect(iconChanges == 1)
        footer.render(spaces: [spaces[0]], activeSpaceID: spaces[0].id)
        #expect(!footer.actions(for: spaces[0].id)[5].enabled)
    }
    @Test("Freeze, removal, profile replacement and detached controls reject captured actions")
    func authority() throws {
        for mutation in 0..<4 {
            let (footer, spaces) = fixture()
            var changes = 0
            footer.onRenameSpace = { _ in changes += 1 }
            let staleButton = footer.spaceButtons[1]
            footer.showContextMenu(for: staleButton, present: false)
            let menu = try #require(footer.contextMenu)
            switch mutation {
            case 0: footer.setCommandsEnabled(false); footer.setCommandsEnabled(true)
            case 1: footer.render(spaces: [spaces[0]], activeSpaceID: spaces[0].id)
            case 2:
                var replaced = spaces
                replaced[1] = BrowserSpace(id: spaces[1].id, profileID: ProfileID(), name: "Replacement")
                footer.render(spaces: replaced, activeSpaceID: spaces[0].id)
            default: footer.viewDidMoveToWindow()
            }
            menu.activate(0)
            menu.onAction?(menu.actions[0])
            #expect(changes == 0 && footer.contextMenu == nil)
            if mutation == 1 || mutation == 2 {
                footer.showContextMenu(for: staleButton, present: false)
                #expect(footer.contextMenu == nil)
            }
        }
    }
    @Test("Sidebar owns the menu hold, cancels on hide and catalog replacement, and blocks swipe admission")
    func sidebarLifecycle() throws {
        let (_, spaces) = fixture()
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 640))
        let catalog = BrowserCatalogSnapshot(profiles: [], spaces: spaces)
        sidebar.render(catalog: catalog, activeSpaceID: spaces[0].id, organization: nil)
        sidebar.footer.showContextMenu(for: sidebar.footer.spaceButtons[1], present: false)
        let menu = try #require(sidebar.footer.contextMenu)
        #expect(sidebar.hasFooterPresentation && !sidebar.swipeCanInteract)
        sidebar.viewDidHide()
        #expect(!sidebar.hasFooterPresentation)
        var calls = 0
        menu.onAction = { _ in calls += 1 }
        menu.activate(0)
        #expect(calls == 0)
        sidebar.footer.showContextMenu(for: sidebar.footer.spaceButtons[1], present: false)
        sidebar.render(catalog: nil, activeSpaceID: nil, organization: nil)
        #expect(!sidebar.hasFooterPresentation && sidebar.footer.spaceButtons.isEmpty)
    }

    @Test("Synchronous footer replacement during swipe cancellation cannot open an obsolete target")
    func reentrantReplacement() {
        let (footer, spaces) = fixture()
        let old = footer.spaceButtons[1]
        footer.onMenuWillOpen = { footer.render(spaces: [spaces[0]], activeSpaceID: spaces[0].id) }
        footer.showContextMenu(for: old, present: false)
        #expect(footer.contextMenu == nil)
    }

    @Test("Shared rows preserve the creation menu geometry, identifiers and default floating material")
    func creationMenuRegression() {
        let actions = [SidebarCreationAction(command: .newSpace, title: "New Space", symbol: "square", shortcut: "", enabled: true, perform: {})]
        let menu = SidebarCreationMenu(actions: actions, accent: .defaultSpace)
        let rows = menu.view.subviews.compactMap { $0 as? CreationMenuRow }
        #expect(menu.view.frame.width == OrbitTokens.Metrics.Sidebar.plusMenuWidth)
        #expect(rows.count == 1 && rows[0].frame.height == 40)
        #expect(rows[0].accessibilityIdentifier() == "creation-newSpace")
        #expect(!rows[0].destructive && menu.popover.usesGlass)
    }

    @Test("Keyboard skips disabled ordering, Escape cancels and cancelled actions stay inert")
    func keyboard() {
        let (footer, spaces) = fixture()
        let menu = SidebarSpaceMenu(actions: footer.actions(for: spaces[0].id), accent: .defaultSpace)
        _ = menu.view
        var actions: [SidebarSpaceAction.Kind] = []
        menu.onAction = { actions.append($0.kind) }
        #expect(menu.handle(#selector(NSResponder.moveDown(_:))))
        #expect(menu.handle(#selector(NSResponder.insertNewline(_:))))
        #expect(actions == [.rename])
        menu.activate(1)
        #expect(actions.count == 1)
        let cancelled = SidebarSpaceMenu(actions: menu.actions, accent: .defaultSpace)
        cancelled.onAction = { actions.append($0.kind) }
        cancelled.handle(#selector(NSResponder.cancelOperation(_:)))
        cancelled.activate(0)
        #expect(actions.count == 1)
    }
}
}
