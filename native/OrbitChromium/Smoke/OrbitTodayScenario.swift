import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

extension OrbitSmokeDriver {
    func todayScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        environment.ai.terminateNow()
        _ = await until(10) { !environment.ai.isChecking }
        let live = arguments.contains("--orbit-smoke-today-live")
        if !live {
            let client = OrbitAssistantFixtureClient(id: .codex, root: runRoot)
            environment.ai.clientOverrides[.codex] = client
            environment.ai.statuses[.codex] = await client.status(refresh: false)
            let mode = arguments.contains("--orbit-smoke-today-error") ? "error" : arguments.contains("--orbit-smoke-today-empty") ? "today-empty" : arguments.contains("--orbit-smoke-today-stop") ? "slow" : "today"
            try? Data(mode.utf8).write(to: runRoot.appendingPathComponent("fixture-mode"))
        }
        try? await environment.settings.updateAI {
            $0.isEnabled = true; $0.readsCurrentTabOnRequest = true; $0.helpers.tidyToday = true
            if !live { $0.defaultModels[.quick] = .init(provider: .codex, model: "synthetic-codex", effort: "low") }
        }
        if live { environment.ai.refresh(explicit: true, keepRunning: true); _ = await until(12) { !environment.ai.isChecking } }
        guard let window = owner.window else { return }
        window.appearance = NSAppearance(named: arguments.contains("--orbit-smoke-today-light") ? .aqua : .darkAqua)
        window.center(); window.makeKeyAndOrderFront(nil)
        func owns() -> Bool {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
            return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        func click(_ view: NSView) async {
            let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard owns() else { check("today.input-owner", false); return }
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0)
                if let event { NSApp.postEvent(event, atStart: false) }
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
        func capture(_ name: String) {
            guard owns() else { return }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-l", String(window.windowNumber), runRoot.appendingPathComponent(name + ".png").path]
            try? process.run(); process.waitUntilExit()
        }
        if arguments.contains("--orbit-smoke-today-reference") {
            let url = fixture.appendingPathComponent("reference.html")
            owner.openTab(url: url); _ = await committed(owner, url)
            guard let surface = owner.pageCommandSurface() else { return }
            func evaluate(_ script: String) async {
                guard owns(), let data = try? JSONSerialization.data(withJSONObject: ["expression": script]) else { return }
                _ = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: data, as: UTF8.self))
            }
            await evaluate("document.querySelector('#h4').scrollIntoView({block:'center'})")
            try? await Task.sleep(for: .milliseconds(1500))
            let movie = Process(); movie.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            movie.arguments = ["-x", "-v", "-V", "8", "-l", String(window.windowNumber), runRoot.appendingPathComponent("reference.mov").path]
            event("today-reference-movie-start", [:])
            if owns() { try? movie.run() }
            try? await Task.sleep(for: .milliseconds(350))
            await evaluate("document.querySelector('#h4b').click()")
            try? await Task.sleep(for: .milliseconds(900))
            capture("reference-proposals")
            await evaluate("document.querySelector('#h4g .r button').click()")
            try? await Task.sleep(for: .milliseconds(700))
            event("today-reference-archive-click", [:])
            await evaluate("document.querySelector('#h4g .r[data-g=inv] button').click()")
            _ = await until(9) { !movie.isRunning }
            return
        }
        for index in 0..<3 {
            let url = fixture.appendingPathComponent("today-\(index).html")
            owner.openTab(url: url); await owner.session.waitForQueuedCommands(); _ = await committed(owner, url)
        }
        owner.todayTidy.reconcile()
        let before = owner.session.organization?.organizationRevision
        let button = owner.sidebar.page.list.tidyButton
        if owns(), let event = NSEvent.mouseEvent(with: .mouseMoved,
            location: button.convert(NSPoint(x: 10, y: 10), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0) {
            owner.sidebar.page.list.mouseMoved(with: event)
        }
        check("today.available", button.isEnabled)
        let movie = Process(); movie.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        movie.arguments = ["-x", "-v", "-V", "8", "-l", String(window.windowNumber), runRoot.appendingPathComponent("native.mov").path]
        event("today-native-movie-start", [:])
        if owns() { try? movie.run() }
        await click(button)
        if arguments.contains("--orbit-smoke-today-stop") {
            try? await Task.sleep(for: .milliseconds(450))
            if let host = owner.sidebar.page.list.subviews.first(where: { String(describing: type(of: $0)).contains("NSHostingView") }) {
                let point = NSView(frame: NSRect(x: host.frame.maxX - 12, y: host.frame.minY + 12, width: 2, height: 2))
                point.isHidden = true; owner.sidebar.page.list.addSubview(point); await click(point); point.removeFromSuperview()
            }
            check("today.stop", !owner.todayTidy.running && owner.todayTidy.suggestions.isEmpty)
            check("today.stop-does-not-mutate", owner.session.organization?.organizationRevision == before)
            _ = await until(9) { !movie.isRunning }; return
        }
        let answered = await until(live ? 20 : 8) { !owner.todayTidy.running && (!owner.todayTidy.suggestions.isEmpty || !owner.todayTidy.message.isEmpty) }
        check("today.answer", answered)
        check("today.proposals-do-not-mutate", owner.session.organization?.organizationRevision == before)
        try? await Task.sleep(for: .milliseconds(550))
        capture("proposals")
        if arguments.contains("--orbit-smoke-today-error") || arguments.contains("--orbit-smoke-today-empty") {
            check("today.safe-message", !owner.todayTidy.message.isEmpty && owner.todayTidy.suggestions.isEmpty)
            _ = await until(9) { !movie.isRunning }; return
        }
        if live {
            try? Data(owner.todayTidy.message.utf8).write(to: runRoot.appendingPathComponent("live-message.txt"))
        } else {
            check("today.two-proposals", owner.todayTidy.suggestions.count == 2)
        }
        if !live, owner.todayTidy.suggestions.count == 2 {
            func proposalPoint(_ index: Int) -> NSView? {
                func hosts(_ view: NSView) -> [NSView] {
                    (String(describing: type(of: view)).contains("NSHostingView") ? [view] : []) + view.subviews.flatMap(hosts)
                }
                return hosts(owner.sidebar.page.list).first
            }
            if let host = proposalPoint(0) {
                let point = NSView(frame: NSRect(x: host.frame.maxX - 46, y: host.frame.minY + 53, width: 2, height: 2))
                point.isHidden = true; owner.sidebar.page.list.addSubview(point)
                await click(point); point.removeFromSuperview()
                _ = await until(5) { owner.todayTidy.suggestions.count == 1 }
                check("today.folder-applied", owner.todayTidy.suggestions.count == 1 && owner.session.organization?.organizationRevision != before)
                capture("folder")
                if let host = proposalPoint(0) {
                    let archiveRows = owner.todayTidy.suggestions.flatMap(\.tabs).compactMap {
                        owner.sidebar.page.list.titleRestoreRow(for: $0)
                    }
                    let traceStart = ProcessInfo.processInfo.systemUptime
                    event("today-native-archive-click", [:])
                    let trace = Task { @MainActor in
                        var csv = "seconds,leaving,opacity,translationX\n"
                        for _ in 0..<90 {
                            for row in archiveRows {
                                let layer = row.layer?.presentation()
                                let x = (layer?.value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue ?? 0
                                csv += "\(ProcessInfo.processInfo.systemUptime - traceStart),\(row.isLeaving),\(layer?.opacity ?? Float(row.alphaValue)),\(x)\n"
                            }
                            try? Data(csv.utf8).write(to: self.runRoot.appendingPathComponent("archive-frames.csv"))
                            try? await Task.sleep(for: .milliseconds(8))
                            if Task.isCancelled { return }
                        }
                    }
                    let point = NSView(frame: NSRect(x: host.frame.maxX - 40, y: host.frame.minY + 35, width: 2, height: 2))
                    point.isHidden = true; owner.sidebar.page.list.addSubview(point); await click(point); point.removeFromSuperview()
                    _ = await until(5) { owner.todayTidy.suggestions.isEmpty }
                    check("today.second-archive", owner.todayTidy.suggestions.isEmpty)
                    try? await Task.sleep(for: .milliseconds(500))
                    trace.cancel()
                }
                _ = await owner.session.undoOrganization().value
                _ = await owner.session.undoOrganization().value
                check("today.undo-restores", owner.session.organization?.allTabs.filter { if case .today = $0.section { return true }; return false }.count ?? 0 >= 3)
                capture("undo")
            } else { check("today.host", false) }
        }
        _ = await until(9) { !movie.isRunning }
        if !live {
            let requestsBeforeGates = (try? FileManager.default.contentsOfDirectory(atPath: runRoot.path).filter { $0.hasPrefix("request-") }.count) ?? 0
            for gate in ["master", "read", "helper", "excluded"] {
                try? await environment.settings.updateAI {
                    $0.isEnabled = gate != "master"
                    $0.readsCurrentTabOnRequest = gate != "read"
                    $0.helpers.tidyToday = gate != "helper"
                    $0.disabledSites = gate == "excluded" ? ["127.0.0.1"] : []
                }
                owner.todayTidy.reconcile()
                check("today.gate-" + gate, owner.todayTidy.suggestions.isEmpty && !owner.todayTidy.running && button.isHidden)
            }
            let count = (try? FileManager.default.contentsOfDirectory(atPath: runRoot.path).filter { $0.hasPrefix("request-") }.count) ?? 0
            check("today.gates-send-no-prompts", count == requestsBeforeGates)
        }
        if !live {
            try? await environment.settings.updateAI {
                $0.isEnabled = true; $0.readsCurrentTabOnRequest = true; $0.helpers.tidyToday = true; $0.disabledSites = []
            }
            owner.todayTidy.reconcile()
            if owns(), let event = NSEvent.mouseEvent(with: .mouseMoved,
                location: button.convert(NSPoint(x: 10, y: 10), to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0) {
                owner.sidebar.page.list.mouseMoved(with: event)
            }
            await click(button)
            _ = await until(5) { owner.todayTidy.suggestions.count == 2 }
            if let tab = owner.session.organization?.selectedTab {
                owner.session.renameTab(tab.id, to: "Manual synthetic title")
                await owner.session.waitForQueuedCommands()
                owner.todayTidy.reconcile()
                check("today.manual-edit-revokes", owner.todayTidy.suggestions.isEmpty && !owner.todayTidy.running)
            }
        }
        environment.ai.terminateNow()
    }
}
