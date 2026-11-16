import AppKit
import BrowserCore
import BrowserEngine
import Foundation

/// Confined check of browser window privacy: a normal and a private window side by side on
/// loopback fixture pages, with their capture and restoration settings. Synthetic bundle only.
@MainActor
enum OrbitContentPrivacyProbe {
    static let bundleID = "lab.orbit.orbit.local-secrets-windows"

    static func run(_ application: OrbitApplication, owner: OrbitWindowController, command: [String: String]) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true else { return ["refused": true] }
        func fixture(_ key: String) -> URL? {
            guard let text = command[key], let url = URL(string: text), url.scheme == "http", url.host == "127.0.0.1" else { return nil }
            return url
        }
        switch command["step"] {
        case "open":
            guard let normalURL = fixture("normal"), let privateURL = fixture("private") else { return ["refused": true] }
            owner.session.openTab(url: normalURL)
            await owner.session.waitForPendingCommands()
            application.createPrivateCommandWindow()
            await application.waitForPrivateWindowCommands()
            guard let privateOwner = application.windows.windows.values.first(where: { $0.isPrivateWindow }) else { return ["privateWindow": false] }
            privateOwner.palette.dismiss()
            privateOwner.session.openTab(url: privateURL)
            await privateOwner.session.waitForPendingCommands()
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let size = NSSize(width: min(640, screen.width / 2 - 24), height: min(460, screen.height - 80))
            owner.window?.setFrame(NSRect(x: screen.minX + 16, y: screen.maxY - size.height - 40, width: size.width, height: size.height), display: true)
            privateOwner.window?.setFrame(NSRect(x: screen.minX + 32 + size.width, y: screen.maxY - size.height - 40,
                                                 width: size.width, height: size.height), display: true)
            owner.window?.orderFrontRegardless()
            privateOwner.window?.orderFrontRegardless()
            for _ in 0..<100 {
                let surfaces = [owner.session.selectedSurface, privateOwner.session.selectedSurface]
                if surfaces.allSatisfy({ $0?.isReady == true && $0?.navigationState.isLoading == false }) { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        case "close-private":
            for window in application.windows.windows.values where window.isPrivateWindow { window.window?.performClose(nil) }
            try? await Task.sleep(for: .milliseconds(300))
        default: break
        }
        return ["windows": application.windows.windows.values.sorted { !$0.isPrivateWindow && $1.isPrivateWindow }.map { controller in
            ["private": controller.isPrivateWindow, "number": controller.window?.windowNumber ?? 0,
             "sharingType": Int(controller.window?.sharingType.rawValue ?? 99),
             "restorable": controller.window?.isRestorable ?? true,
             "tabs": controller.session.snapshot?.tabs.map { $0.url.absoluteString } ?? []] as [String: Any]
        }]
    }
}
