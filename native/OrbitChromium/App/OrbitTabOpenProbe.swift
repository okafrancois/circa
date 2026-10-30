import AppKit
import BrowserCore
import BrowserShell
import ChromiumEngine

/// Confined action-to-sidebar/commit/submission measurements, without OS input.
@MainActor
enum OrbitTabOpenProbe {
    static let bundleID = "lab.orbit.orbit.perf-tabopen"
    private static var spaces: [SpaceID] = []
    private static var serial = 0
    private static var expected: [TabOccurrenceID: URL] = [:]
    private static var uptime: Double { ProcessInfo.processInfo.systemUptime }

    static func run(_ owner: OrbitWindowController, store: BrowserStore, command: [String: String]) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              let window = owner.window, NSApp.windows.contains(where: { $0 === window }),
              let base = command["url"].flatMap(URL.init(string:)), base.scheme == "http", base.host == "127.0.0.1"
        else { return ["refused": true] }
        let n = Int(command["count"] ?? "1") ?? 1
        guard (1...200).contains(n), let windowID = owner.session.snapshot?.id else { return ["refused": true] }
        let begin = uptime
        var result: [String: Any] = [:]
        if command["step"] == "fixture" {
            window.orderOut(nil)
            for tab in owner.session.snapshot?.tabs ?? [] { owner.session.closeOccurrence(tab.occurrenceID) }
            await owner.session.waitForPendingCommands()
            let profiles = await [store.createProfile(name: "Synthetic first"), store.createProfile(name: "Synthetic second")]
            for i in 0..<3 {
                guard let space = try? await store.createSpace(name: "Synthetic \(i)", profileID: profiles[i % 2]) else { return ["failed": true] }
                spaces.append(space)
                owner.session.activateSpace(space)
                await owner.session.waitForPendingCommands()
                let count = n / 3 + (i < n % 3 ? 1 : 0)
                for j in 0..<count {
                    guard let context = try? await store.captureContext(in: windowID) else { return ["contextFailed": true] }
                    let url = fixtureURL(base, path: "seed-\(i)-\(j)")
                    guard let id = try? await store.openTab(url: url, from: context, activate: false) else { return ["openFailed": true] }
                    expected[id] = url
                }
                // Session restoration uses this same model-to-surface installation, but normally
                // creates visible surfaces only. Eager admission supplies already-loaded controls.
                owner.session.surfaceLoadingPolicy = .eager
                owner.session.activateSpace(space)
                await owner.session.waitForPendingCommands()
                if let id = owner.session.snapshot?.tabs.last?.occurrenceID {
                    owner.session.selectOccurrence(id)
                    await owner.session.waitForPendingCommands()
                }
            }
            owner.session.surfaceLoadingPolicy = .visibleOnly
            owner.session.activateSpace(spaces[0])
            await owner.session.waitForPendingCommands()
            await settle(owner, seconds: 12)
            result["loaded"] = expected.filter { id, url in
                guard let s = owner.session.surface(for: id) else { return false }
                return s.isReady && !s.navigationState.isLoading && s.navigationState.committedURL == url
            }.count
        } else if command["step"] == "restore" {
            window.orderOut(nil)
            let document = await store.sessionDocument()
            result["modelTabs"] = document.tabs.count
            result["createdInitially"] = owner.session.ownedSurfaces.count
            var rows: [[String: Any]] = []
            for group in document.windows.first(where: { $0.id == windowID })?.spaces ?? [] {
                guard let id = group.selectedOccurrenceID,
                      let tab = document.tabs.first(where: { $0.occurrenceID == id }) else { continue }
                let start = uptime
                owner.session.activateSpace(group.spaceID)
                await owner.session.waitForPendingCommands()
                if let surface = owner.session.surface(for: id) {
                    let deadline = uptime + 5
                    while uptime < deadline, surface.navigationState.committedURL != tab.url {
                        try? await Task.sleep(for: .milliseconds(2))
                    }
                    rows.append(["committed": surface.navigationState.committedURL == tab.url, "ms": (uptime - start) * 1000])
                }
            }
            result["selections"] = rows
            result["createdFinally"] = owner.session.ownedSurfaces.count
        } else if command["step"] == "actions" {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(300))
            var rows: [[String: Any]] = []
            for action in ["new", "new-submit", "background", "palette", "reopen"] {
                if action == "new" {
                    BrowserPerformance.resetWork(); BrowserPerformance.resetCounters()
                    let start = uptime
                    // This is the registered Cmd+T handler: it opens the palette, not a blank tab.
                    owner.palette.present(.newTab)
                    let shown = (uptime - start) * 1000
                    await owner.palette.waitForResults()
                    rows.append(["action": action, "controls": n, "presentMS": shown, "readyMS": (uptime - start) * 1000,
                        "insertMS": NSNull(), "commitMS": NSNull(), "work": BrowserPerformance.work,
                        "occlusion": OrbitResourcePerformanceProbe.occlusion(owner)])
                    owner.palette.dismiss()
                    continue
                }
                // Reopen preparation supplies one archived entry while retaining N loaded controls.
                if action == "reopen" {
                    owner.openTab(url: fixtureURL(base, path: "archived"))
                    await owner.session.waitForPendingCommands()
                    if let surface = owner.session.selectedSurface { await loaded(surface, seconds: 3) }
                    owner.session.closeSelectedTab()
                    await owner.session.waitForPendingCommands()
                }
                if action == "palette" || action == "new-submit" {
                    owner.palette.present(action == "new-submit" ? .newTab : .currentTab)
                    await owner.palette.waitForResults()
                    owner.palette.query(fixtureURL(base, path: action).absoluteString)
                    await owner.palette.waitForResults()
                }
                let old = Set(owner.session.snapshot?.tabs.map(\.occurrenceID) ?? [])
                BrowserPerformance.resetWork(); BrowserPerformance.resetCounters()
                let start = uptime
                switch action {
                case "background": owner.openPageURLInNewTab(fixtureURL(base, path: action))
                case "palette", "new-submit": owner.palette.accept()
                default: owner.session.restoreMostRecentArchivedTab()
                }
                var inserted: Double?, target: ChromiumSurface?, id: TabOccurrenceID?
                if action == "palette" {
                    target = owner.session.selectedSurface
                    id = owner.session.snapshot?.selectedOccurrenceID
                }
                let deadline = uptime + 4
                while action != "palette", uptime < deadline {
                    if let tab = owner.session.snapshot?.tabs.first(where: { !old.contains($0.occurrenceID) }) {
                        id = tab.occurrenceID; target = owner.session.surface(for: tab.occurrenceID); inserted = (uptime - start) * 1000; break
                    }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                if let target {
                    let deadline = uptime + 3
                    while uptime < deadline, target.navigationState.committedURL == nil
                        || (["palette", "new-submit"].contains(action) && target.navigationState.committedURL != fixtureURL(base, path: action)) {
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                }
                let destination = fixtureURL(base, path: action == "reopen" ? "archived" : action)
                let commit = target?.navigationState.committedURL == destination ? (uptime - start) * 1000 : nil
                var frame: [String: Any] = [:]
                if let api = target?.pagePerformance {
                    let f = await api.activationFrame(activationID: UInt64(serial + 10000)); serial += 1
                    frame = ["status": f.status.rawValue, "ms": (uptime - start) * 1000]
                }
                if action == "palette" || action == "new-submit" { await owner.palette.waitForAcceptance() }
                await owner.session.waitForPendingCommands()
                rows.append(["action": action, "controls": n, "startUptime": start, "insertMS": inserted as Any? ?? NSNull(),
                    "commitMS": commit as Any? ?? NSNull(), "frame": frame,
                    "selected": id == owner.session.snapshot?.selectedOccurrenceID,
                    "occlusion": OrbitResourcePerformanceProbe.occlusion(owner),
                    "work": BrowserPerformance.work, "counters": BrowserPerformance.counters])
                if let id, action != "palette" { owner.session.closeOccurrence(id); await owner.session.waitForPendingCommands() }
                owner.palette.dismiss()
            }
            result["actions"] = rows
        } else if command["step"] == "navigate" {
            if command["hidden"] == "1" { window.orderOut(nil) } else {
                window.collectionBehavior.insert(.moveToActiveSpace)
                window.orderFrontRegardless()
            }
            let surfaces = owner.session.ownedSurfaces
            serial += 1
            var targets: [(ChromiumSurface, URL)] = []
            var events: [Int: [[String: String]]] = [:]
            let hooks = surfaces.map(\.onEngineEvent)
            defer { for (s, hook) in zip(surfaces, hooks) { s.onEngineEvent = hook } }
            for (i, surface) in surfaces.enumerated() {
                surface.onEngineEvent = { name, fields in
                    hooks[i]?(name, fields)
                    var entry = fields.filter { ["code", "status", "kind", "main", "gesture"].contains($0.key) }
                    entry["event"] = name
                    if events[i, default: []].count < 40 { events[i, default: []].append(entry) }
                }
                let url = fixtureURL(base, path: "visit-\(serial)-\(i)")
                surface.navigate(to: url)
                targets.append((surface, url))
            }
            if command["churn"] == "1" {
                for i in 0..<80 {
                    let index = i % surfaces.count
                    let url = fixtureURL(base, path: "churn-\(serial)-\(i)")
                    surfaces[index].navigate(to: url)
                    targets[index] = (surfaces[index], url)
                }
            }
            let deadline = uptime + 10
            while uptime < deadline, targets.contains(where: { $0.0.navigationState.committedURL != $0.1 }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            result["committed"] = targets.filter { $0.0.navigationState.committedURL == $0.1 }.count
            result["total"] = targets.count
            result["pending"] = targets.enumerated().filter { $0.element.0.navigationState.committedURL != $0.element.1 }.map { i, pair in
                ["index": i, "created": pair.0.isBrowserCreated, "loading": pair.0.navigationState.isLoading,
                 "ready": pair.0.isReady, "events": events[i] ?? []] as [String: Any]
            }
            result["events"] = events.map { ["index": $0.key, "events": $0.value] as [String: Any] }
        } else if command["step"] == "background-burst" {
            window.orderOut(nil)
            let old = Set(owner.session.ownedSurfaces.map(ObjectIdentifier.init))
            for i in 0..<n { owner.openPageURLInNewTab(fixtureURL(base, path: "background-\(i)")) }
            await owner.session.waitForPendingCommands()
            let added = owner.session.ownedSurfaces.filter { !old.contains(ObjectIdentifier($0)) }
            let deadline = uptime + 8
            while uptime < deadline, added.contains(where: { $0.navigationState.committedURL?.path.hasPrefix("/background-") != true }) {
                try? await Task.sleep(for: .milliseconds(5))
            }
            result["total"] = added.count
            result["committed"] = added.filter { $0.navigationState.committedURL?.path.hasPrefix("/background-") == true }.count
        } else if command["step"] == "external" {
            let start = uptime
            let tab = await owner.session.openTabForDelivery(url: fixtureURL(base, path: "external")).value
            if let id = tab?.occurrenceID, let s = owner.session.surface(for: id) { await loaded(s, seconds: 4); result["committed"] = s.navigationState.committedURL == tab?.url }
            result["ms"] = (uptime - start) * 1000
        } else if command["step"] == "sync" {
            if let id = owner.session.organization?.allTabs.first?.id {
                owner.session.pinTabs([id])
                await owner.session.waitForPendingCommands()
            }
            let document = await store.sessionDocument()
            do {
                var projection = try BrowserSyncMapping.project(session: document, settings: .init())
                var changed = 0
                for key in projection.entries.keys where key.hasPrefix("tab/") {
                    let destination = try JSONEncoder().encode(fixtureURL(base, path: "sync-\(changed)"))
                    projection.entries[key]?["url"] = destination
                    projection.entries[key]?["pinnedURL"] = destination
                    changed += 1
                }
                var replica = BrowserSyncReplica(device: "synthetic")
                try replica.capture(projection)
                let value = try BrowserSyncMapping.materialize(replica.visible, local: document, settings: .init())
                result["logicalURLChanges"] = value.organization.tabs.filter { $0.url.path.contains("sync-") }.count
                try await store.applySync(value, expected: document)
                owner.session.synchronizeOrganization()
                await owner.session.waitForPendingCommands()
                result["changed"] = changed
                result["liveDestinationsPreserved"] = await store.sessionDocument().tabs == document.tabs
                result["committed"] = owner.session.ownedSurfaces.filter { $0.navigationState.committedURL?.path.contains("sync-") == true }.count
            } catch { result["syncFailed"] = String(describing: type(of: error)) }
        }
        result["seconds"] = uptime - begin
        result["occlusion"] = OrbitResourcePerformanceProbe.occlusion(owner)
        result["windowVisible"] = window.isVisible
        result["windowOccluded"] = !window.occlusionState.contains(.visible)
        result["budget"] = owner.resources.coordinator.budget?.limit ?? 0
        return result
    }

    private static func fixtureURL(_ base: URL, path: String) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.host = path + ".localhost"
        return c.url!.appendingPathComponent(path)
    }
    private static func loaded(_ s: ChromiumSurface, seconds: Double) async {
        let deadline = uptime + seconds
        while uptime < deadline, (!s.isReady || s.navigationState.isLoading || s.navigationState.committedURL == nil) {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
    private static func settle(_ owner: OrbitWindowController, seconds: Double) async {
        let deadline = uptime + seconds
        while uptime < deadline, expected.contains(where: { id, url in
            guard let s = owner.session.surface(for: id) else { return true }
            return !s.isReady || s.navigationState.isLoading || s.navigationState.committedURL != url
        }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
