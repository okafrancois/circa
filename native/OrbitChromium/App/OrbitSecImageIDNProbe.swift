import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

/// Synthetic-only check of untrusted favicons and IDN hosts in the palette: opens loopback
/// fixtures as tabs, records which ones received engine pixels, then presents the palette with a
/// query and reports each row's host text and whether it shows an icon. No synthetic input.
@MainActor
enum OrbitSecImageIDNProbe {
    static let bundleID = "lab.orbit.orbit.sec-image-idn"

    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              Bundle.main.infoDictionary?["OrbitUseMockKeychain"] as? Bool == true,
              let window = owner.window,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    }

    private static func loopback(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host.hasSuffix(".localhost")
    }

    private static func wait(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    static func run(_ owner: OrbitWindowController, command: [String: String]) async -> [String: Any] {
        _ = await wait(seconds: 5) { owns(owner) }
        let urls = (command["urls"] ?? "").split(separator: " ").compactMap { URL(string: String($0)) }
        guard owns(owner), let window = owner.window, !urls.isEmpty, urls.allSatisfy(loopback) else { return ["refused": true] }
        if let screen = window.screen ?? NSScreen.main {
            window.setFrame(NSRect(x: screen.frame.minX + 60, y: screen.frame.maxY - 60 - 700, width: 1000, height: 700), display: true)
        }
        window.orderFrontRegardless()
        var tabs: [[String: Any]] = []
        for url in urls {
            owner.session.openTab(url: url)
            await owner.session.waitForQueuedCommands()
            guard let surface = owner.session.selectedSurface else { tabs.append(["url": url.absoluteString, "opened": false]); continue }
            let loaded = await wait(seconds: 10) {
                surface.isReady && !surface.navigationState.isLoading && surface.navigationState.committedURL != nil
            }
            _ = await wait(seconds: 3) { surface.navigationState.faviconMetadataIsSettled && surface.navigationState.faviconImage != nil }
            let state = surface.navigationState
            tabs.append(["url": url.absoluteString, "loaded": loaded, "title": state.title ?? "",
                         "faviconScheme": state.faviconURL?.scheme ?? "", "enginePixels": state.faviconImage != nil])
        }
        guard owns(owner) else { return ["refused": true] }
        owner.palette.present(.newTab)
        await owner.palette.waitForResults()
        owner.palette.query(command["query"] ?? "page")
        await owner.palette.waitForResults()
        // Palette favicons decode off the main actor and re-render on completion.
        try? await Task.sleep(for: .milliseconds(1200))
        owner.window?.displayIfNeeded()
        let rows: [[String: Any]] = owner.palette.results.compactMap { result in
            guard result.url != nil else { return nil }
            return ["title": result.title, "detail": result.detail, "section": "\(result.section)",
                    "icon": owner.palette.view.favicons[result.id] != nil]
        }
        return ["tabs": tabs, "rows": rows, "window": window.windowNumber]
    }
}
