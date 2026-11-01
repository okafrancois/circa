import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import ChromiumEngine

extension OrbitSmokeDriver {
    func writingScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        environment.ai.terminateNow()
        _ = await until(10) { !environment.ai.isChecking }
        let live = arguments.contains("--orbit-smoke-writing-live")
        if !live {
            let client = OrbitAssistantFixtureClient(id: .codex, root: runRoot)
            environment.ai.clientOverrides[.codex] = client
            environment.ai.statuses[.codex] = await client.status(refresh: false)
        }
        try? await environment.settings.updateAI {
            $0.isEnabled = true
            $0.readsCurrentTabOnRequest = true
            $0.helpers.writingHelp = true
            if !live { $0.defaultModels[.quick] = .init(provider: .codex, model: "synthetic-codex", effort: "low") }
        }
        if live {
            environment.ai.refresh(explicit: true, keepRunning: true)
            _ = await until(12) { !environment.ai.isChecking }
        }
        guard let window = owner.window else { check("writing.window", false); return }
        if arguments.contains("--orbit-smoke-writing-light") {
            NSApp.appearance = NSAppearance(named: .aqua)
            window.appearance = NSAppearance(named: .aqua)
        }
        window.center(); window.makeKeyAndOrderFront(nil)
        let page = fixture.appendingPathComponent("writing.html")
        owner.openTab(url: page)
        await owner.session.waitForQueuedCommands()
        _ = await committed(owner, page)
        guard let surface = owner.pageCommandSurface(), let writer = surface as? any BrowserAIWriting else { check("writing.surface", false); return }
        func evaluate(_ expression: String) async -> Any? {
            guard let params = try? JSONSerialization.data(withJSONObject: ["expression": expression, "returnByValue": true]) else { return nil }
            let (_, reply) = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: params, as: UTF8.self))
            return ((try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]).flatMap { $0["result"] as? [String: Any] }?["value"]
        }
        func owns() -> Bool {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
            return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        if arguments.contains("--orbit-smoke-writing-reference") {
            let reference = fixture.appendingPathComponent("reference.html")
            owner.openTab(url: reference)
            _ = await committed(owner, reference)
            guard let referenceSurface = owner.pageCommandSurface() else { return }
            func ref(_ script: String) async {
                guard owns(), let data = try? JSONSerialization.data(withJSONObject: ["expression": script]) else { return }
                _ = await referenceSurface.devToolsCall("Runtime.evaluate", params: String(decoding: data, as: UTF8.self))
            }
            await ref("document.querySelector('#h6').scrollIntoView({block:'center'})")
            let recording = Process(); recording.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            recording.arguments = ["-x", "-v", "-V", "7", "-l", String(window.windowNumber), runRoot.appendingPathComponent("reference.mov").path]
            if owns() { try? recording.run() }
            try? await Task.sleep(for: .milliseconds(300))
            await ref("document.querySelector('#h6b').click()")
            try? await Task.sleep(for: .milliseconds(900))
            await ref("document.querySelector('#h6w [data-w]').click()")
            _ = await until(9) { !recording.isRunning }
            return
        }
        let recording = Process(); recording.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        recording.arguments = ["-x", "-v", "-V", "12", "-l", String(window.windowNumber), runRoot.appendingPathComponent("native.mov").path]
        if owns() { try? recording.run() }
        defer { if recording.isRunning { recording.terminate() } }
        _ = await until(3) { owns() }
        if let choice = owner.writingChoice, let data = try? JSONSerialization.data(withJSONObject: [
            "provider": choice.provider.rawValue, "model": choice.model ?? "", "effort": choice.effort ?? "",
            "fixture": !live, "reducedMotion": OrbitMotionPreferences.prefersReducedMotion,
            "appearance": window.effectiveAppearance.name.rawValue]) {
            try? data.write(to: runRoot.appendingPathComponent("provider-choice.json"))
        }
        let measurement = Task { @MainActor in
            let start = ProcessInfo.processInfo.systemUptime
            var rows = "seconds,toolbarScale,resultHeight\n"
            for _ in 0..<220 {
                let toolbar = window.childWindows?.first { $0.identifier?.rawValue == "writing-toolbar" }
                let result = window.childWindows?.first { $0.identifier?.rawValue == "writing-result" }
                rows += "\(ProcessInfo.processInfo.systemUptime - start),\(toolbar?.contentView?.layer?.presentation()?.transform.m11 ?? 0),\(result?.frame.height ?? 0)\n"
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
            }
            try? Data(rows.utf8).write(to: self.runRoot.appendingPathComponent("native-frames.csv"))
        }
        defer { measurement.cancel() }
        for kind in ["input", "textarea", "div"] {
            guard owns() else { check("writing.owner", false); return }
            _ = await evaluate("document.body.innerHTML='<\(kind) id=editor contenteditable=true style=\"margin:80px;width:600px;font:20px system-ui\"></\(kind)>';var e=document.getElementById('editor');if('value' in e)e.value='The team are ready to ships this release.';else e.textContent='The team are ready to ships this release.';e.focus();if('select' in e)e.select();else{var r=document.createRange();r.selectNodeContents(e);var s=getSelection();s.removeAllRanges();s.addRange(r)};true")
            let revision = surface.documentGeneration
            guard let selection = try? await writer.writingSelection(revision: revision, isCurrent: { true }) else { check("writing.\(kind).selection", false); continue }
            check("writing.\(kind).selection", selection.text == "The team are ready to ships this release.")
            guard owns() else { return }
            window.makeFirstResponder(surface.hostView)
            check("writing.\(kind).eligible", owner.writingChoice != nil)
            // Native key-up uses the same settle/capture path as a user's completed selection.
            if let event = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) { NSApp.sendEvent(event) }
            try? await Task.sleep(for: .milliseconds(800))
            check("writing.\(kind).toolbar", window.childWindows?.contains { $0.identifier?.rawValue == "writing-toolbar" } == true)
            if arguments.contains("--orbit-smoke-writing-ask") {
                owner.writingHelp?.run(.ask)
                try? await Task.sleep(for: .milliseconds(400))
                check("writing.ask-prefilled", owner.palette.isPresented && owner.palette.draft == selection.text)
                check("writing.ask-focused", window.firstResponder is NSTextView)
                check("writing.ask-not-sent", !FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("request-codex-1.txt").path))
                return
            }
            owner.writingHelp?.run(.fix)
            _ = await until(live ? 20 : 8) { owner.writingHelp?.running == false }
            check("writing.\(kind).draft", owner.writingHelp?.output.isEmpty == false)
            check("writing.\(kind).unchanged", await evaluate("('value' in e?e.value:e.textContent)==='The team are ready to ships this release.'") as? Bool == true)
            if owns() {
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), runRoot.appendingPathComponent("writing-\(kind).png").path]
                try? capture.run(); capture.waitUntilExit()
            }
            if kind == "div", !live {
                for action in [BrowserWritingHelp.Action.improve, .shorter, .translate] {
                    owner.writingHelp?.run(action)
                    _ = await until(5) { owner.writingHelp?.running == false }
                    check("writing.action.\(action)", owner.writingHelp?.output.isEmpty == false)
                }
                try? Data("slow".utf8).write(to: runRoot.appendingPathComponent("fixture-mode"))
                owner.writingHelp?.retry()
                try? await Task.sleep(for: .milliseconds(150))
                owner.writingHelp?.stop()
                check("writing.stop", owner.writingHelp?.running == false)
                try? Data("error".utf8).write(to: runRoot.appendingPathComponent("fixture-mode"))
                owner.writingHelp?.retry()
                _ = await until(3) { owner.writingHelp?.running == false }
                check("writing.error", owner.writingHelp?.error.isEmpty == false)
                try? FileManager.default.removeItem(at: runRoot.appendingPathComponent("fixture-mode"))
                owner.writingHelp?.retry()
                _ = await until(5) { owner.writingHelp?.running == false }
                check("writing.retry-action", owner.writingHelp?.action == .translate && owner.writingHelp?.output.isEmpty == false)
            }
            let output = owner.writingHelp?.output ?? ""
            owner.writingHelp?.apply(insertBelow: kind == "textarea")
            try? await Task.sleep(for: .milliseconds(500))
            let value = await evaluate("'value' in e?e.value:e.textContent") as? String
            check("writing.\(kind).applied", !output.isEmpty && value?.contains(output) == true)
            guard owns() else { return }
            _ = await evaluate("e.focus();document.execCommand('undo');true")
            check("writing.\(kind).undo", await evaluate("('value' in e?e.value:e.textContent)==='The team are ready to ships this release.'") as? Bool == true)
            if kind == "div", !live {
                _ = await evaluate("var r=document.createRange();r.selectNodeContents(e);getSelection().removeAllRanges();getSelection().addRange(r);true")
                if let lease = try? await writer.writingSelection(revision: revision, isCurrent: { true }) {
                    _ = await evaluate("e.textContent+=' manual edit';true")
                    let applied = try? await writer.applyWriting("stale draft", selection: lease, insertBelow: false, revision: revision, isCurrent: { true })
                    check("writing.stale-rejected", applied == false)
                } else { check("writing.stale-rejected", false) }
            }
            owner.writingHelp?.dismiss()
            if live { break }
        }
        for key in ["master", "helper", "read", "site"] {
            let saved = environment.settings.document.ai
            try? await environment.settings.updateAI {
                switch key {
                case "master": $0.isEnabled = false
                case "helper": $0.helpers.writingHelp = false
                case "read": $0.readsCurrentTabOnRequest = false
                default: $0.disabledSites = ["127.0.0.1"]
                }
            }
            check("writing.block.\(key)", owner.writingChoice == nil)
            try? await environment.settings.updateAI { $0 = saved }
        }
        _ = await evaluate("document.body.innerHTML='<input id=password type=password value=secret>';document.getElementById('password').focus();document.getElementById('password').select();true")
        let password = try? await writer.writingSelection(revision: surface.documentGeneration, isCurrent: { true })
        check("writing.block.password", password == nil)
        _ = await until(14) { !recording.isRunning }
        environment.ai.terminateNow()
    }
}
