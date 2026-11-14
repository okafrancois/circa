import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Capture the Appearance and Advanced categories in light and dark, then toggle
    /// "Space around pages" with a click on the Appearance row and measure the page card.
    func appearanceSettingsScenario(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        func check(_ name: String, _ passed: Bool) { self.check("appearance-settings." + name, passed) }
        guard let profile = owner.session.activeProfileID, let browser = owner.window else { check("context", false); return }
        check("category-order", Array(BrowserSettingsSection.allCases.prefix(2)) == [.general, .appearance]
            && Array(BrowserSettingsSection.navigationSections.prefix(2)) == [.general, .appearance])
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        let settings = BrowserSettingsWindowController(model: model, appearanceOverride: nil)
        guard let window = settings.window, let view = window.contentView, let screen = NSScreen.main?.visibleFrame else {
            check("window", false); return
        }
        defer { window.close() }
        browser.setFrame(NSRect(x: screen.minX + 20, y: screen.maxY - 720, width: 900, height: 700), display: true)
        browser.orderFront(nil)
        window.setFrameTopLeftPoint(NSPoint(x: screen.minX + 940, y: screen.maxY - 20))
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        func owns(_ target: NSWindow) -> Bool {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(target.windowNumber)) as? [[String: Any]]
            return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        func capture(_ target: NSWindow, _ name: String) {
            guard owns(target) else { check("capture-owner", false); return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(target.windowNumber), runRoot.appendingPathComponent(name + ".png").path]
            try? process.run()
            process.waitUntilExit()
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        func scroll(lower: Bool) {
            view.layoutSubtreeIfNeeded()
            for scroll in scrollViews(view) {
                guard let doc = scroll.documentView else { continue }
                let maxY = max(0, doc.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: lower ? maxY : 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        _ = await until(3) { owns(window) && owns(browser) }
        check("input-owner", owns(window) && owns(browser))

        let previous = NSApp.appearance
        defer { NSApp.appearance = previous; window.appearance = nil }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            window.appearance = NSAppearance(named: appearance)
            for section in [BrowserSettingsSection.appearance, .advanced] {
                check("select-\(section.rawValue)", settings.selectSection(section))
                try? await Task.sleep(for: .milliseconds(600))
                scroll(lower: false)
                try? await Task.sleep(for: .milliseconds(150))
                capture(window, "\(section.rawValue)-\(name)")
                if section == .appearance {
                    scroll(lower: true)
                    try? await Task.sleep(for: .milliseconds(250))
                    capture(window, "\(section.rawValue)-lower-\(name)")
                }
            }
        }
        NSApp.appearance = previous
        window.appearance = nil

        // Toggle from the Appearance category with a real click on the switch.
        check("select-appearance-toggle", settings.selectSection(.appearance))
        try? await Task.sleep(for: .milliseconds(600))
        scroll(lower: false)
        try? await Task.sleep(for: .milliseconds(200))
        let initial = environment.settings.document.showsSpaceAroundPages
        let initialCard = owner.windowShell.geometry?.cardFrame
        capture(browser, "browser-space-around-\(initial ? "on" : "off")")
        // SwiftUI exposes no accessibility tree without an assistive client, so click the switch
        // where the top-scrolled Appearance pane renders it: 66.5 pt from the right edge and
        // 364 pt below the top of the window frame. The checks below fail if another row was hit.
        let switchPoint = NSPoint(x: window.frame.width - 66.5, y: window.frame.height - 364)
        check("switch-point", NSPointInRect(switchPoint, NSRect(origin: .zero, size: window.frame.size)))
        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard owns(window) else { check("click-owner", false); return }
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
            }
        }
        click(switchPoint)
        _ = await until(3) { environment.settings.document.showsSpaceAroundPages != initial }
        check("toggle-saved", environment.settings.document.showsSpaceAroundPages != initial)
        _ = await until(2) { owner.windowShell.geometry?.cardFrame != initialCard }
        let toggledCard = owner.windowShell.geometry?.cardFrame
        check("card-inset-changed", toggledCard != nil && toggledCard != initialCard)
        try? await Task.sleep(for: .milliseconds(400))
        capture(window, "appearance-toggled")
        capture(browser, "browser-space-around-\(initial ? "off" : "on")")
        let evidence: [String: Any] = ["initial": initial, "toggled": environment.settings.document.showsSpaceAroundPages,
            "initialCard": initialCard.map { NSStringFromRect($0) } ?? "", "toggledCard": toggledCard.map { NSStringFromRect($0) } ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: .sortedKeys) {
            try? data.write(to: runRoot.appendingPathComponent("space-around-pages.json"))
        }
        click(switchPoint)
        _ = await until(3) { environment.settings.document.showsSpaceAroundPages == initial }
        check("toggle-restored", environment.settings.document.showsSpaceAroundPages == initial)
    }
}
