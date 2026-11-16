import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

/// Opt-in qualification of the bridge hardening on a loopback fixture server (synthetic bundle
/// `lab.orbit.orbit.bridge-hardening` only): Global Privacy Control, the DevTools method allowlist,
/// Chrome-created tabs the shell declines, and the shell's previous "open link by URL" path used
/// as the comparison for context-menu link opens.
@MainActor
enum OrbitBridgeHardeningProbe {
    static let bundleID = "lab.orbit.orbit.bridge-hardening"

    static func run(_ owner: OrbitWindowController, command: [String: String], root: URL) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              let confinement = activeSyntheticDataGuard(), (try? confinement.checkInside(root)) != nil,
              let port = command["port"].flatMap(Int.init), (1024...65535).contains(port) else { return ["refused": true] }
        switch command["step"] {
        case "open":
            // Loopback fixture pages only.
            guard let url = command["url"].flatMap(URL.init(string:)), url.scheme == "http",
                  ["127.0.0.1", "localhost"].contains(url.host ?? ""), url.port == port else { return ["refused": true] }
            owner.openTab(url: url)
            await owner.session.waitForPendingCommands()
            return ["opened": url.absoluteString]
        case "select":
            // Selects the tab whose address contains `match` (the background tab a link opened).
            guard let match = command["match"],
                  let tab = owner.session.snapshot?.tabs.first(where: { $0.url.absoluteString.contains(match) }) else {
                return ["selected": false]
            }
            owner.session.selectOccurrence(tab.occurrenceID)
            await owner.session.waitForPendingCommands()
            return ["selected": true]
        case "context-link":
            // The page context menu through Chrome's own right-click, without the AppKit menu.
            guard let surface = owner.session.selectedSurface,
                  let rect = await OrbitPerformanceProbe.evaluate(surface,
                      "(() => { const r = document.getElementById('link').getBoundingClientRect(); return {x: r.x + 40, y: r.y + r.height / 2}; })()"),
                  let x = rect["x"] as? Double, let y = rect["y"] as? Double else { return ["error": "no link"] }
            var observed: BrowserContextMenuRequest?
            owner.pageInteraction.menuObserver = { request, _ in observed = request }
            defer { owner.pageInteraction.menuObserver = nil }
            for type in ["mousePressed", "mouseReleased"] {
                _ = await surface.devToolsCall("Input.dispatchMouseEvent",
                    params: #"{"type":"\#(type)","x":\#(Int(x)),"y":\#(Int(y)),"button":"right","clickCount":1}"#)
            }
            for _ in 0..<60 where observed == nil { try? await Task.sleep(for: .milliseconds(50)) }
            guard let request = observed else { return ["error": "no menu"] }
            let split = command["placement"] == "split"
            let splitBefore = owner.session.activeSplit?.tabs.count ?? 1
            owner.performPageContextCommand(split ? .pageOpenLinkInSplitView : .pageOpenLinkInNewTab)
            try? await Task.sleep(for: .seconds(2))
            await owner.session.waitForPendingCommands()
            return ["offeredOpenLink": request.availableCommands.contains(.openLink),
                    "canAddSplitPane": owner.canAddSplitPane,
                    "splitPanesBefore": splitBefore, "splitPanesAfter": owner.session.activeSplit?.tabs.count ?? 1,
                    "tabs": owner.session.snapshot?.tabs.count ?? -1]
        case "legacy-open":
            // The code path context-menu link opens used before this lot: a new tab loading the URL.
            guard let url = URL(string: "http://localhost:\(port)/target?case=menu-before") else { return [:] }
            owner.openPageURLInNewTab(url)
            await owner.session.waitForPendingCommands()
            return ["legacyOpened": url.absoluteString]
        default:
            return await checks(owner, port: port)
        }
    }

    private static func checks(_ owner: OrbitWindowController, port: Int) async -> [String: Any] {
        var result: [String: Any] = [:]
        owner.openTab(url: URL(string: "http://127.0.0.1:\(port)/gpc")!)
        await owner.session.waitForPendingCommands()
        guard let surface = owner.session.selectedSurface else { return ["error": "no surface"] }
        for _ in 0..<200 where !(surface.isReady && !surface.navigationState.isLoading
                                 && surface.navigationState.committedURL?.path == "/gpc") {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // H-S4: the document sees the signal (the server logs the request header).
        let gpc = await OrbitPerformanceProbe.evaluate(surface, "({gpc: String(navigator.globalPrivacyControl)})")
        result["navigatorGlobalPrivacyControl"] = gpc?["gpc"] ?? "unavailable"

        // H-S7: methods outside the allowlist are refused before reaching Chromium.
        let started = ProcessInfo.processInfo.systemUptime
        var refused: [String: Bool] = [:]
        for method in ["Browser.close", "Target.createTarget", "Network.setCookies", "Browser.grantPermissions"] {
            let (ok, _) = await surface.devToolsCall(method, params: "{}", timeout: .seconds(2))
            refused[method] = !ok
        }
        result["refusedMethods"] = refused
        result["refusalSeconds"] = (ProcessInfo.processInfo.systemUptime - started).rounded(toPlaces: 3)
        result["allowedMethodWorks"] = await OrbitPerformanceProbe.evaluate(surface, "({one: 1})")?["one"] as? Int == 1

        // S-L13: a Chrome-created tab the shell declines is closed, never kept as a hidden browser.
        func pageTargets() async -> Int? {
            let (ok, data) = await surface.devToolsCall("Target.getTargets", params: "{}")
            guard ok, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let infos = object["targetInfos"] as? [[String: Any]] else { return nil }
            return infos.filter { $0["type"] as? String == "page" }.count
        }
        let windows = owner.engineWindowIDs
        let before = await pageTargets()
        let tabsBefore = owner.session.snapshot?.tabs.count
        for id in windows { owner.engine.setEngineTabAdoption(for: id) { _, _ in nil } }
        let duplicated = surface.duplicateWithHistory()
        var samples: [Int] = []
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            if let count = await pageTargets() { samples.append(count) }
        }
        for id in windows {
            owner.engine.setEngineTabAdoption(for: id) { [weak owner] request, make in
                owner?.adoptEngineCreatedTab(request, make: make)
            }
        }
        result["declinedTab"] = ["duplicateIssued": duplicated, "pageTargetsBefore": before ?? -1,
                                 "pageTargetSamples": samples, "pageTargetsAfter": samples.last ?? -1,
                                 "shellTabsBefore": tabsBefore ?? -1,
                                 "shellTabsAfter": owner.session.snapshot?.tabs.count ?? -1] as [String: Any]
        return result
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
