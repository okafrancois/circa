import AppKit
import BrowserCore
import BrowserShell
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Skin integration checks run against the real engine on confined, invented data.
    func dailyQA6(_ environment: OrbitEnvironment, _ owner: OrbitWindowController,
                  _ engine: ChromiumBrowserEngine) async {
        func check(_ name: String, _ value: Bool) { self.check("daily6." + name, value) }
        owner.showWindow(nil)
        owner.window?.makeKeyAndOrderFront(nil)
        let url = fixture.appendingPathComponent("fixture")
        owner.submitAddress(url.absoluteString)
        guard await committed(owner, url) != nil,
              let profile = owner.session.activeProfileID,
              let id = owner.session.snapshot?.activeSpaceID else { check("fixture", false); return }
        do {
            let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
            var initial = BrandPalette.spaceGradients[0].theme(mode: .dark)
            initial.frost = true
            initial.noise = 0.27
            try await environment.store.setSpaceTheme(initial, for: id, profileID: profile)
            await model.reload()
            guard let space = model.catalog.spaces.first(where: { $0.id == id }) else { check("space", false); return }
            let picker = BrowserSettingsGradientPicker(model: model, space: space)
            picker.select(BrandPalette.spaceGradients[3])
            try await model.waitForPendingActions()
            let saved = model.catalog.spaces.first(where: { $0.id == id })?.theme
            check("gradient-controls", saved?.frost == true && saved?.noise == 0.27 && saved?.mode == .dark)
            check("gradient-palette", saved?.light == BrandPalette.spaceGradients[3].theme().light)
            await environment.refreshSettingsCatalog()
            let settings = BrowserSettingsWindowController(model: model, appearanceOverride: nil)
            defer { settings.window?.close() }
            settings.showWindow(nil)
            let top = settings.window?.frame.maxY ?? 0
            for section in BrowserSettingsSection.allCases {
                check("category-" + section.rawValue, settings.selectSection(section))
                try await Task.sleep(for: .milliseconds(30))
            }
            try await Task.sleep(for: .milliseconds(600))
            if let window = settings.window {
                let expected = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 684, height: BrowserSettingsSection.about.contentHeight)).height
                check("rapid-pane-height", abs(window.frame.height - expected) < 1 && abs(window.frame.maxY - top) < 1)
                check("rapid-pane-content", model.settingsSection == .about && window.title == BrowserSettingsSection.about.title)
                let alert = OrbitFrostAlert()
                alert.messageText = "Synthetic appearance check"
                alert.addButton(withTitle: "OK")
                window.appearance = NSAppearance(named: .aqua)
                let panel = alert.preparedWindow(for: window)
                defer { panel.close() }
                panel.orderFront(nil)
                window.appearance = NSAppearance(named: .darkAqua)
                check("dialog-live-appearance", OrbitAppearance.isDark(panel.effectiveAppearance))
                window.appearance = nil
                check("dialog-automatic-appearance", panel.appearance == nil)
            }
            let appearance = NSApp.appearance
            defer { NSApp.appearance = appearance }
            NSApp.appearance = NSAppearance(named: .aqua)
            let host = NSView()
            host.appearance = NSAppearance(named: .aqua)
            let preview = OrbitOnboardingPromptMock(frame: NSRect(x: 0, y: 0, width: 300, height: 230))
            host.addSubview(preview)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            check("preview-app-appearance", OrbitAppearance.isDark(preview.effectiveAppearance))
            preview.refreshMaterial(reduceTransparency: true)
            check("preview-opaque-fallback", (preview.subviews.first as? NSVisualEffectView)?.isHidden == true)
            preview.refreshMaterial(reduceTransparency: false)
            check("preview-frost-restored", (preview.subviews.first as? NSVisualEffectView)?.isHidden == false)
            try await environment.saveNow()
            check("session-saved", true)
        } catch {
            check("integration", false)
        }
    }
}
