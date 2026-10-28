import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import ChromiumEngine
import Foundation

extension OrbitSmokeDriver {
    func passwordScenarios(_ window: OrbitWindowController, _ tab: ChromiumSurface,
                           _ engine: ChromiumBrowserEngine) async {
        guard let probe = engine.conformanceProbe, let source = tab.passwordPrompts else {
            check("passwords.source", false); return
        }
        var shows: [BrowserPasswordPrompt] = []
        var hides = 0
        var unregisterOnHide = false
        let observe: @MainActor (BrowserPasswordPromptEvent, BrowserPasswordPrompt) -> Void = { event, prompt in
            if event == .show { shows.append(prompt) }
            if event == .hide {
                hides += 1
                if unregisterOnHide { unregisterOnHide = false; source.observePasswordPrompt(nil) }
            }
        }
        source.observePasswordPrompt(observe)
        defer { source.observePasswordPrompt(nil) }
        let login = URL(string: "/essentials/password-login", relativeTo: fixture)!.absoluteURL
        let submitted = URL(string: "/essentials/password-submit", relativeTo: fixture)!.absoluteURL
        func submit(_ username: String, updated: Bool = false, observing: Bool = true) async -> BrowserPasswordPrompt? {
            window.submitAddress(login.absoluteString)
            guard await committed(window, login) != nil else { return nil }
            try? await Task.sleep(for: .milliseconds(400))
            let count = shows.count
            // Fixture values only; never return credential fields through diagnostic events.
            _ = try? await probe.evaluateScript("document.querySelector('#username').value=''; document.querySelector('#username').focus(); 'ready'", in: tab)
            _ = await tab.devToolsCall("Input.insertText", params: "{\"text\":\"\(username)\"}")
            _ = try? await probe.evaluateScript("document.querySelector('#password').value=''; document.querySelector('#password').focus(); 'ready'", in: tab)
            _ = await tab.devToolsCall("Input.insertText", params: "{\"text\":\"\(updated ? "FixtureUpdated!72" : "FixtureInitial!51")\"}")
            _ = try? await probe.evaluateScript("document.querySelector('form').requestSubmit(); 'submitted'", in: tab)
            _ = await committed(window, submitted)
            if !observing {
                guard await until(4, { source.pendingPasswordPrompt?.state == .save }) else { return nil }
                check("passwords.disabled-no-show", shows.count == count)
                return source.pendingPasswordPrompt
            }
            guard await until(4, { shows.count > count }) else {
                check("passwords.pending-state", false, ["state": source.pendingPasswordPrompt?.state.rawValue ?? -1])
                return nil
            }
            try? await Task.sleep(for: .milliseconds(150))
            check("passwords.exactly-one-\(username)", shows.count == count + 1)
            return shows.last
        }
        source.observePasswordPrompt(nil)
        guard let retained = await submit("fixture-pending", observing: false) else { check("passwords.disabled-retained", false); return }
        check("passwords.disabled-retained", retained.canReopen)
        source.observePasswordPrompt(observe)
        guard let pending = source.pendingPasswordPrompt else { return }
        check("passwords.reopen", source.reopenPasswordPrompt(generation: pending.generation))
        check("passwords.pending-decline", source.decidePasswordPrompt(.notNow, generation: pending.generation))
        guard let save = await submit("fixture-save") else { check("passwords.save-callback", false); return }
        check("passwords.save-callback", save.state == .save && save.username == "fixture-save" && save.passwordMasked
              && save.profileID == tab.profileID && save.origin == fixture.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        check("passwords.stale-refused", !source.decidePasswordPrompt(.save, generation: save.generation &- 1))
        unregisterOnHide = true
        check("passwords.save", source.decidePasswordPrompt(.save, generation: save.generation))
        source.observePasswordPrompt(observe)
        check("passwords.one-shot", !source.decidePasswordPrompt(.save, generation: save.generation))
        try? await Task.sleep(for: .milliseconds(600))
        guard let update = await submit("fixture-save", updated: true) else { check("passwords.update-callback", false); return }
        check("passwords.update-callback", update.state == .update)
        check("passwords.update", source.decidePasswordPrompt(.save, generation: update.generation))
        try? await Task.sleep(for: .milliseconds(400))
        guard let notNow = await submit("fixture-decline") else { check("passwords.not-now-callback", false); return }
        check("passwords.not-now", source.decidePasswordPrompt(.notNow, generation: notNow.generation))
        guard let never = await submit("fixture-never") else { check("passwords.never-callback", false); return }
        check("passwords.never", source.decidePasswordPrompt(.never, generation: never.generation))
        check("passwords.hide", hides >= 4)
        try? await Task.sleep(for: .milliseconds(600))
    }
}

extension OrbitSmokeDriver {
    func passwordGenerationScenario(_ window: OrbitWindowController, _ tab: ChromiumSurface,
                                    _ engine: ChromiumBrowserEngine) async {
        guard let probe = engine.conformanceProbe, let native = window.window else { return }
        native.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let registration = URL(string: "/essentials/password-generate", relativeTo: fixture)!.absoluteURL
        window.submitAddress(registration.absoluteString)
        guard await committed(window, registration) != nil else { check("generation.fixture", false); return }
        tab.focusDocument()
        try? await Task.sleep(for: .milliseconds(700))
        _ = try? await probe.evaluateScript("document.querySelector('#username').focus(); 'ready'", in: tab)
        _ = await tab.devToolsCall("Input.insertText", params: #"{"text":"fixture-generation"}"#)
        let bounds = try? await probe.evaluateScript("(()=>{const r=document.querySelector('#password').getBoundingClientRect();return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2})})()", in: tab)
        if let bounds, let data = bounds.data(using: .utf8), let point = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
           let x = point["x"], let y = point["y"] {
            _ = await tab.devToolsCall("Input.dispatchMouseEvent", params: "{\"type\":\"mousePressed\",\"button\":\"left\",\"clickCount\":1,\"x\":\(x),\"y\":\(y)}")
            _ = await tab.devToolsCall("Input.dispatchMouseEvent", params: "{\"type\":\"mouseReleased\",\"button\":\"left\",\"clickCount\":1,\"x\":\(x),\"y\":\(y)}")
        }
        let offered = await until(3) { NSApp.windows.contains { $0 !== native && $0.isVisible && NSStringFromClass(type(of: $0)) == "NativeWidgetMacNSWindow" } }
        check("generation.popup-offered", offered)
        record("generation.window-types", "proven", ["windows": NSApp.windows.filter { $0 !== native && $0.isVisible }.map { ["class": NSStringFromClass(type(of: $0)), "width": $0.frame.width, "height": $0.frame.height] }])
        if offered {
            for (index, popup) in NSApp.windows.filter({ $0 !== native && $0.isVisible }).enumerated() {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(popup.windowNumber), runRoot.appendingPathComponent("generation-popup-\(index).png").path]
                if (try? capture.run()) != nil { capture.waitUntilExit() }
            }
            // Exercise the native Cocoa button observed in the popup capture.
            if let popup = NSApp.windows.first(where: { $0 !== native && $0.isVisible && NSStringFromClass(type(of: $0)) == "NativeWidgetMacNSWindow" }) {
                let point = NSPoint(x: popup.frame.width * 0.78, y: 32)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(event) }
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        let accepted = try? await probe.evaluateScript("(()=>{const v=document.querySelector('#password')?.value??'';return String(v.length>=12&&/[a-z]/.test(v)&&/[A-Z]/.test(v)&&/[0-9]/.test(v))})()", in: tab)
        check("generation.accepted-strong", accepted == "true")
        if accepted == "true" {
            _ = try? await probe.evaluateScript("document.querySelector('form').requestSubmit(); 'submitted'", in: tab)
            _ = await committed(window, URL(string: "/essentials/password-submit", relativeTo: fixture)!.absoluteURL)
            try? await Task.sleep(for: .milliseconds(500))
            let login = URL(string: "/essentials/password-login", relativeTo: fixture)!.absoluteURL
            window.submitAddress(login.absoluteString)
            _ = await committed(window, login)
            tab.focusDocument()
            try? await Task.sleep(for: .milliseconds(500))
            _ = try? await probe.evaluateScript("document.querySelector('#password').focus(); 'ready'", in: tab)
            _ = await tab.devToolsCall("Input.dispatchKeyEvent", params: #"{"type":"rawKeyDown","key":"ArrowDown","code":"ArrowDown","windowsVirtualKeyCode":40}"#)
            _ = await tab.devToolsCall("Input.dispatchKeyEvent", params: #"{"type":"keyUp","key":"ArrowDown","code":"ArrowDown","windowsVirtualKeyCode":40}"#)
            let suggestions = await until(2) { NSApp.windows.contains { $0 !== native && $0.isVisible && NSStringFromClass(type(of: $0)) == "NativeWidgetMacNSWindow" } }
            check("generation.hosted-suggestions", suggestions)
            window.openTab(url: page("password-popup-dismissal"))
            _ = await committed(window, page("password-popup-dismissal"))
            let dismissed = await until(2) { !NSApp.windows.contains { $0 !== native && $0.isVisible && NSStringFromClass(type(of: $0)) == "NativeWidgetMacNSWindow" } }
            check("generation.popup-tab-dismissal", dismissed)

        }
    }
}
