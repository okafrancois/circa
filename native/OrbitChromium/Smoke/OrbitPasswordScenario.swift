import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Foundation
import LocalAuthentication
import ObjectiveC

// This file is linked only into the synthetic smoke bundle. Mock OS authentication as well as
// Keychain storage: CSV export must never ask for the machine owner's password or biometrics.
private extension LAContext {
    @objc func orbitPasswordCanEvaluate(_ policy: LAPolicy, error: NSErrorPointer) -> Bool { true }
    @objc func orbitPasswordEvaluate(_ access: SecAccessControl, operation: LAAccessControlOperation,
                                    localizedReason: String, reply: @escaping (Bool, Error?) -> Void) {
        reply(true, nil)
    }
}

@MainActor
enum OrbitPasswordScenario {
    static func run(application: OrbitApplication, environment: OrbitEnvironment, window: OrbitWindowController, fixture: URL, root: URL,
                    record: (String, String, [String: Any]) -> Void) async {
        func check(_ name: String, _ passed: Bool) { record("passwords." + name, passed ? "proven" : "failed", [:]) }
        let methods: [(Selector, Selector)] = [
            (#selector(LAContext.canEvaluatePolicy(_:error:)), #selector(LAContext.orbitPasswordCanEvaluate(_:error:))),
            (#selector(LAContext.evaluateAccessControl(_:operation:localizedReason:reply:)),
             #selector(LAContext.orbitPasswordEvaluate(_:operation:localizedReason:reply:)))
        ]
        for (original, mock) in methods {
            method_exchangeImplementations(class_getInstanceMethod(LAContext.self, original)!, class_getInstanceMethod(LAContext.self, mock)!)
        }
        defer {
            for (original, mock) in methods {
                method_exchangeImplementations(class_getInstanceMethod(LAContext.self, original)!, class_getInstanceMethod(LAContext.self, mock)!)
            }
            BrowserFileChooserPresenter.shared.responder = nil
        }
        do {
            window.showWindow(nil)
            window.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            guard let profile = window.session.activeProfileID else { check("profile", false); return }
            let managerURL = URL(string: "chrome://password-manager/passwords")!
            window.session.openTab(url: fixture)
            await window.session.waitForPendingCommands()
            guard await ready(window, fixture), let remote = window.session.selectedSurface else { check("fixture", false); return }
            remote.navigate(to: managerURL)
            try await Task.sleep(for: .milliseconds(200))
            check("remote-denied", remote.navigationState.committedURL == fixture)
            let commandTarget = application.commands.registry.capturePaletteTarget(windowID: window.id)
            check("command-accepted", commandTarget != nil && application.commands.registry.dispatch(.openPasswordManager, origin: .palette, target: commandTarget))
            guard await ready(window, managerURL), let manager = window.session.selectedSurface else { check("manager", false); return }
            check("manager", manager.profileID == profile && manager.tabIdentity?.isHosted == true)
            let input = root.appendingPathComponent("input.csv")
            let output = root.appendingPathComponent("output.csv")
            let csv = "name,url,username,password,note\nSynthetic,\(fixture.absoluteString),orbit-fixture-user,orbit-fixture-secret,\n"
            try Data(csv.utf8).write(to: input)
            var opens = 0, saves = 0
            BrowserFileChooserPresenter.shared.responder = { request in
                if request.mode == .save { saves += 1; return [output] }
                opens += 1
                return [input]
            }
            let imported = await evaluate("JSON.stringify(await chrome.passwordsPrivate.importPasswords('DEVICE'))", manager)
            record("passwords.import-result", imported?.contains("SUCCESS") == true ? "proven" : "failed", ["result": imported ?? "unavailable"])
            check("import-dialog", opens == 1)
            check("store-list", await evaluate("String((await chrome.passwordsPrivate.getSavedPasswordList()).length)", manager) == "1")
            manager.navigate(to: URL(string: "chrome://password-manager/settings")!)
            guard await ready(window, URL(string: "chrome://password-manager/settings")!) else { check("settings", false); return }
            try await Task.sleep(for: .milliseconds(600))
            capture(window, root.appendingPathComponent("settings.png"))
            check("saving-default", await evaluate("String((await chrome.settingsPrivate.getPref('credentials_enable_service')).value)", manager) == "true")
            check("saving-off", await evaluate("(async () => { document.querySelector('password-manager-app').shadowRoot.querySelector('settings-section').shadowRoot.querySelector('#passwordToggle').click(); await new Promise(r => setTimeout(r, 200)); return String((await chrome.settingsPrivate.getPref('credentials_enable_service')).value); })()", manager) == "false")
            // Exercise the existing WebUI API and native file chooser, including its OS reauth
            // callback (mocked above). No database writes or custom CSV implementation.
            let exported = await evaluate("chrome.passwordsPrivate.exportPasswords().then(() => 'started')", manager)
            let wrote = await OrbitRelaunchScenarios.until { FileManager.default.fileExists(atPath: output.path) }
            check("export-dialog", exported == "started" && saves == 1 && wrote)
            let exportedCSV = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            check("export-content", exportedCSV.contains("orbit-fixture-user") && exportedCSV.contains("orbit-fixture-secret"))
            // Re-import into a different real profile to prove CSV round-trip and isolation.
            let second = await environment.store.createProfile(name: "Synthetic Password Roundtrip")
            let secondSpace = try await environment.store.createSpace(name: "Synthetic Password Roundtrip", profileID: second)
            await environment.refreshSettingsCatalog()
            window.session.activateSpace(secondSpace)
            await window.session.waitForPendingCommands()
            try await window.openPasswordManager(profile: second)
            guard await ready(window, managerURL), let isolated = window.session.selectedSurface else { check("second-manager", false); return }
            check("profile-isolation", await evaluate("String((await chrome.passwordsPrivate.getSavedPasswordList()).length)", isolated) == "0")
            BrowserFileChooserPresenter.shared.responder = { _ in [output] }
            let roundtrip = await evaluate("JSON.stringify(await chrome.passwordsPrivate.importPasswords('DEVICE'))", isolated)
            let roundtripCount = await evaluate("String((await chrome.passwordsPrivate.getSavedPasswordList()).length)", isolated)
            check("csv-roundtrip", roundtrip?.contains("SUCCESS") == true && roundtripCount == "1")
            check("preference-isolation", await evaluate("String((await chrome.settingsPrivate.getPref('credentials_enable_service')).value)", isolated) == "true")
            // With saving off, existing credentials still fill through Chromium's renderer agents.
            let catalog = await environment.store.catalogSnapshot()
            window.session.activateSpace(catalog.spaces.first { $0.profileID == profile }!.id)
            await window.session.waitForPendingCommands()
            window.session.openTab(url: fixture)
            await window.session.waitForPendingCommands()
            guard await ready(window, fixture), let login = window.session.selectedSurface else { check("login", false); return }
            _ = login.focusDocument()
            // A native input gesture reveals autofilled values and submits the unmodified form.
            // No script writes fields, parses forms, or returns a password to the shell.
            _ = await login.devToolsCall("Input.dispatchMouseEvent", params: #"{"type":"mousePressed","x":60,"y":75,"button":"left","clickCount":1}"#)
            _ = await login.devToolsCall("Input.dispatchMouseEvent", params: #"{"type":"mouseReleased","x":60,"y":75,"button":"left","clickCount":1}"#)
            try await Task.sleep(for: .milliseconds(600))
            capture(window, root.appendingPathComponent("login.png"))
            let popupWindows = NSApp.windows.filter { $0.isVisible && $0 !== window.window }
            for (index, popup) in popupWindows.enumerated() {
                capture(popup, root.appendingPathComponent("field-popup-\(index).png"))
            }
            record("passwords.field-popup", popupWindows.isEmpty ? "partial" : "proven", ["visibleAuxiliaryWindows": popupWindows.count])
            _ = await evaluate("document.getElementById('submit').click() ?? 'submitted'", login)
            let filled = await OrbitRelaunchScenarios.until { login.navigationState.title == "Fixture filled" }
            check("engine-filled-saving-off", filled)
            // Restore the backend default through the same WebUI preference used by the toggle.
            check("saving-on", await evaluate("(async () => { document.querySelector('password-manager-app').shadowRoot.querySelector('settings-section').shadowRoot.querySelector('#passwordToggle').click(); await new Promise(r => setTimeout(r, 200)); return String((await chrome.settingsPrivate.getPref('credentials_enable_service')).value); })()", manager) == "true")
            try await window.openPasswordManager(profile: profile)
            guard await ready(window, managerURL), let checkup = window.session.selectedSurface else { check("checkup", false); return }
            let checkupURL = URL(string: "chrome://password-manager/checkup")!
            checkup.navigate(to: checkupURL)
            check("checkup", await ready(window, checkupURL))
            // Submit a different loopback origin with native input to exercise parsing and the
            // invisible pending-save path. Its save decision UI intentionally belongs to a later lot.
            let pendingURL = URL(string: fixture.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"))!
            window.session.openTab(url: pendingURL)
            await window.session.waitForPendingCommands()
            if await ready(window, pendingURL), let pending = window.session.selectedSurface {
                _ = pending.focusDocument()
                for (y, text) in [(30, "orbit-fixture-user"), (75, "orbit-fixture-secret")] {
                    _ = await pending.devToolsCall("Input.dispatchMouseEvent", params: "{\"type\":\"mousePressed\",\"x\":60,\"y\":\(y),\"button\":\"left\",\"clickCount\":1}")
                    _ = await pending.devToolsCall("Input.dispatchMouseEvent", params: "{\"type\":\"mouseReleased\",\"x\":60,\"y\":\(y),\"button\":\"left\",\"clickCount\":1}")
                    let parameters = try JSONSerialization.data(withJSONObject: ["text": text])
                    _ = await pending.devToolsCall("Input.insertText", params: String(decoding: parameters, as: UTF8.self))
                }
                _ = await evaluate("document.getElementById('submit').click() ?? 'submitted'", pending)
                let submitted = await OrbitRelaunchScenarios.until { pending.navigationState.title == "Fixture filled" }
                check("pending-submission-no-crash", submitted)
            } else { check("pending-submission-no-crash", false) }
            try await environment.saveNow()
        } catch { record("passwords.operation", "failed", ["error": String(describing: error)]) }
    }

    private static func capture(_ controller: OrbitWindowController, _ destination: URL) {
        guard let window = controller.window else { return }
        capture(window, destination)
    }
    private static func capture(_ window: NSWindow, _ destination: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), destination.path]
        try? process.run()
        process.waitUntilExit()
    }

    private static func ready(_ window: OrbitWindowController, _ url: URL) async -> Bool {
        await OrbitRelaunchScenarios.until {
            window.session.selectedSurface?.isReady == true && window.session.selectedSurface?.navigationState.isLoading == false
                && window.session.selectedSurface?.navigationState.committedURL == url
        }
    }
    private static func evaluate(_ expression: String, _ surface: ChromiumSurface) async -> String? {
        let params = try! JSONSerialization.data(withJSONObject: ["expression": "(async () => { return \(expression) })()",
            "awaitPromise": true, "returnByValue": true, "userGesture": true])
        let (ok, data) = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: params, as: UTF8.self))
        guard ok, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["exceptionDetails"] == nil, let result = json["result"] as? [String: Any] else {
            FileHandle.standardError.write(Data(("password smoke evaluation failed: " + String(decoding: data, as: UTF8.self) + "\n").utf8))
            return nil
        }
        return result["value"] as? String
    }
}
