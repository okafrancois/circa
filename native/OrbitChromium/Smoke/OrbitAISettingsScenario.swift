import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Capture the real pane without sending input to any other process.
    func aiSettings(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        func check(_ name: String, _ passed: Bool) { self.check("ai-settings." + name, passed) }
        guard let profile = owner.session.activeProfileID else { check("context", false); return }
        if arguments.contains("--orbit-smoke-tidy") { await tidyScenario(environment, owner); return }
        if arguments.contains("--orbit-smoke-writing") {
            await writingScenario(environment, owner)
            return
        }
        if arguments.contains("--orbit-smoke-find-answer") {
            await findAnswerScenario(environment, owner)
            return
        }
        if arguments.contains("--orbit-smoke-assistant") {
            await assistantInteractive(environment, owner)
            return
        }
        owner.window?.setFrameOrigin(NSPoint(x: -8000, y: 0))
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        if !arguments.contains("--orbit-smoke-ai-restored") {
            check("default-off", !environment.settings.document.ai.isEnabled)
        }
        let settings = BrowserSettingsWindowController(model: model, appearanceOverride: nil)
        defer { settings.window?.close(); environment.ai.terminateNow() }
        if arguments.contains("--orbit-smoke-ai-interactive") {
            guard let window = settings.window else { check("window", false); return }
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            let owns = await until(3) {
                let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
                return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
            }
            check("input-owner", owns)
            guard owns, let event = BrowserGlobalQuickWindowShortcut.layoutEvent(
                for: BrowserShortcut(key: "5", modifiers: .command)) else { check("layout-event", false); return }
            try? Data("\(getpid()) \(window.windowNumber)".utf8).write(to: runRoot.appendingPathComponent("interactive-ready"))
            _ = await until(5) { FileManager.default.fileExists(atPath: self.runRoot.appendingPathComponent("interactive-enter").path) }
            check("command-5", window.performKeyEquivalent(with: event) && model.settingsSection == .ai)
            try? Data().write(to: runRoot.appendingPathComponent("interactive-selected"))
            try? await Task.sleep(for: .seconds(30))
            let preferences = environment.settings.document.ai
            let evidence: [String: Any] = ["enabled": preferences.isEnabled,
                "readsCurrentTabOnRequest": preferences.readsCurrentTabOnRequest,
                "quickProvider": preferences.defaultModels[.quick]?.provider.rawValue ?? "automatic",
                "disabledSites": preferences.disabledSites]
            if let data = try? JSONSerialization.data(withJSONObject: evidence, options: .sortedKeys) {
                try? data.write(to: runRoot.appendingPathComponent("interactive-state.json"))
            }
            return
        }
        check("section", settings.selectSection(.ai))
        guard let window = settings.window, let view = window.contentView else { check("window", false); return }
        window.setFrameOrigin(NSPoint(x: -6000, y: 0))
        window.orderFront(nil)
        _ = await until(20) { !environment.ai.isChecking && !environment.ai.statuses.isEmpty }
        check("discovery", !environment.ai.isChecking && !environment.ai.statuses.isEmpty)
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        do {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                window.appearance = NSAppearance(named: appearance)
                for enabled in [false, true] {
                    try await environment.settings.updateAI { $0.isEnabled = enabled }
                    for lower in [false, true] {
                        try await Task.sleep(for: .milliseconds(250))
                        let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), runRoot.appendingPathComponent("window-\(name).png").path]
            try? capture.run()
            capture.waitUntilExit()
            view.layoutSubtreeIfNeeded()
                        for scroll in scrollViews(view) {
                            guard let doc = scroll.documentView else { continue }
                            let maxY = max(0, doc.bounds.height - scroll.contentView.bounds.height)
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: lower ? maxY : 0))
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                        try await Task.sleep(for: .milliseconds(150))
                        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
                        let owns = rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
                        check("capture-owner", owns)
                        guard owns else { return }
                        view.displayIfNeeded()
                        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { check("bitmap", false); return }
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        guard let png = bitmap.representation(using: .png, properties: [:]) else { check("png", false); return }
                        try png.write(to: runRoot.appendingPathComponent("\(name)-\(enabled ? "on" : "off")-\(lower ? "lower" : "top").png"))
                    }
                }
            }
            try await environment.settings.updateAI {
                $0.defaultModels[.quick] = BrowserAIModelChoice(provider: .onDevice)
                $0.readsCurrentTabOnRequest = false
                $0.disabledSites = ["example.test"]
            }
            let expected = environment.settings.document.ai
            await environment.settings.refresh()
            check("persisted", environment.settings.document.ai == expected && expected.isEnabled)
        } catch { check("operation", false) }
    }
}

extension OrbitSmokeDriver {
    func findAnswerScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        environment.ai.terminateNow()
        _ = await until(10) { !environment.ai.isChecking }
        let live = arguments.contains("--orbit-smoke-find-live")
        let client = OrbitAssistantFixtureClient(id: .codex, root: runRoot)
        if !live {
            environment.ai.clientOverrides[.codex] = client
            environment.ai.statuses[.codex] = await client.status(refresh: false)
        }
        try? await environment.settings.updateAI {
            $0.isEnabled = true
            if !live { $0.defaultModels[.chat] = .init(provider: .codex, model: "synthetic-codex") }
        }
        if live {
            environment.ai.refresh(explicit: true, keepRunning: true)
            _ = await until(12) { !environment.ai.isChecking }
        }
        guard let window = owner.window else { check("find-answer.window", false); return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        let page = fixture.appendingPathComponent("find-fixture.html")
        owner.openTab(url: page)
        _ = await committed(owner, page)
        owner.showFind()
        _ = await until(3) { owner.findOwner != nil && owner.findSession.state?.isVisible == true }
        owner.findBar.searchField.stringValue = "Does it support actors?"
        owner.submitFind("Does it support actors?")
        _ = await until(3) { owner.findSession.state?.query == "Does it support actors?" }
        check("find-answer.offered", owner.findAskChoice != nil)
        let queryOrigin = owner.findBar.searchField.convert(NSPoint.zero, to: window.contentView)
        let motion = Process()
        motion.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        motion.arguments = ["-x", "-v", "-V", "5", "-l", String(window.windowNumber), runRoot.appendingPathComponent("native-motion.mov").path]
        let ownedRows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
        if ownedRows?.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }) == true { try? motion.run() }
        try? await Task.sleep(for: .milliseconds(250))
        let frames = Task { @MainActor in
            let start = ProcessInfo.processInfo.systemUptime
            var samples = "frame,seconds,height\n"
            for index in 0..<50 {
                let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
                guard rows?.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }) == true else { return }
                let view = owner.findBar
                samples += "\(index),\(ProcessInfo.processInfo.systemUptime - start),\(view.bounds.height)\n"
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: runRoot.appendingPathComponent(String(format: "frame-%03d.png", index)))
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? Data(samples.utf8).write(to: runRoot.appendingPathComponent("frame-times.csv"))
        }
        if let editor = owner.findBar.searchField.currentEditor() as? NSTextView {
            check("find-answer.return", owner.findBar.control(owner.findBar.searchField, textView: editor,
                doCommandBy: #selector(NSResponder.insertNewline(_:))))
        } else { check("find-answer.return", false) }
        _ = await until(live ? 20 : 8) { owner.findAnswer?.isRunning == false }
        await frames.value
        if let choice = owner.findAnswer?.choice,
           let data = try? JSONSerialization.data(withJSONObject: ["provider": choice.provider.rawValue,
                "model": choice.model ?? "", "fixture": !live]) {
            try? data.write(to: runRoot.appendingPathComponent("provider-choice.json"))
        }
        _ = await until(6) { !motion.isRunning }
        check("find-answer.answer-visible", owner.findBar.bounds.height >= 110)
        check("find-answer.row-stable", abs(owner.findBar.searchField.convert(NSPoint.zero, to: window.contentView).y - queryOrigin.y) < 1)
        check("find-answer.stream", live ? owner.findAnswer?.messages.last?.text.isEmpty == false : owner.findAnswer?.messages.last?.text.contains("Synthetic streamed answer.") == true)
        if live, let message = owner.findAnswer?.messages.last, let citation = BrowserAICitation.parse(message).first,
           let reader = owner.findOwner as? any BrowserAIPageReading {
            let success = (try? await reader.highlightAIPassage(citation.passage, revision: citation.snapshot.source.revision,
                isCurrent: { owner.findAnswerIsCurrent?() == true })) ?? false
            check("find-answer.highlight", success)
        } else if !live {
            let point = owner.findBar.convert(NSPoint(x: 90, y: 83), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
                guard rows?.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }) == true else { return }
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
            }
            try? await Task.sleep(for: .milliseconds(300))
            if let surface = owner.findOwner {
                let (_, result) = await surface.devToolsCall("Runtime.evaluate", params: #"{"expression":"document.querySelectorAll('mark').length > 0","returnByValue":true}"#)
                let json = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any]
                check("find-answer.jump-click-highlight", (json?["result"] as? [String: Any])?["value"] as? Bool == true)
            }
        } else { check("find-answer.highlight", false) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .milliseconds(200))
            guard let view = window.contentView else { continue }
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
            guard rows?.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }) == true else {
                check("find-answer.capture-owner", false); return
            }
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), runRoot.appendingPathComponent("window-\(name).png").path]
            try? capture.run()
            capture.waitUntilExit()
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: runRoot.appendingPathComponent("find-\(name).png"))
            }
        }
        if live { owner.closeFind(); environment.ai.terminateNow(); return }
        try? Data("slow".utf8).write(to: runRoot.appendingPathComponent("fixture-mode"))
        owner.askInFind()
        try? await Task.sleep(for: .milliseconds(150))
        let stopPoint = owner.findBar.convert(NSPoint(x: 44, y: 91), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
            guard rows?.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }) == true else { return }
            if let event = NSEvent.mouseEvent(with: type, location: stopPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
        }
        _ = await until(1) { owner.findAnswer?.isRunning == false }
        check("find-answer.stop-click", owner.findAnswer?.messages.last?.state == .stopped)
        try? Data("error".utf8).write(to: runRoot.appendingPathComponent("fixture-mode"))
        owner.askInFind()
        _ = await until(2) { owner.findAnswer?.isRunning == false }
        check("find-answer.error", owner.findAnswer?.messages.last?.state == .failed(.failed))
        try? FileManager.default.removeItem(at: runRoot.appendingPathComponent("fixture-mode"))
        owner.findBar.searchField.stringValue = "Actors"
        owner.submitFind("Actors")
        _ = await until(3) { owner.findSession.state?.query == "Actors" }
        _ = await until(3) { owner.findSession.state?.count != nil }
        check("find-answer.normal-find", owner.findAnswer == nil && (owner.findSession.state?.count ?? 0) > 0)
        check("find-answer.query-focus", window.firstResponder === owner.findBar.searchField.currentEditor())
        try? await environment.settings.updateAI { $0.helpers.askInFind = false }
        check("find-answer.helper-off", owner.findAskChoice == nil)
        try? await environment.settings.updateAI { $0.helpers.askInFind = true; $0.isEnabled = false }
        check("find-answer.master-off", owner.findAskChoice == nil)
        try? await environment.settings.updateAI { $0.isEnabled = true; $0.disabledSites = ["127.0.0.1"] }
        check("find-answer.excluded", owner.findAskChoice == nil)
        try? await environment.settings.updateAI { $0.disabledSites = [] }
        let ready = environment.ai.statuses[.codex]
        environment.ai.statuses[.codex] = .init(id: .codex, state: .signedOut)
        check("find-answer.provider-unavailable", owner.findAskChoice == nil)
        environment.ai.statuses[.codex] = ready
        owner.findBar.searchField.stringValue = "Does it support actors?"
        owner.submitFind("Does it support actors?")
        _ = await until(3) { owner.findSession.state?.query == "Does it support actors?" }
        owner.askInFind()
        try? await environment.settings.updateAI { $0.readsCurrentTabOnRequest = false }
        owner.reconcileFindAnswer()
        check("find-answer.revoked", owner.findAnswer == nil && owner.findAskChoice == nil)
        try? await environment.settings.updateAI { $0.readsCurrentTabOnRequest = true }
        owner.askInFind()
        owner.session.selectedSurface?.navigate(to: page.appending(queryItems: [.init(name: "next", value: "1")]))
        _ = await until(3) { owner.findAnswerIsCurrent?() != true }
        owner.reconcileFindAnswer()
        check("find-answer.navigation", owner.findAnswer == nil)
        owner.showFind()
        _ = await until(3) { owner.findOwner != nil && owner.findSession.state?.isVisible == true }
        let expectedFocus = owner.focusBeforeFind
        owner.findBar.focusQuery()
        owner.findBar.cancelOperation(nil)
        _ = await until(2) { owner.findSession.state?.isVisible != true }
        check("find-answer.escape", owner.findSession.state?.isVisible != true && owner.findAnswer == nil)
        let responder = window.firstResponder
        let restored = responder === expectedFocus || (expectedFocus as? NSTextField)?.currentEditor() === responder
        let pageFocused = (responder as? NSView).map { view in
            owner.session.selectedSurface.map { view === $0.hostView || view.isDescendant(of: $0.hostView) } ?? false
        } ?? false
        check("find-answer.escape-focus", responder != nil && (restored || pageFocused))
        if let application {
            let previous = Set(application.windows.windows.keys)
            application.createPrivateCommandWindow()
            await application.waitForPrivateWindowCommands()
            if let privateOwner = application.windows.windows.first(where: { !previous.contains($0.key) })?.value {
                privateOwner.openTab(url: page)
                _ = await committed(privateOwner, page)
                privateOwner.showFind()
                _ = await until(3) { privateOwner.findOwner != nil }
                privateOwner.findBar.searchField.stringValue = "Does it support actors?"
                privateOwner.submitFind("Does it support actors?")
                _ = await until(3) { privateOwner.findSession.state?.query == "Does it support actors?" }
                privateOwner.askInFind()
                check("find-answer.private", privateOwner.isPrivateWindow && privateOwner.findOwner != nil
                    && privateOwner.findAskChoice == nil && privateOwner.findAnswer == nil)
                privateOwner.window?.close()
            } else { check("find-answer.private", false) }
        }
        environment.ai.terminateNow()
    }
}
