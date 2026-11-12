import AppKit
import BrowserCore
import ChromiumEngine
import Darwin

/// Synthetic selection measurements; no destinations or page content enter the output.
@MainActor enum OrbitSelectionPerformanceProbe {
    private static var backdrop: NSWindow?
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
        if command["path"] == "metadata" {
            if command["setup"] == "1" {
                owner.window?.setFrame(NSRect(x: 100, y: 100, width: 1100, height: 800), display: true)
                owner.window?.appearance = NSAppearance(named: .aqua)
                if let window = owner.window {
                    let background = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    background.backgroundColor = .black
                    background.order(.below, relativeTo: window.windowNumber)
                    backdrop = background
                }
                for n in 0..<12 {
                    guard ownsWindow() else { return ["ownershipRefused": true] }
                    owner.session.openTab(url: URL(string: "data:text/html,<title>Page%20\(n)</title><body%20style='background:white'>Synthetic</body>")!)
                    await owner.session.waitForPendingCommands()
                }
                let tabs = owner.session.organization!.allTabs
                guard ownsWindow() else { return ["ownershipRefused": true] }
                owner.session.addToFavorites([tabs[0].id])
                await owner.session.waitForPendingCommands()
                guard ownsWindow() else { return ["ownershipRefused": true] }
                owner.session.selectTab(tabs[0].id)
                await owner.session.waitForPendingCommands()
            }
            if command["split"] == "1" {
                let tabs = owner.session.organization!.today.compactMap(\.node.tabID)
                owner.session.createSplit(Array(tabs.prefix(2)))
                await owner.session.waitForPendingCommands()
            }
            let theme = BrowserSpaceTheme.composed(colors: [.init(hex: 0x809090)], noise: command["grain"] == "0" ? 0 : 1)
            if let space = owner.session.snapshot?.activeSpaceID, let profile = owner.session.activeProfileID {
                guard ownsWindow() else { return ["ownershipRefused": true] }
                _ = try? await owner.session.setSpaceTheme(theme, for: space, profileID: profile)
            }
            try? await Task.sleep(for: .milliseconds(800))
            guard let surface = owner.session.selectedSurface else { return ["missingSurface": true] }
            let (frameReady, _) = await surface.devToolsCall("Runtime.evaluate", params: #"{"expression":"new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r(true))))","awaitPromise":true,"returnByValue":true}"#, timeout: .seconds(2))
            BrowserPerformance.resetCounters()
            var issued = 0
            for n in 0..<min(100, max(0, Int(command["count"] ?? "100") ?? 100)) {
                guard ownsWindow() else { return ["ownershipRefused": true] }
                if await OrbitPerformanceProbe.evaluate(surface, "(()=>{document.title='Title \(n)'; return {ok:true}})()")?["ok"] as? Bool == true { issued += 1 }
                try? await Task.sleep(for: .milliseconds(25))
                await owner.session.waitForPendingCommands()
            }
            try? await Task.sleep(for: .milliseconds(300))
            return ["counters": BrowserPerformance.counters, "windowNumber": owner.window!.windowNumber,
                "titleUpdates": issued, "frameReady": frameReady]
        }
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
