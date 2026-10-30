import AppKit
import BrowserCore
import BrowserShell
import Foundation

extension OrbitSmokeDriver {
    /// Confined product integration with external open events and an injected timeout clock.
    func littleLifecycle(_ application: OrbitApplication, _ environment: OrbitEnvironment) async {
        func check(_ name: String, _ passed: Bool) { self.check("little." + name, passed) }
        let bundle = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        var now = Date()
        environment.quickWindowClock = { now }
        application.quickWindowPresenter = { little in
            little.window?.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            little.showWindow(nil)
        }
        func external(_ url: URL) throws {
            guard let owned = NSRunningApplication(processIdentifier: pid), owned.bundleURL?.standardizedFileURL == bundle.standardizedFileURL,
                  Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true else {
                throw BrowserStoreError.windowMissing
            }
            // Full bundle path prevents Launch Services from choosing an installed application.
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-g", "-a", bundle.path, url.absoluteString]
            try task.run()
        }
        func capture(_ window: NSWindow, _ name: String) throws {
            guard let view = window.contentView else { throw BrowserStoreError.windowMissing }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw BrowserStoreError.windowMissing }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw BrowserStoreError.windowMissing }
            try png.write(to: runRoot.appendingPathComponent(name + ".png"))
        }
        do {
            let a = fixture.appendingPathComponent("little-first"), b = fixture.appendingPathComponent("little-second")
            try external(a)
            guard await until(8, { environment.quickWindows.count == 1 }) else { check("first-open", false); return }
            let first = environment.quickWindows.values.first!
            let surface = first.surface
            try external(b)
            guard await until(8, { environment.quickWindows.count == 2 }) else { check("second-open", false); return }
            try external(a)
            try await Task.sleep(for: .milliseconds(400))
            await application.waitForQuickWindowCommands()
            check("external-repeat-reuses-live-document", environment.quickWindows.count == 2 && first.surface === surface)
            let ready = await until(8, { environment.quickWindows.values.allSatisfy { $0.surface?.isReady == true && $0.surface?.navigationState.isLoading == false } })
            check("real-documents-ready", ready)
            if let window = first.window { try capture(window, "two-links-first") }
            let model = BrowserSettingsModel(environment: environment, profileID: first.profileID, shortcuts: [])
            await model.reload()
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let settings = BrowserSettingsWindowController(model: model, appearanceOverride: appearance)
                defer { settings.window?.close() }
                _ = settings.selectSection(.general)
                settings.window?.setFrameOrigin(NSPoint(x: -4000, y: -4000))
                settings.showWindow(nil)
                try await Task.sleep(for: .milliseconds(600))
                if let window = settings.window { try capture(window, "settings-" + name) }
            }
            try await environment.settings.setQuickWindowArchiveThreshold(.after(2))
            now.addTimeInterval(2)
            await environment.sweepQuickWindowArchives()
            check("shortened-timeout-closes-both", environment.quickWindows.isEmpty)
            let records = await environment.store.sessionDocument().organization.archive.filter(\.isLittleWindow)
            check("automatic-origin", records.count == 2 && records.allSatisfy { $0.reason == .automatic })
            try await environment.saveNow()
            check("saved", true)
        } catch { record("little.operation", "failed", ["kind": String(describing: error)]) }
    }
}
