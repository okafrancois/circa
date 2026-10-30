import AppKit
import BrowserEngine
import ChromiumEngine

/// Synthetic-only exercise of the production diagnostic bindings and extension menu dispatch.
@MainActor
enum OrbitR14ShellProbe {
    static func run(_ owner: OrbitWindowController, application: OrbitApplication) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.engine-r14",
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              Bundle.main.infoDictionary?["OrbitUseMockKeychain"] as? Bool == true,
              let window = owner.window else { return ["refused": true] }
        func owned(_ window: NSWindow) -> Bool {
            let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
            return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        }
        owner.session.openTab(url: URL(string: "about:blank")!)
        await owner.session.waitForQueuedCommands()
        guard let surface = owner.session.selectedSurface else { return ["surfaceMissing": true] }
        for _ in 0..<160 {
            if surface.isReady && !surface.navigationState.isLoading { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard owned(window), window.frame.maxX < 0 else { return ["offscreenRefused": true] }
        // Suppress only Finder activation in the confined run; the production reveal callback
        // is independently exercised by shell tests. Native diagnostic/menu handlers are unchanged.
        var revealed: URL?
        let recording = BrowserTraceRecording(reveal: { revealed = $0 })
        let registry = try! BrowserCommandRegistry(router: application.windows, state: { $0?.commandState ?? .init() },
            currentWindowID: { owner.id }, deliver: { controller, action in controller.performAcceptedCommand(action) })
        BrowserDiagnosticCommands.install(in: registry, recording: recording)
        var checks: [String: Any] = [:]
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        guard owned(window) else { return checks }
        checks["taskAccepted"] = registry.dispatch(.openTaskManager, origin: .menu)
        await owner.session.waitForQueuedCommands()
        try? await Task.sleep(for: .milliseconds(400))
        let created = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
        checks["taskOwnedOffscreen"] = created.count == 1 && created.allSatisfy { owned($0) && $0.frame.maxX < 0 }
        for task in created where owned(task) { task.performClose(nil) }
        try? await Task.sleep(for: .milliseconds(100))
        checks["taskClosed"] = created.allSatisfy { !$0.isVisible }
        guard owned(window) else { return checks }
        checks["recordAccepted"] = registry.dispatch(.recordTrace, origin: .menu)
        await owner.session.waitForQueuedCommands()
        await recording.operation?.value
        checks["recording"] = registry.isEnabled(.cancelTrace)
        try? await Task.sleep(for: .milliseconds(200))
        guard owned(window) else { return checks }
        checks["stopAccepted"] = registry.dispatch(.recordTrace, origin: .menu)
        await owner.session.waitForQueuedCommands()
        await recording.operation?.value
        let root = owner.engine.diagnosticDataRoot(for: surface.profileID)
        checks["traceInProfile"] = revealed?.deletingLastPathComponent().standardizedFileURL.path == root?.standardizedFileURL.path
        checks["traceBytes"] = revealed.flatMap { try? Data(contentsOf: $0).count } ?? 0
        checks["tracePath"] = revealed?.path ?? ""
        guard owned(window) else { return checks }
        checks["cancelBegin"] = registry.dispatch(.recordTrace, origin: .menu)
        await owner.session.waitForQueuedCommands(); await recording.operation?.value
        checks["cancelAccepted"] = registry.dispatch(.cancelTrace, origin: .palette)
        await owner.session.waitForQueuedCommands(); await recording.operation?.value
        checks["cancelRemoved"] = recording.surface == nil && root.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("trace-") }.count
        } == 1
        guard let host = owner.engine.extensions else { return checks }
        let inventory = (try? host.installedExtensions(on: surface)) ?? []
        guard let fixture = inventory.first(where: { $0.hasOptionsPage == true }),
              let menu = owner.extensionControls.contextMenu(for: fixture, surface: surface) else { return checks }
        let index = menu.indexOfItem(withTitle: uiText("Options"))
        checks["optionsVisible"] = index >= 0
        checks["privateOptionAbsent"] = !menu.items.contains { $0.title.lowercased().contains("incognito") }
        guard index >= 0, owned(window) else { return checks }
        menu.performActionForItem(at: index)
        for _ in 0..<160 {
            if owner.session.selectedSurface?.navigationState.url == fixture.optionsURL { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        checks["optionsOpened"] = owner.session.selectedSurface?.navigationState.url == fixture.optionsURL
        // Closing the source while recording must stop the process-wide recorder before teardown.
        guard let current = owner.session.selectedSurface, let api = current.nativePageServices, owned(window) else { return checks }
        checks["closeBegin"] = await api.beginTracing(categories: "browser,toplevel")
        owner.session.openTab(url: URL(string: "about:blank")!)
        await owner.session.waitForQueuedCommands()
        current.dispose()
        for _ in 0..<160 {
            if current.isTeardownComplete { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        checks["closeTeardown"] = current.isTeardownComplete
        for _ in 0..<160 {
            if owner.session.selectedSurface?.isReady == true { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if let next = owner.session.selectedSurface?.nativePageServices {
            checks["recordAfterClose"] = await next.beginTracing(categories: "browser,toplevel")
            if let root {
                let file = root.appendingPathComponent("close-check.json")
                checks["endAfterClose"] = await next.endTracing(to: file)
                try? FileManager.default.removeItem(at: file)
            }
        }
        return checks
    }
}
