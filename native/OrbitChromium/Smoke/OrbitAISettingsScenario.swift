import AppKit
import BrowserCore
import BrowserShell
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Capture the real pane without sending input to any other process.
    func aiSettings(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        func check(_ name: String, _ passed: Bool) { self.check("ai-settings." + name, passed) }
        guard let profile = owner.session.activeProfileID else { check("context", false); return }
        owner.window?.setFrameOrigin(NSPoint(x: -8000, y: 0))
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        check("default-off", !environment.settings.document.ai.isEnabled)
        let settings = BrowserSettingsWindowController(model: model, appearanceOverride: nil)
        defer { settings.window?.close(); environment.ai.terminateNow() }
        check("section", settings.selectSection(.ai))
        guard let window = settings.window, let view = window.contentView else { check("window", false); return }
        window.setFrameOrigin(NSPoint(x: -6000, y: 0))
        window.orderFront(nil)
        _ = await until(20) { !environment.ai.isChecking && !environment.ai.statuses.isEmpty }
        check("discovery", !environment.ai.isChecking && !environment.ai.statuses.isEmpty)
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        do {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                window.appearance = NSAppearance(named: appearance)
                for enabled in [false, true] {
                    try await environment.settings.updateAI { $0.isEnabled = enabled }
                    for lower in [false, true] {
                        try await Task.sleep(for: .milliseconds(250))
                        view.layoutSubtreeIfNeeded()
                        for scroll in scrollViews(view) {
                            guard let doc = scroll.documentView else { continue }
                            let maxY = max(0, doc.bounds.height - scroll.contentView.bounds.height)
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: lower ? maxY : 0))
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                        try await Task.sleep(for: .milliseconds(150))
                        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
                        let owns = rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
                        check("capture-owner", owns)
                        guard owns else { return }
                        view.displayIfNeeded()
                        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { check("bitmap", false); return }
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        guard let png = bitmap.representation(using: .png, properties: [:]) else { check("png", false); return }
                        try png.write(to: runRoot.appendingPathComponent("\(name)-\(enabled ? "on" : "off")-\(lower ? "lower" : "top").png"))
                    }
                }
            }
            try await environment.settings.updateAI {
                $0.defaultModels[.quick] = BrowserAIModelChoice(provider: .onDevice)
                $0.readsCurrentTabOnRequest = false
                $0.disabledSites = ["example.test"]
            }
            let expected = environment.settings.document.ai
            await environment.settings.refresh()
            check("persisted", environment.settings.document.ai == expected && expected.isEnabled)
        } catch { check("operation", false) }
    }
}
