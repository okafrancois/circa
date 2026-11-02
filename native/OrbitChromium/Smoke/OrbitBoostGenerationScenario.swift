import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

private actor OrbitBoostFixtureClient: BrowserAIProviderClient {
    nonisolated let id: BrowserAIProviderID = .codex
    let root: URL
    init(root: URL) { self.root = root }
    func status(refresh: Bool) async -> BrowserAIProviderStatus {
        .init(id: id, state: .ready(.init(plan: nil, usage: nil)), models: [.init(provider: id, id: "synthetic-boost-chat", displayName: "Synthetic Chat")])
    }
    func shutdown() async {}
    func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        let mode = (try? String(contentsOf: root.appendingPathComponent("fixture-mode"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "valid"
        let body = ["prompt": request.prompt, "instructions": request.instructions, "model": request.model ?? "", "effort": request.effort ?? ""]
        if let bytes = try? JSONSerialization.data(withJSONObject: body) { try? bytes.write(to: root.appendingPathComponent("request.json")) }
        let pair = AsyncStream<BrowserAITurnEvent>.makeStream()
        let task = Task {
            let source: String
            switch mode {
            case "js", "js-slow": source = "// Reviewed generated draft\nconst count = () => { document.body.dataset.boostCount = String(Number(document.body.dataset.boostCount || 0) + 1); };\nif (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', count, {once:true}); else count();"
            case "js-invalid": source = "document.body.dataset.boostCount = ;"
            case "js-markdown": source = "```javascript\ndocument.body.dataset.boostCount = '1';\n```"
            case "invalid-comments": source = "h1 { color: blue; color: r/**/ed; }"
            case "source-map": source = "/*# sourceMappingURL=http://127.0.0.1:8893/forbidden-resource */\n.shorts-shelf { display: none; }"
            case "invalid": source = "<style>body { display:none }</style>"
            case "resource": source = "body { background-image: u\\72l(http://127.0.0.1:8893/forbidden-resource); }"
            case "script": source = "document.body.textContent = 'unsafe'"
            case "empty": source = ""
            default: source = ".shorts-shelf { display: none !important; }\n#primary.watch-layout { grid-template-columns: 1fr; max-width: 100%; margin: 0; }\n#secondary { display: none; }"
            }
            for line in source.split(separator: "\n") {
                do { try await Task.sleep(for: .milliseconds(["slow", "js-slow"].contains(mode) ? 3000 : 350)) } catch { return }
                pair.continuation.yield(.text(String(line) + "\n"))
            }
            pair.continuation.yield(mode == "quota-error" ? .failed(.limitReached(resetsAt: nil)) : mode == "error" ? .failed(.failed) : .completed)
            pair.continuation.finish()
        }
        return .init(events: pair.stream, interrupt: { task.cancel(); pair.continuation.finish() })
    }
}

extension OrbitSmokeDriver {
    func boostGenerationScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        let live = arguments.contains("--orbit-smoke-boost-live")
        if !live {
            let client = OrbitBoostFixtureClient(root: runRoot)
            environment.ai.clientOverrides[.codex] = client
            environment.ai.statuses[.codex] = await client.status(refresh: false)
        } else {
            environment.ai.refresh(explicit: true, keepRunning: true)
            _ = await until(12) { !environment.ai.isChecking }
        }
        try? await environment.settings.updateAI {
            $0.isEnabled = true; $0.readsCurrentTabOnRequest = true
            if !live { $0.defaultModels[.chat] = .init(provider: .codex, model: "synthetic-boost-chat") }
        }
        guard let window = owner.window else { return }
        let dark = arguments.contains("--orbit-smoke-boost-dark")
        let desiredAppearance: NSAppearance.Name = dark ? .darkAqua : .aqua
        let theme = OrbitTokens.SpaceTheme(stops: [NSColor(calibratedWhite: dark ? 0.12 : 0.94, alpha: 1)], mode: dark ? .dark : .light, texture: .none, textureIntensity: 0)
        OrbitSpaceThemes.resolver = { _, _ in theme }
        owner.windowShell.apply(theme: theme, animated: false)
        window.appearance = NSAppearance(named: desiredAppearance)
        window.setContentSize(NSSize(width: 1506, height: 949)); window.center()
        owner.showWindow(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        func recordMotion(_ name: String) -> Process? {
            guard NSApp.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]], rows.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }) else { return nil }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-v", "-V", "8", "-l", String(window.windowNumber), runRoot.appendingPathComponent(name + ".mov").path]
            try? process.run(); return process
        }
        if arguments.contains("--orbit-smoke-boost-reference") {
            var parts = URLComponents(url: fixture.appendingPathComponent("reference.html"), resolvingAgainstBaseURL: false)!
            parts.queryItems = [.init(name: "theme", value: arguments.contains("--orbit-smoke-boost-dark") ? "dark" : "light")]
            let url = parts.url!
            owner.openTab(url: url); await owner.session.waitForQueuedCommands()
            guard let surface = await committed(owner, url) else { return }
            func ref(_ script: String) async -> String? { try? await environment.engine.conformanceProbe?.evaluateScript(script, in: surface) }
            _ = await ref("document.querySelector('#s5').scrollIntoView({block:'center'});typeof gsap")
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(600))
            let recording = recordMotion("reference")
            guard recording != nil, NSApp.isActive, NSApp.keyWindow === window else { check("boost.reference-owner", false); return }
            check("boost.reference-scale", await ref("String(document.querySelector('.be').getBoundingClientRect().width)") == "480")
            _ = await ref("globalThis.__boostTrace=[];const start=performance.now();const tick=()=>{const p=document.getElementById('player'),s=document.getElementById('shorts');__boostTrace.push({t:performance.now()-start,width:p.getBoundingClientRect().width,opacity:getComputedStyle(s).opacity,display:getComputedStyle(s).display});if(performance.now()-start<6500)requestAnimationFrame(tick)};requestAnimationFrame(tick);document.getElementById('b5').click();true")
            _ = await until(9) { recording?.isRunning != true }
            if let trace = await ref("JSON.stringify(__boostTrace)") {
                try? Data(trace.utf8).write(to: runRoot.appendingPathComponent("reference-trace.json"))
                let rows = (try? JSONSerialization.jsonObject(with: Data(trace.utf8))) as? [[String: Any]] ?? []
                let widths = rows.compactMap { $0["width"] as? Double }
                check("boost.reference-layout", (widths.max() ?? 0) - (widths.min() ?? 0) > 10)
                check("boost.reference-fade", rows.contains { ($0["display"] as? String) == "none" } && rows.contains { let a = Double($0["opacity"] as? String ?? "1") ?? 1; return a > 0 && a < 1 })
            }
            check("boost.reference-recorded", recording?.terminationStatus == 0)
            return
        }
        let url = fixture.appendingPathComponent("boost.html")
        owner.openTab(url: url); await owner.session.waitForQueuedCommands()
        guard let surface = await committed(owner, url) else { check("boost.fixture", false); return }
        if arguments.contains("--orbit-smoke-boost-relaunch"), arguments.contains("--orbit-smoke-boost-generated-js") {
            try? await Task.sleep(for: .milliseconds(400))
            check("js.relaunch-one", (try? await environment.engine.conformanceProbe?.evaluateScript("document.body.dataset.boostCount || '0'", in: surface)) == "1")
            check("js.relaunch-no-generation", !FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("request.json").path))
            return
        }
        if arguments.contains("--orbit-smoke-boost-relaunch") {
            var display: String?
            for _ in 0..<30 {
                display = try? await environment.engine.conformanceProbe?.evaluateScript("getComputedStyle(document.querySelector('.shorts-shelf')).display", in: surface)
                if display == "none" { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            check("boost.relaunch-dom", display == "none")
            if let runtime = owner.boostsRuntime, let profile = owner.session.activeProfileID, let store = try? runtime.store(for: profile) {
                check("boost.relaunch-saved-css", await store.snapshot().boosts.contains { !$0.content.customCSS.isEmpty })
            } else { check("boost.relaunch-saved-css", false) }
            check("boost.relaunch-no-generation", !FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("request.json").path))
            return
        }
        func owns(_ w: NSWindow) -> Bool {
            guard NSApp.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), NSApp.keyWindow === w, w.isVisible, w.isOnActiveSpace, w.occlusionState.contains(.visible) else { return false }
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]]
            return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        func click(_ view: NSView) async -> Bool {
            guard let w = view.window else { return false }
            NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
            _ = await until(2) { owns(w) }
            guard owns(w) else { check("boost.input-owner", false); return false }
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard owns(w), let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return false }
                NSApp.postEvent(event, atStart: false)
            }
            try? await Task.sleep(for: .milliseconds(120))
            return true
        }
        func evaluate(_ source: String) async -> String? { try? await environment.engine.conformanceProbe?.evaluateScript(source, in: surface) }
        owner.createBoost(); await owner.boostTask?.value
        guard let editor = owner.boostEditor else { check("boost.editor", false); return }
        let failureMode = (try? String(contentsOf: runRoot.appendingPathComponent("fixture-mode"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "valid"
        let existingCSSCase = ["--orbit-smoke-boost-cancel", "--orbit-smoke-boost-revoke", "--orbit-smoke-boost-stale", "--orbit-smoke-boost-stop", "--orbit-smoke-boost-prompt-change"].contains(where: arguments.contains) || ["invalid", "invalid-comments", "source-map", "resource", "script", "empty", "error", "quota-error"].contains(failureMode)
        if existingCSSCase { editor.session.edit { $0.customCSS = "h1 { color: #8b1717 !important; }" }; await editor.session.pending?.value }
        if arguments.contains("--orbit-smoke-boost-existing-js") {
            editor.session.edit { $0.customJavaScript = "document.addEventListener('DOMContentLoaded', () => { document.body.dataset.previousBoost = '1'; }, {once:true});" }
            editor.session.setJavaScriptConsent(true)
            await editor.session.pending?.value
        }
        owner.windowShell.apply(theme: theme, animated: false)
        window.appearance = NSAppearance(named: desiredAppearance)
        editor.showCode()
        guard let panel = editor.window, let code = panel.contentView as? BrowserBoostCodeView else { return }
        panel.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(600))
        let baseline = await editor.session.store.snapshot()
        let baselineCSS = editor.session.boost.content.customCSS
        let baselineColor = await evaluate("getComputedStyle(document.querySelector('h1')).color")
        if existingCSSCase { check("boost.existing-css-rendered", baselineColor == "rgb(139, 23, 23)") }
        check("boost.native-scale", panel.frame.width == 480)
        let rgb = code.layer?.backgroundColor?.components ?? []
        let expectedRGB: [Double] = dark ? [34.0/255, 33.0/255, 40.0/255] : [1, 1, 1]
        check("boost.editor-appearance", code.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == desiredAppearance && rgb.count >= 3 && zip(rgb.prefix(3), expectedRGB).allSatisfy { abs(Double($0.0) - $0.1) < 0.001 })
        if arguments.contains("--orbit-smoke-boost-gates") {
            _ = await click(code.prompt)
            for character in "hide shorts" {
                guard owns(panel), let event = BrowserKeyEquivalentMatcher.layoutEvent(producing: String(character), flags: []) else { check("boost.gate-input-owner", false); return }
                NSApp.postEvent(event, atStart: false); try? await Task.sleep(for: .milliseconds(8))
            }
            check("boost.gated-native-prompt", code.prompt.stringValue == "hide shorts")
            func gateButtons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? gateButtons($0) } }
            guard let send = gateButtons(code).first(where: { $0.accessibilityLabel() == uiText("Generate CSS") }) else { check("boost.gate-send", false); return }
            func gatedClick(_ name: String) async {
                _ = await click(send)
                check("boost." + name + "-native-rejection", !editor.generation.running && !editor.generation.ready && !editor.generation.error.isEmpty)
            }
            let original = environment.settings.document.ai
            try? await environment.settings.updateAI { $0.readsCurrentTabOnRequest = false }
            check("boost.read-gate", owner.boostChatChoice == nil)
            await gatedClick("read")
            try? await environment.settings.updateAI { $0 = original; $0.disabledSites = ["127.0.0.1"] }
            check("boost.site-gate", owner.boostChatChoice == nil)
            await gatedClick("site")
            try? await environment.settings.updateAI { $0 = original; $0.isEnabled = false }
            check("boost.master-gate", owner.boostChatChoice == nil)
            await gatedClick("master")
            try? await environment.settings.updateAI { $0 = original }
            let status = environment.ai.statuses[.codex]
            environment.ai.statuses[.codex] = .init(id: .codex, state: .signedOut)
            check("boost.provider-gate", owner.boostChatChoice == nil)
            await gatedClick("provider")
            check("boost.provider-state", owner.boostGenerationUnavailableText == browserAssistantErrorText(.signedOut))
            environment.ai.statuses[.codex] = .init(id: .codex, state: .ready(.init(plan: nil, usage: .init(windows: [.init(span: .fiveHours, usedPercent: 100, resetsAt: nil)]))))
            check("boost.quota-gate", owner.boostChatChoice == nil)
            await gatedClick("quota")
            check("boost.quota-state", owner.boostGenerationUnavailableText == browserAssistantErrorText(.limitReached(resetsAt: nil)))
            environment.ai.statuses[.codex] = status
            if let application {
                application.createPrivateCommandWindow(); await application.waitForPrivateWindowCommands()
                if let privateOwner = application.windows.windows.values.first(where: { $0.isPrivateWindow }) {
                    privateOwner.openTab(url: url); await privateOwner.session.waitForPendingCommands()
                    _ = await committed(privateOwner, url)
                    privateOwner.createBoost(); await privateOwner.boostTask?.value
                    check("boost.private-gate", privateOwner.boostChatChoice == nil && !privateOwner.canCreateBoost && privateOwner.boostEditor == nil)
                    privateOwner.window?.performClose(nil)
                } else { check("boost.private-gate", false) }
            }
            check("boost.gates-no-request", !FileManager.default.fileExists(atPath: runRoot.appendingPathComponent("request.json").path))
            editor.close(); return
        }
        check("boost.chat-ready", owner.boostChatChoice != nil)
        if let choice = owner.boostChatChoice, let bytes = try? JSONSerialization.data(withJSONObject: ["provider": choice.provider.rawValue, "model": choice.model ?? "automatic", "effort": choice.effort ?? "automatic", "fixture": !live]) { try? bytes.write(to: runRoot.appendingPathComponent("provider-choice.json")) }
        _ = await click(code.prompt)
        if arguments.contains("--orbit-smoke-boost-manual") {
            _ = await click(code.textView)
            for character in "body" {
                guard owns(panel), let event = BrowserKeyEquivalentMatcher.layoutEvent(producing: String(character), flags: []) else { return }
                NSApp.postEvent(event, atStart: false)
                try? await Task.sleep(for: .milliseconds(30))
            }
            await editor.session.pending?.value
            check("boost.manual-code-visible", code.textView.string == "body")
            check("boost.manual-code-saved", editor.session.boost.content.customCSS == "body")
            func findBack(_ view: NSView) -> NSButton? {
                for child in view.subviews {
                    if let button = child as? NSButton, button.title == uiText("←  Back") { return button }
                    if let found = findBack(child) { return found }
                }
                return nil
            }
            if let back = findBack(code) { _ = await click(back) }
            _ = await until(2) { panel.contentView === editor.editor }
            check("boost.manual-back", panel.contentView === editor.editor)
            check("boost.manual-controls-appearance", panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
            editor.close(); return
        }
        if arguments.contains("--orbit-smoke-boost-generated-js") {
            func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
            func count() async -> String? { await evaluate("document.body.dataset.boostCount || '0'") }
            guard let js = buttons(code).first(where: { $0.title == uiText("JS") }) else { check("js.tab", false); return }
            _ = await click(js); await code.selectionTask?.value
            check("js.tab-no-consent", !code.isCSS && panel.attachedSheet == nil && editor.session.boost.javaScriptOptIn == baseline.boosts.first?.javaScriptOptIn)
            _ = await click(code.prompt)
            let prompt = "once the body is ready increment the body attribute whose html name is data boost count with hyphens between the three words"
            for character in prompt {
                guard owns(panel) else { check("js.input-owner", false); return }
                guard let event = BrowserKeyEquivalentMatcher.layoutEvent(producing: String(character), flags: []) else { check("js.input-layout", false); return }
                NSApp.postEvent(event, atStart: false)
                try? await Task.sleep(for: .milliseconds(5))
            }
            try? await Task.sleep(for: .milliseconds(100))
            check("js.exact-prompt", code.prompt.stringValue == prompt)
            check("js.input-guards", owns(panel), ["pid": getpid(), "window": panel.windowNumber, "bundle": Bundle.main.bundleIdentifier ?? "", "activeSpace": panel.isOnActiveSpace, "visible": panel.isVisible, "occluded": !panel.occlusionState.contains(.visible), "foremost": NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()])
            guard let send = buttons(code).first(where: { $0.accessibilityLabel() == uiText("Generate JavaScript") }) else { check("js.send", false); return }
            var recording: Process?
            if arguments.contains("--orbit-smoke-boost-motion"), owns(panel) {
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-v", "-V", "8", "-l", String(panel.windowNumber), runRoot.appendingPathComponent("js-native.mov").path]
                do { try capture.run(); recording = capture } catch { check("js.recording-start", false) }
            }
            defer { recording?.waitUntilExit() }
            _ = await click(send)
            _ = await until(3) { editor.generation.running && !code.textView.string.isEmpty }
            if !["js-invalid", "js-markdown", "empty", "error", "quota-error"].contains(failureMode) {
                check("js.streaming-visible", editor.generation.running && !code.textView.string.isEmpty)
            }
            check("js.streaming-zero", await count() == "0")
            check("js.streaming-not-saved", await editor.session.store.snapshot() == baseline)
            if arguments.contains("--orbit-smoke-boost-stop") {
                _ = await click(send)
                check("js.stop", !editor.generation.running && !editor.generation.ready)
                check("js.stop-zero", await count() == "0")
                check("js.stop-not-saved", await editor.session.store.snapshot() == baseline)
                editor.close(); return
            }
            let deadline = ContinuousClock.now + .seconds(live ? 28 : 5)
            var zeroThroughout = true, unchangedThroughout = true, samples = 0
            while editor.generation.running, ContinuousClock.now < deadline {
                if await count() != "0" { zeroThroughout = false }
                if await editor.session.store.snapshot() != baseline { unchangedThroughout = false }
                samples += 1
                try? await Task.sleep(for: .milliseconds(40))
            }
            if !["js-invalid", "js-markdown", "empty", "error", "quota-error"].contains(failureMode) { check("js.stream-sampled", samples > 0) }
            check("js.stream-observations-zero", zeroThroughout)
            check("js.stream-observations-not-saved", unchangedThroughout)
            if let bytes = try? JSONSerialization.data(withJSONObject: ["samples": samples, "zero": zeroThroughout, "unchanged": unchangedThroughout]) { try? bytes.write(to: runRoot.appendingPathComponent("js-observations.json")) }
            check("js.review-zero", await count() == "0")
            check("js.review-not-saved", await editor.session.store.snapshot() == baseline)
            if ["js-invalid", "js-markdown", "empty", "error", "quota-error"].contains(failureMode) {
                check("js.rejected", !editor.generation.ready && !editor.generation.error.isEmpty)
                editor.close(); return
            }
            check("js.review-ready", editor.generation.ready && !code.isCSS && code.textView.string == editor.generation.output)
            var reviewedSource = editor.generation.output
            if arguments.contains("--orbit-smoke-boost-edit") {
                _ = await click(code.textView)
                guard owns(panel), let selectAll = BrowserKeyEquivalentMatcher.layoutEvent(producing: "a", flags: .maskCommand) else { check("js.edit-owner", false); return }
                NSApp.postEvent(selectAll, atStart: false)
                try? await Task.sleep(for: .milliseconds(60))
                for character in "return" {
                    guard owns(panel), let event = BrowserKeyEquivalentMatcher.layoutEvent(producing: String(character), flags: []) else { check("js.edit-owner", false); return }
                    NSApp.postEvent(event, atStart: false)
                    try? await Task.sleep(for: .milliseconds(30))
                }
                check("js.edit-source", code.textView.string == "return" && editor.generation.output == "return")
                check("js.edit-not-saved", await editor.session.store.snapshot() == baseline)
                guard let apply = buttons(code).first(where: { $0.title == uiFormat("Apply to %@", editor.session.boost.hostPattern.host) }) else { return }
                _ = await click(apply)
                _ = await until(3) { !editor.generation.applying }
                check("js.edit-syntax-rejected", !editor.generation.ready && !editor.generation.error.isEmpty)
                check("js.edit-no-consent", panel.attachedSheet == nil)
                check("js.edit-zero", await count() == "0")
                check("js.edit-preserved", await editor.session.store.snapshot() == baseline)
                _ = await click(send)
                _ = await until(5) { !editor.generation.running }
                check("js.edit-regenerated-ready", editor.generation.ready)
                reviewedSource = editor.generation.output
            }
            if owns(panel) {
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(panel.windowNumber), runRoot.appendingPathComponent("js-review.png").path]
                try? capture.run(); capture.waitUntilExit()
            }
            if let bytes = try? JSONSerialization.data(withJSONObject: ["source": editor.generation.output, "fixture": !live]) { try? bytes.write(to: runRoot.appendingPathComponent("js-review.json")) }
            if arguments.contains("--orbit-smoke-boost-other-window"), let application, let id = application.windows.newWindow() {
                await application.windows.waitForPendingCommands()
                if let other = application.windows.windows[id] {
                    other.openTab(url: url); await other.session.waitForPendingCommands()
                    if let page = await committed(other, url) {
                        check("js.other-window-zero", (try? await other.engine.conformanceProbe?.evaluateScript("document.body.dataset.boostCount || '0'", in: page)) == "0")
                    } else { check("js.other-window-zero", false) }
                    other.window?.performClose(nil)
                }
                check("js.other-window-not-saved", await editor.session.store.snapshot() == baseline)
                editor.close(); return
            }
            if arguments.contains("--orbit-smoke-boost-revoke") || arguments.contains("--orbit-smoke-boost-stale") || arguments.contains("--orbit-smoke-boost-navigation") || arguments.contains("--orbit-smoke-boost-cancel") || arguments.contains("--orbit-smoke-boost-space") {
                if arguments.contains("--orbit-smoke-boost-revoke") { try? await environment.settings.updateAI { $0.isEnabled = false } }
                if arguments.contains("--orbit-smoke-boost-stale") { editor.session.rename(to: "Concurrent source"); await editor.session.pending?.value }
                if arguments.contains("--orbit-smoke-boost-space") {
                    let profile = await environment.store.createProfile(name: "Synthetic JavaScript profile")
                    if let space = try? await environment.store.createSpace(name: "Synthetic JavaScript Space", profileID: profile) {
                        owner.session.activateSpace(space); await owner.session.waitForPendingCommands()
                    }
                }
                if arguments.contains("--orbit-smoke-boost-navigation") || arguments.contains("--orbit-smoke-boost-space") {
                    owner.submitAddress(url.appending(queryItems: [.init(name: "next", value: "true")]).absoluteString)
                    await owner.session.waitForPendingCommands()
                }
                if arguments.contains("--orbit-smoke-boost-cancel") { editor.close() }
                _ = await until(3) { !editor.generation.ready }
                check("js.revoked", !editor.generation.ready)
                let saved = await editor.session.store.snapshot().boosts.first
                check("js.revoked-source", saved?.content.customJavaScript == baseline.boosts.first?.content.customJavaScript && saved?.javaScriptOptIn == baseline.boosts.first?.javaScriptOptIn)
                editor.close(); return
            }
            guard let apply = buttons(code).first(where: { $0.title == uiFormat("Apply to %@", editor.session.boost.hostPattern.host) }) else { return }
            _ = await click(apply)
            _ = await until(3) { panel.attachedSheet != nil }
            guard let sheet = panel.attachedSheet, let content = sheet.contentView,
                  let cancel = buttons(content).first(where: { $0.title == uiText("Cancel") }) else { check("js.consent", false); return }
            if owns(sheet) {
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(sheet.windowNumber), runRoot.appendingPathComponent("js-consent.png").path]
                try? capture.run(); capture.waitUntilExit()
            }
            _ = await click(cancel)
            _ = await until(2) { !editor.generation.applying }
            check("js.declined-unchanged", await editor.session.store.snapshot() == baseline)
            check("js.declined-zero", await count() == "0")
            _ = await click(apply)
            _ = await until(3) { panel.attachedSheet != nil }
            guard let acceptedSheet = panel.attachedSheet, let acceptedContent = acceptedSheet.contentView,
                  let enable = buttons(acceptedContent).first(where: { $0.title == uiText("Enable JavaScript") }) else { check("js.fresh-consent", false); return }
            _ = await click(enable)
            _ = await until(4) { !editor.generation.applying }
            check("js.saved-consent", editor.session.boost.javaScriptOptIn && editor.session.boost.content.customJavaScript == reviewedSource && !reviewedSource.isEmpty)
            check("js.applied-before-reload-zero", await count() == "0")
            editor.close(); surface.reload(); _ = await committed(owner, url)
            for _ in 0..<30 {
                if await count() == "1" { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            check("js.reload-one", await count() == "1")
            if arguments.contains("--orbit-smoke-boost-existing-js") { check("js.reload-old-script-absent", await evaluate("document.body.dataset.previousBoost || '0'") == "0") }
            return
        }
        let prompt = "hide shorts and make the player full width"
        for character in prompt {
            guard owns(panel), let event = BrowserKeyEquivalentMatcher.layoutEvent(producing: String(character), flags: []) else { check("boost.character-route", false); return }
            NSApp.postEvent(event, atStart: false)
            try? await Task.sleep(for: .milliseconds(8))
        }
        try? await Task.sleep(for: .milliseconds(120))
        check("boost.native-prompt", code.prompt.stringValue == prompt)
        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        guard let send = buttons(code).first(where: { $0.accessibilityLabel() == uiText("Generate CSS") }) else { check("boost.send", false); return }
        let recording = arguments.contains("--orbit-smoke-boost-motion") ? recordMotion("native") : nil
        _ = await evaluate("globalThis.__boostTrace=[];const start=performance.now();const tick=()=>{const p=document.getElementById('player'),s=document.querySelector('.shorts-shelf');__boostTrace.push({t:performance.now()-start,width:p.getBoundingClientRect().width,opacity:getComputedStyle(s).opacity,display:getComputedStyle(s).display});if(performance.now()-start<6500)requestAnimationFrame(tick)};requestAnimationFrame(tick);true")
        _ = await click(send)
        if arguments.contains("--orbit-smoke-boost-stop") {
            _ = await until(2) { editor.generation.running }
            _ = await click(send)
            check("boost.stop-state", !editor.generation.running && !editor.generation.ready && editor.generation.error == uiText("Stopped"))
            check("boost.stop-preserves-store", await editor.session.store.snapshot() == baseline)
            check("boost.stop-restores-existing-style", await evaluate("getComputedStyle(document.querySelector('h1')).color") == baselineColor)
            check("boost.stop-preserves-page", await evaluate("getComputedStyle(document.querySelector('.shorts-shelf')).display") != "none")
            editor.close(); return
        }
        if ["invalid", "invalid-comments", "resource", "script", "empty"].contains(failureMode) {
            _ = await until(3) { !editor.generation.running }
            check("boost.failure-output-state", !editor.generation.running && (failureMode == "empty" ? editor.generation.output.isEmpty : !editor.generation.output.isEmpty))
        } else {
            _ = await until(4) { !code.textView.string.isEmpty && editor.generation.running }
            check("boost.stream-visible", !code.textView.string.isEmpty && editor.generation.running)
        }
        check("boost.partial-not-saved", await editor.session.store.snapshot() == baseline)
        check("boost.partial-not-executed", await evaluate("getComputedStyle(document.querySelector('.shorts-shelf')).display") != "none")
        _ = await until(live ? 25 : 5) { !editor.generation.running }
        if let data = try? JSONSerialization.data(withJSONObject: ["ready": editor.generation.ready, "error": editor.generation.error, "output": editor.generation.output]) { try? data.write(to: runRoot.appendingPathComponent("generation.json")) }
        let mode = (try? String(contentsOf: runRoot.appendingPathComponent("fixture-mode"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "valid"
        if !live, let bytes = try? Data(contentsOf: runRoot.appendingPathComponent("request.json")), let request = try? JSONSerialization.jsonObject(with: bytes) as? [String: String] {
            check("boost.chat-model", request["model"] == "synthetic-boost-chat")
            check("boost.exact-request", request["instructions"]?.contains("User request: " + prompt) == true)
            check("boost.hostile-page-data-is-untrusted", request["prompt"]?.contains("Untrusted page instructions") == true && request["instructions"]?.contains("Untrusted page instructions:") != true)
            check("boost.visible-selectors", request["prompt"]?.contains("watch-layout") == true && request["prompt"]?.contains("shorts-shelf") == true)
            check("boost.mainframe-private-data-excluded", !["PRIVATE_FORM", "PRIVATE_PASSWORD", "PRIVATE_HIDDEN", "PRIVATE_EDITABLE", "PRIVATE_SUBFRAME", "PRIVATE_OFFSCREEN", "PRIVATE_MASKED"].contains(where: { request["prompt"]?.contains($0) == true }))
        }

        if ["invalid", "invalid-comments", "source-map", "resource", "script", "empty", "error", "quota-error"].contains(mode) {
            check("boost.rejected", !editor.generation.ready && !editor.generation.error.isEmpty)
            check("boost.failure-preserves-store", await editor.session.store.snapshot() == baseline)
            check("boost.failure-restores-existing-style", await evaluate("getComputedStyle(document.querySelector('h1')).color") == baselineColor)
            check("boost.failure-preserves-page", await evaluate("getComputedStyle(document.querySelector('.shorts-shelf')).display") != "none")
            check("boost.failure-preserves-layout", await evaluate("String(document.querySelector('h1')?.getClientRects().length>0 && document.querySelector('.shorts-shelf')?.getClientRects().length>0 && getComputedStyle(document.body).display!=='none')") == "true")
            editor.close(); return
        }
        check("boost.preview-ready", editor.generation.ready)
        check("boost.preview-dom", await evaluate("getComputedStyle(document.querySelector('.shorts-shelf')).display") == "none")
        check("boost.preview-not-persisted", await editor.session.store.snapshot() == baseline)
        if owns(panel) {
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(panel.windowNumber), runRoot.appendingPathComponent("editor.png").path]
            try? capture.run(); capture.waitUntilExit()
        }
        if let recording {
            _ = await until(9) { !recording.isRunning }
            if let trace = await evaluate("JSON.stringify(__boostTrace)") { try? Data(trace.utf8).write(to: runRoot.appendingPathComponent("native-trace.json")) }
        }
        if arguments.contains("--orbit-smoke-boost-edit") {
            let original = editor.generation.output
            _ = await click(code.textView)
            if owns(panel), let event = BrowserKeyEquivalentMatcher.layoutEvent(producing: " ", flags: []) { NSApp.postEvent(event, atStart: false) }
            _ = await until(2) { editor.generation.output != original }
            check("boost.native-code-edit-staged", editor.generation.output != original)
            check("boost.native-code-edit-not-saved", await editor.session.store.snapshot() == baseline)
        }
        if arguments.contains("--orbit-smoke-boost-js-consent") {
            guard let js = buttons(code).first(where: { $0.title == uiText("JS") }),
                  let css = buttons(code).first(where: { $0.title == uiText("CSS") }) else { return }
            _ = await click(js); await code.selectionTask?.value
            check("boost.js-tab-no-consent", !code.isCSS && panel.attachedSheet == nil && !editor.session.boost.javaScriptOptIn)
            func firstWrite() async {
                _ = await click(code.textView)
                guard owns(panel), let event = BrowserKeyEquivalentMatcher.layoutEvent(producing: "b", flags: []) else { check("boost.js-manual-owner", false); return }
                NSApp.postEvent(event, atStart: false)
                _ = await until(2) { panel.attachedSheet != nil }
            }
            await firstWrite()
            if let sheet = panel.attachedSheet, let content = sheet.contentView, let cancel = buttons(content).first(where: { $0.title == uiText("Cancel") }) { _ = await click(cancel) }
            check("boost.js-cancel-no-consent", !editor.session.boost.javaScriptOptIn && editor.session.boost.content.customJavaScript.isEmpty)
            _ = await click(css); await code.selectionTask?.value
            _ = await click(js); await code.selectionTask?.value
            await firstWrite()
            if let sheet = panel.attachedSheet, let content = sheet.contentView, let enable = buttons(content).first(where: { $0.title == uiText("Enable JavaScript") }) { _ = await click(enable) }
            await editor.session.pending?.value
            check("boost.js-explicit-consent", editor.session.boost.javaScriptOptIn)
            check("boost.js-manual-write", !code.isCSS && code.textView.string == "b" && editor.session.boost.content.customJavaScript == "b")
            check("boost.js-no-generated-persistence", editor.session.boost.content.customCSS.isEmpty)
            editor.close(); return
        }
        if arguments.contains("--orbit-smoke-boost-other-window"), let application, let id = application.windows.newWindow() {
            await application.windows.waitForPendingCommands()
            if let other = application.windows.windows[id] {
                other.openTab(url: url); await other.session.waitForPendingCommands()
                if let page = await committed(other, url) {
                    let display = try? await other.engine.conformanceProbe?.evaluateScript("getComputedStyle(document.querySelector('.shorts-shelf')).display", in: page)
                    check("boost.other-window-unmodified", display != "none")
                    check("boost.origin-preview-retained", await evaluate("getComputedStyle(document.querySelector('.shorts-shelf')).display") == "none")
                } else { check("boost.other-window-unmodified", false) }
                other.window?.performClose(nil)
            }
        }
        if arguments.contains("--orbit-smoke-boost-navigation") || arguments.contains("--orbit-smoke-boost-space") {
            if arguments.contains("--orbit-smoke-boost-space") {
                let profile = await environment.store.createProfile(name: "Synthetic other profile")
                if let space = try? await environment.store.createSpace(name: "Synthetic other Space", profileID: profile) { owner.session.activateSpace(space); await owner.session.waitForPendingCommands() }
            }
            let nextURL = url.appending(queryItems: [.init(name: "new-document", value: "true")])
            owner.submitAddress(nextURL.absoluteString)
            await owner.session.waitForPendingCommands()
            if let next = await committed(owner, nextURL) {
                let display = try? await owner.engine.conformanceProbe?.evaluateScript("getComputedStyle(document.querySelector('.shorts-shelf')).display", in: next)
                check("boost.new-source-unmodified", display != "none")
            } else { check("boost.new-source-unmodified", false) }
            _ = await until(3) { !editor.generation.ready }
            check("boost.source-change-invalidates", !editor.generation.ready)
            check("boost.source-change-preserves-store", await editor.session.store.snapshot().boosts.first?.content.customCSS == baselineCSS)
            editor.close(); return
        }
        if arguments.contains("--orbit-smoke-boost-revoke") || arguments.contains("--orbit-smoke-boost-stale") || arguments.contains("--orbit-smoke-boost-prompt-change") {
            if arguments.contains("--orbit-smoke-boost-revoke") { try? await environment.settings.updateAI { $0.isEnabled = false } }
            else if arguments.contains("--orbit-smoke-boost-stale") { editor.session.rename(to: "Changed Boost"); await editor.session.pending?.value }
            else {
                _ = await click(code.prompt)
                if owns(panel), let event = BrowserKeyEquivalentMatcher.layoutEvent(producing: " ", flags: []) { NSApp.postEvent(event, atStart: false) }
                _ = await until(2) { !editor.generation.ready }
                check("boost.prompt-edit-cancels", !editor.generation.running && !editor.generation.ready)
                check("boost.prompt-edit-no-save", await editor.session.store.snapshot() == baseline)
            }
            _ = await until(2) { !editor.generation.ready }
            try? await Task.sleep(for: .milliseconds(250))
            check("boost.invalidated-restores-page", await evaluate("getComputedStyle(document.querySelector('.shorts-shelf')).display") != "none")
            check("boost.invalidated-preserves-css", await editor.session.store.snapshot().boosts.first?.content.customCSS == baselineCSS)
            check("boost.invalidated-restores-existing-style", await evaluate("getComputedStyle(document.querySelector('h1')).color") == baselineColor)
            editor.close(); return
        }
        if arguments.contains("--orbit-smoke-boost-cancel") {
            editor.close()
            _ = await until(2) { editor.session.isClosed }
            try? await Task.sleep(for: .milliseconds(200))
            check("boost.close-restores", await evaluate("getComputedStyle(document.querySelector('.shorts-shelf')).display") != "none")
            check("boost.close-preserves-store", await editor.session.store.snapshot() == baseline)
            check("boost.close-restores-existing-style", await evaluate("getComputedStyle(document.querySelector('h1')).color") == baselineColor)
            return
        }
        guard let apply = buttons(code).first(where: { $0.title == uiFormat("Apply to %@", editor.session.boost.hostPattern.host) }) else { return }
        _ = await click(apply)
        _ = await until(4) { !editor.generation.applying && !editor.generation.ready }
        let saved = await editor.session.store.snapshot()
        check("boost.explicit-apply", saved.revision > baseline.revision && !editor.session.boost.content.customCSS.isEmpty)
        editor.close()
        surface.reload(); _ = await committed(owner, url)
        try? await Task.sleep(for: .milliseconds(400))
        check("boost.reload-persists", await evaluate("getComputedStyle(document.querySelector('.shorts-shelf')).display") == "none")
    }
}
