import AppKit
import BrowserCore
import ChromiumEngine

/// Synthetic-only fixture for the optional toolbar: places the window on screen at a fixed
/// geometry, loads a loopback page and reports control rectangles in screen points.
@MainActor
enum OrbitToolbarProbe {
    static let bundleID = "lab.orbit.orbit.toolbar"

    /// `controllers` are all live windows: a menu command targets the router's selected window,
    /// which a restored session may resolve to another window than `owner`.
    static func run(_ owner: OrbitWindowController, controllers: [OrbitWindowController],
                    command: [String: String]) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              let configuration = activeSiteSessionConfiguration(), configuration.syntheticGuard != nil,
              configuration.usesMockKeychain, let window = owner.window,
              let screen = window.screen ?? NSScreen.main,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
              rows.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }) else { return ["refused": true] }
        switch command["action"] {
        case "setup":
            NSApp.appearance = NSAppearance(named: command["appearance"] == "dark" ? .darkAqua : .aqua)
            let visible = screen.visibleFrame
            window.setFrame(NSRect(x: visible.maxX - 1104, y: visible.maxY - 40 - 800, width: 1100, height: 800), display: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // Use a stable 500 pt card origin for comparison captures.
            for _ in 0..<3 {
                window.contentView?.layoutSubtreeIfNeeded()
                let minX = owner.contentCard.convert(owner.contentCard.bounds, to: nil).minX
                owner.windowShell.setSidebarWidth(owner.sidebar.frame.width + 500 - minX)
            }
            if let url = command["url"].flatMap(URL.init(string:)), url.scheme == "http", url.host == "127.0.0.1" {
                owner.session.openTab(url: url)
                await waitForPage(owner, url: url)
            }
        case "toggle":
            if let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains(where: {
                $0.identifier?.rawValue == BrowserCommandID.showHideToolbar.rawValue
            }) == true })?.submenu,
               let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == BrowserCommandID.showHideToolbar.rawValue }) {
                menu.performActionForItem(at: index)
            }
        case "dismiss":
            owner.palette.dismiss()
        case "split":
            if let url = command["url"].flatMap(URL.init(string:)), url.scheme == "http", url.host == "127.0.0.1" {
                owner.session.addSplitPane(url: url)
                await waitForPage(owner, url: url)
            }
        case "unsplit":
            if let group = owner.session.activeSplit { owner.session.unsplit(group.group.id) }
            try? await Task.sleep(for: .milliseconds(300))
        default: break
        }
        // Settle every window's queue, not only the owner's: the command may run in another one.
        for controller in controllers { await controller.session.waitForPendingCommands() }
        window.contentView?.layoutSubtreeIfNeeded()
        func screenRect(_ view: NSView) -> [String: Double] {
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            return ["x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height]
        }
        let toolbar = owner.optionalToolbar
        return ["pid": Int(getpid()), "windowNumber": window.windowNumber, "window": screenRect(window.contentView!),
                "screenHeight": screen.frame.height, "toolbarVisible": owner.isToolbarVisible,
                "windowCount": controllers.count, "ownerIsKey": NSApp.keyWindow === window,
                "allToolbarsVisible": controllers.map(\.isToolbarVisible),
                "documentShowsToolbar": owner.settingsPreferences?.runtime.document.interaction.showsToolbar ?? false,
                "addressHovered": toolbar.address.pillOpacity > 0,
                "header": owner.contentCard.header === toolbar, "card": screenRect(owner.contentCard),
                "address": screenRect(toolbar.address), "site": screenRect(toolbar.site), "split": screenRect(toolbar.split),
                "back": screenRect(toolbar.back),
                "palettePresented": owner.palette.isPresented, "paletteInput": owner.palette.view.input.stringValue,
                "paneHeaders": owner.split.view.subviews.compactMap { $0 as? BrowserSplitPaneView }.filter {
                    !$0.back.isHidden && !$0.address.isHidden && !$0.close.isHidden
                }.count, "sidebarAddressHidden": owner.sidebar.addressContainer.isHidden]
    }

    /// Bounded: the probe always answers, loaded or not.
    private static func waitForPage(_ owner: OrbitWindowController, url: URL) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if let surface = owner.session.selectedSurface, surface.navigationState.committedURL == url,
               !surface.navigationState.isLoading { break }
        }
        try? await Task.sleep(for: .milliseconds(300))
    }
}
