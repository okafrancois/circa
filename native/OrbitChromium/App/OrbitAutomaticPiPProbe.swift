import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

/// A confined native-window receipt for automatic video presentation qualification.
@MainActor
enum OrbitAutomaticPiPProbe {
    static func run(_ owner: OrbitWindowController, command: [String: String]) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.autopip-app",
              activeSiteSessionConfiguration()?.syntheticGuard != nil,
              let window = owner.window,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
              rows.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }) else { return ["refused": true] }
        switch command["action"] {
        case "prepare":
            guard let text = command["url"], let url = URL(string: text),
                  url.scheme == "http", url.host == "127.0.0.1" else { return ["refused": true] }
            window.setFrame(NSRect(x: 180, y: 100, width: 1100, height: 800), display: true)
            window.appearance = NSAppearance(named: .aqua)
            owner.session.openTab(url: url)
            await owner.session.waitForPendingCommands()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        case "other":
            owner.session.openTab(url: URL(string: "about:blank")!)
            await owner.session.waitForPendingCommands()
        case "media":
            if let tab = owner.session.snapshot?.tabs.first(where: { $0.url.host == "127.0.0.1" }) {
                owner.session.selectOccurrence(tab.occurrenceID)
                await owner.session.waitForPendingCommands()
            }
        case "global-off", "global-on":
            try? await owner.settingsPreferences?.runtime.store.setAutomaticPictureInPicture(command["action"] == "global-on")
            await owner.settingsPreferences?.runtime.refresh()
            owner.siteControls.render()
        case "site-off", "site-on":
            if let surface = owner.session.selectedSurface {
                var settings = owner.siteControls.preferences.preferences(url: surface.navigationState.committedURL, profileID: surface.profileID)
                settings.automaticPictureInPicture = command["action"] == "site-on"
                try? owner.siteControls.preferences.set(settings, url: surface.navigationState.committedURL, profileID: surface.profileID)
                owner.siteControls.render()
            }
        default: break
        }
        let players = NSApp.windows.filter {
            $0.styleMask.contains(.fullSizeContentView) && !$0.styleMask.contains(.titled) && $0.level == .floating
        }
        let page = if let surface = owner.session.selectedSurface {
            await OrbitPerformanceProbe.evaluate(surface, "({pip:!!document.pictureInPictureElement,playing:!!document.querySelector('video')&&!document.querySelector('video').paused,activated:navigator.userActivation.hasBeenActive,button:(()=>{let r=document.querySelector('button')?.getBoundingClientRect();return r?{x:r.x+r.width/2,y:r.y+r.height/2}:null})()})")
        } else { nil as [String: Any]? }
        var clickPoint: [String: Double] = [:]
        if let button = page?["button"] as? [String: Double], let surface = owner.session.selectedSurface,
           let x = button["x"], let y = button["y"] {
            let view = surface.documentView
            let point = view.convert(NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y), to: nil)
            let global = window.convertPoint(toScreen: point)
            clickPoint = ["x": global.x, "y": (window.screen?.frame.maxY ?? 0) - global.y]
        }
        return ["clickPoint": clickPoint, "uptime": ProcessInfo.processInfo.systemUptime, "active": NSApp.isActive,
                "hidden": NSApp.isHidden, "minimized": window.isMiniaturized,
                "window": window.windowNumber, "frame": NSStringFromRect(window.frame),
                "players": players.map { ["id": $0.windowNumber, "frame": NSStringFromRect($0.frame),
                                            "visible": $0.isVisible, "alpha": $0.alphaValue] as [String: Any] },
                "page": page ?? [:]]
    }
}
