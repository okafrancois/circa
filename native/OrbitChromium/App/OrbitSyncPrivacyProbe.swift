import AppKit
import BrowserCore
import Foundation

/// Synthetic-only walk through Settings > General > iCloud sync: turn sync on (password sync
/// stays off for a new setup), then turn password sync on and off. It drives the same runtime
/// calls as the Settings switches, through the local-only sync seam (no CloudKit container);
/// the external script records the Settings window after its owner PID is verified.
@MainActor
enum OrbitSyncPrivacyProbe {
    static let bundleID = "lab.orbit.orbit.sync-privacy"

    static func run(_ application: OrbitApplication, sync: BrowserSyncRuntime, root: URL) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true else { return ["refused": true] }
        var result: [String: Any] = ["localOnly": sync.localSettingsOnly, "available": sync.available]
        guard sync.localSettingsOnly, !sync.available else { return result.merging(["passed": false]) { $1 } }
        application.showSettings(section: .general)
        try? await Task.sleep(for: .milliseconds(900))
        guard let settings = application.settingsWindow, let window = settings.window, owns(window) else {
            return result.merging(["settings": false]) { $1 }
        }
        try? String(window.windowNumber).write(to: root.appendingPathComponent("sync-privacy-window.txt"), atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(2200))  // The script starts recording.
        result["initial"] = ["sync": sync.enabled, "passwords": sync.passwordsEnabled]
        settings.model.perform { try await sync.setEnabled(true) }
        try? await Task.sleep(for: .milliseconds(2200))
        result["afterSyncOn"] = ["sync": sync.enabled, "passwords": sync.passwordsEnabled]
        settings.model.perform { try await sync.setPasswordsEnabled(true) }
        try? await Task.sleep(for: .milliseconds(2200))
        result["afterPasswordsOn"] = ["sync": sync.enabled, "passwords": sync.passwordsEnabled]
        settings.model.perform { try await sync.setPasswordsEnabled(false) }
        try? await Task.sleep(for: .milliseconds(2400))
        result["afterPasswordsOff"] = ["sync": sync.enabled, "passwords": sync.passwordsEnabled]
        result["error"] = settings.model.errorMessage ?? ""
        let expected: [[String: Bool]] = [["sync": false, "passwords": false], ["sync": true, "passwords": false],
                                          ["sync": true, "passwords": true], ["sync": true, "passwords": false]]
        let observed = ["initial", "afterSyncOn", "afterPasswordsOn", "afterPasswordsOff"].map { result[$0] as? [String: Bool] ?? [:] }
        result["passed"] = observed == expected && (result["error"] as? String)?.isEmpty == true
        settings.window?.close()
        return result
    }

    private static func owns(_ window: NSWindow) -> Bool {
        guard window.isVisible,
              let entries = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
        else { return false }
        return entries.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
            && ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
    }
}
