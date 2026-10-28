import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

@MainActor
private final class SpaceHoverTimer: OrbitCancellable {
    let action: @MainActor () -> Void
    var cancelled = false
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func cancel() { cancelled = true }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SpaceSwitchHoverTests {
    private func fixture() -> (BrowserSidebarView, NSWindow, BrowserCatalogSnapshot) {
        let profile = BrowserProfile(id: ProfileID(), name: "Work")
        let spaces = ["Research", "Personal", "Reading"].map {
            BrowserSpace(id: SpaceID(), profileID: profile.id, name: $0)
        }
        let catalog = BrowserCatalogSnapshot(profiles: [profile], spaces: spaces)
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 640))
        let window = NSWindow(contentRect: sidebar.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.render(catalog: catalog, activeSpaceID: spaces[0].id, organization: nil)
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, window, catalog)
    }

    @Test("Cold dwell is cancelled on early exit, warm targets replace immediately, and idle rearms the dwell")
    func dwellAndHandoff() throws {
        let (sidebar, window, _) = fixture()
        defer { window.close() }
        let capsule = try #require(sidebar.subviews.compactMap { $0 as? SidebarSpaceTooltip }.first)
        var timers: [SpaceHoverTimer] = []
        var delays: [TimeInterval] = []
        sidebar.scheduleSpaceHover = { delay, action in
            delays.append(delay)
            let timer = SpaceHoverTimer(action)
            timers.append(timer)
            return timer
        }
        let buttons = sidebar.footer.spaceButtons
        sidebar.footer.onHoverSpace?(buttons[0])
        #expect(capsule.isHidden && delays == [0.45])
        sidebar.footer.onHoverSpace?(nil)
        #expect(timers[0].cancelled && capsule.isHidden)
        sidebar.footer.onHoverSpace?(buttons[1])
        #expect(delays == [0.45, 0.45])
        timers[1].action()
        #expect(!capsule.isHidden && capsule.name == "Personal")
        let texts = descendantTextFields(capsule).map(\.stringValue)
        #expect(!texts.contains("Work"), "The capsule never shows the Space's profile")
        #expect(capsule.shortcut == "⌃2" && capsule.alphaValue == 1)
        sidebar.footer.onHoverSpace?(buttons[2])
        #expect(timers.count == 2 && !capsule.isHidden && capsule.name == "Reading")
        sidebar.footer.onHoverSpace?(nil)
        #expect(capsule.isHidden)
        sidebar.footer.onHoverSpace?(buttons[0])
        #expect(capsule.isHidden && timers.count == 3)
    }

    @Test("Selection retains hovered controls, known icons and the active indicator without selecting on hover")
    func selectionAndIcons() throws {
        let (sidebar, window, catalog) = fixture()
        defer { window.close() }
        let button = sidebar.footer.spaceButtons[1]
        button.settingsIcon = "🏀"
        var selected: SpaceID?
        sidebar.onSelectSpace = { selected = $0 }
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        button.mouseEntered(with: event)
        #expect(selected == nil && button.iconEmphasis == 1 && button.hoverAmount == 1)
        button.performClick(nil)
        #expect(selected == button.space.id)
        sidebar.render(catalog: catalog, activeSpaceID: button.space.id, organization: nil)
        #expect(sidebar.footer.spaceButtons[1] === button)
        #expect(button.settingsIcon == "🏀" && button.isActive && button.isHovering)
        #expect(!sidebar.footer.spaceButtons[0].isActive)
        button.mouseExited(with: event)
        #expect(button.iconEmphasis == 1 && button.hoverAmount == 0)
        sidebar.render(catalog: catalog, activeSpaceID: catalog.spaces[0].id, organization: nil)
        #expect(!button.isActive && button.iconEmphasis == 0)
        #expect(button.frame.height == 32 && button.dotDiameter == 8)
    }

    @Test("Menu, disabled commands and detached controls cannot publish a pending capsule")
    func invalidation() throws {
        let (sidebar, window, _) = fixture()
        defer { window.close() }
        let capsule = try #require(sidebar.subviews.compactMap { $0 as? SidebarSpaceTooltip }.first)
        var timer: SpaceHoverTimer?
        sidebar.scheduleSpaceHover = { _, action in let next = SpaceHoverTimer(action); timer = next; return next }
        sidebar.footer.onHoverSpace?(sidebar.footer.spaceButtons[0])
        sidebar.setCommandsEnabled(false)
        #expect(timer?.cancelled == true)
        timer?.action()
        #expect(capsule.isHidden)
        sidebar.setCommandsEnabled(true)
        sidebar.footer.onHoverSpace?(sidebar.footer.spaceButtons[0])
        sidebar.footer.showContextMenu(for: sidebar.footer.spaceButtons[0], present: false)
        timer?.action()
        #expect(capsule.isHidden)
        sidebar.cancelFooterPresentations()
        sidebar.footer.onHoverSpace?(sidebar.footer.spaceButtons[0])
        sidebar.removeFromSuperview()
        timer?.action()
        #expect(capsule.isHidden)
    }

    @Test("The capsule holds only the name and shortcut, fits its maximum width and keeps its exact short width")
    func nameAndShortcutOnly() {
        let capsule = SidebarSpaceTooltip()
        let short = capsule.configure(name: "Personal", shortcut: "⌃2")
        #expect(short.height == 28 && short.width < 160)
        #expect(Set(descendantTextFields(capsule).map(\.stringValue)) == ["Personal", "⌃", "2"])
        let long = capsule.configure(name: String(repeating: "Long ", count: 30), shortcut: "⌃9", maximumWidth: 240)
        #expect(long.width <= 240)
        #expect(capsule.configure(name: "Personal", shortcut: "⌃2") == short)
    }

    @Test("Symbol Space icons render upright in the flipped footer button")
    func symbolIconOrientation() throws {
        let (sidebar, window, _) = fixture()
        defer { window.close() }
        let button = try #require(sidebar.footer.spaceButtons.first)
        button.iconSelection = .systemSymbol("triangle.fill")
        button.layoutSubtreeIfNeeded()
        let bitmap = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: bitmap)
        // A point-up triangle has most of its ink in its lower half; flipped drawing inverts that.
        var upper = 0.0, lower = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let alpha = Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                if y < bitmap.pixelsHigh / 2 { upper += alpha } else { lower += alpha }
            }
        }
        #expect(upper + lower > 0)
        #expect(lower > upper * 1.5)
    }
}
}

@MainActor
private func descendantTextFields(_ view: NSView) -> [NSTextField] {
    view.subviews.flatMap { subview -> [NSTextField] in
        if let field = subview as? NSTextField { return [field] }
        return descendantTextFields(subview)
    }
}
