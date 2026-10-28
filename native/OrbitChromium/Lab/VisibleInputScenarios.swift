import AppKit
import BrowserCore
import ChromiumEngine
import Foundation

/// Visible input has its own audit contract. It never produces a hidden-mode result.
@MainActor
final class VisibleInputAudit {
    let window: NSWindow
    let ledger: LabLedger
    var onViolation: (() -> Void)?
    private var timer: Timer?
    private(set) var samples = 0
    private(set) var violations = 0
    private(set) var keyAndActiveSamples = 0

    init(window: NSWindow, ledger: LabLedger) {
        self.window = window
        self.ledger = ledger
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func tick() {
        samples += 1
        if window.isKeyWindow && NSApp.isActive { keyAndActiveSamples += 1 }
        // Check only this process's windows. Never enumerate personal windows or their titles.
        let others = NSApp.windows.filter { $0 !== window }
        if !others.isEmpty {
            violations += 1
            ledger.event("visible-input-violation", ["otherOwnedWindows": String(others.count)])
            if violations == 1 { onViolation?() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }
    var isValid: Bool { samples > 0 && violations == 0 && keyAndActiveSamples > 0 }
    var summary: [String: Any] {
        ["samples": samples, "violations": violations, "keyAndActiveSamples": keyAndActiveSamples,
         "ownedWindowNumber": window.windowNumber, "mode": "visible-input", "hiddenPassed": false]
    }
}

extension Laboratory {
    func visibleInputScenario() async {
        let limit = arguments.visibleInputSeconds
        ledger.event("visible-input-start", ["maximumSeconds": String(limit)])
        // Independent of individual awaits. The runner and external witness also enforce bounds.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(limit))
            guard !self.finished else { return }
            self.visibleInputWindow?.orderOut(nil)
            await self.finish(abortReason: "visible-input-watchdog")
        }
        engine = ChromiumBrowserEngine(persistence: .persistent)
        delegate = RecorderDelegate(ledger: ledger)
        delegate.acceptNewSurfaces = false
        guard engine.patchLevel >= 1 else {
            ledger.record("visible.input.preconditions", "failed", ["reason": "hosted patch is required"])
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 840, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Orbit synthetic visible input — automatic close"
        visibleInputWindow = window
        let audit = VisibleInputAudit(window: window, ledger: ledger)
        visibleInputAudit = audit
        audit.onViolation = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.finish(abortReason: "unexpected-visible-input-window") }
        }
        audit.start()
        let capability: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                       "windowNumber": window.windowNumber, "mode": "visible-input"]
        do {
            let data = try JSONSerialization.data(withJSONObject: capability)
            let path = arguments.root.appendingPathComponent("visible-window.json")
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            ledger.record("visible.input.preconditions", "failed", ["reason": "window capability could not be written"])
            return
        }
        guard !finished, let registration = engine.makeWindow(for: window) else { return }
        visibleInputRegistration = registration
        let profile = ProfileID()
        _ = engine.profile(for: profile)
        await engine.profileReady(profile)
        guard !finished, let tab = engine.makeTabSurface(profileID: profile, in: registration, delegate: delegate) else {
            ledger.record("visible.input.preconditions", "failed", ["reason": "hosted tab creation refused"])
            return
        }
        surfaces.append(tab)
        place(tab, in: window.contentView!)
        tab.onEngineEvent = { [ledger] name, fields in
            let allowed = fields.filter { ["style", "browser", "generation", "code", "status"].contains($0.key) }
            ledger.event("visible-engine-" + name, allowed)
        }
        ledger.event("visible-creation-wait-start")
        let created = await until(5) { tab.isBrowserCreated }
        ledger.check("visible.input.creation", created && !finished, ["created": created,
            "pending": tab.isCreationPending, "bridge": bridgeDiagnostics(),
            "logicalBrowsers": registration.logicalBrowserCount])
        guard created, !finished else { return }
        ledger.event("visible-document-wait-start")
        tab.navigate(to: url("/page?case=x2-visible-input"))
        let loaded = await committed(tab, "case=x2-visible-input", 5)
        let counts = delegate.count(tab)
        ledger.check("visible.input.document", loaded && !finished, ["loading": tab.navigationState.isLoading,
            "hasCommittedURL": tab.navigationState.committedURL != nil,
            "matchesFixture": tab.navigationState.committedURL?.absoluteString.contains("case=x2-visible-input") == true,
            "starts": counts.starts, "commits": counts.commits, "finishes": counts.finishes, "failures": counts.failures])
        guard loaded, !finished else { return }
        let identity = tab.tabIdentity
        let generation = tab.documentGeneration
        func stableLifetime() -> Bool {
            !finished && !tab.isDisposed && tab.isBrowserCreated && tab.documentGeneration == generation
                && tab.tabIdentity == identity && identity?.isHosted == true && identity?.isActive == true
        }
        let policyAccepted = NSApp.setActivationPolicy(.regular)
        ledger.event("visible-activation-request", ["policyAccepted": String(policyAccepted),
                     "activationPolicy": String(NSApp.activationPolicy().rawValue)])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        _ = await until(3) {
            VisibleInputReadiness.decision(ownerStable: stableLifetime(), key: window.isKeyWindow,
                                          active: NSApp.isActive, confirmed: false) != .waiting
        }
        let activationReady = VisibleInputReadiness.decision(ownerStable: stableLifetime(), key: window.isKeyWindow,
                                                            active: NSApp.isActive, confirmed: false) == .ready
        ledger.check("visible.input.activation", policyAccepted && activationReady, ["policyAccepted": policyAccepted,
                     "keyWindow": window.isKeyWindow, "appActive": NSApp.isActive, "ownerStable": stableLifetime(),
                     "activationPolicy": NSApp.activationPolicy().rawValue, "reason": activationReady ? "confirmed" : "not-confirmed-or-owner-changed"])
        guard policyAccepted, activationReady else { return }
        let focusRequested = tab.focusDocument()
        ledger.event("visible-native-focus-request", ["accepted": String(focusRequested)])
        _ = await evaluate(tab, """
        (() => {
          const field = document.getElementById('field');
          const observation = window.__orbitVisibleInput = {events: []};
          for (const type of ['compositionstart','compositionupdate','compositionend','beforeinput','input','selectionchange']) {
            document.addEventListener(type, event => {
              if (event.target !== field && type !== 'selectionchange') return;
              observation.events.push({type, trusted: event.isTrusted, data: event.data ?? null,
                inputType: event.inputType ?? null, value: field.value,
                start: field.selectionStart, end: field.selectionEnd});
            }, true);
          }
          field.focus();
          return document.activeElement === field;
        })()
        """)
        func sameOwner() -> Bool {
            VisibleInputReadiness.decision(ownerStable: stableLifetime(), key: window.isKeyWindow,
                                          active: NSApp.isActive, confirmed: true) == .ready
                && (window.firstResponder as? NSView)?.isDescendant(of: tab.hostView) == true
        }
        func nativeState() -> [String: Any] {
            let current = tab.tabIdentity
            return ["tabID": Int(current?.tabID ?? -1), "windowID": Int(current?.windowID ?? -1),
                    "windowToken": current?.windowToken ?? 0, "documentGeneration": tab.documentGeneration,
                    "hosted": current?.isHosted == true, "active": current?.isActive == true,
                    "keyWindow": window.isKeyWindow, "appActive": NSApp.isActive,
                    "firstResponderInHostView": (window.firstResponder as? NSView)?.isDescendant(of: tab.hostView) == true,
                    "sameOwner": sameOwner()]
        }
        func snapshot() async -> [String: Any] {
            await evaluate(tab, """
            (() => { const f = document.getElementById('field'); return {
              active: document.activeElement === f, focus: document.hasFocus(), value: f.value,
              start: f.selectionStart, end: f.selectionEnd, events: window.__orbitVisibleInput.events
            }; })()
            """) as? [String: Any] ?? [:]
        }
        func observe(_ condition: ([String: Any]) -> Bool) async -> [String: Any] {
            let deadline = Date().addingTimeInterval(3)
            var state: [String: Any] = [:]
            repeat {
                guard sameOwner() else { return state }
                state = await snapshot()
                if condition(state) { return state }
                await pause(0.04)
            } while Date() < deadline && !finished
            return state
        }
        func externallyWitnessed() -> Bool {
            let path = arguments.root.appendingPathComponent("visible-window-observed.json")
            guard let data = try? Data(contentsOf: path),
                  let observed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return observed["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier)
                && observed["windowNumber"] as? Int == window.windowNumber
                && observed["mode"] as? String == "visible-input"
        }
        let ready = await observe { externallyWitnessed() && $0["active"] as? Bool == true && $0["focus"] as? Bool == true }
        guard sameOwner(), externallyWitnessed(), ready["active"] as? Bool == true, ready["focus"] as? Bool == true,
              ready["value"] as? String == "",
              let client = window.firstResponder as? (NSView & NSTextInputClient) else {
            ledger.record("visible.input.preconditions", "failed", ["nativeOwnerAndFocus": sameOwner(), "native": nativeState(), "dom": ready])
            return
        }
        ledger.record("visible.input.preconditions", "proven", ["nativeOwnerAndFocus": true,
            "externalWindowWitnessObserved": externallyWitnessed(),
            "native": nativeState(), "documentGeneration": generation, "tabID": Int(identity?.tabID ?? -1),
            "windowID": Int(identity?.windowID ?? -1), "dom": ready])
        func eventTypes(_ state: [String: Any]) -> Set<String> {
            Set((state["events"] as? [[String: Any]] ?? []).filter { $0["trusted"] as? Bool == true }
                .compactMap { $0["type"] as? String })
        }
        guard sameOwner() else { return }
        client.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let composing = await observe { state in
            state["value"] as? String == "か"
                && eventTypes(state).isSuperset(of: ["compositionstart", "compositionupdate", "beforeinput", "input"])
        }
        let markedDuringComposition = client.hasMarkedText()
        let compositionOK = markedDuringComposition && sameOwner() && composing["active"] as? Bool == true
            && composing["focus"] as? Bool == true && composing["value"] as? String == "か"
            && eventTypes(composing).isSuperset(of: ["compositionstart", "compositionupdate", "beforeinput", "input"])
        ledger.check("visible.input.composition", compositionOK, ["dom": composing, "native": nativeState(), "nativeMarkedText": markedDuringComposition])
        guard compositionOK, sameOwner() else { return }
        client.insertText("漢", replacementRange: NSRange(location: NSNotFound, length: 0))
        let committed = await observe { state in
            state["value"] as? String == "漢" && eventTypes(state).contains("compositionend")
                && (state["start"] as? Int) == 1 && (state["end"] as? Int) == 1
        }
        let events = committed["events"] as? [[String: Any]] ?? []
        let nativeInputObserved = events.contains { $0["type"] as? String == "input"
            && $0["trusted"] as? Bool == true && $0["value"] as? String == "漢" }
        let markedAfterCommit = client.hasMarkedText()
        ledger.check("visible.input.commit", !markedAfterCommit && sameOwner() && committed["focus"] as? Bool == true
            && committed["active"] as? Bool == true && committed["value"] as? String == "漢"
            && eventTypes(committed).contains("compositionend") && nativeInputObserved
            && committed["start"] as? Int == 1 && committed["end"] as? Int == 1,
            ["dom": committed, "native": nativeState(), "nativeMarkedTextAfterCommit": markedAfterCommit])
        window.orderOut(nil)
    }
}
