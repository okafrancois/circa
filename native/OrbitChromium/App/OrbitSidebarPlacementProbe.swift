import AppKit
import BrowserCore

/// Confined fixture for placement and motion validation in the real engine bundle.
@MainActor
enum OrbitSidebarPlacementProbe {
    static let bundleID = "lab.orbit.orbit.sidebar-right"

    static func run(_ owner: OrbitWindowController, command: [String: String]) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              let configuration = activeSiteSessionConfiguration(), configuration.syntheticGuard != nil,
              configuration.usesMockKeychain, let window = owner.window,
              NSApp.windows.contains(where: { $0 === window }),
              window.windowController === owner else { return ["refused": true] }
        switch command["action"] {
        case "setup":
            if let screen = window.screen ?? NSScreen.main {
                window.setFrame(NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 760,
                                       width: 1000, height: 700), display: true)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            owner.windowShell.setSidebarWidth(260)
            owner.palette.dismiss()
            if let url = URL(string: "http://127.0.0.1:18765/") { owner.session.openTab(url: url) }
        case "side": owner.toggleSidebarSide()
        case "pin": owner.toggleSidebar()
        case "toolbar": owner.toggleToolbar()
        case "width": owner.windowShell.setSidebarWidth(CGFloat(Double(command["width"] ?? "260") ?? 260))
        case "fullscreen": window.toggleFullScreen(nil)
        case "appearance":
            var theme = owner.windowShell.theme
            theme.mode = command["mode"] == "dark" ? .dark : .light
            owner.windowShell.apply(theme: theme, animated: false)
        case "split": owner.session.addSplitPane(url: URL(string: "http://127.0.0.1:18765/second")!)
        case "unsplit": if let group = owner.session.activeSplit { owner.session.unsplit(group.group.id) }
        case "orderOut": window.orderOut(nil)
        case "show": window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        default: break
        }
        await owner.session.waitForPendingCommands()
        window.contentView?.layoutSubtreeIfNeeded()
        func rect(_ frame: CGRect) -> [CGFloat] { [frame.minX, frame.minY, frame.width, frame.height] }
        return ["pid": getpid(), "windowID": window.windowNumber,
                "windowFrame": rect(window.frame), "sidebar": rect(owner.sidebar.frame),
                "card": rect(owner.contentCard.frame), "onRight": owner.windowShell.sidebarOnRight,
                "docked": owner.windowShell.isDocked, "floating": owner.windowShell.isFloatingRevealed,
                "fullScreen": owner.windowShell.isFullScreen, "toolbar": owner.isToolbarVisible,
                "lights": [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
                    window.standardWindowButton($0).map { button in rect(button.convert(button.bounds, to: nil)) }
                }]
    }
}
