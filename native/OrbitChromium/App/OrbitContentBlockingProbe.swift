import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

/// Opt-in qualification of built-in content blocking on the loopback fixture sites
/// (`--orbit-content-blocking-fixture` maps them and known ad and tracker hosts to 127.0.0.1).
/// Drives the real site control row, the profile setting and a private window; captures only
/// this process's own windows.
@MainActor
enum OrbitContentBlockingProbe {
    static let bundleID = "lab.orbit.orbit.content-blocking"

    static func run(_ owner: OrbitWindowController, environment: OrbitEnvironment, application: OrbitApplication,
                    command: [String: String], root: URL) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              let confinement = activeSyntheticDataGuard(), (try? confinement.checkInside(root)) != nil,
              let port = command["port"].flatMap(Int.init), (1024...65535).contains(port),
              let profile = owner.session.activeProfileID else { return ["refused": true] }
        var result: [String: Any] = [:]
        application.confirmQuit = { .quit }
        let captures = root.appendingPathComponent("captures")
        try? FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let blocker = owner.engine.contentBlocking as? ChromiumContentBlocking
        result["available"] = environment.contentBlocking != nil && blocker != nil

        func owned(_ window: NSWindow?) -> Bool {
            guard let window else { return false }
            let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
            return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        }
        func capture(_ window: NSWindow?, _ name: String) async {
            guard let window, owned(window) else { return }
            try? await Task.sleep(for: .milliseconds(300))
            window.displayIfNeeded(); CATransaction.flush()
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), captures.appendingPathComponent(name + ".png").path]
            try? process.run(); process.waitUntilExit()
        }
        /// Loads a fixture page in a new tab of `window` and returns its own report.
        func load(_ window: OrbitWindowController, site: String) async -> String {
            let url = URL(string: "http://\(site).fixture.test:\(port)/")!
            window.openTab(url: url)
            await window.session.waitForPendingCommands()
            return await report(window)
        }
        func report(_ window: OrbitWindowController) async -> String {
            guard let surface = window.session.selectedSurface else { return "no surface" }
            for _ in 0..<300 {
                if surface.isReady, !surface.navigationState.isLoading,
                   let value = await OrbitPerformanceProbe.evaluate(surface, "(() => ({title: document.title}))()"),
                   let title = value["title"] as? String, title.hasPrefix("CB ") { return title }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return "timeout"
        }
        func reload(_ window: OrbitWindowController) async -> String {
            window.session.selectedSurface?.reload()
            try? await Task.sleep(for: .milliseconds(200))
            return await report(window)
        }
        func button(_ identifier: String) -> NSButton? {
            func find(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
                for child in view.subviews { if let found = find(child) { return found } }
                return nil
            }
            for window in NSApp.windows where window.isVisible {
                if let content = window.contentView, let found = find(content) { return found }
            }
            return nil
        }
        func ack() async -> String { await blocker?.acknowledgement(profileID: profile) ?? "none" }

        if command["step"] == "relaunch" {
            // After a relaunch: what the restored tab reports, then the engine's own manager page.
            result["restored"] = await report(owner)
            result["ack"] = await ack()
            if let surface = owner.session.selectedSurface, let manager = owner.engine.extensionManagement {
                result["managerOpened"] = (try? manager.openManagement(on: surface)) != nil
                try? await Task.sleep(for: .milliseconds(1500))
                await capture(owner.window, "10-engine-extension-manager")
            }
            return result
        }

        owner.window?.setFrame(NSRect(x: 60, y: 120, width: 1280, height: 820), display: true)
        owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 1. Default: on, both lists apply.
        result["defaultSetting"] = environment.settings.document.profile(profile).blocksAdsAndTrackers
        result["newsOn"] = await load(owner, site: "news")
        result["ackAfterStartup"] = await ack()
        await capture(owner.window, "1-news-blocking-on")

        // 2. The internal extension is absent from every shell extension inventory.
        let listed = (try? owner.engine.extensions?.installedExtensions(in: profile).map(\.id)) ?? []
        result["shellExtensionInventory"] = listed
        result["internalExtensionListed"] = listed.contains(ChromiumContentBlocking.extensionID)

        // 3. The site row turns blocking off for this host, then the page reloads.
        owner.siteControls.show()
        for _ in 0..<100 where button("site-content-blocking") == nil { try? await Task.sleep(for: .milliseconds(30)) }
        let row = button("site-content-blocking")
        result["siteRowLabel"] = row?.accessibilityLabel() ?? "missing"
        await capture(row?.window, "2-site-controls-row-on")
        await capture(owner.window, "2b-window-with-site-controls")
        row?.performClick(nil)
        for _ in 0..<100 where button("site-content-blocking")?.accessibilityLabel() == row?.accessibilityLabel() {
            try? await Task.sleep(for: .milliseconds(30))
        }
        result["siteRowLabelAfterClick"] = button("site-content-blocking")?.accessibilityLabel() ?? "missing"
        await capture(button("site-content-blocking")?.window, "3-site-controls-row-off")
        result["newsAllowListed"] = await report(owner)
        result["exceptions"] = environment.sitePreferences.contentBlockingExceptions(profileID: profile)
        owner.siteControls.render()
        NSApp.windows.filter { $0 !== owner.window && $0.isVisible && $0.level != .normal }.forEach { $0.orderOut(nil) }
        await capture(owner.window, "4-news-allow-listed")
        // Another site of the same profile keeps blocking.
        result["shopStillBlocked"] = await load(owner, site: "shop")
        await capture(owner.window, "5-shop-still-blocked")

        // 4. The profile setting (the Settings switch's model path) turns blocking off everywhere.
        application.showSettings(section: .general)
        try? await Task.sleep(for: .milliseconds(400))
        await capture(application.settingsWindow?.window, "6-settings-switch-on")
        try? await environment.settings.updateProfile(profile) { $0.blocksAdsAndTrackers = false }
        try? await Task.sleep(for: .milliseconds(600))
        await capture(application.settingsWindow?.window, "7-settings-switch-off")
        application.settingsWindow?.window?.orderOut(nil)
        result["shopOff"] = await reload(owner)
        await capture(owner.window, "8-shop-setting-off")
        owner.siteControls.show()
        try? await Task.sleep(for: .milliseconds(300))
        result["siteRowWhileOff"] = button("site-content-blocking") == nil ? "absent" : "present"
        NSApp.windows.filter { $0 !== owner.window && $0.isVisible && $0.level != .normal }.forEach { $0.orderOut(nil) }
        try? await environment.settings.updateProfile(profile) { $0.blocksAdsAndTrackers = true }
        try? await Task.sleep(for: .milliseconds(600))
        result["shopOnAgain"] = await reload(owner)
        result["ackFinal"] = await ack()

        // 5. Private windows: isolated memory-only context without the blocker or its row.
        application.createPrivateCommandWindow()
        await application.waitForPrivateWindowCommands()
        if let id = application.privateWindows.keys.first, let window = application.windows.windows[id] {
            window.palette.dismiss()
            result["privateBlockerAvailable"] = window.engine.contentBlocking != nil
            result["privateNews"] = await load(window, site: "news")
            window.siteControls.show()
            try? await Task.sleep(for: .milliseconds(300))
            result["privateSiteRow"] = button("site-content-blocking") == nil ? "absent" : "present"
            await capture(window.window, "9-private-window")
            NSApp.windows.filter { $0 !== window.window && $0.isVisible && $0.level != .normal }.forEach { $0.orderOut(nil) }
            window.window?.close()
        } else {
            result["privateNews"] = "no private window"
        }
        return result
    }
}
