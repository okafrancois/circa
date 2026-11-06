import AppKit
import BrowserCore
import ChromiumEngine
import Foundation

/// Confined page scrollbar fixture: measures layout gutters on a loopback page and drives the
/// window geometry for bounded native input. Synthetic bundle only.
@MainActor
enum OrbitOverlayScrollbarsProbe {
    static let bundleID = "lab.orbit.orbit.overlay-scrollbars"

    /// The loopback fixture defines `__overlayFixtureMeasure()`; it reports its own boxes, shadow
    /// roots and the gutters its frames post back. Only the page gutter is measured here.
    private static let measurement = """
    (() => {
      const own = typeof window.__overlayFixtureMeasure === 'function' ? window.__overlayFixtureMeasure() : {};
      return Object.assign({innerWidth: innerWidth, clientWidth: document.documentElement.clientWidth,
        gutter: innerWidth - document.documentElement.clientWidth, devicePixelRatio: devicePixelRatio,
        scrollY: scrollY}, {fixture: own});
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
        default:
            break
        }
        return result
    }
}
