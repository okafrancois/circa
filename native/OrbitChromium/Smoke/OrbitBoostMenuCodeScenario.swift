import AppKit
import BrowserCore
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Every synthetic UI action is bound to this test bundle and its current CG window owner.
    func boostMenuCodeScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController,
                               _ engine: ChromiumBrowserEngine) async {
        func pause(_ seconds: Double = 0.5) async { try? await Task.sleep(for: .seconds(seconds)) }
        func check(_ name: String, _ value: Bool) { self.check("boost-menu-code." + name, value) }
        func gate(_ window: NSWindow?) -> Bool {
            guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.boost-menu-code.synthetic", let window,
                  let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
                  let row = rows.first,
                  (row[kCGWindowOwnerPID as String] as? Int32) == getpid(),
                  (row[kCGWindowNumber as String] as? Int) == window.windowNumber else {
                check("input-refused", false); return false
            }
            event("boost-input-gate", ["pid": getpid(), "window": window.windowNumber, "passed": true])
            return true
        }
        func capture(_ name: String, _ view: NSView?) {
            guard let view, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(to: runRoot.appendingPathComponent(name + ".png"))
        }
        func evaluate(_ source: String, _ page: ChromiumSurface) async -> String? {
            try? await engine.conformanceProbe?.evaluateScript(source, in: page)
        }
        owner.window?.setContentSize(NSSize(width: 1506, height: 920))
        owner.window?.center(); owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await environment.settings.markBoostsIntroductionSeen()
        let url = fixture.appendingPathComponent("fixture")
        owner.submitAddress(url.absoluteString)
        guard let page = await committed(owner, url), gate(owner.window) else { return }
        owner.createBoost(); await owner.boostTask?.value
        guard let editor = owner.boostEditor, let panel = editor.window else { check("create", false); return }
        check("create", !editor.session.isClosed)
        panel.setFrameOrigin(NSPoint(x: owner.window!.frame.maxX - 193, y: owner.window!.frame.maxY - 735))
        panel.makeKeyAndOrderFront(nil)
        let identity: [String: Any] = ["pid": getpid(), "parent": owner.window!.windowNumber, "panel": panel.windowNumber]
        try? JSONSerialization.data(withJSONObject: identity).write(to: runRoot.appendingPathComponent("capture-window.json"))
        _ = await until(8) { FileManager.default.fileExists(atPath: self.runRoot.appendingPathComponent("capture-ready").path) }
        await pause()
        let menu = editor.editor.makeHeaderMenu()
        check("supported-menu", menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Reset all Edits", "Delete this Boost", "All Boosts…"])
        if gate(panel) {
            let timer = Timer(timeInterval: 1.2, target: BoostMenuTrackingEnd(menu), selector: #selector(BoostMenuTrackingEnd.cancel), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            event("boost-menu-open", [:])
            menu.popUp(positioning: nil, at: NSPoint(x: 40, y: 34), in: editor.editor)
        }
        await pause()
        guard gate(panel) else { return }
        editor.showCode(); await pause(0.8)
        guard let code = panel.contentView as? BrowserBoostCodeView else { check("code", false); return }
        check("expanded-code", abs(panel.frame.width - 480) < 1)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(code.textView)
        guard gate(panel), panel.isKeyWindow else { return }
        code.textView.insertText("h1 { color: rgb(190, 30, 70) !important; }", replacementRange: NSRange(location: 0, length: 0))
        await editor.session.pending?.value; await pause(1)
        check("live-css", await evaluate("String(getComputedStyle(document.querySelector('h1')).color)", page) == "rgb(190, 30, 70)")
        capture("orbit-css", code)
        capture("orbit-css-page", owner.window?.contentView)
        check("css-persisted", await editor.session.store.snapshot().boosts.first?.content.customCSS.contains("190, 30, 70") == true)
        // JS bytes remain gated until the explicit device-local opt-in is accepted.
        editor.session.edit { $0.customJavaScript = "document.documentElement.dataset.boostConsent = 'accepted'" }
        await editor.session.pending?.value
        check("js-before-consent", await evaluate("String(document.documentElement.dataset.boostConsent)", page) == "undefined")
        editor.session.setJavaScriptConsent(true); await editor.session.pending?.value
        check("js-no-live-rerun", await evaluate("String(document.documentElement.dataset.boostConsent)", page) == "undefined")
        page.reload()
        _ = await until(5) { !page.navigationState.isLoading }
        check("js-on-reload", await evaluate("String(document.documentElement.dataset.boostConsent)", page) == "accepted")
        guard gate(panel) else { return }
        editor.showControls(); await pause(0.8)
        capture("orbit-before-reset", editor.editor)
        guard gate(panel) else { return }
        event("boost-reset", [:]); menu.performActionForItem(at: 0)
        await editor.session.pending?.value; await pause(1)
        check("reset-content", editor.session.boost.content == BrowserBoostContent() && !editor.session.boost.javaScriptOptIn)
        check("reset-live-css", await evaluate("String(getComputedStyle(document.querySelector('h1')).color !== 'rgb(190, 30, 70)')", page) == "true")
        capture("orbit-reset", editor.editor)
        capture("orbit-reset-page", owner.window?.contentView)
        guard gate(panel) else { return }
        menu.performActionForItem(at: 1); await pause(1)
        capture("orbit-delete-confirmation", owner.window?.contentView)
        guard gate(owner.window) else { return }
        editor.deleteConfirmation?.finish(false); await pause()
        let retained = await editor.session.store.snapshot()
        check("delete-cancel", !editor.session.isClosed && retained.boosts.count == 1)
        guard gate(panel) else { return }
        menu.performActionForItem(at: 1); await pause()
        check("delete-reopened", editor.deleteConfirmation != nil)
        guard gate(owner.window) else { return }
        editor.deleteConfirmation?.finish(true); await editor.session.pending?.value; await pause()
        let removed = await editor.session.store.snapshot()
        check("delete-accept", editor.session.isDeleted && removed.boosts.isEmpty)
        guard gate(owner.window) else { return }
        owner.showLibrary(.boosts); await owner.library.boostsTask?.value
        capture("orbit-after-delete", owner.window?.contentView)
        check("deleted-library", (await editor.session.store.snapshot()).boosts.isEmpty)
        await pause(1)
    }
}

@MainActor
private final class BoostMenuTrackingEnd: NSObject {
    let menu: NSMenu
    init(_ menu: NSMenu) { self.menu = menu }
    @objc func cancel() { menu.cancelTracking() }
}
