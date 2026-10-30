import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

/// Confined, offscreen qualification of the shipped settings and Command Bar paths.
@MainActor
enum OrbitSiteSearchProbe {
    static func run(environment: OrbitEnvironment, owner: OrbitWindowController, root: URL,
                    command: [String: String]) async -> [String: Any] {
        func owns(_ window: NSWindow?) -> Bool {
            guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.site-search",
                  let guardRoot = activeSyntheticDataGuard(), (try? guardRoot.checkInside(root)) != nil,
                  let window, NSApp.windows.contains(where: { $0 === window }),
                  let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
            return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
                && ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
        }
        guard owns(owner.window), let base = command["base"].flatMap(URL.init(string:)),
              base.scheme == "http", base.host == "127.0.0.1" else { return ["refused": true] }
        do {
            let runtime = environment.settings
            let entry = BrowserSiteSearch(name: "Synthetic Search", shortcut: "lab", template: base.absoluteString + "?q=%s")
            try await runtime.store.saveSiteSearch(entry)
            await runtime.refresh()
            guard owns(owner.window) else { return ["refused": true] }
            owner.palette.present(.newTab)
            guard owns(owner.window) else { return ["refused": true] }
            owner.palette.query("lab")
            let hint = owner.palette.view.siteSearchHint?.id == entry.id
            guard owns(owner.window) else { return ["refused": true] }
            let handoff = owner.palette.view.control(owner.palette.view.input, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
            let query = "two words café 猫 & #"
            guard owns(owner.window) else { return ["refused": true] }
            owner.palette.query(query)
            let destination = owner.palette.results.first?.url == entry.url(for: query)
            guard owns(owner.window) else { return ["refused": true] }
            owner.palette.accept()
            await owner.palette.waitForAcceptance()
            await owner.session.waitForPendingCommands()
            for _ in 0..<100 where owner.session.selectedSurface?.navigationState.isLoading != false {
                try await Task.sleep(for: .milliseconds(50))
            }
            let navigated = owner.session.selectedSurface?.currentURL == entry.url(for: query)
            let model = BrowserSettingsModel(environment: environment, profileID: owner.session.activeProfileID, shortcuts: [],
                defaultBrowser: .init(status: { .init(http: "synthetic", https: "synthetic", html: "synthetic") }, canRequest: { false }, request: {}))
            await model.reload()
            model.settingsSection = .shortcuts
            let controller = BrowserSettingsWindowController(model: model)
            defer { controller.close() }
            guard let window = controller.window else { return ["failed": true] }
            window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            window.orderBack(nil)
            model.showsSiteSearchSettings = true
            try await Task.sleep(for: .milliseconds(500))
            let captures = root.appendingPathComponent("captures")
            try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
            func capture(_ target: NSWindow, _ name: String) throws {
                guard owns(target), let view = target.contentView else { throw CocoaError(.userCancelled) }
                target.setFrameOrigin(NSPoint(x: -5000, y: -5000))
                view.layoutSubtreeIfNeeded(); target.displayIfNeeded(); view.display()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileReadUnknown) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileReadUnknown) }
                try png.write(to: captures.appendingPathComponent(name + ".png"))
            }
            for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(300))
                try capture(window, "settings-" + label)
                guard let sheet = window.attachedSheet else { return ["sheetMissing": true] }
                try capture(sheet, "site-search-" + label)
                let form = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 484, height: 230), styleMask: [.titled], backing: .buffered, defer: false)
                form.isReleasedWhenClosed = false
                form.contentView = NSHostingView(rootView: BrowserSiteSearchForm(entry: entry, entries: runtime.document.siteSearches, error: nil, save: { _ in }, cancel: {}))
                form.orderBack(nil)
                try await Task.sleep(for: .milliseconds(150))
                try capture(form, "editor-" + label)
                form.close()
            }
            try await runtime.store.setSiteSearchEnabled(entry.id, false)
            await runtime.refresh()
            let disabled = BrowserSiteSearch.matching("lab", in: runtime.document.siteSearches) == nil
            try await runtime.store.removeSiteSearch(entry.id)
            await runtime.refresh()
            let deleted = !runtime.document.siteSearches.contains { $0.id == entry.id }
            if let profile = owner.session.activeProfileID { try await runtime.updateProfile(profile) { $0.searchEngine = .perplexity } }
            return ["hint": hint, "tabHandoff": handoff, "encodedDestination": destination, "chromiumNavigation": navigated,
                    "disabled": disabled, "deleted": deleted, "perplexity": owner.addressResolver.searchEngine == .perplexity, "captures": 6]
        } catch { return ["failed": String(describing: type(of: error))] }
    }
}
