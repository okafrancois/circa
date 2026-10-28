import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Darwin

/// Explicit synthetic measurement endpoint. Normal product startup and personal roots never
/// enable it. Results contain counters and timestamps, never page content or destinations.
@MainActor
enum OrbitPerformanceProbe {
    private static var lastPublished: Data?
    static func pauseBeforeRuntime(_ configuration: OrbitProductConfiguration) {
        guard configuration.syntheticGuard != nil, CommandLine.arguments.contains("--perf-wait-for-profiler") else { return }
        raise(SIGSTOP)
    }
    static func start(application: OrbitApplication, configuration: OrbitProductConfiguration) {
        guard configuration.syntheticGuard != nil, CommandLine.arguments.contains("--perf-probe") else { return }
        let log = configuration.dataRoot.appendingPathComponent("download-events.jsonl")
        ChromiumRuntime.shared.trace = { name, fields in
            guard name == "download", let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: log) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data([10]))
        }
        Task { await run(application, root: configuration.dataRoot) }
    }

    private static func write(_ values: [String: Any], to file: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
            guard data != lastPublished else { return }
            try? data.write(to: file, options: .atomic)
            lastPublished = data
        }
    }

    static func evaluate(_ surface: ChromiumSurface, _ expression: String) async -> [String: Any]? {
        let parameters: [String: Any] = ["expression": expression, "returnByValue": true, "userGesture": true]
        guard let json = try? JSONSerialization.data(withJSONObject: parameters),
              let params = String(data: json, encoding: .utf8) else { return nil }
        let (ok, data) = await surface.devToolsCall("Runtime.evaluate", params: params)
        guard ok, let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let remote = result["result"] as? [String: Any] else { return nil }
        return remote["value"] as? [String: Any]
    }

    private static func run(_ application: OrbitApplication, root: URL) async {
        let output = root.appendingPathComponent("perf-state.json")
        var result: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier]
        var firstPaint = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(firstPaint ? 250 : 20))
            guard let environment = application.environment,
                  let owner = environment.liveControllers.first,
                  let snapshot = owner.session.snapshot else { continue }
            if result["interactiveUptime"] == nil, owner.window?.isVisible == true,
               !owner.session.hasPendingCommands, owner.window?.firstResponder != nil {
                result["interactiveUptime"] = ProcessInfo.processInfo.systemUptime
            }
            if !firstPaint, let id = snapshot.selectedOccurrenceID, let surface = owner.session.surface(for: id),
               surface.isReady, !surface.navigationState.isLoading,
               let paint = await evaluate(surface, "(() => { const p=performance.getEntriesByType('paint').find(p=>p.name==='first-contentful-paint'); return p ? {age:(Date.now()-performance.timeOrigin-p.startTime)/1000} : {}; })()"),
               let age = paint["age"] as? Double {
                result["firstPaintUptime"] = ProcessInfo.processInfo.systemUptime - age
                firstPaint = true
            }
            result["surfaces"] = owner.session.ownedSurfaces.count
            result["browsers"] = owner.session.ownedSurfaces.filter(\.isBrowserCreated).count
            result["windowNumber"] = owner.window?.windowNumber
            let commandFile = root.appendingPathComponent("perf-command.json")
            if let data = try? Data(contentsOf: commandFile),
               let command = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                try? FileManager.default.removeItem(at: commandFile)
                let name = command["command"] ?? ""
                if name == "url-pill-fixture" {
                    let document = await environment.store.sessionDocument()
                    if let index = Int(command["statusSpace"] ?? ""), document.spaces.indices.contains(index) {
                        let target = document.spaces[index].id, message = command["status"]
                        owner.addressField.statusForSpace = { $0 == target ? message : nil }
                    }
                    // Hermetic runs intentionally disable installed extensions. This explicit
                    // metadata fixture exercises the native presentation on real Chromium pages.
                    let icons = (1...2).compactMap { index in
                        try? Data(contentsOf: root.appendingPathComponent("extension-\(index)/icon.png"))
                    }
                    let second = document.profiles.dropFirst().first?.id
                    owner.extensionControls.presentationInventory = { profile in
                        icons.prefix(profile == second ? 2 : 1).enumerated().map { n, data in
                            BrowserExtensionSummary(id: String(repeating: n == 0 ? "a" : "b", count: 32),
                                name: "Synthetic \(n + 1)", version: "1", isEnabled: true, hasAction: true,
                                isPinned: true, iconPNGBase64: data.base64EncodedString())
                        }
                    }
                    owner.extensionControls.render()
                    owner.sidebar.addressContainer.holdsAccessoriesVisible = true
                    result["pillFixtureReady"] = true
                    result["pillPinCount"] = owner.sidebar.extensionsContainer.visiblePinCount
                } else if name == "load-all" {
                    let document = await environment.store.sessionDocument()
                    var verified = 0
                    var pausedVideos = 0
                    for space in document.spaces {
                        owner.session.activateSpace(space.id)
                        await owner.session.waitForQueuedCommands()
                        for tab in owner.session.snapshot?.tabs ?? [] {
                            owner.session.selectOccurrence(tab.occurrenceID)
                            await owner.session.waitForQueuedCommands()
                            if let surface = owner.session.surface(for: tab.occurrenceID) {
                                let deadline = ProcessInfo.processInfo.systemUptime + 40
                                while !surface.isReady || surface.navigationState.isLoading {
                                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                                    try? await Task.sleep(for: .milliseconds(50))
                                }
                                if let state = await evaluate(surface, "(() => { const v=[...document.querySelectorAll('video')]; v.forEach(p=>p.pause()); return {loaded:document.readyState==='complete' && location.protocol==='https:', pausedVideos:v.filter(p=>p.paused).length}; })()") {
                                    if state["loaded"] as? Bool == true { verified += 1 }
                                    pausedVideos += state["pausedVideos"] as? Int ?? 0
                                }
                            }
                        }
                    }
                    result["loadedAll"] = true
                    result["loadedDocuments"] = verified
                    result["pausedVideos"] = pausedVideos
                } else if name == "suspend" {
                    var reasons: [String: Int] = [:]
                    for surface in owner.session.ownedSurfaces {
                        surface.onEngineEvent = { name, fields in
                            if name == "suspension-refused", let reason = fields["reason"] { reasons[reason, default: 0] += 1 }
                        }
                    }
                    result["suspendedCount"] = await owner.tabSuspension.sweep(now: ProcessInfo.processInfo.systemUptime + 86401)
                    result["suspensionRefusals"] = reasons
                } else if name == "verify-suspension", let fixture = command["fixture"], let url = URL(string: fixture) {
                    result["suspensionChecks"] = await verifySuspension(owner, fixture: url)
                } else if name == "download-audio" {
                    result["downloadAudio"] = await OrbitDownloadAudioProbe.run(owner, command: command, root: root)
                } else if name == "settings" {
                    application.showSettings(section: .advanced)
                    result["settingsWindowNumber"] = application.settingsWindow?.window?.windowNumber
                } else if name == "quit" {
                    write(result, to: output)
                    NSApp.terminate(nil)
                    return
                }
                result["completedCommand"] = command["id"] ?? name
            }
            if owner.isPeekPresented, let rect = owner.peekOverlay.sourceRect {
                result["peekOrigin"] = ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
            } else { result.removeValue(forKey: "peekOrigin") }
            result["surfaces"] = owner.session.ownedSurfaces.count
            result["browsers"] = owner.session.ownedSurfaces.filter(\.isBrowserCreated).count
            write(result, to: output)
        }
    }

    private static func waitForLoad(_ surface: ChromiumSurface) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !surface.isReady || surface.navigationState.isLoading {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(100))
    }

    private static func verifySuspension(_ owner: OrbitWindowController, fixture: URL) async -> [String: Bool] {
        var surfaces: [String: ChromiumSurface] = [:]
        var refusalReasons: [String: String] = [:]
        var occurrences: [String: TabOccurrenceID] = [:]
        var trustedToggleChanged = false
        for name in ["clean", "dirty", "dirty-toggle", "pinned", "audio", "visible"] {
            owner.session.openTab(url: fixture.appendingPathComponent(name))
            await owner.session.waitForQueuedCommands()
            guard let surface = owner.session.selectedSurface, let id = owner.session.snapshot?.selectedOccurrenceID else { return ["created": false] }
            await waitForLoad(surface)
            surfaces[name] = surface
            surface.onEngineEvent = { event, fields in
                if event == "suspension-refused" { refusalReasons[name] = fields["reason"] }
            }
            occurrences[name] = id
            if name == "clean" {
                surface.navigate(to: fixture.appendingPathComponent("clean-second"))
                await waitForLoad(surface)
                _ = await evaluate(surface, "(() => { scrollTo(0,1200); return {}; })()")
            } else if name == "dirty" {
                _ = await evaluate(surface, "(() => { document.querySelector('input').value='synthetic edit'; return {}; })()")
            } else if name == "dirty-toggle" {
                owner.window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
                _ = surface.focusDocument()
                try? await Task.sleep(for: .milliseconds(50))
                if let point = await evaluate(surface, "(() => { const r=document.querySelector('#toggle').getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}; })()"),
                   let x = point["x"] as? Double, let y = point["y"] as? Double {
                    _ = await surface.devToolsCall("Input.dispatchMouseEvent", params: "{\"type\":\"mousePressed\",\"x\":\(x),\"y\":\(y),\"button\":\"left\",\"clickCount\":1}")
                    _ = await surface.devToolsCall("Input.dispatchMouseEvent", params: "{\"type\":\"mouseReleased\",\"x\":\(x),\"y\":\(y),\"button\":\"left\",\"clickCount\":1}")
                    let state = await evaluate(surface, "({changed:!document.querySelector('#toggle').checked})")
                    trustedToggleChanged = state?["changed"] as? Bool == true
                }
            } else if name == "pinned", let tab = owner.session.snapshot?.tabs.first(where: { $0.occurrenceID == id }) {
                owner.session.pinTabs([tab.id])
                await owner.session.waitForQueuedCommands()
            } else if name == "audio" {
                _ = await evaluate(surface, "(() => { globalThis.perfAudio=new AudioContext(); return {}; })()")
            }
        }
        let order = owner.session.snapshot?.tabs.map(\.occurrenceID)
        for _ in 0..<3 {
            await owner.session.waitForPendingCommands()
            try? await Task.sleep(for: .milliseconds(200))
            _ = await owner.tabSuspension.sweep(now: ProcessInfo.processInfo.systemUptime + 86401)
            if surfaces["clean"]?.isDisposed == true { break }
        }
        var result: [String: Bool] = [:]
        if let clean = surfaces["clean"], !clean.isDisposed {
            result["cleanNativeAllows"] = clean.allowsSuspension
            result["cleanEngineCheck"] = await clean.captureStateForSuspension() != nil
            if let reason = refusalReasons["clean"] { result["cleanRefused:" + reason] = false }
        }
        result["cleanDisposed"] = surfaces["clean"]?.isDisposed == true
        result["dirtyProtected"] = surfaces["dirty"]?.isDisposed == false
        result["trustedToggleProtected"] = surfaces["dirty-toggle"]?.isDisposed == false
        result["trustedToggleChanged"] = trustedToggleChanged
        result["pinnedProtected"] = surfaces["pinned"]?.isDisposed == false
        result["audioProtected"] = surfaces["audio"]?.isDisposed == false
        result["visibleProtected"] = surfaces["visible"]?.isDisposed == false
        result["orderPreserved"] = order == owner.session.snapshot?.tabs.map(\.occurrenceID)
        if let clean = occurrences["clean"] {
            result["titlePreserved"] = owner.session.organization?.allTabs.first { $0.occurrenceID == clean }?.pageTitle == "Performance fixture"
            result["faviconPreserved"] = owner.tabSuspension.icon(for: clean) != nil
            owner.session.selectOccurrence(clean)
            await owner.session.waitForQueuedCommands()
            if let surface = owner.session.surface(for: clean) {
                await waitForLoad(surface)
                try? await Task.sleep(for: .milliseconds(300))
                result["recreated"] = surface !== surfaces["clean"] && !surface.isDisposed
                let state = await evaluate(surface, "({y:scrollY})")
                result["scrollRestored"] = (state?["y"] as? Double ?? 0) >= 1100
                result["backHistoryPreserved"] = surface.goBack() == fixture.appendingPathComponent("clean")
                await waitForLoad(surface)
                result["forwardHistoryPreserved"] = surface.goForward() == fixture.appendingPathComponent("clean-second")
                await waitForLoad(surface)
            }
        }
        return result
    }
}
