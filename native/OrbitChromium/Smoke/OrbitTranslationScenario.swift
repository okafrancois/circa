import AppKit
import BrowserCore
import ChromiumEngine
import CoreGraphics
import QuartzCore

@MainActor
enum OrbitTranslationScenario {
    static func run(window initialWindow: BrowserWindowController<ChromiumBrowserEngine>, environment: BrowserEnvironment<ChromiumBrowserEngine>, root: URL, probeOnly: Bool,
                    record: @escaping (String, String, [String: Any]) -> Void) async {
        var window = initialWindow
        func check(_ name: String, _ ok: Bool) { record("translation." + name, ok ? "proven" : "failed", [:]) }
        // Every synthetic event is gated by the exact native window's owner PID and baked ID.
        func owned(_ target: NSWindow?) -> Bool {
            guard let target, Bundle.main.bundleIdentifier?.hasPrefix("lab.orbit.orbit.") == true,
                  Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true,
                  let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(target.windowNumber)) as? [[String: Any]],
                  let row = rows.first,
                  (row[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier else { return false }
            record("translation.owner-verified", "observed", ["pid": ProcessInfo.processInfo.processIdentifier, "window": target.windowNumber])
            return true
        }
        func clickStatus() async -> Bool {
            let rect = window.addressField.statusAnchorRect
            let point = window.addressField.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            guard let target = window.window, let root = target.contentView else { return false }
            let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
            record("translation.hit-target", "observed", ["type": hit.map { String(describing: type(of: $0)) } ?? "none",
                "fieldHeight": window.addressField.bounds.height, "statusY": rect.midY])
            guard let button = hit as? NSButton, button.window === target, owned(button.window) else { return false }
            button.performClick(nil)
            return await OrbitRelaunchScenarios.until { window.translation.popover.isShown }
        }
        let theme = OrbitTokens.SpaceTheme(stops: [NSColor(srgbRed: 40/255, green: 37/255, blue: 55/255, alpha: 1)], mode: .dark, texture: .none, textureIntensity: 0)
        func capture(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(250))
            window.windowShell.apply(theme: theme, animated: false)
            window.window?.appearance = NSAppearance(named: .darkAqua)
            window.window?.displayIfNeeded()
            CATransaction.flush()
            guard owned(window.window) else { check("capture-owner", false); return }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.window!.windowNumber), root.appendingPathComponent(name + ".png").path]
            try? process.run(); process.waitUntilExit()
        }
        window.window?.setFrame(NSRect(x: 0, y: 80, width: 1506, height: 949), display: true)
        OrbitSpaceThemes.resolver = { _, _ in OrbitTokens.SpaceTheme(stops: [NSColor(srgbRed: 40/255, green: 37/255, blue: 55/255, alpha: 1)], mode: .dark, texture: .none, textureIntensity: 0) }
        window.sidebarWidth.constant = 500
        window.windowShell.apply(theme: OrbitTokens.SpaceTheme(stops: [NSColor(srgbRed: 40/255, green: 37/255, blue: 55/255, alpha: 1)], mode: .dark, texture: .none, textureIntensity: 0), animated: false)
        window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let url = URL(string: "https://de.wikipedia.org/wiki/Baum")!
        window.openTab(url: url)
        await window.session.waitForPendingCommands()
        guard await OrbitRelaunchScenarios.until({ window.session.selectedSurface?.navigationState.committedURL == url && window.session.selectedSurface?.navigationState.isLoading == false }),
              let tab = window.session.selectedSurface else { check("page-loaded", false); return }
        check("page-loaded", true)
        try? await Task.sleep(for: .seconds(1))
        // This is an explicit native command, not a synthetic keyboard/mouse event.
        check("chromium-no-key-refused", !tab.requestBuiltInTranslation())
        if probeOnly { await capture("chromium-probe"); return }
        guard await OrbitRelaunchScenarios.until({ window.translation.page?.state.phase == .available }),
              let page = window.translation.page else { check("available", false); await capture("unavailable"); return }
        window.window?.makeFirstResponder(nil)
        tab.focusDocument()
        record("translation.pair", "observed", ["source": page.state.source, "target": page.state.target])
        check("available", true); await capture("offer")
        guard owned(window.window) else { check("offer-owner", false); return }
        check("offer-click", await clickStatus())
        await capture("popup")
        guard window.translation.popover.isShown, let view = window.translation.popover.contentViewController?.view as? BrowserTranslationPopover,
              owned(view.primary.window) else { check("translate-owner", false); return }
        view.primary.performClick(nil)
        let deadline = ContinuousClock.now + .seconds(38)
        while page.state.phase == .translating && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if let failure = page.failure {
            record("translation.failure-diagnostic", "observed", ["stage": failure.stage, "domain": failure.domain, "code": failure.code])
        }
        check("translated", page.state.phase == .translated)
        await capture("translated")
        guard page.state.phase == .translated else { return }
        check("english-heading", await evaluate("document.querySelector('h1').innerText", tab: tab) != "Baum")
        _ = await evaluate("globalThis.orbitTranslationButton=document.createElement('button'); orbitTranslationButton.textContent='Ein Baum hat viele grüne Blätter.'; orbitTranslationButton.onclick=()=>{orbitTranslationButton.dataset.activated='yes'}; document.querySelector('h1').insertAdjacentElement('afterend',orbitTranslationButton); 'ok'", tab: tab)
        let dynamicDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < dynamicDeadline {
            if await evaluate("orbitTranslationButton.textContent", tab: tab) != "Ein Baum hat viele grüne Blätter." { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        check("dynamic-content", await evaluate("orbitTranslationButton.textContent", tab: tab) != "Ein Baum hat viele grüne Blätter.")
        guard owned(window.window) else { check("page-button-owner", false); return }
        _ = await evaluate("orbitTranslationButton.click(); 'ok'", tab: tab)
        check("interactive", await evaluate("orbitTranslationButton.dataset.activated", tab: tab) == "yes")
        _ = await evaluate("document.body.append(orbitTranslationButton); 'ok'", tab: tab)
        // Same-document navigation must retain the isolated world and restoration records.
        _ = await evaluate("location.hash='Definitionen'; 'ok'", tab: tab)
        check("same-document", page.isCurrent && page.state.phase == .translated)
        _ = await evaluate("scrollTo(0,0); 'ok'", tab: tab)
        // Keep the active translation task and its originals while moving the live tab.
        do {
            let destination = try await environment.makeWindow()
            destination.showWindow(nil); destination.window?.makeKeyAndOrderFront(nil)
            guard let move = window.moveSurface(tab, to: destination), await move.value != nil else {
                check("translated-move", false); return
            }
            let source = window
            window = destination
            source.window?.close()
            await window.session.waitForPendingCommands()
            try? await Task.sleep(for: .milliseconds(500))
            check("translated-move", window.translation.page === page && page.state.phase == .translated)
        } catch { check("translated-move", false); return }
        guard owned(window.window) else { check("original-owner", false); return }
        check("original-click", await clickStatus())
        await capture("original-popup")
        guard window.translation.popover.isShown, let original = window.translation.popover.contentViewController?.view as? BrowserTranslationPopover,
              owned(original.primary.window) else { check("restore-owner", false); return }
        original.primary.performClick(nil)
        check("restored", await OrbitRelaunchScenarios.until { page.state.phase == .original })
        check("german-heading", await evaluate("document.querySelector('h1').innerText", tab: tab) == "Baum")
        check("dynamic-restored", await evaluate("orbitTranslationButton.textContent", tab: tab) == "Ein Baum hat viele grüne Blätter.")
        _ = await evaluate("orbitTranslationButton.remove(); 'ok'", tab: tab)
        await capture("restored")
    }

    private static func evaluate(_ expression: String, tab: ChromiumSurface) async -> String? {
        let data = try! JSONSerialization.data(withJSONObject: ["expression": expression, "returnByValue": true])
        let (ok, result) = await tab.devToolsCall("Runtime.evaluate", params: String(decoding: data, as: UTF8.self))
        guard ok, let json = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              let remote = json["result"] as? [String: Any] else { return nil }
        return remote["value"] as? String
    }
}
