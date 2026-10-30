import AppKit
import BrowserCore
import BrowserShell
import BrowserEngine
import ChromiumEngine
import Darwin
import QuartzCore
import OSLog
import ObjectiveC.runtime

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
        if ["lab.orbit.orbit.engine-r11", "lab.orbit.orbit.engine-r12", "lab.orbit.orbit.engine-r13", "lab.orbit.orbit.sec-permissions"].contains(Bundle.main.bundleIdentifier ?? "") { application.confirmQuit = { .quit } }
        if ["lab.orbit.orbit.engine-r13", "lab.orbit.orbit.sec-permissions"].contains(Bundle.main.bundleIdentifier ?? ""),
           CommandLine.arguments.contains("--orbit-security-fixture") || CommandLine.arguments.contains("--orbit-permissions-fixture") {
            application.windowPresenter = { controller, _ in
                controller.window?.setFrame(NSRect(x: -2000, y: -1200, width: 1280, height: 900), display: false)
                controller.window?.orderBack(nil)
                controller.window?.makeKey()
            }
        }
        if ["lab.orbit.orbit.pinned-tabs", "lab.orbit.orbit.search-suggestions", "lab.orbit.orbit.circa-rename"].contains(Bundle.main.bundleIdentifier ?? "") {
            application.confirmQuit = { .quit }
            application.windowPresenter = { controller, _ in
                controller.window?.setFrame(NSRect(x: -2000, y: -1200, width: 1280, height: 900), display: false)
                controller.window?.orderBack(nil)
                controller.window?.makeKey()
            }
        }
        installDrawCounter()
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
            try? await Task.sleep(for: .milliseconds(firstPaint && result["interactiveUptime"] != nil ? 250 : 20))
            guard let environment = application.environment,
                  let owner = environment.liveControllers.first,
                  let snapshot = owner.session.snapshot else { continue }
            if result["interactiveUptime"] == nil, owner.window?.isVisible == true,
               !owner.session.hasPendingCommands, owner.window?.firstResponder != nil {
                owner.window?.displayIfNeeded()
                CATransaction.flush()
                BrowserPerformance.mark(.windowCommitted)
                BrowserPerformance.mark(.windowInteractive)
                result["interactiveUptime"] = BrowserPerformance.phases["windowInteractive"]
            }
            if !firstPaint, let id = snapshot.selectedOccurrenceID, let surface = owner.session.surface(for: id),
               surface.isReady, !surface.navigationState.isLoading,
               let paint = await evaluate(surface, "(() => { const p=performance.getEntriesByType('paint').find(p=>p.name==='first-contentful-paint'); return p ? {age:(Date.now()-performance.timeOrigin-p.startTime)/1000} : {}; })()"),
               let age = paint["age"] as? Double {
                result["firstPaintUptime"] = ProcessInfo.processInfo.systemUptime - age
                firstPaint = true
            }
            result["startupPhases"] = BrowserPerformance.phases
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
                result["commandNonce"] = command["nonce"] ?? ""
                if name == "search-suggestions" {
                    result["searchSuggestions"] = await searchSuggestions(owner, root: root, command: command)
                } else if name == "branding-capture" {
                    result["branding"] = await OrbitBrandingProbe.run(application, environment: environment, owner: owner, root: root, appearance: command["appearance"] ?? "light")
                } else if name == "pinned-tabs" {
                    result["pinnedTabs"] = await OrbitPinnedTabProbe.run(owner, store: environment.store, root: root, command: command)
                } else if name == "split-divider" {
                    result["splitDivider"] = await splitDividerFixture(owner, command: command)
                } else if name == "folder-hover", ownsWindow(owner, bundleID: "lab.orbit.orbit.folder-hover") {
                    result["folderHoverActionUptime"] = ProcessInfo.processInfo.systemUptime
                    result["folderHover"] = await folderHoverFixture(owner, store: environment.store, command: command)
                } else if name == "theme-fixture", ownsWindow(owner, bundleID: "lab.orbit.orbit.theme-fixture") {
                    result["themeFixture"] = await themeFixture(owner, store: environment.store, command: command)
                } else if name == "resource-coordinator", ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-coord-0") {
                    application.confirmQuit = { .quit }
                    result["resourceCoordinator"] = await OrbitResourcePerformanceProbe.run(owner, store: environment.store, command: command)
                } else if name == "tab-open", Bundle.main.bundleIdentifier == OrbitTabOpenProbe.bundleID {
                    application.confirmQuit = { .quit }
                    result["tabOpen"] = await OrbitTabOpenProbe.run(owner, store: environment.store, command: command)
                } else if name == "resource-budget", Bundle.main.bundleIdentifier == OrbitResourceBudgetProbe.bundleID {
                    application.confirmQuit = { .quit }
                    result["resourceBudget"] = await OrbitResourceBudgetProbe.run(owner, store: environment.store, root: root, command: command)
                } else if name == "import-auth-check", ownsWindow(owner, bundleID: "lab.orbit.orbit.import-auth") {
                    do {
                        guard let configuration = activeSiteSessionConfiguration() else { throw BrowserAuthenticationImportError.invalidState }
                        let run = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: ChromiumAuthenticationStartup.recoveryKey(configuration))
                        let catalog = await environment.store.catalogSnapshot()
                        if let space = catalog.spaces.first(where: { $0.profileID == run.status.profileID }) {
                            owner.session.activateSpace(space.id)
                            await owner.session.waitForPendingCommands()
                            owner.session.openTab(url: URL(string: "http://127.0.0.1:18080/login")!)
                            await owner.session.waitForPendingCommands()
                            if let surface = owner.session.selectedSurface {
                                await waitForLoad(surface)
                                try await Task.sleep(for: .milliseconds(600))
                                guard ownsWindow(owner, bundleID: "lab.orbit.orbit.import-auth") else { throw BrowserAuthenticationImportError.invalidState }
                                _ = await surface.devToolsCall("Input.dispatchMouseEvent", params: #"{"type":"mousePressed","x":60,"y":75,"button":"left","clickCount":1}"#)
                                guard ownsWindow(owner, bundleID: "lab.orbit.orbit.import-auth") else { throw BrowserAuthenticationImportError.invalidState }
                                _ = await surface.devToolsCall("Input.dispatchMouseEvent", params: #"{"type":"mouseReleased","x":60,"y":75,"button":"left","clickCount":1}"#)
                                try await Task.sleep(for: .milliseconds(600))
                                let session = await evaluate(surface, "({signedIn:document.title==='Synthetic signed in'})")
                                guard ownsWindow(owner, bundleID: "lab.orbit.orbit.import-auth") else { throw BrowserAuthenticationImportError.invalidState }
                                _ = await evaluate(surface, "document.querySelector('form').requestSubmit();({submitted:true})")
                                try await Task.sleep(for: .milliseconds(800))
                                result["importAuth"] = ["signedIn": session?["signedIn"] as? Bool ?? false,
                                    "autofilled": surface.navigationState.title == "Synthetic filled", "phase": run.status.phase.rawValue]
                            }
                        } else {
                            result["importAuth"] = ["restored": run.status.phase == .restored,
                                "remainingProfiles": catalog.profiles.count]
                        }
                    } catch { result["importAuth"] = ["failed": true] }
                } else if name == "import-ui-start", ownsWindow(owner, bundleID: "lab.orbit.orbit.import-ui") {
                    if command["appearance"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
                    else { NSApp.appearance = NSAppearance(named: .aqua) }
                    application.startBrowserImport()
                    result["importUIStarted"] = true
                } else if name == "import-ui-appearance", ownsWindow(owner, bundleID: "lab.orbit.orbit.import-ui") {
                    NSApp.appearance = NSAppearance(named: command["appearance"] == "dark" ? .darkAqua : .aqua)
                } else if name == "import-ui-check", ownsWindow(owner, bundleID: "lab.orbit.orbit.import-ui") {
                    let catalog = await environment.store.catalogSnapshot()
                    var check: [String: Any] = ["profiles": catalog.profiles.count, "spaces": catalog.spaces.count,
                        "running": application.browserImport.isRunning]
                    do {
                        guard let configuration = activeSiteSessionConfiguration(), configuration.usesMockKeychain else { throw BrowserAuthenticationImportError.invalidState }
                        let run = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: ChromiumAuthenticationStartup.recoveryKey(configuration))
                        check["phase"] = run.status.phase.rawValue
                        check["passwords"] = try await environment.engine.passwordStore?.list(profileID: run.status.profileID).count
                        if let space = catalog.spaces.first(where: { $0.profileID == run.status.profileID }) {
                            owner.session.activateSpace(space.id)
                            await owner.session.waitForPendingCommands()
                            owner.session.openTab(url: URL(string: "http://127.0.0.1:18080/login")!)
                            await owner.session.waitForPendingCommands()
                            if let surface = owner.session.selectedSurface {
                                await waitForLoad(surface)
                                check["signedIn"] = await evaluate(surface, "({signedIn:document.title==='Synthetic signed in'})")?["signedIn"] as? Bool ?? false
                            }
                        }
                    } catch { check["failed"] = true }
                    result["importUI"] = check
                } else if name == "import-recovery-fixture" {
                    result["importRecovery"] = ["started": true, "profiles": await environment.store.catalogSnapshot().profiles.count]
                } else if name == "password-import", ownsWindow(owner, bundleID: ArcPasswordProductProbe.bundleID) {
                    application.confirmQuit = { .quit }
                    result["passwordImport"] = await ArcPasswordProductProbe.run(application: application, action: command["action"] ?? "check", appearance: command["appearance"] ?? "light")
                } else if name == "sunset-import", ownsWindow(owner, bundleID: SunsetImportProbe.bundleID) {
                    application.confirmQuit = { .quit }
                    result["sunsetImport"] = await SunsetImportProbe.run(environment: environment, root: root, action: command["action"] ?? "import")
                } else if name == "chromium-import-fixture" {
                    result["importFixture"] = await ChromiumImportProbe.run(root: root)
                } else if name == "safari-import-fixture" {
                    result["safariImport"] = await SafariImportProbe.run(root: root, store: environment.store, passwords: environment.engine.passwordStore)
                } else if name == "firefox-import-fixture", ownsWindow(owner, bundleID: "lab.orbit.orbit.import-recovery") {
                    result["firefoxImport"] = await FirefoxImportProbe.run(root: root, store: environment.store)
                    do {
                        guard let configuration = activeSiteSessionConfiguration(), configuration.usesMockKeychain else { throw BrowserAuthenticationImportError.invalidState }
                        let run = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: ChromiumAuthenticationStartup.recoveryKey(configuration))
                        let catalog = await environment.store.catalogSnapshot()
                        if let space = catalog.spaces.first(where: { $0.profileID == run.status.profileID }) {
                            owner.session.activateSpace(space.id)
                            await owner.session.waitForPendingCommands()
                            owner.session.openTab(url: URL(string: "http://127.0.0.1:18080/login")!)
                            await owner.session.waitForPendingCommands()
                            if let surface = owner.session.selectedSurface {
                                await waitForLoad(surface)
                                let value = await evaluate(surface, "({signedIn:document.title==='Synthetic signed in'})")
                                result["firefoxCookie"] = value?["signedIn"] as? Bool ?? false
                            }
                        }
                    } catch { result["firefoxCookie"] = false }
                } else if name == "memory-caches-show", Bundle.main.bundleIdentifier == "lab.orbit.orbit.perf-mem-caches",
                          let window = owner.window, NSApp.windows.contains(where: { $0 === window }) {
                    window.makeKeyAndOrderFront(nil)
                    result["memoryShown"] = true
                } else if name == "memory-caches", ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-mem-caches") {
                    var check: [String: Any] = [:]
                    let document = await environment.store.sessionDocument()
                    let count = min(1000, max(0, Int(command["count"] ?? "0") ?? 0))
                    let offset = Int(command["offset"] ?? "0") ?? 0
                    var visits = 0, icons = 0
                    if let port = Int(command["port"] ?? ""), (1024...65535).contains(port) {
                        for index in offset..<(offset + count) {
                            guard ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-mem-caches"), document.spaces.count >= 3 else { break }
                            let space = document.spaces[(index / 10) % 3]
                            owner.session.activateSpace(space.id)
                            await owner.session.waitForPendingCommands()
                            guard ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-mem-caches"),
                                  let surface = owner.session.selectedSurface,
                                  let url = URL(string: "http://o\(index).localhost:\(port)/\(index)") else { break }
                            surface.navigate(to: url)
                            await waitForLoad(surface)
                            let deadline = ProcessInfo.processInfo.systemUptime + 2
                            while (surface.navigationState.faviconImage?.sourceURL.host != url.host || surface.navigationState.committedURL != url),
                                  ProcessInfo.processInfo.systemUptime < deadline {
                                try? await Task.sleep(for: .milliseconds(10))
                            }
                            if surface.navigationState.committedURL == url { visits += 1 }
                            if let pixels = surface.navigationState.faviconImage, pixels.sourceURL.host == url.host, let native = await pixels.nativeImage() {
                                await environment.favoriteIcons?.put(pixels, profile: space.profileID, home: url)
                                environment.sidebarIconMemory.put(native, profile: space.profileID, home: url)
                                icons += 1
                            }
                            await environment.historyRecorder.prepareSuggestions(for: space.profileID)
                        }
                    }
                    await environment.historyRecorder.flush()
                    if command["pressure"] == "1" {
                        BrowserMemoryPressure.simulate()
                        await environment.favoriteIcons?.releaseMemory()
                        environment.sidebarIconMemory.releaseMemory()
                        await environment.historyRecorder.releaseInactiveMemory()
                        owner.extensionControls.releaseMemory()
                    }
                    check["visits"] = visits; check["icons"] = icons
                    check["encoded"] = await environment.favoriteIcons?.cacheStatistics
                    check["sidebar"] = environment.sidebarIconMemory.cacheStatistics
                    check["palette"] = owner.palette.faviconCacheStatistics
                    check["history"] = environment.historyRecorder.cacheStatistics
                    check["extensions"] = owner.extensionControls.cacheStatistics
                    check["occluded"] = owner.window?.occlusionState.contains(.visible) != true
                    check["windowNumber"] = owner.window?.windowNumber
                    result["memoryCaches"] = check
                    owner.window?.orderOut(nil)
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
                } else if name == "selection-performance", ownsWindow(owner) {
                    result["selectionPerformance"] = await OrbitSelectionPerformanceProbe.run(owner, command: command)
                } else if name == "mainthread" {
                    result["mainthread"] = await mainthread(owner, command: command, root: root)
                } else if name == "lists" {
                    result["lists"] = await lists(owner, command: command, root: root)
                } else if name == "space-compositing", ownsWindow(owner) {
                    result["spaceCompositing"] = await spaceCompositing(owner, store: environment.store, command: command)
                } else if name == "glyph-diagnostics", ownsWindow(owner) {
                    result["glyphDiagnostics"] = await glyphDiagnostics(owner, root: root, store: environment.store, command: command)
                } else if name == "ui-quick-wins", ownsWindow(owner) {
                    result["uiQuickWins"] = await uiQuickWins(owner, store: environment.store, command: command)
                } else if name == "startup-check", ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-startup") {
                    let document = await environment.store.sessionDocument()
                    let restored = document.windows.first { $0.id == owner.session.snapshot?.id }
                    var check: [String: Any] = [
                        "profiles": document.profiles.count, "spaces": document.spaces.count,
                        "windows": document.windows.count, "tabs": document.tabs.count,
                        "activeSpacePreserved": restored?.activeSpaceID == owner.session.snapshot?.activeSpaceID,
                        "findDeferred": owner.findBarStorage == nil,
                        "libraryDeferred": !owner.library.contentsInstalled,
                        "quickWindows": environment.quickWindows.count,
                        "quickWindowLoaded": environment.quickWindows.values.contains {
                            $0.window?.isVisible == true && $0.surface?.navigationState.isLoading == false
                                && $0.surface?.navigationState.committedURL?.host == "127.0.0.1"
                        }
                    ]
                    if command["exercise"] == "1" {
                        var verified = 0
                        for space in document.spaces {
                            guard ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-startup") else { break }
                            owner.session.activateSpace(space.id)
                            await owner.session.waitForPendingCommands()
                            if let surface = owner.session.selectedSurface {
                                await waitForLoad(surface)
                                if surface.profileID == space.profileID,
                                   owner.session.snapshot?.activeSpaceID == space.id { verified += 1 }
                            }
                        }
                        check["verifiedSpaces"] = verified
                        if ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-startup") {
                            let begin = ProcessInfo.processInfo.systemUptime
                            owner.showFind()
                            await owner.session.waitForPendingCommands()
                            check["findVisible"] = owner.findBarStorage?.isHidden == false
                            owner.closeFind()
                            owner.showLibrary(.history)
                            await owner.session.waitForPendingCommands()
                            check["libraryVisible"] = owner.library.isPresented && owner.library.contentsInstalled
                            check["firstToolsMilliseconds"] = (ProcessInfo.processInfo.systemUptime - begin) * 1000
                            owner.hideLibrary()
                        }
                    }
                    result["startupCheck"] = check
                } else if name == "sync-idle" {
                    // Explicit fake transport only; never enable account-backed runtime sync.
                    do {
                        let session = await environment.store.sessionDocument()
                        let settings = await environment.settings.store.snapshot()
                        var boosts: [BrowserBoostDocument] = []
                        for profile in session.profiles { boosts.append(await (try environment.boosts.store(for: profile.id)).snapshot()) }
                        let snapshot = BrowserSyncWorker.Snapshot(session: session, settings: settings, boosts: boosts)
                        let destination = root.appendingPathComponent("idle-replica.json")
                        let worker = BrowserSyncWorker(state: .init(), destination: destination)
                        let transport = BrowserSyncMemoryTransport(cloud: BrowserSyncMemoryCloud(), account: "synthetic")
                        var unchanged = 0
                        let start = ProcessInfo.processInfo.systemUptime
                        for _ in 0..<5 {
                            try await worker.admit("synthetic")
                            let outgoing = try await worker.capture(snapshot)
                            try await worker.merge(await transport.exchange(outgoing), identity: "synthetic")
                            let prepared = try await worker.prepare(snapshot)
                            if !prepared.changed { unchanged += 1 }
                            try await worker.acknowledge(prepared.projection)
                        }
                        result["syncIdle"] = ["cycles": 5, "unchanged": unchanged, "transport": "memory",
                            "milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                            "durableBytes": (try Data(contentsOf: destination)).count] as [String: Any]
                    } catch { result["syncIdle"] = ["failed": true] }
                } else if name == "command-bar", ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-cmdbar") {
                    result["commandBar"] = await commandBar(owner, command: command)
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
                } else if name == "thumbnail-performance", ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-r11-thumbs") {
                    result["thumbnailPerformance"] = await OrbitThumbnailPerformanceProbe.run(owner, command: command, root: root)
                } else if name == "permissions" {
                    result["permissions"] = await OrbitPermissionsProbe.run(owner, environment: environment, root: root, command: command)
                } else if name == "native-security" {
                    result["nativeSecurity"] = await OrbitEngineSecurityProbe.run(owner, command: command)
                } else if name == "native-performance" {
                    result["nativePerformance"] = await OrbitEnginePerformanceProbe.run(owner, command: command, root: root)
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
    private static func commandBar(_ owner: OrbitWindowController, command: [String: String]) async -> [String: Any] {
        let bundleID = "lab.orbit.orbit.perf-cmdbar"
        guard ownsWindow(owner, bundleID: bundleID) else { return ["ownershipRefused": true] }
        NSApp.appearance = NSAppearance(named: command["appearance"] == "dark" ? .darkAqua : .aqua)
        if !owner.palette.isPresented { owner.palette.present(.newTab) }
        await owner.palette.waitForResults()
        var first: [Double] = [], final: [Double] = [], arrows: [Double] = []
        for query in ["", "s", "sy", "synthetic", "~", "résumé", "東京"] {
            guard ownsWindow(owner, bundleID: bundleID) else { return ["ownershipRefused": true] }
            let start = ProcessInfo.processInfo.systemUptime
            owner.palette.query(query)
            first.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            await owner.palette.waitForResults()
            final.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            guard ownsWindow(owner, bundleID: bundleID) else { return ["ownershipRefused": true] }
            let arrow = ProcessInfo.processInfo.systemUptime
            owner.palette.move(1)
            owner.palette.view.layoutSubtreeIfNeeded()
            arrows.append((ProcessInfo.processInfo.systemUptime - arrow) * 1000)
        }
        guard ownsWindow(owner, bundleID: bundleID) else { return ["ownershipRefused": true] }
        owner.palette.query(command["query"] ?? "synthetic")
        await owner.palette.waitForResults()
        owner.window?.displayIfNeeded()
        CATransaction.flush()
        let table = owner.palette.view.scroll.documentView as? NSTableView
        let cells = (0..<(table?.numberOfRows ?? 0)).compactMap {
            table?.view(atColumn: 0, row: $0, makeIfNecessary: false) as? PaletteResultCell
        }
        let before = cells.reduce(0) { $0 + $1.configurationCount }
        if command["icons"] == "1", let first = owner.palette.results.first {
            guard ownsWindow(owner, bundleID: bundleID) else { return ["ownershipRefused": true] }
            let saved = owner.palette.view.favicons
            owner.palette.view.favicons[first.id] = NSImage(size: NSSize(width: 16, height: 16))
            owner.palette.view.render(owner.palette.results, selected: owner.palette.selection.index)
            let changed = cells.reduce(0) { $0 + $1.configurationCount } - before
            owner.palette.view.favicons = saved
            owner.palette.view.render(owner.palette.results, selected: owner.palette.selection.index)
            return ["cachedCells": cells.count, "iconReconfigurations": changed]
        }
        return ["firstMS": first, "finalMS": final, "arrowMS": arrows,
                "results": owner.palette.results.count, "window": owner.window?.windowNumber ?? 0]
    }

    private static func ownsWindow(_ owner: OrbitWindowController, bundleID: String = "lab.orbit.orbit.perf-core-3") -> Bool {
        guard Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              Bundle.main.bundleIdentifier == bundleID
                || (bundleID == "lab.orbit.orbit.perf-core-3" && Bundle.main.bundleIdentifier == "lab.orbit.orbit.perf-measure"),
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
            case "seed":
                for (index, title) in ["Mail", "Calendar", "Notes", "Design review", "Team calendar", "Q4 roadmap"].enumerated() {
                    guard ownsWindow(owner, bundleID: "lab.orbit.orbit.theme-fixture") else { return false }
                    owner.session.openTab(url: URL(string: "https://fixture.invalid/\(index)")!)
                    await owner.session.waitForPendingCommands()
                    guard let tab = owner.session.organization?.selectedTab?.id,
                          let windowID = owner.session.snapshot?.id else { return false }
                    let context = try await store.captureContext(in: windowID)
                    _ = try await store.renameTab(tab, to: title, from: context)
                    if index < 3 { _ = try await store.addToFavorites([tab], from: context) }
                    else { _ = try await store.pinTabs([tab], from: context) }
                }
                owner.session.refreshCatalog()
                await owner.session.waitForPendingCommands()
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
            case "preset":
                guard let editor = owner.themeEditor, let index = Int(command["index"] ?? ""),
                      editor.view.swatches.indices.contains(index), !editor.view.swatches[index].isHidden,
                      let target = editor.view.window,
                      let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(target.windowNumber)) as? [[String: Any]],
                      windows.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
                          && ($0[kCGWindowNumber as String] as? Int) == target.windowNumber }) else { return false }
                editor.view.swatches[index].performClick(nil)
            case "frost":
                guard let editor = owner.themeEditor,
                      ownsWindow(owner, bundleID: "lab.orbit.orbit.theme-fixture") else { return false }
                editor.view.frostSwitch.state = command["enabled"] == "true" ? .on : .off
                _ = editor.view.frostSwitch.sendAction(editor.view.frostSwitch.action, to: editor.view.frostSwitch.target)
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
                let preset = BrandPalette.spaceGradients.first { $0.id == command["preset"] }
                guard preset != nil || !colors.isEmpty else { return false }
                var model: BrowserSpaceTheme
                if let preset {
                    model = preset.theme()
                } else if command["baked"] == "true" {
                    model = BrowserSpaceTheme(mode: .automatic, colors: [], intensity: 0.78, noise: 0,
                                              light: .init(stops: colors), dark: .init(stops: colors))
                } else {
                    model = .radial(colors: colors, intensity: Double(command["intensity"] ?? "0.78") ?? 0.78)
                }
                owner.window?.makeFirstResponder(nil)
                model.frost = command["frost"] == "true"
                if let appearance = command["appearance"] { model.mode = appearance == "dark" ? .dark : .light }
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
        if kind.hasPrefix("measure-") {
            return await measure(owner, command: command, store: store)
        }
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
                guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                let interval = poster.beginInterval("Interaction", id: poster.makeSignpostID(), "kind=\(task, privacy: .public)")
                let start = ProcessInfo.processInfo.systemUptime
                var valid = true
                if task == "tab", let tabs = owner.session.snapshot?.tabs, tabs.count > 1 {
                    measurements["tabSelectionChanged", default: []].append(owner.session.snapshot?.selectedOccurrenceID == tabs[i % 2].occurrenceID ? 0 : 1)
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
                if task == "palette" {
                    guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                    owner.palette.dismiss(returnFocus: true)
                }
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
                        if let tab = tabs.first(where: { !$0.isSelected }) {
                            values["tabSelectionChanged", default: []].append(1)
                            ok = await select(tab.id)
                        }
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
    private static func threadCPU() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }

    private static func mainthread(_ owner: OrbitWindowController, command: [String: String], root: URL) async -> [String: Any] {
        guard ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-w2-mainthread"), let profile = owner.session.activeProfileID else { return ["ownershipRefused": true] }
        let kind = command["kind"] ?? "switches"
        var result: [String: Any] = [:]
        var maxGap = 0.0
        var lastBeat = ProcessInfo.processInfo.systemUptime
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
                let now = ProcessInfo.processInfo.systemUptime
                maxGap = max(maxGap, (now - lastBeat) * 1000)
                lastBeat = now
            }
        }
        defer { heartbeat.cancel() }
        if kind == "prepare" {
            for tab in owner.session.snapshot?.tabs.prefix(3) ?? [] {
                guard ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-w2-mainthread") else { return ["ownershipRefused": true] }
                owner.session.selectOccurrence(tab.occurrenceID)
                await owner.session.waitForQueuedCommands()
                if let surface = owner.session.selectedSurface { await waitForLoad(surface) }
            }
            return ["prepared": true]
        }
        if kind == "switches" {
            var counts: [String: Int] = [:]
            ChromiumSurface.snapshotProbe = { name, value in counts[name, default: 0] += name == "decodedBytes" ? value : 1 }
            defer { ChromiumSurface.snapshotProbe = nil }
            let cpu = threadCPU()
            let tabs = Array(owner.session.snapshot?.tabs.prefix(3) ?? [])
            for index in 0..<50 {
                guard ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-w2-mainthread"), tabs.count == 3 else { return ["ownershipRefused": true] }
                owner.session.selectOccurrence(tabs[index % tabs.count].occurrenceID)
                await owner.session.waitForQueuedCommands()
                try? await Task.sleep(for: .milliseconds(12))
            }
            try? await Task.sleep(for: .milliseconds(700))
            result["mainCPUms"] = (threadCPU() - cpu) * 1000
            result["captures"] = counts
            guard ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-w2-mainthread") else { return ["ownershipRefused": true] }
            owner.tabSwitcher.controlIsHeld = { true }
            owner.tabSwitcher.cycle()
            owner.tabSwitcher.show()
            try? await Task.sleep(for: .milliseconds(300))
            result["thumbnailCount"] = owner.session.ownedSurfaces.filter { owner.tabSwitcher.snapshots.image(for: $0) != nil }.count
        } else if kind == "downloads" {
            let files = root.appendingPathComponent("download-fixture")
            let records = await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
                return (0..<1000).map { index in
                    let url = files.appendingPathComponent("history-\(index).bin")
                    if index % 3 != 0 { try? Data([42]).write(to: url) }
                    return BrowserDownloadHistoryRecord(BrowserDownloadSnapshot(
                        key: .init(id: UUID(), profileID: profile, lifetime: UUID()), owner: .init(profileID: profile),
                        revision: 0, sequence: 1, suggestedFilename: "history-\(index).bin", state: .complete,
                        receivedBytes: 1, totalBytes: 1, capabilities: [], currentURL: nil, destinationURL: url,
                        fileAvailability: .unknown, failure: nil, pendingAction: nil, isCancellationRequested: false, controlError: nil))
                }
            }.value
            try? owner.downloads.coordinator.restore(records)
            guard ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-w2-mainthread") else { return ["ownershipRefused": true] }
            owner.tabSwitcher.cancel()
            // Measure a settled history as well as cold-open failure in the external harness.
            _ = owner.downloads.snapshots(profileID: profile)
            try? await Task.sleep(for: .milliseconds(500))
            guard ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-w2-mainthread") else { return ["ownershipRefused": true] }
            var cpu = threadCPU()
            let start = ProcessInfo.processInfo.systemUptime
            owner.showDownloads()
            await owner.session.waitForQueuedCommands()
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            owner.window?.displayIfNeeded()
            result["openCPUms"] = (threadCPU() - cpu) * 1000
            result["openWallMs"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
            try? await Task.sleep(for: .milliseconds(500))
            cpu = threadCPU()
            for n in 0..<20 {
                guard ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-w2-mainthread") else { return ["ownershipRefused": true] }
                let scroll = owner.downloadsPane.list.subviews.compactMap { $0 as? NSScrollView }.first
                if let scroll {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(n % 10) * 500))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                owner.renderDownloads()
                owner.window?.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(8))
            }
            result["scrollRefreshCPUms"] = (threadCPU() - cpu) * 1000
            owner.downloads.destinationProvider = { _, name in files.appendingPathComponent(name) }
            let before = owner.downloads.coordinator.allSnapshots.count
            cpu = threadCPU()
            if let base = command["fixture"].flatMap(URL.init(string:)) {
                for n in 0..<5 {
                    guard ownsWindow(owner, bundleID: "lab.orbit.orbit.perf-w2-mainthread") else { return ["ownershipRefused": true] }
                    owner.session.openTab(url: base.appendingPathComponent("download/\(n)"))
                    await owner.session.waitForQueuedCommands()
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                while ProcessInfo.processInfo.systemUptime < deadline {
                    let active = owner.downloads.coordinator.allSnapshots.dropFirst(before)
                    if active.count == 5 && active.allSatisfy({ $0.state.isTerminal }) { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            result["fiveDownloadsCPUms"] = (threadCPU() - cpu) * 1000
            result["downloadStates"] = owner.downloads.coordinator.allSnapshots.dropFirst(before).map { $0.state.rawValue }
            result["historyRows"] = owner.downloads.snapshots(profileID: profile).count
        } else if kind == "delete" {
            let id = ProfileID()
            let path = URL(fileURLWithPath: ChromiumRuntime.shared.rootCachePath).appendingPathComponent("profile-" + id.rawValue.uuidString.lowercased())
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                for n in 0..<20000 { try? Data([42]).write(to: path.appendingPathComponent("file-\(n)")) }
            }.value
            maxGap = 0; lastBeat = ProcessInfo.processInfo.systemUptime
            let cpu = threadCPU(), start = ProcessInfo.processInfo.systemUptime
            do {
                try await owner.engine.removeProfile(id)
                result["removed"] = !FileManager.default.fileExists(atPath: path.path)
                _ = owner.engine.profile(for: id)
                await owner.engine.profileReady(id)
                result["recreated"] = !owner.engine.refusedProfiles.contains(id)
                try await owner.engine.removeProfile(id)
            } catch { result["error"] = String(describing: error) }
            result["deleteCPUms"] = (threadCPU() - cpu) * 1000
            result["deleteWallMs"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        try? await Task.sleep(for: .milliseconds(10))
        result["longestMainGapMs"] = maxGap
        return result
    }
}

extension OrbitPerformanceProbe {
    private static let listsBundleID = "lab.orbit.orbit.perf-w2-lists"
    /// A fixed past instant keeps day headings and row times identical between runs.
    private static let listsBase = Date(timeIntervalSinceReferenceDate: 812_462_400)
    private static var listsThumbnailBytes = (resident: 0, peak: 0, accepted: 0)

    private static func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private static func viewCount(_ view: NSView) -> Int { view.subviews.reduce(1) { $0 + viewCount($1) } }

    private static func listViews(_ owner: OrbitWindowController, _ category: String) -> (root: NSView, scroll: NSScrollView?)? {
        switch category {
        case "downloads": return (owner.downloadsPane.list, owner.downloadsPane.list.subviews.compactMap { $0 as? NSScrollView }.first)
        case "media": return (owner.library.mediaView, owner.library.mediaView.scroll)
        case "history": return (owner.library.historyView, owner.library.historyView.table.enclosingScrollView)
        case "folder": return (owner.folderPreview.view, owner.folderPreview.view.scroll)
        default: return nil
        }
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    private static func listStats(_ owner: OrbitWindowController, _ category: String) -> [String: Any] {
        guard let views = listViews(owner, category) else { return [:] }
        var stats: [String: Any] = ["viewsAlive": viewCount(views.root), "footprintMiB": footprintMiB()]
        if let scroll = views.scroll {
            stats["documentHeight"] = scroll.documentView?.frame.height ?? 0
            stats["scrollY"] = scroll.contentView.bounds.origin.y
        }
        if category == "media" {
            stats["thumbnailResidentBytes"] = listsThumbnailBytes.resident
            stats["thumbnailPeakBytes"] = listsThumbnailBytes.peak
            stats["thumbnailAcceptedBytes"] = listsThumbnailBytes.accepted
            stats["mediaRows"] = owner.library.mediaView.rows.count
        }
        if category == "history" {
            stats["historyRows"] = owner.library.historyView.rows.count
            stats["historyReloads"] = owner.library.historyView.reloadCount
        }
        if category == "downloads" { stats["downloadTitles"] = owner.downloadsPane.list.displayedTitles.count }
        if category == "folder" { stats["folderResults"] = folderResults(owner).count }
        return stats
    }

    private static func folderResults(_ owner: OrbitWindowController) -> [FolderPreviewResult] {
        guard let folder = owner.sidebar.page.folderRows.first?.node.folderID,
              case let .folder(root)? = owner.session.organization?.item(for: .folder(folder)) else { return [] }
        return FolderPreviewResult.ordered(root.children)
    }

    private static func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    /// Synthetic long lists: seeds downloads, media and history, opens a list, scrolls it and
    /// reports main-thread time, live views, thumbnail bytes and footprint. No content leaves it.
    private static func lists(_ owner: OrbitWindowController, command: [String: String], root: URL) async -> [String: Any] {
        guard ownsWindow(owner, bundleID: listsBundleID), let profile = owner.session.activeProfileID else { return ["ownershipRefused": true] }
        let kind = command["kind"] ?? ""
        let category = command["category"] ?? ""
        let count = Int(command["count"] ?? "") ?? 1000
        var result: [String: Any] = [:]
        BrowserLibraryMediaView.thumbnailBytesProbe = { delta in
            listsThumbnailBytes.resident += delta
            listsThumbnailBytes.peak = max(listsThumbnailBytes.peak, listsThumbnailBytes.resident)
            if delta > 0 { listsThumbnailBytes.accepted += delta }
        }
        switch kind {
        case "appearance":
            NSApp.appearance = NSAppearance(named: command["value"] == "dark" ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(300))
        case "theme":
            guard let space = owner.session.snapshot?.activeSpaceID else { return ["error": "space"] }
            let colors = (command["colors"] ?? "").split(separator: ",").compactMap { BrowserThemeColor(hexString: String($0)) }
            do { _ = try await owner.session.setSpaceTheme(.radial(colors: colors, intensity: 0.78), for: space, profileID: profile) }
            catch { return ["error": "theme"] }
            try? await Task.sleep(for: .milliseconds(500))
        case "seed-downloads", "seed-media":
            let media = kind == "seed-media"
            let files = root.appendingPathComponent(media ? "media-fixture" : "download-fixture")
            let base = listsBase
            let records = await Task.detached(priority: .utility) { () -> [BrowserDownloadHistoryRecord] in
                try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
                let extensions = ["pdf", "zip", "txt", "dmg", "bin", "csv"]
                var images: [Data] = []
                if media {
                    for variant in 0..<8 {
                        let space = CGColorSpace(name: CGColorSpace.sRGB)!
                        guard let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                        let hue = CGFloat(variant) / 8
                        context.setFillColor(NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).cgColor)
                        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
                        context.setFillColor(NSColor(hue: 1 - hue, saturation: 0.7, brightness: 0.5, alpha: 1).cgColor)
                        context.fillEllipse(in: CGRect(x: 150 + variant * 20, y: 80, width: 240, height: 240))
                        let data = NSMutableData()
                        if let image = context.makeImage(),
                           let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) {
                            CGImageDestinationAddImage(destination, image, nil)
                            if CGImageDestinationFinalize(destination) { images.append(data as Data) }
                        }
                    }
                }
                return (0..<count).map { index in
                    let name = media ? "Synthetic image \(index).png" : "Synthetic file \(index).\(extensions[index % extensions.count])"
                    let url = files.appendingPathComponent(name)
                    let bytes = media ? images[index % max(1, images.count)] : Data([42])
                    if media || index % 3 != 0 { try? bytes.write(to: url) }
                    let started = base.addingTimeInterval(-Double(index) * (media ? 60 : 1500))
                    return BrowserDownloadHistoryRecord(BrowserDownloadSnapshot(
                        key: .init(id: UUID(), profileID: profile, lifetime: UUID()), owner: .init(profileID: profile),
                        revision: 0, sequence: 1, suggestedFilename: name, state: .complete,
                        receivedBytes: Int64(bytes.count), totalBytes: Int64(bytes.count), capabilities: [], currentURL: nil,
                        destinationURL: url, fileAvailability: .unknown, failure: nil, pendingAction: nil,
                        isCancellationRequested: false, controlError: nil, startedAt: started, completedAt: started))
                }
            }.value
            do { try owner.downloads.coordinator.restore(records) } catch { return ["error": "restore"] }
            // Settle file availability the way an open panel would, before measuring.
            _ = owner.downloads.snapshots(profileID: profile)
            try? await Task.sleep(for: .milliseconds(1500))
            _ = owner.downloads.snapshots(profileID: profile)
            try? await Task.sleep(for: .milliseconds(500))
            result["records"] = records.count
        case "seed-history":
            let base = listsBase
            let visits = (0..<count).map { index in
                BrowserHistoryVisit(url: URL(string: "http://127.0.0.1/history/\(index)")!, title: "Synthetic visit \(index)",
                                    visitedAt: base.addingTimeInterval(-Double(index) * 300), transition: .link)
            }
            do { result["imported"] = try await owner.library.history.recorder.importDocument(BrowserHistoryDocument(profileID: profile, visits: visits)) }
            catch { return ["error": "history"] }
        case "open":
            owner.tabSwitcher.cancel()
            let before = footprintMiB()
            let cpu = threadCPU(), start = ProcessInfo.processInfo.systemUptime
            switch category {
            case "downloads": owner.showDownloads()
            case "media": owner.showLibrary(.media)
            case "history": owner.showLibrary(.history)
            case "folder":
                guard let row = owner.sidebar.page.folderRows.first else { return ["error": "folder"] }
                owner.folderPreview.hover(row, inside: true)
            default: return ["error": "category"]
            }
            await owner.session.waitForQueuedCommands()
            if category == "history" {
                result["settled"] = await waitUntil(10) { !owner.library.history.isLoading && !owner.library.historyView.rows.isEmpty }
            }
            if category == "folder" {
                result["presentedByHover"] = await waitUntil(1.5) { owner.folderPreview.isPresented }
                if !owner.folderPreview.isPresented, let row = owner.sidebar.page.folderRows.first, let host = row.window?.contentView {
                    result["hoverDiagnostics"] = ["keyWindow": row.window?.isKeyWindow == true, "allowed": owner.folderPreview.allowed(),
                                                  "phase": String(describing: owner.folderPreview.intent.phase)]
                    // The hover intent declined (e.g. the synthetic window is not key): present the
                    // same view with the same results and favicon resolver directly.
                    let cpu = threadCPU()
                    let view = owner.folderPreview.view
                    let results = folderResults(owner)
                    view.search.stringValue = ""
                    view.title.stringValue = (row as? SidebarFolderRow)?.item.title ?? ""
                    host.addSubview(view, positioned: .above, relativeTo: nil)
                    view.frame = FolderPreviewGeometry.frame(anchor: row.convert(row.visibleRect, to: host), viewport: host.bounds,
                                                             flipped: host.isFlipped, count: results.count)
                    view.render(results, image: { owner.folderPreview.favicon($0.tab) })
                    view.animateAppearance()
                    owner.window?.contentView?.layoutSubtreeIfNeeded()
                    owner.window?.displayIfNeeded()
                    result["directOpenCPUms"] = (threadCPU() - cpu) * 1000
                }
                result["settled"] = owner.folderPreview.isPresented
            }
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            owner.window?.displayIfNeeded()
            result["openCPUms"] = (threadCPU() - cpu) * 1000
            result["openWallMs"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
            result["footprintBeforeMiB"] = before
            try? await Task.sleep(for: .milliseconds(1200))
            result.merge(listStats(owner, category)) { $1 }
        case "scroll":
            guard let scroll = listViews(owner, category)?.scroll else { return ["error": "scroll"] }
            let y = CGFloat(Double(command["y"] ?? "") ?? 0)
            let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, maxY)))
            scroll.reflectScrolledClipView(scroll.contentView)
            owner.window?.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(1500))
            result.merge(listStats(owner, category)) { $1 }
        case "steps":
            guard let scroll = listViews(owner, category)?.scroll else { return ["error": "scroll"] }
            let steps = Int(command["steps"] ?? "") ?? 600
            let stride = CGFloat(Double(command["stride"] ?? "") ?? 120)
            var cpuSteps: [Double] = [], wallSteps: [Double] = []
            let total = threadCPU()
            for step in 0..<steps {
                guard step % 50 != 0 || ownsWindow(owner, bundleID: listsBundleID) else { return ["ownershipRefused": true] }
                let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
                let y = maxY > 0 ? (CGFloat(step + 1) * stride).truncatingRemainder(dividingBy: maxY) : 0
                let cpu = threadCPU(), start = ProcessInfo.processInfo.systemUptime
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                owner.window?.displayIfNeeded()
                cpuSteps.append((threadCPU() - cpu) * 1000)
                wallSteps.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                try? await Task.sleep(for: .milliseconds(4))
            }
            result["stepsCPUms"] = (threadCPU() - total) * 1000
            result["stepCPUp50"] = percentile(cpuSteps, 0.5)
            result["stepCPUp95"] = percentile(cpuSteps, 0.95)
            result["stepCPUmax"] = cpuSteps.max() ?? 0
            result["stepWallp95"] = percentile(wallSteps, 0.95)
            result["stepWallmax"] = wallSteps.max() ?? 0
            try? await Task.sleep(for: .milliseconds(800))
            result.merge(listStats(owner, category)) { $1 }
        case "loadmore":
            let model = owner.library.history, view = owner.library.historyView
            guard let scroll = view.table.enclosingScrollView else { return ["error": "scroll"] }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 2600))
            scroll.reflectScrolledClipView(scroll.contentView)
            owner.window?.displayIfNeeded()
            func anchor() -> (UUID?, CGFloat) {
                let point = NSPoint(x: 1, y: scroll.contentView.bounds.minY + 40)
                let row = view.table.row(at: point)
                guard view.rows.indices.contains(row), case let .visit(visit) = view.rows[row] else { return (nil, 0) }
                return (visit.id, view.table.rect(ofRow: row).minY - scroll.contentView.bounds.minY)
            }
            if let index = view.rows.firstIndex(where: { if case .visit = $0 { return true }; return false }).map({ $0 + 10 }) {
                view.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            let selected = view.selectedVisit?.id
            let initial = anchor()
            var pages: [Double] = []
            var stable = true
            let reloads = view.reloadCount
            let total = threadCPU()
            while model.hasMore {
                guard ownsWindow(owner, bundleID: listsBundleID) else { return ["ownershipRefused": true] }
                let cpu = threadCPU()
                model.loadMore()
                guard await waitUntil(10, { !model.isLoading }) else { result["timeout"] = true; break }
                owner.window?.displayIfNeeded()
                pages.append((threadCPU() - cpu) * 1000)
                let current = anchor()
                if current.0 != initial.0 || abs(current.1 - initial.1) > 0.001 { stable = false }
            }
            result["loadMoreCPUms"] = (threadCPU() - total) * 1000
            result["pages"] = pages.count
            result["pageCPUp95"] = percentile(pages, 0.95)
            result["pageCPUmax"] = pages.max() ?? 0
            result["pageCPUlast"] = pages.last ?? 0
            result["anchorStable"] = stable && initial.0 != nil
            result["selectionKept"] = selected != nil && view.selectedVisit?.id == selected
            result["fullReloadsDuringLoadMore"] = view.reloadCount - reloads
            result.merge(listStats(owner, category)) { $1 }
        case "folder-input":
            let view = owner.folderPreview.view
            guard owner.folderPreview.isPresented else { return ["error": "folder"] }
            let editor = NSTextView()
            var moves: [Double] = []
            for _ in 0..<40 {
                let cpu = threadCPU()
                _ = view.control(view.search, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
                owner.window?.displayIfNeeded()
                moves.append((threadCPU() - cpu) * 1000)
            }
            result["selectionMoveCPUp95"] = percentile(moves, 0.95)
            result["selectionMoveCPUmax"] = moves.max() ?? 0
            var searches: [Double] = []
            // The intent's search sequence: rows turn inert at once, then the filtered results arrive.
            let all = folderResults(owner)
            for term in ["Synthetic", "Synthetic tab 1", "Synthetic"] {
                let cpu = threadCPU()
                view.search.stringValue = term
                view.render([], image: { _ in nil })
                owner.window?.displayIfNeeded()
                view.render(all.filter { $0.title.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil },
                            image: { owner.folderPreview.favicon($0.tab) })
                owner.window?.displayIfNeeded()
                searches.append((threadCPU() - cpu) * 1000)
            }
            view.search.stringValue = ""
            result["searchCPUms"] = searches
            result.merge(listStats(owner, category)) { $1 }
        case "transfers":
            guard let base = command["fixture"].flatMap(URL.init(string:)) else { return ["error": "fixture"] }
            let files = root.appendingPathComponent("transfer-fixture")
            try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            owner.downloads.destinationProvider = { _, name in files.appendingPathComponent(name) }
            let before = owner.downloads.coordinator.allSnapshots.count
            let cpu = threadCPU()
            for n in 0..<5 {
                guard ownsWindow(owner, bundleID: listsBundleID) else { return ["ownershipRefused": true] }
                owner.session.openTab(url: base.appendingPathComponent("download/\(n)"))
                await owner.session.waitForQueuedCommands()
            }
            // The list stays presented while the transfers run.
            if !owner.library.isPresented || owner.library.category != .downloads { owner.showDownloads() }
            let finished = await waitUntil(20) {
                let active = owner.downloads.coordinator.allSnapshots.dropFirst(before)
                return active.count == 5 && active.allSatisfy { $0.state.isTerminal }
            }
            result["fiveDownloadsCPUms"] = (threadCPU() - cpu) * 1000
            result["finished"] = finished
            result["downloadStates"] = owner.downloads.coordinator.allSnapshots.dropFirst(before).map { $0.state.rawValue }
            result.merge(listStats(owner, "downloads")) { $1 }
        case "stats":
            result.merge(listStats(owner, category)) { $1 }
        default:
            return ["error": "kind"]
        }
        return result
    }

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

extension OrbitPerformanceProbe {
    private static var drawCounterInstalled = false
    /// Install the counter only in an admitted probe process, leaving shared theme sources alone.
    private static func installDrawCounter() {
        guard !drawCounterInstalled,
              let original = class_getInstanceMethod(OrbitGlyphButton.self, #selector(NSView.draw(_:))),
              let replacement = class_getInstanceMethod(OrbitGlyphButton.self, #selector(OrbitGlyphButton.perfDraw(_:))) else { return }
        method_exchangeImplementations(original, replacement)
        drawCounterInstalled = true
    }

    private static func history(_ surface: ChromiumSurface) async -> [String: Any]? {
        let (ok, data) = await surface.devToolsCall("Page.getNavigationHistory")
        guard ok, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]], let index = json["currentIndex"] else { return nil }
        // Compare internally; never publish the destinations or titles.
        return ["index": index, "entries": entries.map { $0["url"] as? String ?? "" }]
    }
    private struct WakeTrial {
        let id: TabOccurrenceID
        let surface: ChromiumSurface
        let state: BrowserNavigationState
        let history: NSDictionary
    }
    private static var wakeTrial: WakeTrial?

    private static func measure(_ owner: OrbitWindowController, command: [String: String], store: BrowserStore) async -> [String: Any] {
        guard ownsWindow(owner) else { return ["ownershipRefused": true] }
        let kind = command["kind"] ?? ""
        let document = await store.sessionDocument()
        func settle(_ milliseconds: Int = 350) async {
            await owner.session.waitForQueuedCommands()
            try? await Task.sleep(for: .milliseconds(milliseconds))
            await owner.session.waitForPendingCommands()
            owner.window?.displayIfNeeded(); CATransaction.flush()
        }
        func select(_ id: TabOccurrenceID) async -> ChromiumSurface? {
            guard ownsWindow(owner) else { return nil }
            owner.session.selectOccurrence(id)
            await owner.session.waitForQueuedCommands()
            guard let surface = owner.session.selectedSurface else { return nil }
            await waitForLoad(surface)
            return surface
        }
        if kind == "measure-prepare" {
            var loaded = 0
            for space in document.spaces.prefix(Int(command["spaces"] ?? "5") ?? 5) {
                guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                owner.session.activateSpace(space.id)
                await owner.session.waitForQueuedCommands()
                for tab in (owner.session.snapshot?.tabs ?? []).prefix(2) {
                    if await select(tab.occurrenceID) != nil { loaded += 1 }
                }
            }
            guard ownsWindow(owner) else { return ["ownershipRefused": true] }
            owner.session.activateSpace(document.spaces[0].id)
            await settle(700)
            return ["loaded": loaded, "surfaces": owner.session.ownedSurfaces.count]
        }
        if kind == "measure-tabs" {
            var values: [String: [Double]] = [:]
            let tabs = owner.session.snapshot?.tabs ?? []
            guard tabs.count >= 2 else { return ["failures": [1]] }
            for tab in tabs.prefix(2) { _ = await select(tab.occurrenceID) }
            await settle()
            for i in 0..<(Int(command["count"] ?? "20") ?? 20) {
                if command["paletteWait"] != nil {
                    guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                    owner.palette.present(.newTab)
                    await owner.palette.waitForResults()
                    guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                    owner.palette.view.input.stringValue = "x"
                    owner.palette.view.onQuery?("x")
                    await owner.palette.waitForResults()
                    guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                    owner.palette.dismiss(returnFocus: true)
                    if command["paletteWait"] == "settled" { await settle(350) }
                }
                guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                if command["spaceWait"] != nil, document.spaces.count > 1 {
                    let active = owner.session.snapshot?.activeSpaceID
                    let index = document.spaces.firstIndex { $0.id == active } ?? 0
                    owner.session.activateSpace(document.spaces[(index+1) % 2].id)
                    await owner.session.waitForQueuedCommands()
                    if command["spaceWait"] == "settled" {
                        while owner.sidebar.isSpaceTransitionAnimating { try? await Task.sleep(for: .milliseconds(2)) }
                    }
                }
                let currentTabs = owner.session.snapshot?.tabs ?? tabs
                guard let tab = currentTabs.prefix(2).first(where: { $0.occurrenceID != owner.session.snapshot?.selectedOccurrenceID }) else { return ["failures": [1]] }
                guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                let start = ProcessInfo.processInfo.systemUptime
                let target = command["path"] == "noop" ? owner.session.snapshot?.selectedOccurrenceID ?? tab.occurrenceID : tab.occurrenceID
                values["tabSelectionChanged", default: []].append(target == owner.session.snapshot?.selectedOccurrenceID ? 0 : 1)
                if command["path"] == "occurrence" || command["path"] == "noop" { owner.session.selectOccurrence(target) }
                else { owner.session.selectTab(tab.id) }
                await owner.session.waitForQueuedCommands()
                let queued = ProcessInfo.processInfo.systemUptime
                guard let surface = owner.session.selectedSurface else { return ["failures": [1]] }
                let deadline = queued + 5
                while !surface.isReady || surface.navigationState.isLoading {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { return ["failures": [1]] }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                let loaded = ProcessInfo.processInfo.systemUptime
                let ok = await nextPageFrame(surface)
                let frame = ProcessInfo.processInfo.systemUptime
                values["queueMs", default: []].append((queued-start)*1000)
                values["loadWaitMs", default: []].append((loaded-queued)*1000)
                values["frameWaitMs", default: []].append((frame-loaded)*1000)
                values["tabMs", default: []].append((frame-start)*1000)
                if !ok { values["failures", default: []].append(1) }
            }
            return values
        }
        if kind == "measure-counters" {
            let tabs = owner.session.snapshot?.tabs ?? []
            guard tabs.count >= 2 else { return ["failures": [1]] }
            _ = await select(tabs[0].occurrenceID)
            guard let background = await select(tabs[1].occurrenceID) else { return ["failures": [1]] }
            _ = await select(tabs[0].occurrenceID)
            await settle(700)
            var results: [String: Any] = [:]
            for action in ["title", "favicon", "navigation", "tab", "space", "character"] {
                guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                if action == "character" { owner.palette.present(.newTab); await owner.palette.waitForResults(); await settle() }
                guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                BrowserPerformance.resetCounters()
                var valid = true
                if action == "title" {
                    valid = await evaluate(background, "(() => {document.title='Synthetic changed'; return {ok: true};})()")?["ok"] as? Bool == true
                } else if action == "favicon" {
                    valid = await evaluate(background, "(() => {let l=document.querySelector('link[rel=icon]') || document.head.appendChild(document.createElement('link'));l.rel='icon';l.href='/icon.svg?changed=1';return {ok:true};})()")?["ok"] as? Bool == true
                } else if action == "navigation", let url = owner.session.selectedSurface?.currentURL {
                    owner.session.selectedSurface?.navigate(to: url.appendingPathComponent("next"))
                    if let surface = owner.session.selectedSurface { await waitForLoad(surface) }
                } else if action == "tab" { owner.session.selectOccurrence(tabs[1].occurrenceID) }
                else if action == "space", document.spaces.count > 1 { owner.session.activateSpace(document.spaces[1].id) }
                else if action == "character" {
                    owner.palette.view.input.stringValue = "x"
                    owner.palette.view.onQuery?("x")
                    await owner.palette.waitForResults()
                    valid = owner.palette.draft == "x"
                }
                await settle(800)
                results[action] = ["counters": BrowserPerformance.counters, "valid": valid]
            }
            guard ownsWindow(owner) else { return ["ownershipRefused": true] }
            owner.palette.dismiss(returnFocus: true)
            return results
        }
        if kind == "measure-wake-prepare" {
            let tabs = owner.session.snapshot?.tabs ?? []
            let index = Int(command["index"] ?? "1") ?? 1
            guard tabs.indices.contains(index), let surface = await select(tabs[index].occurrenceID), let base = surface.currentURL else { return ["failures": [1]] }
            if command["history"] == "1" {
                surface.navigate(to: base.appendingPathComponent("second")); await waitForLoad(surface)
                surface.navigate(to: base.appendingPathComponent("third")); await waitForLoad(surface)
                _ = surface.goBack(); await waitForLoad(surface)
            }
            await settle(500)
            let iconDeadline = ProcessInfo.processInfo.systemUptime + 2
            while surface.navigationState.faviconImage == nil && ProcessInfo.processInfo.systemUptime < iconDeadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let history = await history(surface) else { return ["failures": [1]] }
            wakeTrial = WakeTrial(id: tabs[index].occurrenceID, surface: surface, state: surface.navigationState, history: history as NSDictionary)
            _ = await select(tabs[0].occurrenceID)
            await settle(500)
            return ["prepared": true]
        }
        if kind == "measure-discard", let trial = wakeTrial {
            let count = await owner.tabSuspension.sweep(now: ProcessInfo.processInfo.systemUptime + 86401)
            return ["discarded": trial.surface.isSuspended, "count": count, "sameSurface": owner.session.surface(for: trial.id) === trial.surface]
        }
        if kind == "measure-wake", let trial = wakeTrial {
            guard ownsWindow(owner), trial.surface.isSuspended else { return ["failures": [1]] }
            let start = ProcessInfo.processInfo.systemUptime
            owner.session.selectOccurrence(trial.id)
            await owner.session.waitForQueuedCommands()
            var frame = await nextPageFrame(trial.surface)
            let frameDeadline = start + 5
            while !frame && ProcessInfo.processInfo.systemUptime < frameDeadline {
                try? await Task.sleep(for: .milliseconds(2))
                frame = await nextPageFrame(trial.surface)
            }
            let frameEnd = ProcessInfo.processInfo.systemUptime
            await waitForLoad(trial.surface)
            var paint: Double?
            let deadline = start + 5
            while paint == nil && ProcessInfo.processInfo.systemUptime < deadline {
                let value = await evaluate(trial.surface, "(() => {const p=performance.getEntriesByType('paint').find(p=>p.name==='first-contentful-paint');return p?{age:(Date.now()-performance.timeOrigin-p.startTime)/1000}:{};})()")
                if let age = value?["age"] as? Double { paint = ProcessInfo.processInfo.systemUptime-age }
                else { try? await Task.sleep(for: .milliseconds(5)) }
            }
            await settle(150)
            let iconDeadline = ProcessInfo.processInfo.systemUptime + 2
            while trial.surface.navigationState.faviconImage == nil && ProcessInfo.processInfo.systemUptime < iconDeadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            let state = trial.surface.navigationState
            let afterHistory = await history(trial.surface)
            let visible = trial.surface.hostView.window === owner.window && !trial.surface.hostView.isHiddenOrHasHiddenAncestor
            return ["frameMs": (frameEnd-start)*1000, "contentPaintMs": paint.map { ($0-start)*1000 } ?? -1,
                    "valid": frame && (paint.map { $0 >= start } ?? false) && visible && !trial.surface.isSuspended,
                    "faviconBefore": trial.state.faviconImage != nil, "faviconAfter": state.faviconImage != nil,
                    "faviconSourcePreserved": state.faviconURL == trial.state.faviconURL,
                    "backBefore": trial.state.canGoBack, "forwardBefore": trial.state.canGoForward,
                    "historyEntries": (afterHistory?["entries"] as? [String])?.count ?? 0,
                    "titlePreserved": state.title == trial.state.title,
                    "urlPreserved": state.committedURL == trial.state.committedURL,
                    "faviconPreserved": state.faviconImage?.png == trial.state.faviconImage?.png && state.faviconImage != nil,
                    "historyPreserved": afterHistory.map { trial.history.isEqual(to: $0) } ?? false,
                    "backPreserved": state.canGoBack == trial.state.canGoBack,
                    "forwardPreserved": state.canGoForward == trial.state.canGoForward,
                    "sameSurface": owner.session.surface(for: trial.id) === trial.surface]
        }
        return ["unknownKind": kind]
    }
}

extension OrbitGlyphButton {
    @objc fileprivate func perfDraw(_ rect: NSRect) {
        BrowserPerformance.count(.glyphDraws)
        perfDraw(rect)
    }
}


extension OrbitPerformanceProbe {
    /// Synthetic glyph attribution: draw causes per display frame, deterministic theme frames and a
    /// state/scale fixture. Every action refuses a window this process does not own.
    private static func glyphDiagnostics(_ owner: OrbitWindowController, root: URL, store: BrowserStore,
                                         command: [String: String]) async -> [String: Any] {
        guard ownsWindow(owner), let window = owner.window, let content = window.contentView else { return ["ownershipRefused": true] }
        OrbitUIWorkCounters.enabled = true
        func counters() -> [String: Int] { OrbitUIWorkCounters.values.filter { !$0.key.contains("ObjectIdentifier") } }
        switch command["action"] {
        case "reset":
            OrbitUIWorkCounters.reset()
            return [:]
        case "status":
            func layers(_ layer: CALayer) -> Int { 1 + (layer.mask.map(layers) ?? 0) + (layer.sublayers ?? []).reduce(0) { $0 + layers($1) } }
            return ["layers": (content.superview?.layer ?? content.layer).map(layers) ?? 0]
        case "front":
            // Motion runs only for an unoccluded window; raise the owned window for this GUI lease.
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(400))
            return ["occluded": !window.occlusionState.contains(.visible), "key": window.isKeyWindow]
        case "frames":
            // Snapshot glyph counters on every display frame of one Space switch.
            let document = await store.sessionDocument()
            guard let index = Int(command["index"] ?? ""), document.spaces.indices.contains(index) else { return ["badIndex": true] }
            OrbitUIWorkCounters.reset()
            let sampler = OrbitGlyphFrameSampler()
            let occluded = !window.occlusionState.contains(.visible)
            let link = content.displayLink(target: sampler, selector: #selector(OrbitGlyphFrameSampler.tick(_:)))
            link.add(to: .main, forMode: .common)
            let start = ProcessInfo.processInfo.systemUptime
            owner.session.activateSpace(document.spaces[index].id)
            await owner.session.waitForQueuedCommands()
            try? await Task.sleep(for: .milliseconds(30))
            while owner.sidebar.isSpaceTransitionAnimating && ProcessInfo.processInfo.systemUptime < start + 3 {
                try? await Task.sleep(for: .milliseconds(2))
            }
            let animated = ProcessInfo.processInfo.systemUptime - start
            let span = Double(command["window"] ?? "") ?? 1
            try? await Task.sleep(for: .milliseconds(Int(max(0.15, start + span - ProcessInfo.processInfo.systemUptime) * 1000)))
            link.invalidate()
            sampler.tick(nil)
            return ["frames": sampler.frames, "start": start, "animatedSeconds": animated, "occluded": occluded,
                    "totals": counters()]
        case "blend":
            // A deterministic Space theme frame through the production swipe paint path.
            let document = await store.sessionDocument()
            guard let active = owner.session.snapshot?.activeSpaceID,
                  let other = document.spaces.first(where: { $0.id != active }) else { return ["badSpaces": true] }
            OrbitUIWorkCounters.reset()
            if command["progress"] == "clear" {
                owner.sidebar.spaceSwipe.onThemeProgress?(nil)
            } else {
                let progress = CGFloat(Double(command["progress"] ?? "") ?? 0.5)
                owner.sidebar.spaceSwipe.onThemeProgress?(SpaceSwipeThemeBlend(source: owner.resolvedSpaceTheme(for: active),
                    destination: owner.resolvedSpaceTheme(for: other.id), progress: progress))
            }
            window.displayIfNeeded(); CATransaction.flush()
            return ["counters": counters()]
        case "fixture":
            let identifier = NSUserInterfaceItemIdentifier("synthetic-glyph-fixture")
            content.subviews.filter { $0.identifier == identifier }.forEach { $0.removeFromSuperview() }
            if command["remove"] == "true" { window.displayIfNeeded(); CATransaction.flush(); return ["removed": true] }
            let fixture = NSView(frame: NSRect(x: 10, y: 60, width: 960, height: 600))
            fixture.identifier = identifier
            fixture.wantsLayer = true
            fixture.layer?.backgroundColor = NSColor.white.cgColor
            fixture.appearance = NSAppearance(named: command["appearance"] == "dark" ? .darkAqua : .aqua)
            let source = OrbitTokens.SpaceTheme(stops: [NSColor(srgbRed: 32.0/255, green: 63.0/255, blue: 152.0/255, alpha: 1)], mode: .automatic, texture: .none, textureIntensity: 0)
            let destination = OrbitTokens.SpaceTheme(stops: [NSColor(srgbRed: 184.0/255, green: 244.0/255, blue: 120.0/255, alpha: 1)], mode: .automatic, texture: .none, textureIntensity: 0)
            var themes: [OrbitTokens.SpaceTheme] = [.default, source, destination]
            for seconds in [0.035, 0.07, 0.12, 0.184, 0.3] {
                themes.append(SpaceSwipeThemeBlend(source: source, destination: destination,
                    progress: CGFloat(OrbitThemeTransition.progress(at: seconds))).theme)
            }
            for progress: CGFloat in [0.1, 0.35, 0.65, 0.9] {
                themes.append(SpaceSwipeThemeBlend(source: source, destination: destination, progress: progress).theme)
            }
            let glyphs = [OrbitGlyph.back, OrbitGlyph.forward, OrbitGlyph.reload, OrbitGlyph.close, OrbitGlyph.newTab,
                          OrbitGlyph.sidebarToggle, OrbitGlyph.faviconPlaceholder, OrbitGlyph.siteControlCenter]
            for (index, theme) in themes.enumerated() {
                let panel = NSView(frame: NSRect(x: (index % 3) * 320, y: (index / 3) * 150, width: 320, height: 150))
                panel.wantsLayer = true
                panel.layer?.backgroundColor = theme.stops[0].cgColor
                fixture.addSubview(panel)
                let accent = OrbitSpaceThemes.accent(for: theme)
                for state in 0..<4 {
                    for (column, glyph) in glyphs.enumerated() {
                        let button = OrbitGlyphButton(glyph: glyph, label: "Synthetic glyph")
                        // Odd columns sit on quarter-point positions, like a page mid-slide.
                        button.frame = NSRect(x: CGFloat(column * 38) + (column % 2 == 1 ? 0.25 : 0), y: CGFloat(state * 36), width: 32, height: 32)
                        button.tint = accent.icon
                        button.disabledTint = accent.foreground.withAlphaComponent(0.25)
                        button.isEnabled = state != 1
                        button.isHighlighted = state == 3
                        if state == 2 { button.mouseEntered(with: NSEvent()) }
                        panel.addSubview(button)
                    }
                }
            }
            content.addSubview(fixture)
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            // A 1x bitmap of the attached fixture supplements the physical 2x display capture.
            if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 960, pixelsHigh: 600,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
               let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                bitmap.size = fixture.bounds.size
                fixture.displayIgnoringOpacity(fixture.bounds, in: context)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: root.appendingPathComponent("glyph-fixture-1x.png"))
                }
            }
            return ["scale": window.backingScaleFactor, "buttons": themes.count * 4 * glyphs.count,
                    "colorSpace": window.colorSpace?.localizedName ?? "unknown"]
        default:
            return ["counters": counters()]
        }
    }
}

@MainActor
private final class OrbitGlyphFrameSampler: NSObject {
    private var last: [String: Int] = [:]
    private(set) var frames: [[String: Any]] = []
    @objc func tick(_ link: CADisplayLink?) {
        let current = OrbitUIWorkCounters.values.filter { $0.key.hasPrefix("glyphDraw") }
        var delta: [String: Int] = [:]
        for (key, value) in current where value != last[key, default: 0] { delta[key] = value - last[key, default: 0] }
        last = current
        guard !delta.isEmpty || !frames.isEmpty else { return }
        frames.append(["t": link?.timestamp ?? CACurrentMediaTime(), "delta": delta])
    }
}

extension OrbitPerformanceProbe {
    /// Space page slide diagnostics: per-frame native/visible positions, accessibility and hit-test
    /// geometry of the moving pages, glyph draws, and input dispatched mid-slide. Synthetic only.
    private static func spaceCompositing(_ owner: OrbitWindowController, store: BrowserStore,
                                         command: [String: String]) async -> [String: Any] {
        guard ownsWindow(owner), let window = owner.window, let content = window.contentView else { return ["ownershipRefused": true] }
        OrbitUIWorkCounters.enabled = true
        let sidebar = owner.sidebar
        let document = await store.sessionDocument()
        let occluded = !window.occlusionState.contains(.visible)
        switch command["action"] {
        case "elements":
            return ["occluded": occluded, "pages": SpaceCompositingProbe.pages(sidebar, window: window)]
        case "phase":
            // Hold swipe presentations at successive offsets so earlier positions were painted first.
            guard let active = owner.session.snapshot?.activeSpaceID,
                  let index = document.spaces.firstIndex(where: { $0.id == active }) else { return ["badSpaces": true] }
            let offsets = (command["offsets"] ?? "").split(separator: ",").compactMap { Double($0) }
            let forward = offsets.last.map { $0 < 0 } ?? true
            let targetIndex = forward ? index + 1 : index - 1
            guard document.spaces.indices.contains(targetIndex) else { return ["badSpaces": true] }
            let target = document.spaces[targetIndex]
            OrbitUIWorkCounters.reset()
            for offset in offsets {
                guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                sidebar.showSpaceSwipe(offset: CGFloat(offset), space: target,
                    content: SpaceSwipePreview.content(document: document, spaceID: target.id, windowID: sidebar.organization?.windowID, icon: sidebar.previewIcon),
                    favorites: SpaceSwipePreview.favorites(document: document, spaceID: target.id, windowID: sidebar.organization?.windowID, icon: sidebar.previewIcon))
                window.displayIfNeeded(); CATransaction.flush()
                try? await Task.sleep(for: .milliseconds(40))
            }
            return ["occluded": occluded, "offset": offsets.last ?? 0, "pages": SpaceCompositingProbe.pages(sidebar, window: window),
                    "clipped": sidebar.compositedSpaceViews.count, "counters": OrbitUIWorkCounters.values.filter { $0.key.hasPrefix("glyphDraw") }]
        case "mixed":
            // The mixed 10 s workload with per-frame occlusion; occluded samples are discarded by the harness.
            let sampler = SpaceCompositingProbe.Sampler(sidebar: sidebar, window: window)
            let link = content.displayLink(target: sampler, selector: #selector(SpaceCompositingProbe.Sampler.tick(_:)))
            link.add(to: .main, forMode: .common)
            let values = await uiQuickWins(owner, store: store, command: ["action": "mixed"])
            link.invalidate()
            return ["values": values, "occluded": occluded, "endOccluded": !window.occlusionState.contains(.visible),
                    "occludedFrames": sampler.frames.filter { $0["occluded"] as? Bool == true }.count, "frames": sampler.frames.count]
        case "repaint":
            // Repaint every sidebar view at its current position, once per display cycle.
            for _ in 0..<(Int(command["count"] ?? "") ?? 1) {
                guard ownsWindow(owner) else { return ["ownershipRefused": true] }
                for view in SpaceCompositingProbe.descendants(sidebar) { view.needsDisplay = true }
                window.displayIfNeeded(); CATransaction.flush()
                try? await Task.sleep(for: .milliseconds(60))
            }
            return ["occluded": occluded]
        case "phase-end":
            sidebar.finishSpaceSwipe(committed: nil)
            window.displayIfNeeded(); CATransaction.flush()
            return ["occluded": occluded, "clipped": sidebar.compositedSpaceViews.count]
        case "switch":
            guard let mode = command["mode"], let index = Int(command["index"] ?? ""), document.spaces.indices.contains(index) else { return ["badIndex": true] }
            let initial = owner.session.snapshot?.activeSpaceID
            let initialSelection = owner.session.snapshot?.selectedOccurrenceID
            OrbitUIWorkCounters.reset()
            SpaceCompositingProbe.installNewTabDrawLog()
            SpaceCompositingProbe.newTabDraws.removeAll()
            let sampler = SpaceCompositingProbe.Sampler(sidebar: sidebar, window: window)
            let link = content.displayLink(target: sampler, selector: #selector(SpaceCompositingProbe.Sampler.tick(_:)))
            link.add(to: .main, forMode: .common)
            defer { link.invalidate() }
            let start = ProcessInfo.processInfo.systemUptime
            var input: [String: Any] = [:]
            if let fraction = Double(command["inputAt"] ?? "") {
                sampler.inputAt = fraction
                sampler.inputKind = command["input"] ?? "click"
                sampler.onInput = { report in input = report }
            }
            switch mode {
            case "click":
                guard ownsWindow(owner), sidebar.footer.spaceButtons.indices.contains(index) else { return ["ownershipRefused": true] }
                sidebar.footer.spaceButtons[index].performClick(nil)
            case "keyboard":
                guard ownsWindow(owner), let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: String(index + 1), charactersIgnoringModifiers: String(index + 1), isARepeat: false, keyCode: 0) else { return ["ownershipRefused": true] }
                _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
            case "ordinary":
                owner.session.activateSpace(document.spaces[index].id)
            case "observe":
                // A real keyboard shortcut is sent by the harness right after this command starts.
                while !sidebar.isSpaceTransitionAnimating && ProcessInfo.processInfo.systemUptime < start + 2 {
                    try? await Task.sleep(for: .milliseconds(1))
                }
            case "swipe", "interrupt":
                func packet(_ phase: Int64, _ delta: Int32) {
                    guard ownsWindow(owner), let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: delta, wheel3: 0) else { return }
                    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                    cg.timestamp = DispatchTime.now().uptimeNanoseconds
                    if let event = NSEvent(cgEvent: cg) { _ = sidebar.spaceSwipe.handleScroll(event, inside: true) }
                }
                let sign: Int32 = index > (document.spaces.firstIndex { $0.id == initial } ?? 0) ? -1 : 1
                packet(1, 0)
                for _ in 0..<10 { packet(2, sign * 32); try? await Task.sleep(for: .milliseconds(16)) }
                packet(4, 0)
                if mode == "interrupt" {
                    try? await Task.sleep(for: .milliseconds(65)); packet(1, 0)
                    for _ in 0..<6 { packet(2, -sign * 28); try? await Task.sleep(for: .milliseconds(16)) }
                    packet(4, 0)
                }
            default: return ["badMode": true]
            }
            let swipePath = sidebar.spaceSwipe.isActive
            await owner.session.waitForQueuedCommands()
            try? await Task.sleep(for: .milliseconds(30))
            while sidebar.isSpaceTransitionAnimating && ProcessInfo.processInfo.systemUptime < start + 3 {
                try? await Task.sleep(for: .milliseconds(2))
            }
            try? await Task.sleep(for: .milliseconds(Int(Double(command["tail"] ?? "") ?? 120)))
            window.displayIfNeeded(); CATransaction.flush()
            sampler.tick(nil)
            return ["occluded": occluded, "endOccluded": !window.occlusionState.contains(.visible), "frames": sampler.frames,
                    "start": start, "selectionChanged": initial != owner.session.snapshot?.activeSpaceID,
                    "selectedTabChanged": initialSelection != owner.session.snapshot?.selectedOccurrenceID,
                    "input": input, "swipePath": swipePath, "newTabDraws": SpaceCompositingProbe.newTabDraws,
                    "activeIndex": document.spaces.firstIndex { $0.id == owner.session.snapshot?.activeSpaceID } ?? -1, "clippedAtRest": sidebar.compositedSpaceViews.count,
                    "selectedTab": String(describing: owner.session.snapshot?.selectedOccurrenceID as Any),
                    "totals": OrbitUIWorkCounters.values.filter { !$0.key.contains("ObjectIdentifier") && $0.key.hasPrefix("glyph") }]
        default:
            return ["badAction": true]
        }
    }
}

@MainActor
private enum SpaceCompositingProbe {
    /// Where the layer tree draws the view, in window coordinates (includes any layer transform).
    static func visibleRect(_ view: NSView, window: NSWindow) -> CGRect? {
        guard let content = window.contentView, let layer = view.layer, let root = content.layer else { return nil }
        return content.convert(layer.convert(layer.bounds, to: root), to: nil)
    }
    static func describe(_ view: NSView, window: NSWindow) -> [String: Any] {
        let native = view.convert(view.bounds, to: nil)
        let ax = window.convertFromScreen(view.accessibilityFrame())
        var entry: [String: Any] = ["class": String(describing: type(of: view)),
            "native": [native.minX, native.minY, native.width, native.height],
            "ax": [ax.minX, ax.minY, ax.width, ax.height], "axHidden": view.isAccessibilityHidden() || view.isHiddenOrHasHiddenAncestor]
        if let visible = visibleRect(view, window: window) {
            entry["visible"] = [visible.minX, visible.minY, visible.width, visible.height]
            let center = NSPoint(x: visible.midX, y: visible.midY)
            let hit = window.contentView?.hitTest(center)
            entry["hitIsElement"] = hit.map { $0 === view || $0.isDescendant(of: view) } ?? false
            entry["hitClass"] = hit.map { String(describing: type(of: $0)) } ?? "nil"
        }
        let tracking = view.convert(view.visibleRect, to: nil)
        entry["hoverRegion"] = [tracking.minX, tracking.minY, tracking.width, tracking.height]
        return entry
    }
    static func pages(_ sidebar: BrowserSidebarView, window: NSWindow) -> [[String: Any]] {
        let pages = (sidebar.page.superview?.subviews ?? []).compactMap { $0 as? SidebarSpacePageView }
        return pages.map { page in
            var elements: [String: Any] = ["title": describe(page.titleLabel, window: window),
                                           "newTab": describe(page.list.newTabRow, window: window)]
            let rows = descendants(page.list).compactMap { $0 as? SidebarTabRow }.sorted { $0.frame.minY < $1.frame.minY }
            for (index, row) in rows.prefix(3).enumerated() {
                elements["row\(index)"] = describe(row, window: window)
                elements["row\(index)Close"] = describe(row.closeButton, window: window)
            }
            return ["live": page === sidebar.page, "spaceIndex": page.spaceID.map { String(describing: $0).count } ?? 0,
                    "x": page.convert(page.bounds, to: nil).minX, "subviews": page.subviews.count, "elements": elements]
        }
    }
    static func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    /// Every draw of a New Tab "+" glyph: when, where in the window, and whether it clipped.
    static var newTabDraws: [[String: Any]] = []
    private static var drawLogInstalled = false
    static func installNewTabDrawLog() {
        guard !drawLogInstalled,
              let original = class_getInstanceMethod(OrbitGlyphButton.self, #selector(NSView.draw(_:))),
              let replacement = class_getInstanceMethod(OrbitGlyphButton.self, #selector(OrbitGlyphButton.compositingProbeDraw(_:))) else { return }
        method_exchangeImplementations(original, replacement)
        drawLogInstalled = true
    }

    @MainActor
    final class Sampler: NSObject {
        weak var sidebar: BrowserSidebarView?
        weak var window: NSWindow?
        var frames: [[String: Any]] = []
        var inputAt: Double?
        var inputKind = "click"
        var onInput: (([String: Any]) -> Void)?
        private var last: [String: Int] = [:]
        private var slideStart: CFTimeInterval?
        init(sidebar: BrowserSidebarView, window: NSWindow) { self.sidebar = sidebar; self.window = window }
        @objc func tick(_ link: CADisplayLink?) {
            guard let sidebar, let window else { return }
            let current = OrbitUIWorkCounters.values.filter { $0.key.hasPrefix("glyphDraw") }
            var delta: [String: Int] = [:]
            for (key, value) in current where value != last[key, default: 0] { delta[key] = value - last[key, default: 0] }
            last = current
            let pages = (sidebar.page.superview?.subviews ?? []).compactMap { $0 as? SidebarSpacePageView }
            let newTab = sidebar.page.list.newTabRow
            let native = newTab.convert(newTab.bounds, to: nil)
            let ax = window.convertFromScreen(newTab.accessibilityFrame())
            let visible = visibleRect(newTab, window: window) ?? .zero
            let hit = window.contentView?.hitTest(NSPoint(x: visible.midX, y: visible.midY))
            frames.append(["t": link?.timestamp ?? CACurrentMediaTime(), "target": link?.targetTimestamp ?? 0,
                "pages": pages.map { ["live": $0 === sidebar.page, "x": $0.convert($0.bounds, to: nil).minX,
                                      "visibleX": visibleRect($0, window: window)?.minX ?? -9999] },
                "newTabX": native.minX, "newTabVisibleX": visible.minX, "newTabAXX": ax.minX,
                "hitNewTab": hit.map { $0 === newTab || $0.isDescendant(of: newTab) } ?? false,
                "clipped": sidebar.compositedSpaceViews.count, "delta": delta,
                "occluded": !window.occlusionState.contains(.visible)])
            let now = link?.timestamp ?? CACurrentMediaTime()
            if inputAt != nil, slideStart == nil, pages.count > 1 { slideStart = now }
            if let inputAt, let slideStart, now - slideStart >= inputAt {
                self.inputAt = nil
                dispatchInput(sidebar: sidebar, window: window)
            }
        }
        /// In-process events through NSApplication (local monitors included), aimed at what is drawn.
        private func dispatchInput(sidebar: BrowserSidebarView, window: NSWindow) {
            // Aim at what is drawn: the page covering most of the sidebar, its second tab row if it has
            // live rows (an adjacent preview is a raster without rows), else the middle of that page.
            let pages = (sidebar.page.superview?.subviews ?? []).compactMap { $0 as? SidebarSpacePageView }
            let width = sidebar.bounds.width
            guard let page = pages.max(by: { a, b in
                let fa = a.convert(a.bounds, to: sidebar), fb = b.convert(b.bounds, to: sidebar)
                return max(0, min(fa.maxX, width) - max(fa.minX, 0)) < max(0, min(fb.maxX, width) - max(fb.minX, 0))
            }) else { onInput?(["skipped": true]); return }
            let rows = descendants(page.list).compactMap { $0 as? SidebarTabRow }.sorted { $0.frame.minY < $1.frame.minY }
            let target: NSView = rows.count > 1 ? rows[1] : page
            guard let visible = visibleRect(target, window: window) else { onInput?(["skipped": true]); return }
            let location = NSPoint(x: visible.midX, y: rows.count > 1 ? visible.midY : visible.minY + visible.height * 0.6)
            let hit = window.contentView?.hitTest(location)
            let native = target.convert(target.bounds, to: nil)
            let report: [String: Any] = ["kind": inputKind, "pageX": page.convert(page.bounds, to: nil).minX, "pageIsLive": page === sidebar.page,
                "targetIsRow": rows.count > 1, "point": [location.x, location.y],
                "nativeTarget": [native.minX, native.minY, native.width, native.height],
                "visibleTarget": [visible.minX, visible.minY, visible.width, visible.height],
                "hitIsTarget": hit.map { $0 === target || $0.isDescendant(of: target) } ?? false,
                "hitInPage": hit.map { $0 === page || $0.isDescendant(of: page) } ?? false,
                "hitClass": hit.map { String(describing: type(of: $0)) } ?? "nil",
                "swipeActive": sidebar.spaceSwipe.isActive,
                "targetTab": rows.count > 1 ? String(describing: rows[1].item.occurrenceID as Any) : "page"]
            let types: [NSEvent.EventType] = inputKind == "hover" ? [.mouseMoved] : [.leftMouseDown, .leftMouseUp]
            for type in types {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            onInput?(report)
            let row = rows.count > 1 ? rows[1] : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                var later = report
                later["hoverAfter"] = row?.isHovering ?? false
                later["swipeActiveAfter"] = sidebar.spaceSwipe.isActive
                self?.onInput?(later)
            }
        }
    }
}

extension OrbitGlyphButton {
    @objc fileprivate func compositingProbeDraw(_ rect: NSRect) {
        if superview is SidebarNewTabRow {
            let frame = convert(bounds, to: nil)
            SpaceCompositingProbe.newTabDraws.append(["t": CACurrentMediaTime(), "x": frame.minX, "id": ObjectIdentifier(self).hashValue,
                                                      "clips": clipsToBounds, "dirty": [rect.minX, rect.minY, rect.width, rect.height]])
        }
        compositingProbeDraw(rect)
    }
}


extension OrbitPerformanceProbe {
    /// Confined fixture for real-engine sidebar interaction and motion checks.
    private static func folderHoverFixture(_ owner: OrbitWindowController, store: BrowserStore,
                                           command: [String: String]) async -> Bool {
        guard ownsWindow(owner, bundleID: "lab.orbit.orbit.folder-hover") else { return false }
        switch command["action"] {
        case "seed":
            guard owner.session.snapshot?.activeSpaceID != nil else { return false }
            for title in ["Alpha", "Beta", "Gamma"] {
                guard ownsWindow(owner, bundleID: "lab.orbit.orbit.folder-hover") else { return false }
                owner.session.openTab(url: URL(string: "http://127.0.0.1:18743/" + title.lowercased())!)
                await owner.session.waitForPendingCommands()
                guard let tab = owner.session.organization?.selectedTab?.id else { return false }
                owner.session.renameTab(tab, to: title)
                if title == "Alpha" { owner.session.pinTabs([tab]) }
                await owner.session.waitForPendingCommands()
            }
        case "create": owner.createSidebarFolder()
        case "show": owner.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        default: return false
        }
        await owner.session.waitForPendingCommands()
        return true
    }
}


extension OrbitPerformanceProbe {
    /// Hermetic two-document fixture for pointer resizing and compositor measurements.
    private static func splitDividerFixture(_ owner: OrbitWindowController, command: [String: String]) async -> [String: Any] {
        let bundleID = "lab.orbit.orbit.split-divider"
        guard Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              Bundle.main.bundleIdentifier == bundleID,
              let ownWindow = owner.window, NSApp.windows.contains(where: { $0 === ownWindow }) else {
            return ["ownershipRefused": true]
        }
        ownWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard ownsWindow(owner, bundleID: bundleID) else { return ["ownershipRefused": true] }
        if command["action"] == "seed", let base = command["base"],
           let url = URL(string: base), url.scheme == "http", url.host == "127.0.0.1" {
            owner.window?.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 940), display: true)
            owner.session.openTab(url: url.appendingPathComponent("alpha"))
            await owner.session.waitForPendingCommands()
            owner.session.addSplitPane(url: url.appendingPathComponent("gamma"))
            await owner.session.waitForPendingCommands()
            for surface in owner.session.ownedSurfaces { await waitForLoad(surface) }
        }
        guard ownsWindow(owner, bundleID: bundleID), let window = owner.window,
              let group = owner.session.activeSplit else { return ["missingSplit": true] }
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        func screenRect(_ view: NSView) -> [Double] {
            let r = window.convertToScreen(view.convert(view.bounds, to: nil))
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            return [r.minX, top - r.maxY, r.width, r.height]
        }
        var result: [String: Any] = ["pid": getpid(), "window": window.windowNumber,
            "ratios": group.group.ratios,
            "panes": group.group.tabIDs.compactMap { owner.split.view.panes[$0].map(screenRect) },
            "dividers": owner.split.view.dividers.map(screenRect)]
        var pages: [[String: Any]] = []
        for id in group.group.tabIDs {
            guard let occurrence = owner.session.organization?.tab(id)?.occurrenceID,
                  let surface = owner.session.surface(for: occurrence) else { continue }
            if command["action"] == "arm" {
                _ = await evaluate(surface, "(() => { window.resizeSamples=[]; let last=0; function tick(t) { resizeSamples.push({t,dt:last?t-last:0,w:innerWidth}); last=t; if(resizeSamples.length<1200) requestAnimationFrame(tick); } requestAnimationFrame(tick); return {}; })()")
            }
            if let state = await evaluate(surface, "({width:innerWidth, ready:document.readyState, samples:window.resizeSamples||[]})") { pages.append(state) }
        }
        result["pages"] = pages
        return result
    }
}


extension OrbitPerformanceProbe {
    /// Offscreen real-engine proof using a confined loopback suggestion endpoint.
    private static func searchSuggestions(_ owner: OrbitWindowController, root: URL, command: [String: String]) async -> [String: Any] {
        func owns() -> Bool {
            guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.search-suggestions",
                  let configuration = activeSiteSessionConfiguration(), configuration.syntheticGuard != nil,
                  configuration.usesMockKeychain, let window = owner.window,
                  NSApp.windows.contains(where: { $0 === window }),
                  let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
            return windows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
                && ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
        }
        guard owns(), let base = command["base"].flatMap(URL.init(string:)),
              base.scheme == "http", base.host == "127.0.0.1", base.user == nil, base.password == nil else { return ["refused": true] }
        owner.palette.searchSuggestions = BrowserSearchSuggestions(endpoint: { _, query in
            var components = URLComponents(url: base.appendingPathComponent("suggest"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            return components.url
        })
        guard owns() else { return ["refused": true] }
        owner.palette.present(.newTab)
        await owner.palette.waitForResults()
        guard owns() else { return ["refused": true] }
        owner.palette.query("nebula")
        let localCount = owner.palette.results.count
        await owner.palette.waitForResults()
        guard owns(), let host = owner.window?.contentView else { return ["refused": true] }
        host.layoutSubtreeIfNeeded()
        owner.window?.displayIfNeeded()
        CATransaction.flush()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return ["captureFailed": true] }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return ["captureFailed": true] }
        try? data.write(to: root.appendingPathComponent("suggestions.png"))
        let remoteCount = owner.palette.results.filter { $0.remoteSuggestion != nil }.count
        var deleted = false
        if let row = owner.palette.results.firstIndex(where: { $0.remoteSuggestion != nil }) {
            guard owns() else { return ["refused": true] }
            owner.palette.move(row - owner.palette.selection.index)
            guard owns() else { return ["refused": true] }
            owner.palette.deleteSuggestion()
            deleted = owner.palette.results.filter { $0.remoteSuggestion != nil }.count == remoteCount - 1
        }
        owner.palette.dismiss(returnFocus: false)
        return ["pid": getpid(), "offscreen": true, "localCount": localCount, "remoteCount": remoteCount, "deleted": deleted]
    }
}
