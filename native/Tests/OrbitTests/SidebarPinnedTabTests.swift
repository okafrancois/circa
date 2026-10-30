import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class PinnedKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class PinnedHoverTicket: OrbitCancellable {
    let action: @MainActor () -> Void
    var cancelled = false
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func cancel() { cancelled = true }
}

extension NativeWebKitTests {
@MainActor
struct SidebarPinnedTabTests {
    @Test("Pinned actions follow local loaded state including remote-only pins")
    func actionPolicy() {
        var item = SidebarTabItem(id: TabID(), title: "Synthetic pin", selected: false, isPinned: true)
        #expect(item.trailingAction == .archivePin)
        item.isOpenInAnotherWindow = true
        #expect(item.trailingAction == .archivePin)
        item.isLoadedInThisWindow = true
        #expect(item.trailingAction == .closePage)
        item.isPinned = false
        item.isLoadedInThisWindow = false
        #expect(item.trailingAction == .closePage)
    }

    @Test("Action help uses localized copy, system text and measured dwell and departure")
    func pillContract() {
        #expect(SidebarTabActionButton.appearanceDelay == 0.75)
        #expect(SidebarTabActionButton.appearanceDuration == 0)
        #expect(SidebarTabActionButton.departureDuration == 0.3)
        #expect(SidebarTabTrailingAction.closePage.pillText == uiText("Close and Keep Pinned"))
        #expect(SidebarTabTrailingAction.archivePin.pillText == uiText("Archive this tab"))
        let pill = SidebarTabActionPill()
        #expect(pill.configure(action: .closePage).height == 28)
        #expect(pill.label.font == NSFont.systemFont(ofSize: 12, weight: .semibold))
        #expect(pill.hitTest(.zero) == nil)
    }

    @Test("Leaving, unloading, reusing and disabling a button retire pending action help")
    func staleDwell() {
        let window = PinnedKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                     styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let row = SidebarTabRow(item: .init(id: TabID(), title: "Synthetic pin", selected: false,
                                            isPinned: true, isLoadedInThisWindow: true))
        row.frame = NSRect(x: 8, y: 100, width: 300, height: 36)
        window.contentView?.addSubview(row)
        row.layoutSubtreeIfNeeded()
        defer { row.resetForReuse(); SidebarTabHoverCard.shared.dismiss(); window.close() }
        let button = row.closeButton
        var tickets: [PinnedHoverTicket] = []
        button.schedule = { _, action in let ticket = PinnedHoverTicket(action); tickets.append(ticket); return ticket }
        row.mouseEntered(with: NSEvent())
        button.mouseEntered(with: NSEvent())
        #expect(tickets.count == 1 && !button.isPillPresented)
        button.mouseExited(with: NSEvent())
        tickets[0].action()
        #expect(tickets[0].cancelled && !button.isPillPresented)
        button.mouseEntered(with: NSEvent())
        tickets[1].action()
        #expect(button.isPillPresented)
        row.resetForReuse()
        #expect(!button.isPillPresented)
        row.mouseEntered(with: NSEvent())
        button.mouseEntered(with: NSEvent())
        button.isEnabled = false
        tickets.last?.action()
        #expect(!button.isPillPresented)
    }

    @Test("Loaded and dormant pins are unfilled at rest, and only the hovered row receives a fill")
    func pinnedCards() {
        let id = TabID()
        let row = SidebarTabRow(item: .init(id: id, title: "Cached title", selected: true,
                                            isPinned: true, isLoadedInThisWindow: true))
        row.update(.init(id: id, title: "Cached title", selected: false, isPinned: true, isLoadedInThisWindow: true), depth: 1)
        #expect(row.background.fillColor == nil && row.background.outerShadow?.blur == nil)
        row.mouseEntered(with: NSEvent())
        #expect(row.background.fillColor == OrbitTokens.Color.State.pinnedHover)
        row.mouseExited(with: NSEvent())
        #expect(row.background.fillColor == nil)
        #expect(row.background.cornerRadius == 11)
        row.frame = NSRect(x: 0, y: 0, width: 300, height: 36)
        row.layoutSubtreeIfNeeded()
        #expect(row.background.frame == NSRect(x: 13, y: 0, width: 288, height: 36))
        row.update(.init(id: id, title: "Cached title", selected: false, isPinned: true), depth: 1)
        #expect(row.background.fillColor == nil)
        #expect(row.titleLabel.stringValue == "Cached title" && !row.favicon.isHidden)
    }
}
}

extension NativeWebKitTests.SidebarPinnedTabTests {
    @Test("Selected pin card is opaque in light Spaces and keeps the shared style in dark Spaces")
    func selectedPinGeometry() {
        let row = SidebarTabRow(item: .init(id: TabID(), title: "Illustrated Atlas — Field Notes", selected: true,
            isPinned: true, isLoadedInThisWindow: true), depth: 1)
        row.wantsLayer = true
        row.frame = NSRect(x: 8, y: 0, width: 480, height: 36)
        row.layoutSubtreeIfNeeded()
        #expect(row.background.frame == NSRect(x: 13, y: 0, width: 468, height: 36))
        #expect(row.background.layer?.frame.minX == row.background.frame.minX)
        #expect(row.favicon.frame == NSRect(x: 23, y: 10, width: 16, height: 16))
        #expect(row.titleLabel.frame.minX == 47 && row.titleLabel.frame.minY == 9.5)
        #expect(row.closeButton.frame.midX == 463)
        #expect(row.background.cornerRadius == 11)
        row.appearance = NSAppearance(named: .aqua)
        #expect(row.background.outerShadow?.blur == 2 && row.background.outerShadow?.offsetY == 1)
        #expect(row.background.fillColor == OrbitTokens.Color.State.pinnedSelected)
        #expect(row.titleLabel.textColor == OrbitTokens.Color.State.pinnedSelectedText)
        row.appearance = NSAppearance(named: .darkAqua)
        #expect(row.background.fillColor != OrbitTokens.Color.State.pinnedSelected)
        #expect(row.background.outerShadow?.color == OrbitTokens.Color.ShadowColor.tabSelected)
        #expect(row.titleLabel.textColor != OrbitTokens.Color.State.pinnedSelectedText)
    }
}
