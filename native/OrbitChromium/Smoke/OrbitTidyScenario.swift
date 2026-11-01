import AppKit
import BrowserCore
import BrowserShell
import BrowserEngine
import ChromiumEngine

extension OrbitSmokeDriver {
    func tidyScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        environment.ai.terminateNow()
        _ = await until(10) { !environment.ai.isChecking }
        let live = arguments.contains("--orbit-smoke-tidy-live")
        if !live {
            let client = OrbitAssistantFixtureClient(id: .codex, root: runRoot)
            environment.ai.clientOverrides[.codex] = client
            environment.ai.statuses[.codex] = await client.status(refresh: false)
            try? Data("tidy".utf8).write(to: runRoot.appendingPathComponent("fixture-mode"))
        }
        try? await environment.settings.updateAI {
            $0.isEnabled = true; $0.readsCurrentTabOnRequest = true; $0.helpers.tidyTitlesAndDownloads = true
            if !live { $0.defaultModels[.quick] = .init(provider: .codex, model: "synthetic-codex", effort: "low") }
        }
        if live { environment.ai.refresh(explicit: true, keepRunning: true); _ = await until(12) { !environment.ai.isChecking } }
        guard let window = owner.window else { return }
        if arguments.contains("--orbit-smoke-tidy-light") { window.appearance = NSAppearance(named: .aqua) }
        window.center(); window.makeKeyAndOrderFront(nil)
        func owns() -> Bool {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
            return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        if arguments.contains("--orbit-smoke-tidy-reference") {
            if let frame = window.screen?.visibleFrame { window.setFrame(frame.insetBy(dx: 16, dy: 16), display: true) }
            let reference = fixture.appendingPathComponent("reference.html")
            owner.openTab(url: reference)
            _ = await committed(owner, reference)
            guard let surface = owner.pageCommandSurface() else { return }
            func evaluate(_ script: String) async {
                guard owns(), let data = try? JSONSerialization.data(withJSONObject: ["expression": script]) else { return }
                _ = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: data, as: UTF8.self))
            }
            await evaluate("document.querySelector('#h2').scrollIntoView({block:'center'})")
            await evaluate("""
            (()=>{window.tidyTrace={frames:[],start:performance.now()};const tick=()=>{let p=document.querySelector('#h2pt'),d=document.querySelector('#h3t');let a=getComputedStyle(p),b=getComputedStyle(d);tidyTrace.frames.push({ms:performance.now()-tidyTrace.start,titleOpacity:a.opacity,titleWidth:p.getBoundingClientRect().width,toastOpacity:b.opacity,toastTransform:b.transform,titleRect:p.getBoundingClientRect().toJSON(),toastRect:d.getBoundingClientRect().toJSON()});if(performance.now()-tidyTrace.start<10500)requestAnimationFrame(tick)};requestAnimationFrame(tick)})()
            """)
            let movie = Process(); movie.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            movie.arguments = ["-x", "-v", "-V", "10", "-l", String(window.windowNumber), runRoot.appendingPathComponent("reference.mov").path]
            if owns() { try? movie.run() }
            try? await Task.sleep(for: .milliseconds(300))
            await evaluate("document.querySelector('#h2b').click();document.querySelector('#h3b').click()")
            if arguments.contains("--orbit-smoke-tidy-reference-undo") {
                try? await Task.sleep(for: .milliseconds(2500))
                await evaluate("document.querySelector('#h3u').click();document.querySelector('#h2u').click()")
            }
            _ = await until(12) { !movie.isRunning }
            if owns(), let data = try? JSONSerialization.data(withJSONObject: ["expression": "JSON.stringify(window.tidyTrace)", "returnByValue": true]) {
                let (_, reply) = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: data, as: UTF8.self))
                if let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
                   let value = (object["result"] as? [String: Any])?["value"] as? String {
                    try? Data(value.utf8).write(to: runRoot.appendingPathComponent("reference-frames.json"))
                }
            }
            return
        }
        let page = fixture.appendingPathComponent("tidy.html")
        owner.openTab(url: page)
        await owner.session.waitForQueuedCommands()
        _ = await committed(owner, page)
        guard owns(), let tab = owner.session.organization?.selectedTab else { check("tidy.owner", false); return }
        if arguments.contains("--orbit-smoke-tidy-edge") { await tidyEdges(environment, owner); return }
        let preferences = environment.settings.document.ai
        if let choice = preferences.defaultModels[.quick] ?? BrowserAIPolicy.automaticChoice(for: .quick, statuses: environment.ai.statuses),
           let data = try? JSONSerialization.data(withJSONObject: ["provider": choice.provider.rawValue, "model": choice.model ?? "", "effort": choice.effort ?? "", "fixture": !live]) {
            try? data.write(to: runRoot.appendingPathComponent("provider-choice.json"))
        }
        let originalResponder = window.firstResponder
        let recording = Process(); recording.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        recording.arguments = ["-x", "-v", "-V", "16", "-l", String(window.windowNumber), runRoot.appendingPathComponent("native.mov").path]
        try? recording.run()
        let samples = Task { @MainActor in
            let start = ProcessInfo.processInfo.systemUptime
            var csv = "seconds,titleOpacity,titleWidth,toastVisible\n"
            for _ in 0..<1000 {
                let label = owner.sidebar.page.list.titleRestoreRow(for: tab.id)?.titleLabel
                let layer = label?.layer?.presentation()
                csv += "\(ProcessInfo.processInfo.systemUptime - start),\(layer?.opacity ?? Float(label?.alphaValue ?? 0)),\(layer?.bounds.width ?? label?.frame.width ?? 0),\(owner.tidyDownloadPanel != nil)\n"
                try? Data(csv.utf8).write(to: self.runRoot.appendingPathComponent("native-frames.csv"))
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
            }
        }
        defer { samples.cancel() }
        owner.togglePinSidebarTargets()
        await owner.session.waitForQueuedCommands()
        let renamed = await until(live ? 20 : 8) { owner.session.organizationTab(tab.id)?.customTitle != nil }
        check("tidy.title-renamed", renamed)
        if let answer = owner.session.organizationTab(tab.id)?.customTitle { try? Data(answer.utf8).write(to: runRoot.appendingPathComponent("title-answer.txt")) }
        try? await Task.sleep(for: .milliseconds(650))
        if owns(), let row = owner.sidebar.page.list.titleRestoreRow(for: tab.id),
           let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil) {
            row.mouseEntered(with: event)
            row.layoutSubtreeIfNeeded()
            check("tidy.restore-hover", !row.restoreButton.isHidden)
        }
        if owns() {
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), runRoot.appendingPathComponent("title.png").path]
            try? capture.run(); capture.waitUntilExit()
            if let button = owner.sidebar.page.list.titleRestoreRow(for: tab.id)?.restoreButton {
                let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard owns() else { check("tidy.restore-owner", false); return }
                    let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
                    event?.cgEvent?.postToPid(getpid())
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
        }
        await owner.session.waitForQueuedCommands()
        check("tidy.title-restored", owner.session.organizationTab(tab.id)?.customTitle == nil)
        let observesDismissal = arguments.contains("--orbit-smoke-tidy-no-undo")
        if observesDismissal {
            let point = CGPoint(x: window.frame.minX + window.frame.width * 0.7,
                y: (NSScreen.screens.first?.frame.maxY ?? 0) - window.frame.midY)
            let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
            let target = rows?.first { row in
                guard (row[kCGWindowLayer as String] as? Int) == 0,
                      let bounds = row[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                return rect.contains(point)
            }
            guard owns(), (target?[kCGWindowOwnerPID as String] as? Int32) == getpid(),
                  (target?[kCGWindowNumber as String] as? Int) == window.windowNumber else {
                check("tidy.dismissal-owner", false); return
            }
            CGWarpMouseCursorPosition(point)
        }
        owner.downloads.destinationProvider = { [root = runRoot!] _, name in root.appendingPathComponent(name) }
        guard owns(), let surface = owner.pageCommandSurface() else { return }
        let script = "var a=document.createElement('a');a.href='/download.pdf';a.download='INV-2026-10.pdf';document.body.append(a);a.click();true"
        let params = try? JSONSerialization.data(withJSONObject: ["expression": script])
        if let params { _ = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: params, as: UTF8.self)) }
        let renamedFile = await until(live ? 20 : 10) { owner.tidyDownloadPanel != nil }
        check("tidy.download-toast", renamedFile)
        check("tidy.native-focus", window.firstResponder === originalResponder)
        if let profile = owner.session.activeProfileID {
            let items = owner.downloads.snapshots(profileID: profile)
            check("tidy.download-model", items.contains { $0.state == .complete && $0.destinationURL?.lastPathComponent != "INV-2026-10.pdf" })
        }
        try? await Task.sleep(for: .milliseconds(450))
        if owns() {
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), runRoot.appendingPathComponent("download.png").path]
            try? capture.run(); capture.waitUntilExit()
        }
        if !observesDismissal, owns(), renamedFile, let panel = owner.tidyDownloadPanel {
            func ownsPanel() -> Bool {
                let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]]
                return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
            }
            let location = NSPoint(x: panel.frame.width - 28, y: panel.frame.height / 2)
            if arguments.contains("--orbit-smoke-tidy-hover"), ownsPanel() {
                let screenPoint = CGPoint(x: panel.frame.maxX - 28,
                    y: (NSScreen.screens.first?.frame.maxY ?? 0) - panel.frame.midY)
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
                let target = windows?.first { row in
                    guard (row[kCGWindowLayer as String] as? Int) == 0,
                          let bounds = row[kCGWindowBounds as String] as? [String: Any],
                          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                    return rect.contains(screenPoint)
                }
                guard ownsPanel(), (target?[kCGWindowOwnerPID as String] as? Int32) == getpid(),
                      (target?[kCGWindowNumber as String] as? Int) == panel.windowNumber else {
                    check("tidy.hover-owner", false); return
                }
                CGWarpMouseCursorPosition(screenPoint)
                guard ownsPanel() else { check("tidy.hover-owner", false); return }
                let move = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
                move?.cgEvent?.postToPid(getpid())
                try? await Task.sleep(for: .milliseconds(6300))
                check("tidy.hover-pauses-dwell", owner.tidyDownloadPanel === panel)
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard ownsPanel() else { check("tidy.undo-owner", false); return }
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
                event?.cgEvent?.postToPid(getpid())
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? await Task.sleep(for: .milliseconds(400))
            check("tidy.download-undo", FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("INV-2026-10.pdf").path))
        }
        if observesDismissal {
            let dismissed = await until(8) { owner.tidyDownloadPanel == nil }
            check("tidy.download-dismissed", dismissed)
        }
        _ = await until(18) { !recording.isRunning }
        environment.ai.terminateNow()
    }
}
