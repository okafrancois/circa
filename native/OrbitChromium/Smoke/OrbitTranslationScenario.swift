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
        let optionsRun = ProcessInfo.processInfo.arguments.contains("--translation-options")
        let theme = optionsRun
            ? OrbitTokens.SpaceTheme(stops: [NSColor(srgbRed: 224/255, green: 222/255, blue: 241/255, alpha: 1)], mode: .light, texture: .none, textureIntensity: 0)
            : OrbitTokens.SpaceTheme(stops: [NSColor(srgbRed: 40/255, green: 37/255, blue: 55/255, alpha: 1)], mode: .dark, texture: .none, textureIntensity: 0)
        func capture(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(250))
            window.windowShell.apply(theme: theme, animated: false)
            window.window?.appearance = NSAppearance(named: optionsRun ? .aqua : .darkAqua)
            window.window?.displayIfNeeded()
            CATransaction.flush()
            guard owned(window.window) else { check("capture-owner", false); return }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.window!.windowNumber), root.appendingPathComponent(name + ".png").path]
            try? process.run(); process.waitUntilExit()
        }
        window.window?.setFrame(NSRect(x: 0, y: 80, width: 1506, height: 949), display: true)
        OrbitSpaceThemes.resolver = { _, _ in theme }
        window.sidebarWidth.constant = 500
        window.windowShell.apply(theme: theme, animated: false)
        window.window?.appearance = NSAppearance(named: optionsRun ? .aqua : .darkAqua)
        window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let url = URL(string: ProcessInfo.processInfo.arguments.contains("--translation-options") ? "https://de.wikipedia.org/wiki/Berlin" : "https://de.wikipedia.org/wiki/Baum")!
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
        if ProcessInfo.processInfo.arguments.contains("--translation-options") {
            // Capture only this process's windows, including native menus and popovers.
            func captureOwned(_ name: String) {
                guard owned(window.window), let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return }
                var manifest: [[String: Any]] = []
                for row in rows.reversed() where (row[kCGWindowOwnerPID as String] as? Int32) == getpid() {
                    guard let bounds = row[kCGWindowBounds as String] as? [String: Any] else { continue }
                    manifest.append(["bounds": bounds])
                }
                // A native window capture includes its popover/menu hierarchy on this OS.
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", String(window.window!.windowNumber), root.appendingPathComponent(name + ".png").path]
                try? process.run(); process.waitUntilExit()
                try? JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent(name + ".json"))
            }
            func openOptions(_ name: String) async -> BrowserTranslationOptionsMenu? {
                _ = await OrbitRelaunchScenarios.until { window.translation.page?.targets.isEmpty == false }
                window.translation.popover.close()
                try? await Task.sleep(for: .milliseconds(200))
                guard await clickStatus() else { return nil }
                guard await OrbitRelaunchScenarios.until({
                    guard let view = window.translation.popover.contentViewController?.view as? BrowserTranslationPopover,
                          view.options.window?.isVisible == true else { return false }
                    return owned(view.options.window)
                }), let view = window.translation.popover.contentViewController?.view as? BrowserTranslationPopover,
                      owned(view.options.window) else { return nil }
                captureOwned(name + "-popup")
                // The tracking loop runs in common modes, so the timer can capture and dismiss it.
                let timer = Timer(timeInterval: 0.5, target: TranslationMenuCapture {
                    captureOwned(name)
                    window.translation.optionsMenu?.cancelTracking()
                }, selector: #selector(TranslationMenuCapture.fire), userInfo: nil, repeats: false)
                RunLoop.main.add(timer, forMode: .common)
                // Recheck the exact target after capture, immediately before dispatch.
                guard owned(view.options.window) else { return nil }
                view.options.performClick(nil)
                return window.translation.makeOptionsMenu()
            }
            guard await OrbitRelaunchScenarios.until({ page.targets.contains("fr") }),
                  let menu = await openOptions("options-menu"), let languages = menu.items.first?.submenu,
                  let french = languages.items.firstIndex(where: { $0.representedObject as? String == "fr" }),
                  owned(window.window) else { check("options-open", false); return }
            check("options-open", true)
            languages.performActionForItem(at: french)
            let deadline = ContinuousClock.now + .seconds(43)
            while page.state.phase != .translated && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            check("french-translated", page.state.phase == .translated && page.state.target == "fr")
            if let failure = page.failure {
                record("translation.failure-diagnostic", "observed", ["stage": failure.stage, "domain": failure.domain, "code": failure.code])
            }
            let frenchText = await evaluate("document.querySelector('p').innerText", tab: tab) ?? ""
            check("french-content", frenchText.contains("Berlin") && !frenchText.contains("Dieser Artikel"))
            captureOwned("french-result")
            guard let never = await openOptions("never-site-before"), owned(window.window) else { return }
            never.performActionForItem(at: 1)
            check("never-site", await OrbitRelaunchScenarios.until { page.state.siteSuppressed && !page.state.offersTranslation && page.state.phase == .original })
            captureOwned("never-site-result")
            guard let checked = await openOptions("never-site-check") else { return }
            check("never-checked", checked.items[1].state == .on)
            window.translation.popover.close()
            tab.reload()
            check("reload-suppressed", await OrbitRelaunchScenarios.until {
                window.translation.page !== page && window.translation.page?.state.siteSuppressed == true
                    && window.translation.page?.state.phase == .available && !tab.navigationState.isLoading
            })
            captureOwned("never-site-reloaded")
            guard let undo = await openOptions("never-site-undo"), owned(window.window) else { return }
            check("reload-checked", undo.items[1].state == .on)
            undo.performActionForItem(at: 1)
            check("never-undo", window.translation.page?.state.offersTranslation == true)
            guard let restored = await openOptions("site-preference-restored"), owned(window.window) else { return }
            check("undo-unchecked", restored.items[1].state == .off)
            restored.performActionForItem(at: 3)
            await window.session.waitForPendingCommands()
            check("language-settings", await OrbitRelaunchScenarios.until { window.session.selectedSurface?.navigationState.committedURL?.absoluteString.hasPrefix("chrome://settings/languages") == true })
            _ = await OrbitRelaunchScenarios.until { window.session.selectedSurface?.navigationState.isLoading == false }
            try? await Task.sleep(for: .milliseconds(750))
            captureOwned("language-settings")
            return
        }
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

@MainActor
private final class TranslationMenuCapture: NSObject {
    private let capture: () -> Void
    init(_ capture: @escaping () -> Void) { self.capture = capture }
    @objc func fire() { capture() }
}
