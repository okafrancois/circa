import AppKit
import BrowserCore
import BrowserShell
import QuartzCore

/// Opt-in captures of shipped native surfaces, confined to the synthetic measurement endpoint.
@MainActor
enum OrbitBrandingProbe {
    static func run(_ application: OrbitApplication, environment: OrbitEnvironment,
                    owner: OrbitWindowController, root: URL, appearance: String) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.circa-rename",
              let confinement = activeSyntheticDataGuard(), (try? confinement.checkInside(root)) != nil else { return ["refused": true] }
        let directory = root.appendingPathComponent("captures")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name: NSAppearance.Name = appearance == "dark" ? .darkAqua : .aqua
            NSApp.appearance = NSAppearance(named: name)
            var evidence: [String: Any] = ["pid": getpid(), "runningName": NSRunningApplication.current.localizedName ?? "",
                                         "bundleName": Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? ""]
            func capture(_ window: NSWindow?, _ label: String) throws {
                guard let window, let view = window.contentView else { throw CocoaError(.fileReadUnknown) }
                window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                view.display()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileReadUnknown) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileReadUnknown) }
                try png.write(to: directory.appendingPathComponent(label + "-" + appearance + ".png"))
                evidence[label + "Title"] = window.title
            }
            let settingsModel = BrowserSettingsModel(environment: environment, profileID: nil, shortcuts: [],
                defaultBrowser: .init(status: { .init(http: "synthetic", https: "synthetic", html: "synthetic") }, canRequest: { false }, request: {}))
            let settings = BrowserSettingsWindowController(model: settingsModel, appearanceOverride: name)
            defer { settings.close() }
            try? await Task.sleep(for: .milliseconds(250))
            try capture(settings.window, "settings")
            settingsModel.settingsSection = .about
            try? await Task.sleep(for: .milliseconds(400))
            try capture(settings.window, "about")
            let welcome = OrbitOnboardingWindowController(flow: .init(sources: [], syncAvailability: .unavailable), services: .init(), themeTarget: nil)
            defer { welcome.close() }
            try capture(welcome.window, "onboarding-welcome")
            let importing = BrowserImportBrandingCapture.onboarding()
            defer { importing.close() }
            try capture(importing.window, "onboarding-import")
            application.quickWindowPresenter = { controller in controller.window?.setFrameOrigin(NSPoint(x: -5000, y: -5000)) }
            application.openQuickWindow(source: owner)
            await application.waitForQuickWindowCommands()
            let quick = environment.quickWindows.values.first
            try capture(quick?.window, "little")
            quick?.close()
            let alert = BrowserImportBrandingCapture.alert()
            let alertWindow = alert.preparedWindow()
            defer { alertWindow.close() }
            try capture(alertWindow, "import-alert")
            evidence["menuTitles"] = NSApp.mainMenu?.items.map(\.title) ?? []
            evidence["applicationMenu"] = NSApp.mainMenu?.items.first?.submenu?.items.map(\.title) ?? []
            if let menu = NSApp.mainMenu?.items.first?.submenu {
                let file = directory.appendingPathComponent("application-menu-" + appearance + ".png")
                let target = OrbitBrandingMenuCapture(menu: menu, file: file)
                let timer = Timer(timeInterval: 0.3, target: target, selector: #selector(OrbitBrandingMenuCapture.capture), userInfo: nil, repeats: false)
                RunLoop.main.add(timer, forMode: .common)
                menu.popUp(positioning: nil, at: NSPoint(x: 120, y: NSScreen.main?.frame.height ?? 800), in: nil)
                evidence["menuCaptured"] = FileManager.default.fileExists(atPath: file.path)
            }
            evidence["completed"] = true
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("identity-" + appearance + ".json"))
            return evidence
        } catch { return ["failed": String(describing: type(of: error))] }
    }
}


@MainActor
private final class OrbitBrandingMenuCapture: NSObject {
    let menu: NSMenu
    let file: URL
    init(menu: NSMenu, file: URL) { self.menu = menu; self.file = file }
    @objc func capture() {
        // Capture only a window owned by this synthetic PID, never the entire desktop.
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        if let row = rows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
            && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }),
           let number = row[kCGWindowNumber as String] as? Int {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(number), file.path]
            try? process.run(); process.waitUntilExit()
        }
        menu.cancelTracking()
    }
}
