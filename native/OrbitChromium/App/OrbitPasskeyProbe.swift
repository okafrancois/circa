import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Foundation

/// Confined WebAuthn qualification in a synthetic mock-Keychain bundle. Ceremonies run against
/// the engine's DevTools virtual authenticator, or open the engine's own authenticator dialog
/// for capture and cancellation. No real authenticator, account or system passkey is used.
@MainActor
enum OrbitPasskeyProbe {
    static let bundleID = "lab.orbit.orbit.passkeys-system"

    private static var authenticatorID: String?
    private static var windowsBeforeDialog: Set<Int> = []

    static func run(_ owner: OrbitWindowController, command: [String: String], root: URL) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true,
              activeSiteSessionConfiguration()?.usesMockKeychain == true else { return ["refused": true] }
        switch command["step"] {
        case "open":
            guard let text = command["url"], let url = URL(string: text), admitted(url) else { return ["refused": true] }
            owner.session.openTab(url: url)
            await owner.session.waitForPendingCommands()
            guard let surface = await loadedSurface(owner) else { return ["loaded": false] }
            return ["loaded": true, "url": surface.navigationState.committedURL?.absoluteString ?? ""]
        case "authenticator":
            guard let surface = owner.session.selectedSurface else { return ["missingSurface": true] }
            _ = await call(surface, "WebAuthn.enable", ["enableUI": false])
            let transport = command["transport"] ?? "internal"
            guard ["internal", "usb", "hybrid"].contains(transport) else { return ["refused": true] }
            let options: [String: Any] = ["protocol": "ctap2", "ctap2Version": "ctap2_1", "transport": transport,
                "hasResidentKey": true, "hasUserVerification": true, "isUserVerified": true,
                "automaticPresenceSimulation": true]
            let reply = await call(surface, "WebAuthn.addVirtualAuthenticator", ["options": options])
            authenticatorID = reply?["authenticatorId"] as? String
            return ["added": authenticatorID != nil, "transport": transport]
        case "evaluate":
            guard let surface = owner.session.selectedSurface, let expression = command["expression"] else { return ["missingSurface": true] }
            let reply = await call(surface, "Runtime.evaluate", ["expression": expression, "returnByValue": true,
                "awaitPromise": true, "userGesture": true], timeout: .seconds(25))
            let value = (reply?["result"] as? [String: Any])?["value"]
            return ["value": value ?? NSNull(), "exception": reply?["exceptionDetails"] != nil]
        case "credentials":
            guard let surface = owner.session.selectedSurface, let authenticatorID else { return ["missingAuthenticator": true] }
            let reply = await call(surface, "WebAuthn.getCredentials", ["authenticatorId": authenticatorID])
            let credentials = reply?["credentials"] as? [[String: Any]] ?? []
            // Counts and relying parties only; key material never leaves the engine.
            return ["count": credentials.count, "rpIds": credentials.compactMap { $0["rpId"] as? String },
                    "resident": credentials.filter { $0["isResidentCredential"] as? Bool == true }.count,
                    "signCounts": credentials.compactMap { $0["signCount"] as? Int }]
        case "disable":
            guard let surface = owner.session.selectedSurface else { return ["missingSurface": true] }
            if let authenticatorID {
                _ = await call(surface, "WebAuthn.removeVirtualAuthenticator", ["authenticatorId": authenticatorID])
            }
            authenticatorID = nil
            return ["disabled": await call(surface, "WebAuthn.disable", [:]) != nil]
        case "dialog-start":
            guard let surface = owner.session.selectedSurface, let expression = command["expression"] else { return ["missingSurface": true] }
            windowsBeforeDialog = Set(NSApp.windows.map(\.windowNumber))
            // Not awaited: the engine's own dialog stays open until it is cancelled.
            let reply = await call(surface, "Runtime.evaluate", ["expression": expression, "userGesture": true])
            return ["started": reply != nil]
        case "dialog-capture":
            try? await Task.sleep(for: .milliseconds(3000))
            let added = NSApp.windows.filter { !windowsBeforeDialog.contains($0.windowNumber) && $0.isVisible }
            var rows: [[String: Any]] = []
            for (index, window) in added.enumerated() where ownedByThisProcess(window) {
                let file = root.appendingPathComponent("dialog-\(command["name"] ?? "window")-\(index).png")
                rows.append(["class": String(describing: type(of: window)), "width": window.frame.width,
                             "height": window.frame.height, "parent": window.parent === owner.window,
                             "captured": capture(window, to: file)])
            }
            if let window = owner.window, ownedByThisProcess(window) {
                _ = capture(window, to: root.appendingPathComponent("dialog-\(command["name"] ?? "window")-browser.png"))
            }
            // Every on-screen window of this process, in case a dialog is not an AppKit-visible NSWindow.
            let system = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
                .map { row -> [String: Any] in
                    let bounds = row[kCGWindowBounds as String] as? [String: Any] ?? [:]
                    return ["layer": row[kCGWindowLayer as String] as? Int ?? 0, "number": row[kCGWindowNumber as String] as? Int ?? 0,
                            "width": bounds["Width"] as? Double ?? 0, "height": bounds["Height"] as? Double ?? 0]
                }
            return ["windows": rows, "systemWindows": system, "appWindows": NSApp.windows.filter(\.isVisible).count]
        case "dialog-press":
            // In-process accessibility only: no synthetic OS input reaches other applications.
            guard let label = command["label"], !label.isEmpty else { return ["refused": true] }
            let dialogs = NSApp.windows.filter { !windowsBeforeDialog.contains($0.windowNumber) && $0.isVisible && ownedByThisProcess($0) }
            for window in dialogs {
                if let element = find(label, in: window.accessibilityChildren() ?? [], depth: 0) {
                    return ["pressed": element.accessibilityPerformPress()]
                }
            }
            return ["pressed": false, "dialogs": dialogs.count]
        default:
            return ["refused": true]
        }
    }

    private static func find(_ label: String, in children: [Any], depth: Int) -> NSAccessibilityProtocol? {
        guard depth < 30 else { return nil }
        for case let element as NSAccessibilityProtocol in children {
            let text = [element.accessibilityLabel(), element.accessibilityTitle()].compactMap { $0 }.joined(separator: " ")
            if text.localizedCaseInsensitiveContains(label), element.accessibilityRole() == .button { return element }
            if let found = find(label, in: element.accessibilityChildren() ?? [], depth: depth + 1) { return found }
        }
        return nil
    }

    private static func admitted(_ url: URL) -> Bool {
        if url.scheme == "http", url.host == "localhost" { return true }
        return url.scheme == "https" && url.host == "webauthn.io"
    }

    private static func ownedByThisProcess(_ window: NSWindow) -> Bool {
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    }

    private static func capture(_ window: NSWindow, to file: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func loadedSurface(_ owner: OrbitWindowController) async -> ChromiumSurface? {
        for _ in 0..<400 {
            if let surface = owner.session.selectedSurface, surface.isReady, !surface.navigationState.isLoading,
               surface.navigationState.committedURL != nil { return surface }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private static func call(_ surface: ChromiumSurface, _ method: String, _ parameters: [String: Any],
                             timeout: Duration = .seconds(8)) async -> [String: Any]? {
        guard let json = try? JSONSerialization.data(withJSONObject: parameters),
              let params = String(data: json, encoding: .utf8) else { return nil }
        let (ok, data) = await surface.devToolsCall(method, params: params, timeout: timeout)
        guard ok else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
