import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

/// Independent synthetic, windowless review checks; no OS input or material claim.
extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SidebarSpaceIndependentReviewTests {
    private func fixture(_ count: Int = 3) -> (SidebarFooterView, [BrowserSpace]) {
        let profile = ProfileID()
        let spaces = (0..<count).map { BrowserSpace(id: SpaceID(), profileID: profile, name: "Review Space \($0)") }
        let footer = SidebarFooterView()
        footer.render(spaces: spaces, activeSpaceID: spaces[0].id)
        return (footer, spaces)
    }

    @Test("Context key and Shift-F10 dispatch once without invoking Space selection")
    func contextKeys() {
        let (footer, _) = fixture()
        let button = footer.spaceButtons[1]
        var opens = 0, selections = 0
        button.onContextMenu = { opens += 1 }
        footer.onSelectSpace = { _ in selections += 1 }
        for (key, flags): (UInt16, NSEvent.ModifierFlags) in [(110, []), (99, .shift)] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                        timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)!
            button.keyDown(with: event)
        }
        #expect(opens == 2 && selections == 0)
    }

    @Test("Ordering captures the exact before destination and allows each action only once")
    func orderingAndSingleUse() throws {
        for index in 0..<3 {
            for actionIndex in [3, 4] {
                let (footer, spaces) = fixture()
                var moves: [(SpaceID, SpaceID?)] = []
                footer.onMoveSpace = { moves.append(($0, $1)) }
                footer.showContextMenu(for: footer.spaceButtons[index], present: false)
                let menu = try #require(footer.contextMenu)
                menu.activate(actionIndex)
                menu.activate(actionIndex)
                let enabled = actionIndex == 3 ? index > 0 : index < 2
                #expect(moves.count == (enabled ? 1 : 0))
                if enabled {
                    #expect(moves.first?.0 == spaces[index].id)
                    let destination = actionIndex == 3 ? spaces[index - 1].id : (index + 2 < spaces.count ? spaces[index + 2].id : nil)
                    #expect(moves.first?.1 == destination)
                }
            }
        }
    }

    @Test("Selection and reorder revoke retained menu rows and closures")
    func retainedRowsAfterPublication() throws {
        for reorder in [false, true] {
            let (footer, spaces) = fixture()
            var edits = 0
            footer.onRenameSpace = { _ in edits += 1 }
            footer.showContextMenu(for: footer.spaceButtons[1], present: false)
            let old = try #require(footer.contextMenu)
            let row = try #require(old.view.subviews.compactMap { $0 as? CreationMenuRow }.first)
            footer.render(spaces: reorder ? Array(spaces.reversed()) : spaces,
                          activeSpaceID: reorder ? spaces[0].id : spaces[2].id)
            _ = row.accessibilityPerformPress()
            old.onAction?(old.actions[0])
            #expect(edits == 0 && footer.contextMenu == nil)
        }
    }

    @Test("Reentrant freeze during hover cancellation leaves no menu authority")
    func freezeOnHoverCancellation() {
        let (footer, _) = fixture()
        footer.onHoverSpace = { _ in footer.setCommandsEnabled(false) }
        footer.showContextMenu(for: footer.spaceButtons[1], present: false)
        #expect(footer.contextMenu == nil)
    }

    @Test("Active Space remains revealed after catalog reorder with unchanged selection and viewport")
    func reorderedActiveVisibility() throws {
        let (footer, spaces) = fixture(40)
        let geometry = OrbitSidebarGeometry.resolve(.init(width: 220, height: 640, spaceCount: spaces.count))
        footer.frame = geometry.footerFrame
        footer.apply(geometry)
        #expect(footer.spaceButtons[0].visibleRect.width >= 24)
        footer.render(spaces: Array(spaces.reversed()), activeSpaceID: spaces[0].id)
        footer.apply(geometry)
        let active = try #require(footer.spaceButtons.first { $0.isActive })
        #expect(active.visibleRect.width >= 24)
    }
    @Test("Keyboard traverses disabled ordering and AX rows preserve enabled single-use actions")
    func keyboardAndAccessibilityRows() throws {
        let (footer, spaces) = fixture()
        let menu = SidebarSpaceMenu(actions: footer.actions(for: spaces[0].id), accent: .defaultSpace)
        _ = menu.view
        var performed: [SidebarSpaceAction.Kind] = []
        menu.onAction = { performed.append($0.kind) }
        for _ in 0..<4 { menu.handle(#selector(NSResponder.moveDown(_:))) }
        menu.handle(#selector(NSResponder.insertNewline(_:)))
        #expect(performed == [.moveRight])
        let rows = menu.view.subviews.compactMap { $0 as? CreationMenuRow }
        #expect(rows.count == 7)
        #expect(rows[3].accessibilityRole() == .menuItem)
        #expect(!rows[3].accessibilityPerformPress())
        #expect(rows[0].accessibilityPerformPress())
        #expect(performed == [.moveRight])
        let fresh = SidebarSpaceMenu(actions: menu.actions, accent: .defaultSpace)
        fresh.onAction = { performed.append($0.kind) }
        let freshRows = fresh.view.subviews.compactMap { $0 as? CreationMenuRow }
        #expect(freshRows[1].accessibilityPerformPress())
        #expect(freshRows[1].accessibilityPerformPress())
        #expect(performed == [.moveRight, .icon])
    }

}
}
