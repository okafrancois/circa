import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Darwin
import QuartzCore
import OSLog

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
            result["syncEnabled"] = environment.sync.enabled
            result["syncTaskScheduled"] = environment.sync.hasScheduledCycle
            let commandFile = root.appendingPathComponent("perf-command.json")
            if let data = try? Data(contentsOf: commandFile),
               let command = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                try? FileManager.default.removeItem(at: commandFile)
                let name = command["command"] ?? ""
                if name == "theme-fixture", ownsWindow(owner, bundleID: "lab.orbit.orbit.theme-fixture") {
                    result["themeFixture"] = await themeFixture(owner, store: environment.store, command: command)
                } else if name == "data-quick-wins" {
                    if let text = command["base"], let base = URL(string: text),
                       base.scheme == "http", base.host == "127.0.0.1" {
                        for index in 1...3 { owner.session.openTab(url: base.appendingPathComponent("page-\(index)")) }
                        await owner.session.waitForQueuedCommands()
                        if let surface = owner.session.selectedSurface { await waitForLoad(surface) }
                    }
                    var timings: [String: Double] = [:]
                    for count in [62, 200, 1000] {
                        var projection = BrowserSyncProjection()
                        let ids = (0..<count).map(String.init)
                        projection.lists["root"] = ids
                        for id in ids { projection.entries[id] = [:] }
                        var replica = BrowserSyncReplica(device: "synthetic")
                        try? replica.capture(projection)
                        let start = ProcessInfo.processInfo.systemUptime
                        try? replica.capture(projection)
                        timings[String(count)] = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    }
                    result["captureMilliseconds"] = timings
                    // Exercise the actual runtime loop with a local closure; no cloud adapters.
                    var cycles = 0
                    let scheduler = BrowserSyncRuntime(destination: root.appendingPathComponent("probe-sync.json"),
                        interval: .seconds(5)) { cycles += 1 }
                    let start = ProcessInfo.processInfo.systemUptime
                    try? await Task.sleep(for: .seconds(11))
                    result["disabledCycles"] = cycles
                    result["disabledTaskScheduled"] = scheduler.hasScheduledCycle
                    result["disabledObservationSeconds"] = ProcessInfo.processInfo.systemUptime - start
                    for _ in 0..<2 {
                        try? await scheduler.setEnabled(true)
                        try? await Task.sleep(for: .milliseconds(50))
                        try? await scheduler.setEnabled(false)
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    result["reenabledCycles"] = cycles
                    await scheduler.prepareForTermination()
                } else if name == "ui-quick-wins", ownsWindow(owner) {
                    result["uiQuickWins"] = await uiQuickWins(owner, store: environment.store, command: command)
                } else if name == "benchmark" {
                    result["benchmark"] = await benchmark(owner, command: command, store: environment.store)
                } else if name == "url-pill-fixture" {
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
                } else if name == "scroll-wheel" {
                    result["scrollWheel"] = await OrbitScrollWheelProbe.run(owner, command: command)
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
        for name in ["clean", "history", "state", "post", "frame-post", "dirty", "dirty-toggle", "pinned", "audio", "visible"] {
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
                _ = await evaluate(surface, "(() => { scrollTo(0,1200); return {}; })()")
            } else if name == "state" {
                _ = await evaluate(surface, "(() => { history.replaceState({token:42}, ''); return {}; })()")
            } else if name == "frame-post" {
                _ = await evaluate(surface, "(() => { const frame=document.createElement('iframe'); frame.name='perf-frame'; document.body.append(frame); const f=document.createElement('form'); f.target=frame.name; f.method='POST'; f.action='/posted-child'; f.innerHTML='<input name=token value=synthetic>'; document.body.append(f); f.submit(); return {}; })()")
                try? await Task.sleep(for: .milliseconds(300))
                await waitForLoad(surface)
                _ = await surface.devToolsCall("Page.resetNavigationHistory")
            } else if name == "post" {
                _ = await evaluate(surface, "(() => { const f=document.createElement('form'); f.method='POST'; f.action='/posted'; f.innerHTML='<input name=token value=synthetic>'; document.body.append(f); f.submit(); return {}; })()")
                try? await Task.sleep(for: .milliseconds(250))
                await waitForLoad(surface)
                _ = await surface.devToolsCall("Page.resetNavigationHistory")
            } else if name == "history" {
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
        result["historyProtected"] = surfaces["history"]?.isDisposed == false
        result["stateProtected"] = surfaces["state"]?.isDisposed == false
        result["framePostProtected"] = surfaces["frame-post"]?.isDisposed == false && surfaces["frame-post"]?.allowsSuspension == false
        result["postProtected"] = surfaces["post"]?.isDisposed == false
        result["postRequestRecognized"] = surfaces["post"]?.allowsSuspension == false
        result["opaqueStateRecognized"] = refusalReasons["state"] == "session-history"
        if let state = surfaces["state"], !state.isDisposed {
            result["statePreserved"] = await evaluate(state, "({ok:history.state?.token===42})")?["ok"] as? Bool == true
        }
        if let post = surfaces["post"], !post.isDisposed {
            result["postDocumentPreserved"] = post.navigationState.committedURL?.path == "/posted"
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
                if let history = surfaces["history"], !history.isDisposed {
                    result["backHistoryPreserved"] = history.goBack() == fixture.appendingPathComponent("history")
                    await waitForLoad(history)
                    result["forwardHistoryPreserved"] = history.goForward() == fixture.appendingPathComponent("clean-second")
                    await waitForLoad(history)
                }
            }
        }
        return result
    }
}


extension OrbitPerformanceProbe {
    /// Refuse synthetic input unless WindowServer attributes this exact window to this process.
    private static func ownsWindow(_ owner: OrbitWindowController, bundleID: String = "lab.orbit.orbit.perf-core-3") -> Bool {
        guard Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              Bundle.main.bundleIdentifier == bundleID,
              let window = owner.window, window.isVisible,
              let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
        else { return false }
        return windows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
            && ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
    }

    /// Synthetic-only theme fixture; it exercises the real editor and store publication paths.
    private static func themeFixture(_ owner: OrbitWindowController, store: BrowserStore,
                                     command: [String: String]) async -> Bool {
        guard ownsWindow(owner, bundleID: "lab.orbit.orbit.theme-fixture") else { return false }
        do {
            switch command["action"] {
            case "create":
                guard let profile = owner.session.activeProfileID else { return false }
                _ = try await store.createSpace(name: command["name"] ?? "Synthetic Theme", profileID: profile)
                owner.session.refreshCatalog()
                await owner.session.waitForQueuedCommands()
            case "select":
                let document = await store.sessionDocument()
                guard let index = Int(command["index"] ?? ""), document.spaces.indices.contains(index) else { return false }
                owner.session.activateSpace(document.spaces[index].id)
                await owner.session.waitForQueuedCommands()
            case "open": owner.presentActiveSpaceThemeEditor()
            case "close": owner.themeEditor?.close(animated: false)
            case "pick":
                guard let editor = owner.themeEditor, let u = Double(command["u"] ?? ""),
                      let v = Double(command["v"] ?? "") else { return false }
                var state = editor.view.state
                state.pick(at: CGPoint(x: u, y: v))
                if let intensity = Double(command["intensity"] ?? "") { state.setIntensity(intensity) }
                editor.view.state = state
                editor.view.onChange?(state)
            case "set":
                guard let space = owner.session.snapshot?.activeSpaceID, let profile = owner.session.activeProfileID else { return false }
                let colors = (command["colors"] ?? "").split(separator: ",").compactMap { BrowserThemeColor(hexString: String($0)) }
                guard !colors.isEmpty else { return false }
                let model: BrowserSpaceTheme
                if command["baked"] == "true" {
                    model = BrowserSpaceTheme(mode: .automatic, colors: [], intensity: 0.78, noise: 0,
                                              light: .init(stops: colors), dark: .init(stops: colors))
                } else {
                    model = .radial(colors: colors, intensity: Double(command["intensity"] ?? "0.78") ?? 0.78)
                }
                _ = try await owner.session.setSpaceTheme(model, for: space, profileID: profile)
            default: return false
            }
            return true
        } catch { return false }
    }

    private static func nextPageFrame(_ surface: ChromiumSurface) async -> Bool {
        let (ok, _) = await surface.devToolsCall("Runtime.evaluate", params: #"{"expression":"new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r(true))))", "awaitPromise":true,"returnByValue":true}"#, timeout: .seconds(2))
        return ok
    }

    /// Synthetic diagnostics report renderer frame opportunities / AppKit commits, not scanout.
    private static func benchmark(_ owner: OrbitWindowController, command: [String: String], store: BrowserStore) async -> [String: Any] {
        let kind = command["kind"] ?? "latency"
        if kind.hasPrefix("workload-") {
            return await workload(owner, kind: kind, store: store)
        }
        let poster = OSSignposter(subsystem: "local.orbit", category: "performance")
        var measurements: [String: [Double]] = [:]
        let document = await store.sessionDocument()
        if kind == "load" {
            for space in document.spaces {
                owner.session.activateSpace(space.id)
                await owner.session.waitForQueuedCommands()
                for tab in owner.session.snapshot?.tabs ?? [] {
                    owner.session.selectOccurrence(tab.occurrenceID)
                    await owner.session.waitForQueuedCommands()
                }
            }
            if let space = document.windows.first?.activeSpaceID {
                owner.session.activateSpace(space)
                await owner.session.waitForQueuedCommands()
            }
            var loaded = 0
            for surface in owner.session.ownedSurfaces {
                await waitForLoad(surface)
                if await evaluate(surface, "({loaded:document.readyState==='complete' && location.hostname==='127.0.0.1'})")?["loaded"] as? Bool == true { loaded += 1 }
            }
            return ["loaded": loaded, "surfaces":owner.session.ownedSurfaces.count]
        }
        if kind == "close" {
            for space in document.spaces {
                owner.session.activateSpace(space.id)
                await owner.session.waitForQueuedCommands()
                let tabs = owner.session.snapshot?.tabs ?? []
                for tab in tabs.dropLast() { owner.session.closeOccurrence(tab.occurrenceID) }
                await owner.session.waitForQueuedCommands()
            }
            return ["surfaces":owner.session.ownedSurfaces.count]
        }
        if kind == "scroll" {
            let clip = owner.sidebar.page.pageScrollView.contentView
            let height = max(1, (clip.documentView?.bounds.height ?? 1) - clip.bounds.height)
            measurements["scrollRange"] = [Double(height)]
            let counter = OrbitPerformanceFrameCounter()
            let link = owner.sidebar.displayLink(target: counter, selector: #selector(OrbitPerformanceFrameCounter.step(_:)))
            link.add(to: .main, forMode: .common)
            defer { link.invalidate() }
            let origin = ProcessInfo.processInfo.systemUptime
            for i in 0..<600 {
                let interval = poster.beginInterval("SidebarScrollCommit")
                let start = ProcessInfo.processInfo.systemUptime
                clip.scroll(to: NSPoint(x:0, y:height * CGFloat(i % 240) / 239))
                owner.sidebar.page.pageScrollView.reflectScrolledClipView(clip)
                owner.window?.displayIfNeeded()
                CATransaction.flush()
                measurements["scrollCommitMs", default:[]].append((ProcessInfo.processInfo.systemUptime-start)*1000)
                measurements["scrollTickMs", default:[]].append((start-origin)*1000)
                poster.endInterval("SidebarScrollCommit", interval)
                let remaining = origin + Double(i+1)/120 - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            }
            measurements["displayTargetsMs"] = counter.targets
            measurements["displayCallbacksMs"] = counter.callbacks
            return measurements
        }
        for space in document.spaces.prefix(2) {
            owner.session.activateSpace(space.id)
            await owner.session.waitForQueuedCommands()
            for tab in (owner.session.snapshot?.tabs ?? []).prefix(2) {
                owner.session.selectOccurrence(tab.occurrenceID)
                await owner.session.waitForQueuedCommands()
                if let surface = owner.session.selectedSurface { await waitForLoad(surface) }
            }
        }
        for i in 0..<(Int(command["count"] ?? "25") ?? 25) {
            for task in ["tab", "space", "palette", "typing"] {
                let interval = poster.beginInterval("Interaction", id: poster.makeSignpostID(), "kind=\(task, privacy: .public)")
                let start = ProcessInfo.processInfo.systemUptime
                var valid = true
                if task == "tab", let tabs = owner.session.snapshot?.tabs, tabs.count > 1 {
                    owner.session.selectOccurrence(tabs[i % 2].occurrenceID)
                    await owner.session.waitForQueuedCommands()
                    if let surface = owner.session.selectedSurface { valid = await nextPageFrame(surface) }
                } else if task == "space", document.spaces.count > 1 {
                    owner.session.activateSpace(document.spaces[i % 2].id)
                    await owner.session.waitForQueuedCommands()
                    if let surface = owner.session.selectedSurface { valid = await nextPageFrame(surface) }
                } else if task == "palette" {
                    owner.palette.present(.newTab)
                    owner.window?.displayIfNeeded()
                    CATransaction.flush()
                    measurements["paletteFirstMs", default:[]].append((ProcessInfo.processInfo.systemUptime-start)*1000)
                    await owner.palette.waitForResults()
                    owner.window?.displayIfNeeded()
                    CATransaction.flush()
                    valid = owner.palette.isPresented && !owner.palette.results.isEmpty
                } else if task == "typing", let surface = owner.session.selectedSurface {
                    _ = await evaluate(surface, "(() => { document.querySelector('input').focus(); return {}; })()")
                    // Start at dispatch, excluding fixture focus setup.
                    guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                    let inputStart = ProcessInfo.processInfo.systemUptime
                    let (ok, _) = await surface.devToolsCall("Input.insertText", params: #"{"text":"x"}"#)
                    let frame = await nextPageFrame(surface)
                    valid = ok && frame
                    measurements["typingMs", default:[]].append((ProcessInfo.processInfo.systemUptime-inputStart)*1000)
                }
                if task != "typing" { measurements[task+"Ms", default:[]].append((ProcessInfo.processInfo.systemUptime-start)*1000) }
                if !valid { measurements["failures", default:[]].append(1) }
                poster.endInterval("Interaction", interval)
                if task == "palette" { owner.palette.dismiss(returnFocus: true) }
            }
        }
        return measurements
    }
}


extension OrbitPerformanceProbe {
    private static func workload(_ owner: OrbitWindowController, kind: String, store: BrowserStore) async -> [String: Any] {
        guard ownsWindow(owner) else { return ["ownershipRefused": true] }
        let document = await store.sessionDocument()
        var values: [String: [Double]] = [:]
        let poster = OSSignposter(subsystem: "local.orbit", category: "performance")
        func commit() {
            owner.window?.displayIfNeeded()
            CATransaction.flush()
        }
        func select(_ id: TabID) async -> Bool {
            guard ownsWindow(owner) else { return false }
            owner.session.selectTab(id)
            await owner.session.waitForQueuedCommands()
            guard let surface = owner.session.selectedSurface else { return false }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !surface.isReady || surface.navigationState.isLoading {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return await nextPageFrame(surface)
        }
        if kind == "workload-prepare" || kind == "workload-load" {
            var loaded = 0
            for space in document.spaces {
                guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                owner.session.activateSpace(space.id)
                await owner.session.waitForQueuedCommands()
                let tabs = owner.session.organization?.allTabs.filter { $0.section.spaceID == space.id } ?? []
                for tab in tabs.prefix(kind == "workload-prepare" ? 2 : tabs.count) {
                    if await select(tab.id) { loaded += 1 }
                }
            }
            if kind == "workload-load" {
                for tab in document.organization.tabs where document.organization.favorites.contains(where: { $0.items.contains(.tab(tab.id)) }) {
                    if await select(tab.id) { loaded += 1 }
                }
            }
            owner.session.activateSpace(document.spaces[0].id)
            await owner.session.waitForQueuedCommands()
            return ["loaded": loaded, "surfaces": owner.session.ownedSurfaces.count]
        }
        if kind == "workload-dormant" {
            for space in document.spaces {
                owner.session.activateSpace(space.id)
                await owner.session.waitForQueuedCommands()
                let tabs = owner.session.organization?.allTabs.filter { $0.section.spaceID == space.id && $0.occurrenceID.flatMap { owner.session.surface(for: $0) } == nil } ?? []
                for tab in tabs.prefix(2) {
                    let start = ProcessInfo.processInfo.systemUptime
                    let ok = await select(tab.id)
                    values["dormantMs", default: []].append((ProcessInfo.processInfo.systemUptime-start)*1000)
                    if !ok { values["failures", default: []].append(1) }
                }
            }
            return values
        }
        if kind == "workload-latency" {
            for i in 0..<10 {
                for task in ["tab", "space", "palette", "paletteTyping"] {
                    guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                    let interval = poster.beginInterval("WorkloadInteraction", id: poster.makeSignpostID(), "kind=\(task, privacy: .public)")
                    let start = ProcessInfo.processInfo.systemUptime
                    var ok = true
                    if task == "tab" {
                        let tabs = owner.session.organization?.allTabs.filter { $0.section.spaceID == owner.session.snapshot?.activeSpaceID && $0.occurrenceID.flatMap { owner.session.surface(for: $0) } != nil } ?? []
                        if let tab = tabs.first(where: { !$0.isSelected }) { ok = await select(tab.id) }
                        else { ok = false }
                    } else if task == "space" {
                        let active = owner.session.snapshot?.activeSpaceID
                        let index = document.spaces.firstIndex(where: { $0.id == active }) ?? 0
                        owner.session.activateSpace(document.spaces[(index+1) % document.spaces.count].id)
                        await owner.session.waitForQueuedCommands()
                        if let surface = owner.session.selectedSurface { ok = await nextPageFrame(surface) } else { ok = false }
                        values["spaceFrameMs", default: []].append((ProcessInfo.processInfo.systemUptime-start)*1000)
                        let deadline = ProcessInfo.processInfo.systemUptime + 3
                        while owner.sidebar.isSpaceTransitionAnimating && ProcessInfo.processInfo.systemUptime < deadline {
                            try? await Task.sleep(for: .milliseconds(2))
                        }
                        ok = ok && !owner.sidebar.isSpaceTransitionAnimating
                        commit()
                    } else if task == "palette" {
                        owner.palette.present(.newTab)
                        commit()
                        values["paletteFirstMs", default: []].append((ProcessInfo.processInfo.systemUptime-start)*1000)
                        await owner.palette.waitForResults()
                        commit()
                        ok = owner.palette.isPresented && !owner.palette.results.isEmpty
                    } else {
                        // Exercise the real field callback without posting global keyboard events.
                        let text = "Workload \(i)"
                        owner.palette.view.input.stringValue = text
                        owner.palette.view.onQuery?(text)
                        commit()
                        values["paletteTypingFirstMs", default: []].append((ProcessInfo.processInfo.systemUptime-start)*1000)
                        await owner.palette.waitForResults()
                        commit()
                        ok = owner.palette.draft == text
                    }
                    values[task+"Ms", default: []].append((ProcessInfo.processInfo.systemUptime-start)*1000)
                    if !ok { values["failures", default: []].append(1) }
                    poster.endInterval("WorkloadInteraction", interval)
                    if task == "paletteTyping" { owner.palette.dismiss(returnFocus: true) }
                }
            }
            return values
        }
        return ["unknownKind": kind]
    }
}


@MainActor
private final class OrbitPerformanceFrameCounter: NSObject {
    var targets: [Double] = []
    var callbacks: [Double] = []
    @objc func step(_ link: CADisplayLink) {
        targets.append(link.targetTimestamp * 1000)
        callbacks.append(ProcessInfo.processInfo.systemUptime * 1000)
    }
}

extension OrbitPerformanceProbe {
    private static func uiQuickWins(_ owner: OrbitWindowController, store: BrowserStore,
                                    command: [String: String]) async -> [String: Any] {
        OrbitUIWorkCounters.enabled = true
        switch command["action"] {
        case "reset": OrbitUIWorkCounters.reset()
        case "mixed":
            OrbitUIWorkCounters.reset()
            let timings = await benchmark(owner, command: ["kind": "workload-latency"], store: store)
            let scroll = await benchmark(owner, command: ["kind": "scroll"], store: store)
            return ["counters": OrbitUIWorkCounters.values, "timings": timings, "scroll": scroll]
        case "scroll", "splits":
            if command["action"] == "splits" {
                let list = owner.sidebar.page.list
                let entries = (0..<100).map { index in
                    let item = SidebarTabItem(id: TabID(), title: "Synthetic split \(index)", selected: index == 0,
                        splitPanes: [.init(title: "Synthetic left", favicon: nil), .init(title: "Synthetic right", favicon: nil)])
                    return SidebarListEntry(node: .split(SplitGroupID()), section: .today, ancestors: [], content: .split(item, []))
                }
                list.apply(.init(entries: entries), animated: false)
                list.setFrameSize(NSSize(width: list.bounds.width, height: list.documentHeight))
                list.layoutSubtreeIfNeeded()
            }
            OrbitUIWorkCounters.reset()
            let timings = await benchmark(owner, command: ["kind": "scroll"], store: store)
            return ["counters": OrbitUIWorkCounters.values, "scroll": timings]
        case "editor":
            owner.presentActiveSpaceThemeEditor()
            await owner.session.waitForQueuedCommands()
            guard let editor = owner.themeEditor else { return ["editorMissing": true] }
            editor.view.layoutSubtreeIfNeeded()
            OrbitUIWorkCounters.reset()
            for index in 0..<120 {
                guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                var state = editor.view.state
                state.pick(at: CGPoint(x: Double(index % 60) / 60, y: 0.6))
                state.setIntensity(Double(index % 100) / 100)
                editor.view.state = state
                editor.view.onChange?(state)
                owner.window?.displayIfNeeded()
                CATransaction.flush()
                try? await Task.sleep(for: .milliseconds(8))
            }
        case "theme":
            guard let space = owner.session.snapshot?.activeSpaceID, let profile = owner.session.activeProfileID else { return [:] }
            let colors = (command["colors"] ?? "203F98,B8F478").split(separator: ",").compactMap { BrowserThemeColor(hexString: String($0)) }
            _ = try? await owner.session.setSpaceTheme(.radial(colors: colors, intensity: 0.78), for: space, profileID: profile)
        case "space":
            let document = await store.sessionDocument()
            if let index = Int(command["index"] ?? ""), document.spaces.indices.contains(index) {
                owner.session.activateSpace(document.spaces[index].id)
                await owner.session.waitForQueuedCommands()
            }
        default: break
        }
        return ["counters": OrbitUIWorkCounters.values]
    }
}
