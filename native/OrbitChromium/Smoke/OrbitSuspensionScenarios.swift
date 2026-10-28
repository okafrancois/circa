import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import ChromiumEngine
import Foundation

extension OrbitSmokeDriver {
    func suspensionScenarios(_ window: OrbitWindowController, _ tab: ChromiumSurface,
                             _ engine: ChromiumBrowserEngine) async {
        guard let probe = engine.conformanceProbe else { check("suspension.probe", false); return }
        func evaluate(_ script: String, _ surface: ChromiumSurface) async -> String? {
            try? await probe.evaluateScript(script, in: surface)
        }
        func ready(_ surface: ChromiumSurface) async -> Bool {
            await until(5) { surface.allowsSuspension }
        }
        let count = arguments.first { $0.hasPrefix("--orbit-smoke-resource-tabs=") }
            .flatMap { Int($0.split(separator: "=").last ?? "0") } ?? 0
        if count > 0 {
            await suspensionResources(window, tab, engine, count: count)
            return
        }
        let first = URL(string: "/essentials/suspension?entry=0", relativeTo: fixture)!.absoluteURL
        window.submitAddress(first.absoluteString)
        guard await committed(window, first) != nil else { check("suspension.fixture", false); return }
        _ = await evaluate("history.replaceState({entry:0},''); history.pushState({entry:1},'','?entry=1'); history.pushState({entry:2},'','?entry=2'); 'ok'", tab)
        _ = tab.goBack()
        let middle = URL(string: "/essentials/suspension?entry=1", relativeTo: fixture)!.absoluteURL
        guard await committed(window, middle) != nil else { check("suspension.middle", false); return }
        _ = await evaluate("scrollTo(0,450); document.querySelector('#check').checked=true; 'ok'", tab)
        // Give Chromium's page-state synchronization time to reach the browser process.
        try? await Task.sleep(for: .milliseconds(5500))
        let occurrence = window.session.occurrenceID(for: tab)
        let identity = tab.tabIdentity
        window.openTab(url: page("suspension-selected"))
        guard await committed(window, page("suspension-selected")) != nil, await ready(tab) else {
            check("suspension.ready", false); return
        }
        let captured = await tab.captureStateForSuspension()
        check("suspension.multi-entry-admitted", captured.map { $0.history.count >= 3 && $0.historyIndex + 1 < $0.history.count } == true)
        await window.session.waitForPendingCommands()
        guard captured != nil, window.session.suspendSurface(tab) else { check("suspension.discard", false); return }
        check("suspension.discard", tab.isSuspended && !tab.isDisposed && tab.tabIdentity?.tabID == identity?.tabID && tab.tabIdentity?.windowID == identity?.windowID)
        try? await Task.sleep(for: .milliseconds(400))
        check("suspension.lazy", tab.isSuspended)
        if let occurrence { window.session.selectOccurrence(occurrence) }
        await window.session.waitForPendingCommands()
        tab.hostDidChange(hidden: false)
        let restored = await until(5) { !tab.isSuspended && !tab.navigationState.isLoading }
        try? await Task.sleep(for: .milliseconds(300))
        let state = await evaluate("JSON.stringify({entry:history.state?.entry, discarded:document.wasDiscarded,scroll:scrollY,checked:document.querySelector('#check')?.checked})", tab)
        check("suspension.restore-state", restored && state?.contains("\"entry\":1") == true && state?.contains("\"discarded\":true") == true,
              ["state": state ?? "missing"])
        check("suspension.restore-scroll-form", state?.contains("\"scroll\":450") == true && state?.contains("\"checked\":true") == true)
        _ = tab.goBack()
        _ = await committed(window, first)
        check("suspension.back", await evaluate("String(history.state?.entry)", tab) == "0")
        _ = tab.goForward()
        _ = await committed(window, middle)
        check("suspension.forward", await evaluate("String(history.state?.entry)", tab) == "1" && tab.navigationState.canGoForward)
        _ = tab.goForward()
        let last = URL(string: "/essentials/suspension?entry=2", relativeTo: fixture)!.absoluteURL
        _ = await committed(window, last)
        check("suspension.forward-tail", await evaluate("String(history.state?.entry)", tab) == "2")
        // A no-store POST deliberately cannot be recovered from the HTTP cache.
        _ = await evaluate("document.querySelector('form').submit(); 'submitted'", tab)
        let post = URL(string: "/essentials/suspension-post", relativeTo: fixture)!.absoluteURL
        guard await committed(window, post) != nil else { check("suspension.post-load", false); return }
        window.openTab(url: page("post-selected"))
        _ = await committed(window, page("post-selected"))
        guard await ready(tab), await tab.captureStateForSuspension() != nil else { check("suspension.post-admitted", false); return }
        await window.session.waitForPendingCommands()
        check("suspension.post-admitted", window.session.suspendSurface(tab))
        try? await Task.sleep(for: .milliseconds(300))
        if let occurrence { window.session.selectOccurrence(occurrence) }
        await window.session.waitForPendingCommands()
        tab.hostDidChange(hidden: false)
        _ = await until(5) { !tab.isSuspended && !tab.navigationState.isLoading }
        // Count actual server-side requests, independent of renderer error-page contents.
        let counts = URL(string: "/essentials/suspension-post-count", relativeTo: fixture)!.absoluteURL
        let data = try? await URLSession.shared.data(from: counts).0
        let requests = data.flatMap { String(data: $0, encoding: .utf8) }
        check("suspension.post-no-resubmit", requests == "1", ["requests": requests ?? "missing"])
        check("suspension.post-history", tab.navigationState.canGoBack)
        _ = tab.goBack()
        _ = await committed(window, last)
        check("suspension.post-back", await evaluate("String(history.state?.entry)", tab) == "2")
    }

    private func suspensionResources(_ window: OrbitWindowController, _ initial: ChromiumSurface,
                                     _ engine: ChromiumBrowserEngine, count: Int) async {
        guard let probe = engine.conformanceProbe else { check("suspension.resources-probe", false); return }
        // All N tabs load real documents; every document has three opaque history states.
        var tabs: [ChromiumSurface] = []
        var historyTabs = 0
        for index in 0..<count {
            let url = URL(string: "/essentials/suspension?tab=\(index)", relativeTo: fixture)!.absoluteURL
            if index == 0 { window.submitAddress(url.absoluteString) } else { window.openTab(url: url) }
            guard let surface = await committed(window, url, 5) else { check("suspension.resources-load", false); return }
            let state = try? await probe.evaluateScript("history.replaceState({entry:0},'');history.pushState({entry:1},'',location.href+'&entry=1');history.pushState({entry:2},'',location.href+'&entry=2');String(history.length>=3 && history.state.entry===2)", in: surface)
            if state == "true" { historyTabs += 1 }
            if index < 5 {
                _ = try? await probe.evaluateScript("let e=document.createElement('div');e.style.cssText='width:30px;height:30px;background:blue';document.body.append(e);e.animate([{transform:'translateX(0)'},{transform:'translateX(100px)'}],{duration:1000,iterations:Infinity});'ok'", in: surface)
            }
            tabs.append(surface)
        }
        let ready = await until(5) { tabs.allSatisfy { $0.allowsSuspension } }
        check("suspension.resources-load", ready && tabs.count == count && historyTabs == count && window.session.ownedSurfaces.count == count)
        try? await Task.sleep(for: .milliseconds(500))
        resourceSample("loaded", tabs: tabs)
        window.tabSuspension.selectionDidChange()
        let suspended = await window.tabSuspension.sweep(now: ProcessInfo.processInfo.systemUptime + 24 * 3600)
        try? await Task.sleep(for: .seconds(1))
        check("suspension.resources-discard", suspended == count - 1 && tabs.filter(\.isSuspended).count == count - 1,
              ["tabs": count, "suspended": suspended])
        resourceSample("suspended", tabs: tabs)
        for tab in tabs.dropLast() { _ = window.session.closeOwnedSurface(tab) }
        await window.session.waitForPendingCommands()
        try? await Task.sleep(for: .milliseconds(500))
        resourceSample("closed", tabs: Array(tabs.suffix(1)))
    }

    private func resourceSample(_ phase: String, tabs: [ChromiumSurface]) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,rss=,comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let rows = text.split(separator: "\n").compactMap { line -> (Int, Int, Int, String)? in
                let cells = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
                guard cells.count == 4, let pid = Int(cells[0]), let parent = Int(cells[1]), let rss = Int(cells[2]) else { return nil }
                return (pid, parent, rss, String(cells[3]))
            }
            var owned: Set<Int> = [Int(ProcessInfo.processInfo.processIdentifier)]
            for _ in 0..<8 { for row in rows where owned.contains(row.1) { owned.insert(row.0) } }
            let members = rows.filter { owned.contains($0.0) && $0.0 != Int(process.processIdentifier) }
            record("suspension.memory-" + phase, "proven", ["tabs": tabs.count,
                "suspended": tabs.filter(\.isSuspended).count,
                "rssMiB": Double(members.reduce(0) { $0 + $1.2 }) / 1024,
                "renderers": members.filter { $0.3.contains("(Renderer)") }.count,
                "activeProcessorCount": ProcessInfo.processInfo.activeProcessorCount])
        } catch { check("suspension.memory-" + phase, false) }
    }
}
