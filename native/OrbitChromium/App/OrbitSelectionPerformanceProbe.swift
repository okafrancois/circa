import AppKit
import BrowserCore
import ChromiumEngine
import Darwin

/// Synthetic selection measurements; no destinations or page content enter the output.
@MainActor enum OrbitSelectionPerformanceProbe {
    static func run(_ owner: OrbitWindowController, command: [String: String]) async -> [String: Any] {
        func ownsWindow() -> Bool {
            guard Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true,
                  Bundle.main.bundleIdentifier == "lab.orbit.orbit.perf-measure",
                  let window = owner.window, window.isVisible,
                  let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
            return info.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        }
        guard ownsWindow() else { return ["ownershipRefused": true] }
        owner.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let scoped = command["scoped"] != "0", path = command["path"] ?? "sidebar"
        owner.session.usesScopedSelectionUpdates = scoped
        if path == "favorite" {
            for id in owner.session.organization?.favorites.compactMap(\.node.tabID).prefix(2) ?? [] {
                guard ownsWindow() else { return ["ownershipRefused": true] }
                owner.session.selectTab(id)
                await owner.session.waitForQueuedCommands()
            }
        }
        let original = owner.session.snapshot?.tabs ?? []
        var targets = Array(original.prefix(2))
        if path == "favorite" {
            let favorites = owner.session.organization?.favorites.compactMap(\.node.tabID) ?? []
            targets = Array(original.filter { favorites.contains($0.id) }.prefix(2))
        } else {
            let favorites = Set(owner.session.organization?.favorites.compactMap(\.node.tabID) ?? [])
            targets = Array(original.filter { !favorites.contains($0.id) }.prefix(2))
        }
        guard targets.count == 2 else { return ["failures": [1]] }
        if path == "split" {
            owner.session.createSplit(targets.map(\.id))
            await owner.session.waitForQueuedCommands()
        }
        for target in targets {
            guard ownsWindow() else { return ["ownershipRefused": true] }
            owner.session.selectTab(target.id)
            await owner.session.waitForQueuedCommands()
            if let surface = owner.session.selectedSurface {
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                while (!surface.isReady || surface.navigationState.isLoading), ProcessInfo.processInfo.systemUptime < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(700))
        var trials: [[String: Any]] = []
        for _ in 0..<(Int(command["count"] ?? "10") ?? 10) {
            guard ownsWindow(), let target = targets.first(where: { $0.occurrenceID != owner.session.snapshot?.selectedOccurrenceID }),
                  let context = await owner.session.captureContextInCommandOrder().value else { return ["ownershipRefused": true] }
            let occludedBefore = owner.window?.occlusionState.contains(.visible) != true
            BrowserPerformance.resetCounters()
            let start = ProcessInfo.processInfo.systemUptime
            if path == "keyboard", let index = owner.session.organization?.tabNavigationItems.firstIndex(where: { $0.id == target.id }) {
                owner.session.selectSidebarTab(at: index)
            } else if path == "palette" {
                _ = await owner.session.selectFromPalette(target.id, from: context, spaceID: context.spaceID).value
            } else if path == "switcher" {
                owner.tabSwitcher.controlIsHeld = { true }
                owner.tabSwitcher.cycle()
                owner.tabSwitcher.model.highlight(target.occurrenceID)
                owner.tabSwitcher.commit()
            } else if path == "favorite" { owner.favorites.grid.onSelect?(target.id) }
            else if path == "split" { owner.split.view.onFocus?(target.id) }
            else { owner.sidebar.onSelectTab?(target.id) }
            let deadline = start + 3
            repeat {
                await owner.session.waitForQueuedCommands()
                if owner.session.snapshot?.selectedOccurrenceID == target.occurrenceID { break }
                await Task.yield()
            } while ProcessInfo.processInfo.systemUptime < deadline
            let queued = ProcessInfo.processInfo.systemUptime
            var frameOK = false
            if let surface = owner.session.selectedSurface, command["rapid"] != "1" {
                let (ok, _) = await surface.devToolsCall("Runtime.evaluate", params: #"{"expression":"new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r(true))))","awaitPromise":true,"returnByValue":true}"#, timeout: .seconds(2))
                frameOK = ok
            }
            let frame = ProcessInfo.processInfo.systemUptime
            if command["rapid"] != "1" { try? await Task.sleep(for: .milliseconds(150)) }
            trials.append(["counters": BrowserPerformance.counters, "queueMs": (queued-start)*1000,
                "frameMs": (frame-start)*1000, "frameOK": frameOK,
                "changed": owner.session.snapshot?.selectedOccurrenceID == target.occurrenceID,
                "occludedBefore": occludedBefore, "occludedAfter": owner.window?.occlusionState.contains(.visible) != true])
        }
        return ["trials": trials, "scoped": scoped, "path": path]
    }
}
