import AppKit
import Carbon.HIToolbox
import ChromiumEngine
import BrowserCore
import BrowserEngine
import ObjectiveC
import LocalAuthentication

/// Runs only in the synthetic, loopback, mock-Keychain smoke lane.
@MainActor
enum OrbitSecureInputScenario {
    static var resignNotifications = 0
    static var deactivateNotifications = 0
    static func run(application: OrbitApplication, environment: OrbitEnvironment, window: OrbitWindowController, fixture: URL,
                    record: (String, String, [String: Any]) -> Void) async {
        guard let native = window.window else { return }
        native.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        func pause() async { try? await Task.sleep(for: .milliseconds(300)) }
        func owns(_ view: NSView) -> Bool {
            guard let target = view.window else { return false }
            let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(target.windowNumber)) as? [[String: Any]]
            return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        func check(_ name: String, _ enabled: Bool) async {
            await pause()
            let actual = IsSecureEventInputEnabled()
            record("secure-input." + name, actual == enabled ? "proven" : "failed", ["enabled": actual, "expected": enabled])
        }
        func focus(_ tab: ChromiumSurface) async {
            guard owns(tab.hostView) else { record("secure-input.pid", "failed", [:]); return }
            _ = tab.focusDocument()
            _ = await tab.devToolsCall("Runtime.evaluate", params: #"{"expression":"document.querySelector('#password').focus()"}"#)
            await pause()
        }
        func activate(_ target: NSWindow) async {
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
            target.makeKeyAndOrderFront(nil)
            _ = await OrbitRelaunchScenarios.until { NSApp.isActive && target.isKeyWindow }
            await pause()
        }
        func deactivate() async {
            guard let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) else {
                record("secure-input.deactivation-target", "failed", [:]); return
            }
            finder.activate(options: [.activateIgnoringOtherApps])
            _ = await OrbitRelaunchScenarios.until { !NSApp.isActive }
            await pause()
        }
        func page() async -> ChromiumSurface? {
            await activate(native)
            window.openTab(url: fixture)
            await window.session.waitForPendingCommands()
            guard await OrbitRelaunchScenarios.until({ window.session.selectedSurface?.navigationState.isLoading == false
                && window.session.selectedSurface?.navigationState.committedURL == fixture }), let tab = window.session.selectedSurface else { return nil }
            await focus(tab)
            await check("password-focused", true)
            return tab
        }
        await activate(native)
        await check("initial", false)
        guard let first = await page() else { return }
        let firstTabID = window.session.snapshot?.tabs.first { $0.occurrenceID == window.session.snapshot?.selectedOccurrenceID }?.id
        let hooks = [("windowDidResignKey:", #selector(NSObject.orbitSecureInputResign(_:))),
                     ("applicationDidResignActive:", #selector(NSObject.orbitSecureInputDeactivate(_:)))]
        var swapped: [(Method, Method)] = []
        if let responder = native.firstResponder {
            for (name, hook) in hooks {
                if let original = class_getInstanceMethod(type(of: responder), NSSelectorFromString(name)),
                   let replacement = class_getInstanceMethod(NSObject.self, hook) {
                    method_exchangeImplementations(original, replacement)
                    swapped.append((original, replacement))
                }
            }
        }
        defer { for (original, replacement) in swapped { method_exchangeImplementations(original, replacement) } }
        // Primary owner reproduction: preserve DOM and AppKit first-responder focus while
        // the app/window loses keyboard eligibility, then restore without refocusing the field.
        await deactivate()
        await check("app-deactivation", false)
        // A background script changing its DOM focus must not reacquire keyboard ownership.
        _ = await first.devToolsCall("Runtime.evaluate", params: #"{"expression":"document.querySelector('#plain').focus(); document.querySelector('#password').focus()"}"#)
        await check("background-dom-focus", false)
        record("secure-input.renderer-notifications", resignNotifications > 0 && deactivateNotifications > 0 ? "proven" : "failed",
               ["resignKey": resignNotifications, "deactivate": deactivateNotifications])
        await activate(native)
        await check("app-reactivation-password", true)
        native.orderOut(nil)
        await check("window-order-out", false)
        await activate(native)
        await check("window-key-password", true)

        let existing = Set(application.windows.windows.keys)
        application.windows.newWindow()
        _ = await OrbitRelaunchScenarios.until { application.windows.windows.keys.contains { !existing.contains($0) } }
        if let other = application.windows.windows.first(where: { !existing.contains($0.key) })?.value,
           let otherWindow = other.window {
            await activate(otherWindow)
            if owns(other.addressField) { other.focusAddress() }
            await check("other-orbit-window", false)
            await activate(native)
            await check("return-from-other-window", true)
            otherWindow.close()
        } else { record("secure-input.other-orbit-window", "failed", [:]) }

        application.quickWindowPresenter = { _ in }
        application.openQuickWindow(url: fixture, source: window)
        await application.waitForQuickWindowCommands()
        _ = await OrbitRelaunchScenarios.until { environment.quickWindows.values.contains { $0.surface?.navigationState.isLoading == false } }
        if let little = environment.quickWindows.values.first, let littleWindow = little.window, let tab = little.surface {
            await activate(littleWindow)
            if owns(little.addressField) { littleWindow.makeFirstResponder(little.addressField) }
            await check("little-window", false)
            await focus(tab)
            await check("little-password", true)
            await activate(native)
            await check("return-from-little-password", true)
            if owns(first.hostView) { window.focusAddress() }
            await check("little-background-password", false)
            await activate(littleWindow)
            await check("little-key-password", true)
            littleWindow.close()
            await activate(native)
            await focus(first)
        } else { record("secure-input.little-window", "failed", [:]) }

        if let peek = window.openPeek(fixture.appendingPathComponent("plain")) {
            _ = await OrbitRelaunchScenarios.until { peek.isReady && !peek.navigationState.isLoading }
            if owns(peek.hostView) { _ = peek.focusDocument() }
            await check("peek-regular-field", false)
            peek.navigate(to: fixture)
            _ = await OrbitRelaunchScenarios.until { peek.navigationState.committedURL == fixture && !peek.navigationState.isLoading }
            await focus(peek)
            await check("peek-password", true)
            _ = window.peek.dismiss(animated: false, remember: false)
            if owns(first.hostView) { window.focusAddress() }
            await check("peek-dismiss", false)
            await focus(first)
            await check("return-from-peek-password", true)
        } else { record("secure-input.peek", "failed", [:]) }

        window.openTab(url: fixture.appendingPathComponent("auth"))
        await window.session.waitForPendingCommands()
        func secureField(_ view: NSView) -> NSSecureTextField? {
            if let secure = view as? NSSecureTextField { return secure }
            return view.subviews.compactMap(secureField).first
        }
        _ = await OrbitRelaunchScenarios.until { secureField(native.contentView!) != nil }
        if let field = secureField(native.contentView!), owns(field) {
            native.makeFirstResponder(field)
            await check("native-auth-password", true)
            await deactivate()
            await check("native-auth-deactivate", false)
            await activate(native)
            await check("native-auth-reactivate", true)
            if let auth = window.session.selectedSurface {
                auth.hostView.isHidden = true
                await check("native-auth-hidden", false)
                auth.hostView.isHidden = false
                if owns(field) { native.makeFirstResponder(field) }
                await check("native-auth-shown", true)
            }
            if owns(field) { window.focusAddress() }
            await check("native-auth-blur", false)
        } else { record("secure-input.native-auth", "failed", [:]) }
        window.closeSelectedTab()
        await window.session.waitForPendingCommands()
        if let firstTabID {
            window.session.selectTab(firstTabID)
            await window.session.waitForPendingCommands()
        }
        if owns(first.hostView) { window.focusAddress() }
        await check("sidebar-url", false)
        await focus(first)
        first.hostView.isHidden = true
        await check("hidden", false)
        first.hostView.isHidden = false
        await focus(first)
        if let parent = first.hostView.superview, let content = native.contentView {
            let frame = first.hostView.frame
            let parking = NSView(frame: NSRect(x: content.bounds.maxX + 20_000, y: 0, width: frame.width, height: frame.height))
            content.addSubview(parking)
            parking.addSubview(first.hostView)
            first.hostView.frame = parking.bounds
            if owns(first.hostView), let view = first.engineContentView { native.makeFirstResponder(view) }
            await check("offscreen-view", false)
            record("secure-input.offscreen-placement", first.hostView.superview === parking ? "proven" : "failed", [:])
            parent.addSubview(first.hostView)
            first.hostView.frame = frame
            parking.removeFromSuperview()
            first.hostDidChange(hidden: false)
        }
        await focus(first)
        first.hostDidChange(hidden: true)
        await check("offscreen-notification", false)
        first.hostDidChange(hidden: false)
        await focus(first)
        window.openTab(url: fixture.appendingPathComponent("plain"))
        await window.session.waitForPendingCommands()
        await check("tab-switch", false)
        let suspend = first.suspendInPlace()
        record("secure-input.discard-request", suspend == .suspended ? "proven" : "failed", [:])
        await check("discard-suspended-tab", false)
        guard let second = await page(), let profile = window.session.activeProfileID else { return }
        let space = try? await environment.store.createSpace(name: "Synthetic secure input", profileID: profile)
        if let space {
            window.session.activateSpace(space)
            await window.session.waitForPendingCommands()
            await check("space-switch", false)
        } else { record("secure-input.space-switch", "failed", [:]) }
        _ = second
        guard let third = await page() else { return }
        window.closeSelectedTab()
        await window.session.waitForPendingCommands()
        await check("close-password-tab", false)
        _ = third
        if let profile = window.session.activeProfileID, let store = window.engine.passwordStore {
            let row = BrowserPasswordRecord(primaryKey: .init(signonRealm: fixture.absoluteString,
                originURL: fixture.absoluteString, usernameElement: "user", usernameValue: "synthetic", passwordElement: "password"),
                actionURL: fixture.absoluteString, passwordValue: "Synthetic-only")
            do {
                try await store.add(row, profileID: profile)
                let authHooks = [(#selector(LAContext.canEvaluatePolicy(_:error:)), #selector(LAContext.orbitSecureCanEvaluate(_:error:))),
                    (#selector(LAContext.evaluateAccessControl(_:operation:localizedReason:reply:)), #selector(LAContext.orbitSecureEvaluate(_:operation:localizedReason:reply:)))]
                var authSwapped: [(Method, Method)] = []
                for (original, replacement) in authHooks {
                    if let a = class_getInstanceMethod(LAContext.self, original), let b = class_getInstanceMethod(LAContext.self, replacement) {
                        method_exchangeImplementations(a, b); authSwapped.append((a, b))
                    }
                }
                defer { for (a, b) in authSwapped { method_exchangeImplementations(a, b) } }
                try await window.openPasswordManager(profile: profile)
                _ = await OrbitRelaunchScenarios.until { window.session.selectedSurface?.navigationState.isLoading == false
                    && window.session.selectedSurface?.navigationState.committedURL?.scheme == "chrome" }
                if let manager = window.session.selectedSurface, owns(manager.hostView) {
                    _ = manager.focusDocument()
                    let (ok, data) = await manager.devToolsCall("Runtime.evaluate", params: #"{"expression":"chrome.passwordsPrivate.getSavedPasswordList().then(rows => chrome.passwordsPrivate.requestPlaintextPassword(rows[0].id, 'VIEW')).then(() => true)","awaitPromise":true,"returnByValue":true}"#)
                    let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let revealed = (result?["result"] as? [String: Any])?["value"] as? Bool == true
                    record("secure-input.manager-reveal-completed", ok && revealed ? "proven" : "failed", [:])
                    await check("manager-reveal", false)
                }
            } catch { record("secure-input.manager-reveal-completed", "failed", [:]) }
        } else { record("secure-input.manager-store", "failed", [:]) }
        guard let fourth = await page() else { return }
        fourth.hostView.removeFromSuperview()
        await check("view-removal", false)
        fourth.dispose()
    }
}

extension NSObject {
    @MainActor @objc func orbitSecureInputResign(_ notification: NSNotification) {
        OrbitSecureInputScenario.resignNotifications += 1
        orbitSecureInputResign(notification)
    }
    @MainActor @objc func orbitSecureInputDeactivate(_ notification: NSNotification) {
        OrbitSecureInputScenario.deactivateNotifications += 1
        orbitSecureInputDeactivate(notification)
    }
}

private extension LAContext {
    @objc func orbitSecureCanEvaluate(_ policy: LAPolicy, error: NSErrorPointer) -> Bool { true }
    @objc func orbitSecureEvaluate(_ access: SecAccessControl, operation: LAAccessControlOperation,
                                   localizedReason: String, reply: @escaping (Bool, Error?) -> Void) { reply(true, nil) }
}
