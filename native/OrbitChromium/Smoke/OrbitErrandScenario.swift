import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import ChromiumEngine

private actor OrbitErrandFixtureClient: BrowserAIProviderClient {
    nonisolated let id: BrowserAIProviderID = .codex
    let root: URL
    let destination: URL
    let mode: String
    var requests: [BrowserAITurnRequest] = []
    init(root: URL, destination: URL, mode: String) { self.root = root; self.destination = destination; self.mode = mode }
    func status(refresh: Bool) async -> BrowserAIProviderStatus {
        .init(id: id, state: .ready(.init(plan: nil)), models: [.init(provider: id, id: "synthetic-errand", displayName: "Synthetic Errand", efforts: ["low", "high"], isDefault: true)])
    }
    func shutdown() async {}
    func startTurn(_ request: BrowserAITurnRequest) async -> BrowserAITurn {
        requests.append(request)
        let data = BrowserAIJSON.parse(Data(request.prompt.utf8))?["data"]?.string ?? ""
        let object = BrowserAIJSON.parse(Data(data.utf8))
        let receiptCount = object?["completedActions"]?.int ?? 0
        let raw = object?["observation"]?.line() ?? Data()
        let observation = try? JSONDecoder().decode(BrowserAIErrandObservation.self, from: raw)
        var result: BrowserAIJSON = ["action": "finish", "summary": "The synthetic task is complete."]
        if ["open", "open-redirect", "open-cross"].contains(mode), receiptCount == 0 {
            let target = mode == "open" ? destination : root.appendingPathComponent(mode == "open-cross" ? "cross" : "redirect")
            result = ["action": "open", "url": .string(target.absoluteString)]
        }
        else if let page = observation?.pages.first, receiptCount < (["functional", "double"].contains(mode) ? 2 : 1) {
            let typing = ["functional", "double"].contains(mode) && receiptCount == 0
            let label = ["pay", "send", "delete"].contains(mode) ? mode : "search"
            if let target = page.targets.first(where: { $0.label.lowercased() == (typing ? "destination" : label) }) {
                result = ["action": typing ? "type" : "click", "tab": .string(page.id.uuidString), "target": .string(target.id.uuidString)]
                if typing, case .object(var fields) = result { fields["value"] = "lisbon"; result = .object(fields) }
            }
        }
        let json = String(decoding: result.line(), as: UTF8.self)
        let stream = AsyncStream<BrowserAITurnEvent>.makeStream()
        let task = Task {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            if mode == "error" { stream.continuation.yield(.failed(.failed)) }
            else if mode == "quota" { stream.continuation.yield(.failed(.limitReached(resetsAt: nil))) }
            else {
                stream.continuation.yield(.text(String(json.prefix(json.count / 2))))
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                stream.continuation.yield(.text(String(json.dropFirst(json.count / 2))))
                stream.continuation.yield(.completed)
            }
            stream.continuation.finish()
        }
        return .init(events: stream.stream, interrupt: { task.cancel(); stream.continuation.finish() })
    }
}

extension OrbitSmokeDriver {
    func errandScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        let mode = (try? String(contentsOf: runRoot.appendingPathComponent("fixture-mode"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "functional"
        let live = arguments.contains("--orbit-smoke-errand-live")
        let client = OrbitErrandFixtureClient(root: fixture, destination: fixture.appendingPathComponent("opened"), mode: mode)
        if live {
            environment.ai.refresh(explicit: true, keepRunning: true)
            _ = await until(12) { !environment.ai.isChecking }
        } else {
            environment.ai.clientOverrides[.codex] = client
            environment.ai.statuses[.codex] = await client.status(refresh: false)
        }
        try? await environment.settings.updateAI {
            $0.isEnabled = true; $0.readsCurrentTabOnRequest = true
            if !live { $0.defaultModels[.errands] = .init(provider: .codex, model: "synthetic-errand", effort: "low") }
        }
        guard let window = owner.window else { check("errand.window", false); return }
        let dark = arguments.contains("--orbit-smoke-errand-dark")
        let theme = OrbitTokens.SpaceTheme(stops: [NSColor(calibratedWhite: dark ? 0.12 : 0.94, alpha: 1)], mode: dark ? .dark : .light, texture: .none, textureIntensity: 0)
        OrbitSpaceThemes.resolver = { _, _ in theme }; owner.windowShell.apply(theme: theme, animated: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(NSSize(width: 1280, height: 820)); window.center()
        owner.showWindow(nil); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        func owns() -> Bool {
            guard NSApp.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
                  NSApp.keyWindow === window, window.isVisible, window.isOnActiveSpace, window.occlusionState.contains(.visible),
                  let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
            return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        }
        _ = await until(3) { owns() }
        guard owns() else { check("errand.owned-window", false); return }
        func movie(_ name: String) -> Process? {
            guard owns() else { return nil }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-v", "-V", "8", "-l", String(window.windowNumber), runRoot.appendingPathComponent(name + ".mov").path]
            do { try process.run(); return process } catch { return nil }
        }
        if mode == "reference" {
            let url = fixture.appendingPathComponent("reference.html")
            owner.openTab(url: url); await owner.session.waitForPendingCommands()
            guard let surface = await committed(owner, url) else { check("errand.reference-loaded", false); return }
            func reference(_ code: String) async -> String? { try? await environment.engine.conformanceProbe?.evaluateScript(code, in: surface) }
            _ = await reference("document.querySelector('[data-theme-set=\(dark ? "dark" : "light")]').click();document.querySelector('#s7').scrollIntoView({block:'center'});true")
            guard await until(5, { surface.navigationState.isLoading == false }) else { return }
            guard let recording = movie("reference") else { check("errand.reference-recording", false); return }
            _ = await reference("globalThis.__errandTrace=[];const start=performance.now();const tick=()=>{const c=document.querySelector('#eappr'),p=document.querySelector('#eag'),r=c.getBoundingClientRect();__errandTrace.push({t:(performance.now()-start)/1000,opacity:Number(getComputedStyle(c).opacity),transform:getComputedStyle(c).transform,display:getComputedStyle(c).display,x:r.x,y:r.y,width:r.width,height:r.height,pointer:getComputedStyle(p).transform});if(performance.now()-start<7000)requestAnimationFrame(tick)};requestAnimationFrame(tick);document.getElementById('e1').click();setTimeout(()=>document.getElementById('eok').click(),3500);true")
            _ = await until(9) { !recording.isRunning }
            if let trace = await reference("JSON.stringify(__errandTrace)") { try? Data(trace.utf8).write(to: runRoot.appendingPathComponent("reference-trace.json")) }
            check("errand.reference-scale", await reference("String(__errandTrace.some(x=>x.display!=='none'&&x.width===420)&&__errandTrace.filter(x=>x.display!=='none').every(x=>x.width===420))") == "true")
            check("errand.reference-recording", recording.terminationStatus == 0)
            return
        }
        func click(_ view: NSView, point: NSPoint? = nil) async -> Bool {
            guard view.window === window, owns() else { check("errand.input-owner", false); return false }
            let location = view.convert(point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard owns(), let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return false }
                NSApp.postEvent(event, atStart: false)
            }
            try? await Task.sleep(for: .milliseconds(80)); return true
        }
        func capture(_ name: String) {
            guard owns() else { check("errand.capture-owner", false); return }
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), runRoot.appendingPathComponent(name + ".png").path]
            try? capture.run(); capture.waitUntilExit()
        }
        let url = fixture.appendingPathComponent("errand")
        owner.openTab(url: url); await owner.session.waitForPendingCommands()
        guard let surface = await committed(owner, url) else { check("errand.fixture", false); return }
        func evaluate(_ code: String) async -> String? { try? await environment.engine.conformanceProbe?.evaluateScript(code, in: surface) }
        let initialTabs = Set(owner.session.organization?.allTabs.map(\.id) ?? [])
        let initialSurfaces = owner.session.ownedSurfaces.count
        if mode == "private", let application {
            application.createPrivateCommandWindow(); await application.waitForPrivateWindowCommands()
            let privateController = application.windows.windows.values.first { $0.isPrivateWindow }
            check("errand.private-controller", privateController != nil)
            check("errand.private-suppressed", privateController?.canStartErrand == false && privateController?.ensureAssistant() == nil)
            let requests = await client.requests
            check("errand.private-no-request", requests.isEmpty)
            return
        }
        check("errand.command-available", owner.canStartErrand)
        guard owns(), owner.palette.registry?.dispatch(.startErrand, origin: .palette) == true else { check("errand.entry", false); return }
        _ = await until(3) { owner.errandDraft && owner.assistantHost != nil }
        let priorRequests = await client.requests
        check("errand.draft-no-request", owner.errandDraft && owner.errand == nil && priorRequests.isEmpty)
        guard let composer = owner.assistantHost else { check("errand.composer", false); return }
        guard await until(2, { (composer.superview?.bounds.width ?? 0) >= 371 && composer.visibleRect.width >= 350 }) else { check("errand.composer-settled", false); return }
        _ = await click(composer, point: NSPoint(x: composer.bounds.midX, y: composer.bounds.height - 84))
        let goal = live ? "click search once then finish with the result" : "type lisbon in destination then click search once and finish"
        for character in goal {
            guard owns(), let event = BrowserKeyEquivalentMatcher.layoutEvent(producing: String(character), flags: []) else { check("errand.input-layout", false); return }
            NSApp.postEvent(event, atStart: false)
            try? await Task.sleep(for: .milliseconds(3))
        }
        _ = await until(2) { (window.firstResponder as? NSTextView)?.string == goal }
        check("errand.native-draft", (window.firstResponder as? NSTextView)?.string == goal)
        guard (window.firstResponder as? NSTextView)?.string == goal else { capture("draft-diagnostic"); return }
        var denseTrace: [[String: Any]] = []
        let pointerStart = ProcessInfo.processInfo.systemUptime
        if arguments.contains("--orbit-smoke-errand-motion") {
            _ = await evaluate("globalThis.__pointerTrace=[];const pt=performance.now();const pointerTick=()=>{const nodes=[...document.documentElement.children],p=nodes.find(x=>x.style.zIndex==='2147483647'&&x.style.pointerEvents==='none'),o=nodes.find(x=>x.style.zIndex==='2147483646'&&x.style.pointerEvents==='none');__pointerTrace.push({t:(performance.now()-pt)/1000,transform:p?getComputedStyle(p).transform:null,outline:o?getComputedStyle(o).outlineWidth:null});if(performance.now()-pt<7000)requestAnimationFrame(pointerTick)};requestAnimationFrame(pointerTick);true")
        }
        let sampleStart = ContinuousClock.now
        let pointerEnd = ProcessInfo.processInfo.systemUptime
        let sampling = Task { @MainActor in
            var last: NSView?
            while !Task.isCancelled, owns() {
                if let current = owner.errandHost { last = current }
                if let card = owner.errandHost ?? last, card.superview != nil, !card.isHidden {
                    let elapsed = sampleStart.duration(to: .now)
                    let rect = card.convert(card.bounds, to: nil)
                    denseTrace.append(["t": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                        "opacity": card.layer?.presentation()?.opacity ?? card.layer?.opacity ?? 1,
                        "y": card.layer?.presentation()?.transform.m42 ?? 0,
                        "x": rect.minX, "top": window.frame.height - rect.maxY, "width": rect.width, "height": rect.height])
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
        let recording = arguments.contains("--orbit-smoke-errand-motion") ? movie("native") : nil
        defer {
            sampling.cancel()
            if recording?.isRunning == true { recording?.interrupt(); recording?.waitUntilExit() }
            if let bytes = try? JSONSerialization.data(withJSONObject: denseTrace) { try? bytes.write(to: runRoot.appendingPathComponent("native-dense-trace.json")) }
        }
        _ = await click(composer, point: NSPoint(x: composer.bounds.width - 36, y: composer.bounds.height - 34))
        _ = await until(live ? 25 : 5) { (owner.errand?.approval != nil && owner.errandHost != nil) || { if case .failed = owner.errand?.phase { return true }; return false }() }
        check("errand.folder-created", owner.errandFolder != nil && owner.errandTabs.count == 1)
        if ["error", "quota"].contains(mode) {
            check("errand.error-no-mutation", await evaluate("String(document.body.dataset.count||'0')") == "0")
            check("errand.failed", { if case .failed = owner.errand?.phase { return true }; return false }())
            capture("error"); return
        }
        guard let task = owner.errand, let approval = task.approval, let card = owner.errandHost else { check("errand.approval", false); capture("missing-approval"); return }
        if live {
            record("errand.live-provider", environment.ai.clientOverrides[task.choice.provider] == nil ? "proven" : "failed",
                ["provider": task.choice.provider.rawValue, "model": task.choice.model, "fixture": false])
        }
        _ = await until(3) { !card.isHidden }
        try? await Task.sleep(for: .milliseconds(400))
        check("errand.zero-before-approval", await evaluate("String(document.body.dataset.count||'0')") == "0")
        check("errand.card-bounds", abs(card.bounds.width - 420) < 1 && card.bounds.height > 80 && card.bounds.height < 400)
        capture("approval")
        if mode == "owner-page" {
            if let raw = await evaluate("JSON.stringify((()=>{const r=document.getElementById('search').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})())"),
               let point = try? JSONDecoder().decode([Double].self, from: Data(raw.utf8)), point.count == 2 {
                let view = surface.hostView
                _ = await click(view, point: NSPoint(x: point[0], y: view.isFlipped ? point[1] : view.bounds.height-point[1]))
            }
            _ = await until(3) { !owner.errandActive }
            check("errand.native-owner-takeover", task.phase == .stopped && owner.errandHost == nil)
            check("errand.manual-effect-only", await evaluate("String(document.body.dataset.count||'0')") == "1")
            check("errand.owner-no-followup", await client.requests.count == 1)
            return
        }
        if ["stop", "card-stop", "revoke", "master", "site", "provider", "stale", "form-change", "navigate", "close", "space", "profile", "transfer"].contains(mode) {
            if mode == "stop" { _ = await click(owner.sidebar.errandStopButton) }
            if mode == "card-stop" { _ = await click(card, point: NSPoint(x: card.bounds.width - 160, y: card.bounds.height - 36)) }
            if mode == "revoke" { try? await environment.settings.updateAI { $0.readsCurrentTabOnRequest = false } }
            if mode == "master" { try? await environment.settings.updateAI { $0.isEnabled = false } }
            if mode == "site" { try? await environment.settings.updateAI { $0.disabledSites = ["127.0.0.1"] } }
            if mode == "provider" { environment.ai.statuses[.codex] = .init(id: .codex, state: .signedOut) }
            if mode == "navigate" {
                owner.submitAddress(fixture.appendingPathComponent("owner-navigation").absoluteString)
                await owner.session.waitForPendingCommands()
                _ = await until(3) { surface.navigationState.committedURL?.path == "/owner-navigation" }
            }
            if mode == "close" { owner.closeSelectedTab(); await owner.session.waitForPendingCommands() }
            if mode == "transfer", let space = owner.session.organization?.spaceID, let tab = owner.session.organization?.selectedTab?.id {
                _ = await owner.session.moveItems([.tab(tab)], to: .init(.today(space))).value
            }
            if ["space", "profile"].contains(mode), let profile = owner.session.activeProfileID {
                let targetProfile = mode == "profile" ? await environment.store.createProfile(name: "Synthetic Other") : profile
                if let space = try? await environment.store.createSpace(name: "Synthetic Other", profileID: targetProfile) {
                    owner.session.activateSpace(space); await owner.session.waitForPendingCommands()
                }
            }
            if ["stale", "form-change"].contains(mode) {
                _ = await evaluate(mode == "stale" ? "document.getElementById('search').replaceWith(document.getElementById('search').cloneNode(true));true" : "document.getElementById('destination').value='changed';true")
                _ = await click(card, point: NSPoint(x: card.bounds.width - 60, y: card.bounds.height - 36))
            }
            _ = await until(3) { !owner.errandActive }
            task.allowOnce(approval.id)
            check("errand.revoked-no-followup", await client.requests.count == 1)
            if !["close", "space", "profile"].contains(mode) { check("errand.revoked-no-effect", await evaluate("String(document.body.dataset.count||'0')") == "0") }
            check("errand.revoked-card-removed", owner.errandHost == nil && !owner.errandActive)
            if ["stop", "card-stop", "revoke", "master", "site", "provider", "stale", "form-change", "navigate", "transfer"].contains(mode) {
                check("errand.stopped-keeps-tabs", initialTabs.isSubset(of: Set(owner.session.organization?.allTabs.map(\.id) ?? [])))
            }
            if mode == "navigate" { check("errand.owner-navigation", surface.navigationState.committedURL?.path == "/owner-navigation") }
            return
        }
        var approvals: [UUID] = [], trace: [[String: Any]] = []
        let traceStart = ContinuousClock.now
        for _ in 0..<4 {
            guard let pending = task.approval, let view = owner.errandHost else { break }
            guard await until(3, { !view.isHidden }) else { check("errand.card-visible", false); return }
            approvals.append(pending.id)
            for _ in 0..<24 {
                let t = traceStart.duration(to: .now)
                trace.append(["t": Double(t.components.seconds) + Double(t.components.attoseconds) / 1e18,
                    "opacity": view.layer?.presentation()?.opacity ?? 1, "y": view.layer?.presentation()?.transform.m42 ?? 0,
                    "width": view.bounds.width, "height": view.bounds.height])
                try? await Task.sleep(for: .milliseconds(16))
            }
            _ = await click(view, point: NSPoint(x: view.bounds.width - 60, y: view.bounds.height - 36))
            if mode == "double", view.window === window { _ = await click(view, point: NSPoint(x: view.bounds.width - 60, y: view.bounds.height - 36)) }
            guard await until(1, { task.approval?.id != pending.id }) else { check("errand.native-allow", false); capture("allow-diagnostic"); return }
            task.allowOnce(pending.id)
            _ = await until(live ? 20 : 5) { task.approval?.id != pending.id && (task.approval != nil || !owner.errandActive) }
            if !owner.errandActive { break }
        }
        if let bytes = try? JSONSerialization.data(withJSONObject: trace) { try? bytes.write(to: runRoot.appendingPathComponent("native-trace.json")) }
        check("errand.single-use-ids", Set(approvals).count == approvals.count && approvals.contains(approval.id))
        if mode == "popup" {
            check("errand.popup-contained", task.phase == .stopped && owner.session.ownedSurfaces.count == initialSurfaces)
            return
        }
        if mode == "open-cross" {
            check("errand.cross-origin-contained", task.phase == .stopped && owner.errandTabs.count == 2)
            return
        }
        check("errand.finished", task.phase == .completed)
        _ = await until(2) { task.pages.isEmpty && owner.errandLeases.isEmpty }
        check("errand.completion-drops-page-leases", task.pages.isEmpty && owner.errandLeases.isEmpty)
        if ["open", "open-redirect"].contains(mode) {
            check("errand.open-owned", owner.errandTabs.count == 2 && owner.errandTabs.isSubset(of: Set(owner.session.organization?.allTabs.map(\.id) ?? [])))
            if mode == "open-redirect" { check("errand.redirect-final", owner.session.ownedSurfaces.contains { $0.navigationState.committedURL?.path == "/opened" }) }
        }
        else { check("errand.exactly-one-effect", await evaluate("String(document.body.dataset.count||'0')") == "1") }
        check("errand.summary-draft", !task.summary.isEmpty)
        if mode == "double" { check("errand.fading-card-shields-input", await evaluate("String(document.body.dataset.danger||'0')") == "0") }
        if task.phase == .completed {
            _ = await until(2) { owner.sidebar.page.list.row(for: .tab(owner.errandSummaryID)) != nil }
            if let row = owner.sidebar.page.list.row(for: .tab(owner.errandSummaryID)) { _ = await click(row) }
            _ = await until(2) { (owner.assistantHost?.superview?.bounds.width ?? 0) >= 371 }
            check("errand.native-summary-open", owner.assistantHost != nil)
        }
        if !live {
            let requests = await client.requests
            check("errand.exact-goal-and-model", requests.allSatisfy { $0.prompt.contains(goal) && $0.model == "synthetic-errand" && $0.effort == "low" })
            check("errand.no-secret-content", requests.allSatisfy { !$0.prompt.contains("private-sentinel") && $0.instructions.contains("You have no tools") })
        }
        capture("result")
        if arguments.contains("--orbit-smoke-errand-motion"), let trace = await evaluate("JSON.stringify(__pointerTrace)") {
            try? Data(trace.utf8).write(to: runRoot.appendingPathComponent("pointer-trace.json"))
            if let timing = try? JSONSerialization.data(withJSONObject: ["clockAdmissionSeconds": pointerEnd - pointerStart]) {
                try? timing.write(to: runRoot.appendingPathComponent("pointer-timing.json"))
            }
        }
        if let recording { _ = await until(9) { !recording.isRunning }; check("errand.motion-recording", recording.terminationStatus == 0) }
    }
}
