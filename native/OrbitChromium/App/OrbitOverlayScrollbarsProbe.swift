import AppKit
import BrowserCore
import ChromiumEngine
import Foundation

/// Confined page scrollbar fixture: measures layout gutters on a loopback page and drives the
/// Settings row through the same model call as its switch. Synthetic bundle only.
@MainActor
enum OrbitOverlayScrollbarsProbe {
    static let bundleID = "lab.orbit.orbit.overlay-scrollbars"

    private static let measurement = """
    (() => {
      const box = id => { const e = document.getElementById(id); return e ? {
        vertical: e.offsetWidth - e.clientWidth - (parseFloat(getComputedStyle(e).borderLeftWidth) || 0) - (parseFloat(getComputedStyle(e).borderRightWidth) || 0),
        horizontal: e.offsetHeight - e.clientHeight - (parseFloat(getComputedStyle(e).borderTopWidth) || 0) - (parseFloat(getComputedStyle(e).borderBottomWidth) || 0),
        scrollLeft: e.scrollLeft, scrollTop: e.scrollTop } : null; };
      let frame = null;
      try { const d = document.getElementById('frame').contentDocument;
        frame = {innerWidth: d.defaultView.innerWidth, clientWidth: d.documentElement.clientWidth,
                 gutter: d.defaultView.innerWidth - d.documentElement.clientWidth}; } catch (e) { frame = {error: String(e)}; }
      return {innerWidth: innerWidth, clientWidth: document.documentElement.clientWidth,
        gutter: innerWidth - document.documentElement.clientWidth, devicePixelRatio: devicePixelRatio,
        scrollY: scrollY, nested: box('nested'), dark: box('dark'), custom: box('custom'),
        horizontal: box('horizontal'), rtl: box('rtl'), frame: frame,
        marker: document.documentElement.dataset.fixture || ''};
    })()
    """

    static func run(_ application: OrbitApplication, environment: OrbitEnvironment,
                    owner: OrbitWindowController, command: [String: String]) async -> [String: Any] {
        var result: [String: Any] = ["step": command["step"] ?? "",
                                     "settingAtLaunch": BrowserOverlayScrollbars.enabledAtLaunch as Any,
                                     "setting": environment.settings.document.overlayScrollbars]
        switch command["step"] {
        case "open":
            guard let url = command["url"].flatMap(URL.init(string:)), url.host == "127.0.0.1" else { return result }
            owner.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            owner.session.openTab(url: url)
            await owner.session.waitForPendingCommands()
            guard let surface = owner.session.selectedSurface else { return result }
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while !surface.isReady || surface.navigationState.isLoading {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(300))
            fallthrough
        case "measure":
            guard let surface = owner.session.selectedSurface else { return result }
            result["page"] = await OrbitPerformanceProbe.evaluate(surface, measurement) ?? [:]
            if let window = owner.window {
                let frame = window.convertToScreen(surface.hostView.convert(surface.hostView.bounds, to: nil))
                result["pageScreenFrame"] = [frame.minX, frame.minY, frame.width, frame.height]
                result["windowNumber"] = window.windowNumber
            }
        case "settings":
            if application.settingsWindow == nil {
                let model = BrowserSettingsModel(environment: environment, profileID: owner.session.activeProfileID, shortcuts: [])
                application.settingsWindow = BrowserSettingsWindowController(model: model, appearanceOverride: nil)
            }
            guard let settings = application.settingsWindow, let window = settings.window else { return result }
            window.makeKeyAndOrderFront(nil)
            _ = settings.selectSection(.advanced)
            result["settingsWindowNumber"] = window.windowNumber
        case "toggle":
            guard let model = application.settingsWindow?.model else { return result }
            let enabled = command["value"] == "on"
            try? await model.setOverlayScrollbars(enabled)
            result["setting"] = environment.settings.document.overlayScrollbars
            result["notice"] = BrowserOverlayScrollbars.state(enabled: enabled, atLaunch: BrowserOverlayScrollbars.enabledAtLaunch) ?? ""
        case "close-settings":
            application.settingsWindow?.window?.close()
            owner.window?.makeKeyAndOrderFront(nil)
        default:
            break
        }
        return result
    }
}
