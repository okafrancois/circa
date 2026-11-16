import AppKit
import BrowserCore
import QuartzCore

extension OrbitSmokeDriver {
    /// Shell hardening checks on the real window, without input events: remote suggestions on
    /// erase-and-retype without and with the in-memory cache (served by the loopback fixture after a
    /// fixed latency, with timed window captures for a side-by-side clip), settings writes during ten
    /// Space switches, session saves under a burst, and the Core Video motion link's display.
    func perfShellBScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        func check(_ name: String, _ passed: Bool, _ evidence: [String: Any] = [:]) {
            self.check("perf-shell-b." + name, passed, evidence)
        }
        guard let window = owner.window, let screen = NSScreen.main?.visibleFrame, let application,
              let profile = owner.session.activeProfileID else { check("window", false); return }
        window.setFrame(NSRect(x: screen.minX + 40, y: screen.maxY - 700, width: 1100, height: 660), display: true)
        window.orderFrontRegardless()
        func owns() -> Bool {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
            return window.isVisible && rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        _ = await until(3) { owns() }
        guard owns() else { check("capture-owner", false); return }
        var report: [String: Any] = [:]

        // Remote suggestions: type, erase one character, retype.
        let fixture = self.fixture!
        func suggestions(capacity: Int) -> BrowserSearchSuggestions {
            BrowserSearchSuggestions(cache: BrowserSearchSuggestionCache(capacity: capacity)) { _, query in
                var components = URLComponents(url: fixture.appendingPathComponent("suggest"), resolvingAgainstBaseURL: false)
                components?.queryItems = [.init(name: "q", value: query)]
                return components?.url
            }
        }
        func remoteShown(_ word: String) -> Bool {
            owner.palette.results.contains { $0.remoteSuggestion?.hasPrefix(word + " ") == true }
        }
        /// Synchronous capture of this window only: it shows what is on screen at that instant.
        func capture(_ name: String) {
            guard owns() else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), runRoot.appendingPathComponent(name + ".png").path]
            try? process.run()
            process.waitUntilExit()
        }
        var clips: [String: [String]] = [:]
        for (label, capacity) in [("before", 0), ("after", 50)] {
            owner.palette.searchSuggestions = suggestions(capacity: capacity)
            owner.palette.showsSearchSuggestions = true
            owner.palette.registry = application.commands.registry
            owner.palette.present(.newTab)
            try? await Task.sleep(for: .milliseconds(300))
            var latencies: [Double] = []
            for word in ["orbit", "kayak"] {
                for length in 1...word.count {
                    owner.palette.query(String(word.prefix(length)))
                    try? await Task.sleep(for: .milliseconds(90))
                }
                _ = await until(2) { remoteShown(word) }
                for _ in 0..<2 {
                    owner.palette.query(String(word.dropLast()))
                    _ = await until(2) { remoteShown(String(word.dropLast())) }
                    let typed = CACurrentMediaTime()
                    owner.palette.query(word)
                    while !remoteShown(word), CACurrentMediaTime() - typed < 2 { try? await Task.sleep(for: .milliseconds(1)) }
                    latencies.append((CACurrentMediaTime() - typed) * 1000)
                }
            }
            // Storyboard, outside the measurements: erased, the instant after retyping, settled.
            owner.palette.query("swift")
            _ = await until(2) { remoteShown("swift") }
            owner.palette.query("swif")
            _ = await until(2) { remoteShown("swif") }
            try? await Task.sleep(for: .milliseconds(150))
            capture("\(label)-1-erased")
            owner.palette.query("swift")
            window.displayIfNeeded()
            CATransaction.flush()
            capture("\(label)-2-retyped")
            _ = await until(2) { remoteShown("swift") }
            try? await Task.sleep(for: .milliseconds(150))
            capture("\(label)-3-settled")
            clips[label] = ["1-erased", "2-retyped", "3-settled"].map { "\(label)-\($0).png" }
            owner.palette.dismiss(returnFocus: false)
            report["suggestions-\(label)-retype-ms"] = latencies
            check("suggestions-\(label)", latencies.count == 4, ["retypeMilliseconds": latencies])
        }
        if let data = try? JSONSerialization.data(withJSONObject: clips, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: runRoot.appendingPathComponent("suggestion-frames.json"))
        }

        // Settings writes during ten Space switches.
        if let settingsFile = environment.sessionFile?.appendingPathExtension("settings.json") {
            func inode() -> UInt64? {
                (try? FileManager.default.attributesOfItem(atPath: settingsFile.path)[.systemFileNumber] as? NSNumber)?.uint64Value
            }
            var spaces: [SpaceID] = [owner.session.snapshot?.activeSpaceID].compactMap { $0 }
            for index in 0..<2 { if let id = try? await environment.store.createSpace(name: "Synthetic \(index)", profileID: profile) { spaces.append(id) } }
            await environment.flushWindowActivity()
            try? await Task.sleep(for: .milliseconds(200))
            var last = inode(), during = 0
            for index in 1...10 {
                owner.activateSpace(spaces[index % spaces.count])
                await owner.session.waitForPendingCommands()
                environment.recordActiveWindow(owner)
                try? await Task.sleep(for: .milliseconds(150))
                await environment.windowActivitySave?.value
                if inode() != last { during += 1; last = inode() }
            }
            try? await Task.sleep(for: .milliseconds(2_400))
            await environment.windowActivitySave?.value
            let settled = inode() != last ? 1 : 0
            report["space-switch-settings-writes"] = ["during": during, "afterSettling": settled]
            check("space-switch-writes", spaces.count == 3 && during == 0 && settled == 1, ["during": during, "afterSettling": settled])
            owner.activateSpace(spaces[0])
            await owner.session.waitForPendingCommands()
        } else {
            check("space-switch-writes", false)
        }

        // Session saves under a 4 s burst of structural changes.
        let previousSuccess = environment.onPersistenceSuccess
        var saves = 0
        environment.onPersistenceSuccess = { saves += 1; previousSuccess?() }
        try? await Task.sleep(for: .milliseconds(1_200))
        saves = 0
        let burstStart = CACurrentMediaTime()
        while CACurrentMediaTime() - burstStart < 4 {
            environment.scheduleSave()
            try? await Task.sleep(for: .milliseconds(16))
        }
        let duringBurst = saves
        try? await Task.sleep(for: .milliseconds(1_200))
        environment.onPersistenceSuccess = previousSuccess
        report["session-saves-burst"] = ["seconds": 4, "saves": duringBurst, "trailing": saves - duringBurst]
        check("save-burst", duringBurst <= 5 && saves > duringBurst, ["saves": duringBurst, "trailing": saves - duringBurst])

        // Core Video motion link: bound to the window's display, paced at its refresh.
        let driver = OrbitCoreVideoMotionDriver()
        var stamps: [CFTimeInterval] = []
        driver.onFrame = { stamps.append(CACurrentMediaTime()) }
        let started = driver.start(window: window)
        try? await Task.sleep(for: .seconds(1))
        let bound = driver.screen.display
        driver.stop()
        let expected = window.screen.flatMap { OrbitDisplayLinkScreen.displayID($0) }
        let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        let mean = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        report["core-video-link"] = ["display": bound.map(Int.init) ?? -1, "windowDisplay": expected.map(Int.init) ?? -1,
                                     "frames": stamps.count, "meanIntervalMs": mean,
                                     "screenMaximumFPS": window.screen?.maximumFramesPerSecond ?? 0]
        check("core-video-link", started && bound != nil && bound == expected && stamps.count > 20,
              ["frames": stamps.count, "meanIntervalMs": mean])

        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: runRoot.appendingPathComponent("perf-shell-b.json"))
        }
    }
}
