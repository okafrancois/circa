import AppKit
import BrowserEngine
import ChromiumEngine

/// Visible qualification using only a marked loopback fixture and the mock credential store.
@MainActor
enum OrbitPasswordPromptScenario {
    static func run(window: OrbitWindowController, fixture: URL, root: URL,
                    record: (String, String, [String: Any]) -> Void) async {
        func check(_ name: String, _ passed: Bool) { record("password-prompt." + name, passed ? "proven" : "failed", [:]) }
        window.window?.setContentSize(NSSize(width: 1506, height: 950))
        window.window?.center()
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if window.isSidebarVisible { window.toggleSidebar() }
        let video = Process()
        video.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        video.arguments = ["-v", "-V", "35", "-l", String(window.window!.windowNumber), root.appendingPathComponent("orbit.mov").path]
        video.standardOutput = FileHandle.nullDevice; video.standardError = FileHandle.standardError
        try? video.run()
        record("password-prompt.capture-started", "proven", [:])
        defer { if video.isRunning { video.interrupt() } }
        try? await Task.sleep(for: .seconds(2))
        func pause() async { try? await Task.sleep(for: .milliseconds(1300)) }
        func navigate(_ host: String) async -> ChromiumSurface? {
            var url = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
            url.host = host; url.path = "/login"
            if let current = window.session.selectedSurface { current.navigate(to: url.url!) }
            else { window.openTab(url: url.url!) }
            await window.session.waitForPendingCommands()
            guard await OrbitRelaunchScenarios.until({ window.session.selectedSurface?.navigationState.committedURL == url.url
                && window.session.selectedSurface?.navigationState.isLoading == false }), let tab = window.session.selectedSurface else { return nil }
            try? await Task.sleep(for: .milliseconds(500))
            return tab
        }
        func input(_ selector: String, text: String, tab: ChromiumSurface) async {
            let expression = "(()=>{const r=document.querySelector('\(selector)').getBoundingClientRect(); return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2})})()"
            let (ok, data) = await tab.devToolsCall("Runtime.evaluate", params: "{\"expression\":\"\(expression)\",\"returnByValue\":true}")
            guard ok, let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = outer["result"] as? [String: Any], let json = result["value"] as? String,
                  let bytes = json.data(using: .utf8), let point = try? JSONSerialization.jsonObject(with: bytes) as? [String: Double],
                  let x = point["x"], let y = point["y"] else { return }
            for type in ["mousePressed", "mouseReleased"] {
                _ = await tab.devToolsCall("Input.dispatchMouseEvent", params: "{\"type\":\"\(type)\",\"x\":\(x),\"y\":\(y),\"button\":\"left\",\"clickCount\":1}")
            }
            let params = try! JSONSerialization.data(withJSONObject: ["text": text])
            _ = await tab.devToolsCall("Input.insertText", params: String(decoding: params, as: UTF8.self))
        }
        func submit(_ tab: ChromiumSurface, fill: Bool = true, expectPrompt: Bool = true) async -> Bool {
            _ = tab.focusDocument()
            if fill {
                await input("#username", text: "orbit-test", tab: tab)
                await input("#password", text: "FixtureOnly-942026", tab: tab)
            }
            await pause()
            _ = await tab.devToolsCall("Runtime.evaluate", params: #"{"expression":"document.querySelector('form').requestSubmit()","userGesture":true}"#)
            if !expectPrompt { try? await Task.sleep(for: .milliseconds(700)); return false }
            return await OrbitRelaunchScenarios.until { window.passwordPrompt.session.prompt != nil }
        }
        func choose(_ decision: BrowserPasswordDecision) -> Bool {
            func find(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.accessibilityIdentifier() == "password-prompt-\(decision.rawValue)" { return button }
                return view.subviews.compactMap(find).first
            }
            guard let root = window.window?.contentView, let button = find(root) else { return false }
            button.performClick(nil)
            return true
        }
        guard let first = await navigate("127.0.0.1") else { check("fixture", false); return }
        check("appear", await submit(first))
        await pause()
        let still = Process()
        still.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        still.arguments = ["-x", "-o", "-l", String(window.window!.windowNumber), root.appendingPathComponent("prompt.png").path]
        try? still.run(); still.waitUntilExit()
        check("no", choose(.notNow))
        await pause()
        guard let repeatTab = await navigate("127.0.0.1") else { check("repeat", false); return }
        check("repeat-appear", await submit(repeatTab))
        await pause()
        check("never", choose(.never))
        await pause()
        guard let blocked = await navigate("127.0.0.1") else { check("blocked-fixture", false); return }
        _ = await submit(blocked, expectPrompt: false)
        check("never-persists", window.passwordPrompt.session.prompt == nil)
        guard let saving = await navigate("localhost") else { check("save-fixture", false); return }
        check("save-appear", await submit(saving))
        await pause()
        check("save", choose(.save))
        await pause()
        guard let filled = await navigate("localhost") else { check("autofill-fixture", false); return }
        // A genuine renderer input gesture releases autofilled values. The server verifies the
        // POST without returning credential values to this native driver or its logs.
        for type in ["mousePressed", "mouseReleased"] {
            _ = await filled.devToolsCall("Input.dispatchMouseEvent", params: "{\"type\":\"\(type)\",\"x\":40,\"y\":40,\"button\":\"left\",\"clickCount\":1}")
        }
        await pause()
        _ = await filled.devToolsCall("Runtime.evaluate", params: #"{"expression":"document.querySelector('form').requestSubmit()","userGesture":true}"#)
        check("autofill", await OrbitRelaunchScenarios.until { filled.navigationState.title == "Fixture filled" })
        await pause()
        guard let updating = await navigate("localhost") else { check("update-fixture", false); return }
        await input("#password", text: "", tab: updating)
        _ = await updating.devToolsCall("Input.dispatchKeyEvent", params: #"{"type":"keyDown","key":"a","modifiers":4,"commands":["selectAll"]}"#)
        _ = await updating.devToolsCall("Input.dispatchKeyEvent", params: #"{"type":"keyUp","key":"a","modifiers":4}"#)
        _ = await updating.devToolsCall("Input.insertText", params: #"{"text":"FixtureOnly-Updated-942026"}"#)
        check("update-appear", await submit(updating, fill: false) && window.passwordPrompt.session.prompt?.state == .update)
        await pause()
        check("update", choose(.save))
        await pause()
        let deadline = ContinuousClock.now + .seconds(12)
        while video.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        check("recording", !video.isRunning && FileManager.default.fileExists(atPath: root.appendingPathComponent("orbit.mov").path))
    }
}
