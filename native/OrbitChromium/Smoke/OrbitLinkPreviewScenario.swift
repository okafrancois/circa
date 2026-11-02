import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

extension OrbitSmokeDriver {
    func linkPreviewScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        environment.ai.terminateNow()
        _ = await until(10) { !environment.ai.isChecking }
        let live = arguments.contains("--orbit-smoke-link-live")
        if !live {
            let client = OrbitAssistantFixtureClient(id: .codex, root: runRoot)
            environment.ai.clientOverrides[.codex] = client
            environment.ai.statuses[.codex] = await client.status(refresh: false)
            try? Data((arguments.contains("--orbit-smoke-link-error") ? "error" : "link-preview").utf8).write(to: runRoot.appendingPathComponent("fixture-mode"))
        }
        try? await environment.settings.updateAI {
            $0.isEnabled = true; $0.readsCurrentTabOnRequest = true; $0.helpers.linkPreviewSummaries = true
            if !live { $0.defaultModels[.quick] = .init(provider: .codex, model: "synthetic-codex", effort: "low") }
        }
        if live { environment.ai.refresh(explicit: true, keepRunning: true); _ = await until(12) { !environment.ai.isChecking } }
        guard let window = owner.window else { check("link.window", false); return }
        window.appearance = NSAppearance(named: arguments.contains("--orbit-smoke-link-light") ? .aqua : .darkAqua)
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let page = fixture.appendingPathComponent("link.html")
        owner.openTab(url: page)
        await owner.session.waitForQueuedCommands()
        _ = await committed(owner, page)
        guard let surface = owner.pageCommandSurface(), let reader = surface as? any BrowserLinkPreviewSource else { check("link.surface", false); return }
        func owns() -> Bool {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
            return window.isKeyWindow && NSApp.isActive && rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        func event(_ type: NSEvent.EventType, shift: Bool, local: NSPoint) async {
            guard owns() else { check("link.input-owner", false); return }
            let point = surface.hostView.convert(local, to: nil)
            let screen = window.convertPoint(toScreen: point)
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: top - screen.y))
            let event: NSEvent?
            if type == .flagsChanged {
                event = NSEvent.keyEvent(with: type, location: point, modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)
            } else {
                event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)
            }
            if let event { NSApp.postEvent(event, atStart: false) }
            try? await Task.sleep(for: .milliseconds(200))
        }
        func capture(_ name: String) {
            guard owns() else { check("link.capture-owner", false); return }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-l", String(owner.linkPreviewHelp?.panel?.windowNumber ?? window.windowNumber), runRoot.appendingPathComponent(name + ".png").path]
            try? process.run(); process.waitUntilExit()
        }
        if arguments.contains("--orbit-smoke-link-reference") {
            let reference = fixture.appendingPathComponent("reference.html")
            owner.openTab(url: reference)
            _ = await committed(owner, reference)
            guard let referenceSurface = owner.pageCommandSurface() else { return }
            func ref(_ script: String) async {
                guard owns(), let data = try? JSONSerialization.data(withJSONObject: ["expression": script]) else { return }
                _ = await referenceSurface.devToolsCall("Runtime.evaluate", params: String(decoding: data, as: UTF8.self))
            }
            await ref("document.querySelector('#h1').scrollIntoView({block:'center'})")
            let recording = Process(); recording.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            recording.arguments = ["-x", "-v", "-V", "7", "-l", String(window.windowNumber), runRoot.appendingPathComponent("reference.mov").path]
            if owns() { try? recording.run() }
            try? await Task.sleep(for: .milliseconds(300))
            await ref("document.querySelector('#h1b').click()")
            _ = await until(9) { !recording.isRunning }
            return
        }
        let recording = Process(); recording.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        recording.arguments = ["-x", "-v", "-V", "12", "-l", String(window.windowNumber), runRoot.appendingPathComponent("native.mov").path]
        if owns() { try? recording.run() }
        defer { if recording.isRunning { recording.terminate() } }
        let point = NSPoint(x: 100, y: surface.hostView.isFlipped ? 100 : surface.hostView.bounds.height - 100)
        let preferences = environment.settings.document.ai
        if let choice = preferences.defaultModels[.quick] ?? BrowserAIPolicy.automaticChoice(for: .quick, statuses: environment.ai.statuses),
           let data = try? JSONSerialization.data(withJSONObject: ["provider": choice.provider.rawValue, "model": choice.model ?? "", "live": live ? "true" : "false"]) {
            try? data.write(to: runRoot.appendingPathComponent("provider-choice.json"))
        }
        if arguments.contains("--orbit-smoke-link-zoom") {
            owner.changePageZoom(.increase)
            _ = await until(3) { surface.pageZoom > 1.01 }
        }
        let revision = surface.documentGeneration
        let target = try? await reader.previewLink(at: CGPoint(x: 100, y: 100), revision: revision, isCurrent: { true })
        check("link.engine-hit", target?.url.lastPathComponent == "linked.html")
        await event(.mouseMoved, shift: false, local: point)
        try? await Task.sleep(for: .milliseconds(400))
        check("link.ordinary-hover", owner.linkPreviewHelp?.panel == nil && owner.linkPreviewHelp?.loading == false
            && !FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("request-codex-1.txt").path))
        await event(.flagsChanged, shift: true, local: point)
        _ = await until(3) { owner.linkPreviewHelp?.panel != nil }
        check("link.description", owner.linkPreviewHelp?.panel != nil && owner.linkPreviewHelp?.lines.isEmpty == true)
        capture("description")
        if arguments.contains("--orbit-smoke-link-error") {
            _ = await until(8) { owner.linkPreviewHelp?.loading == false }
            check("link.error-fallback", owner.linkPreviewHelp?.panel != nil && owner.linkPreviewHelp?.lines.isEmpty == true
                && owner.linkPreviewHelp?.document?.title == "Synthetic linked title")
            capture("error")
            await event(.flagsChanged, shift: false, local: point)
            _ = await until(14) { !recording.isRunning }
            environment.ai.terminateNow()
            return
        }
        _ = await until(live ? 22 : 8) { owner.linkPreviewHelp?.lines.isEmpty == false }
        check("link.summary", owner.linkPreviewHelp?.lines.isEmpty == false)
        if !live {
            check("link.actual-text", owner.linkPreviewHelp?.lines.first == "Synthetic linked body verified.")
            let prompt = (try? String(contentsOf: runRoot.appendingPathComponent("request-codex-1.txt"), encoding: .utf8)) ?? ""
            check("link.linked-body", prompt.contains("LINKED_BODY_SENTINEL") && !prompt.contains("SOURCE_ONLY_SENTINEL"))
        }
        capture("summary")
        await event(.flagsChanged, shift: false, local: point)
        check("link.shift-release", owner.linkPreviewHelp?.panel == nil && owner.linkPreviewHelp?.loading == false)
        await event(.flagsChanged, shift: true, local: point)
        _ = await until(3) { owner.linkPreviewHelp?.panel != nil }
        if !live { check("link.cached", !FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("request-codex-2.txt").path)) }
        await event(.mouseMoved, shift: true, local: NSPoint(x: 400, y: point.y))
        check("link.leave", owner.linkPreviewHelp?.panel == nil)
        await event(.mouseMoved, shift: true, local: point)
        _ = await until(3) { owner.linkPreviewHelp?.panel != nil }
        try? await environment.settings.updateAI { $0.helpers.linkPreviewSummaries = false }
        _ = await until(2) { owner.linkPreviewHelp?.panel == nil }
        check("link.disable", owner.linkPreviewHelp?.panel == nil)
        for gate in ["master", "read", "site"] {
            try? await environment.settings.updateAI {
                $0 = preferences
                switch gate {
                case "master": $0.isEnabled = false
                case "read": $0.readsCurrentTabOnRequest = false
                default: $0.disabledSites = ["127.0.0.1"]
                }
            }
            await event(.flagsChanged, shift: false, local: point)
            await event(.flagsChanged, shift: true, local: point)
            try? await Task.sleep(for: .milliseconds(200))
            check("link.gate." + gate, owner.linkPreviewHelp?.panel == nil && owner.linkPreviewHelp?.loading == false)
        }
        try? await environment.settings.updateAI { $0 = preferences }
        await event(.flagsChanged, shift: false, local: point)
        await event(.flagsChanged, shift: true, local: point)
        _ = await until(3) { owner.linkPreviewHelp?.panel != nil }
        owner.openTab(url: fixture.appendingPathComponent("linked.html"))
        _ = await until(3) { owner.linkPreviewHelp?.panel == nil }
        check("link.navigation", owner.linkPreviewHelp?.panel == nil)
        _ = await until(14) { !recording.isRunning }
        environment.ai.terminateNow()
    }
}
