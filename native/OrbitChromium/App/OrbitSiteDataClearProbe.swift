import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Foundation

/// Synthetic-only walk through Settings > Privacy > "Clear Site Data for This Profile…" on a
/// loopback page that keeps a cookie and local storage. It drives the real Settings model and
/// sheet; the external script records the Settings window (window IDs are published only after
/// their owner PID is verified) and captures the page window before and after.
@MainActor
enum OrbitSiteDataClearProbe {
    static let bundleID = "lab.orbit.orbit.site-data-clear"

    static func run(_ application: OrbitApplication, owner: OrbitWindowController, command: [String: String],
                    root: URL) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true,
              let text = command["url"], let url = URL(string: text), url.host == "127.0.0.1", url.scheme == "http"
        else { return ["refused": true] }
        var result: [String: Any] = [:]
        owner.submitAddress(url.appendingPathComponent("status").absoluteString + "?seed=1")
        await owner.session.waitForPendingCommands()
        guard let tab = await loadedTab(owner) else { return ["navigation": false] }
        try? await Task.sleep(for: .milliseconds(600))
        result["before"] = await pageState(tab)
        await capture("before", window: owner.window, root: root)

        application.showSettings(section: .privacy)
        try? await Task.sleep(for: .milliseconds(900))
        guard let settings = application.settingsWindow, let window = settings.window, owns(window) else {
            return result.merging(["settings": false]) { $1 }
        }
        result["supportsSiteData"] = settings.model.supportsSiteData
        try? String(window.windowNumber).write(to: root.appendingPathComponent("site-data-window.txt"), atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(2200))  // The script starts recording.
        let profile = tab.profileID
        settings.model.perform { try await settings.model.reviewSiteData(origin: nil, profile: profile) }
        try? await Task.sleep(for: .milliseconds(2600))
        guard let request = settings.model.siteDataRequest else { return result.merging(["sheet": false]) { $1 } }
        result["sheet"] = request.origin == nil && request.profileID == profile
        // The sheet's Clear button.
        settings.model.siteDataRequest = nil
        let started = ContinuousClock.now
        settings.model.perform { try await settings.model.clearSiteData(request) }
        while settings.model.isBusy, ContinuousClock.now - started < .seconds(20) { try? await Task.sleep(for: .milliseconds(20)) }
        result["clearMilliseconds"] = Int((ContinuousClock.now - started) / .milliseconds(1))
        result["error"] = settings.model.errorMessage ?? ""
        try? await Task.sleep(for: .milliseconds(2500))
        settings.window?.close()
        owner.window?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(900))
        result["after"] = await pageState(tab)
        await capture("after", window: owner.window, root: root)
        result["passed"] = (result["before"] as? String) == "signed-in,saved" && (result["after"] as? String) == "signed-out,none"
            && result["sheet"] as? Bool == true && (result["error"] as? String)?.isEmpty == true
            && result["supportsSiteData"] as? Bool == true
        return result
    }

    private static func loadedTab(_ owner: OrbitWindowController) async -> ChromiumSurface? {
        for _ in 0..<250 {
            if let surface = owner.session.selectedSurface, surface.isReady, !surface.navigationState.isLoading,
               surface.navigationState.committedURL?.path == "/status" { return surface }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// The page's own summary, refreshed by the fixture every 250 ms.
    private static func pageState(_ surface: ChromiumSurface) async -> String {
        let value = await OrbitPerformanceProbe.evaluate(surface, "({state: document.body.dataset.state || ''})")
        return value?["state"] as? String ?? ""
    }

    private static func owns(_ window: NSWindow) -> Bool {
        guard window.isVisible,
              let entries = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
        else { return false }
        return entries.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
            && ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
    }

    /// Asks the script for a capture of exactly this window and waits (bounded) for it.
    private static func capture(_ name: String, window: NSWindow?, root: URL) async {
        guard let window, owns(window) else { return }
        let file = root.appendingPathComponent("site-data-shot.txt")
        try? "\(name):\(window.windowNumber)".write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<150 where FileManager.default.fileExists(atPath: file.path) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
