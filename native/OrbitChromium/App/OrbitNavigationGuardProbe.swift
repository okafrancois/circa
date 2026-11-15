import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

/// Synthetic-only qualification of the shell load allowlist on the real engine: web pages, the
/// built-in pages the product opens, a PDF and a restored session still load, while debug pages
/// and `javascript:` issued by shell paths (direct surface loads, session tabs) do nothing.
@MainActor
enum OrbitNavigationGuardProbe {
    static let bundleID = "lab.orbit.orbit.nav-scheme-guard"

    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              Bundle.main.infoDictionary?["OrbitUseMockKeychain"] as? Bool == true,
              let window = owner.window,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    }

    private static func settle(_ surface: ChromiumSurface, until condition: () -> Bool, seconds: Double = 10) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if surface.isReady, !surface.navigationState.isLoading, condition() {
                try? await Task.sleep(for: .milliseconds(150))
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private static func committed(_ surface: ChromiumSurface) -> URL? { surface.navigationState.committedURL }

    private static func open(_ owner: OrbitWindowController, _ url: URL) async -> ChromiumSurface? {
        owner.session.openTab(url: url)
        await owner.session.waitForQueuedCommands()
        return owner.session.selectedSurface
    }

    private static func title(_ surface: ChromiumSurface) async -> String? {
        await OrbitPerformanceProbe.evaluate(surface, "({title: document.title})")?["title"] as? String
    }

    static func run(_ owner: OrbitWindowController, environment: OrbitEnvironment,
                    command: [String: String]) async -> [String: Any] {
        for _ in 0..<100 where !owns(owner) { try? await Task.sleep(for: .milliseconds(50)) }
        guard owns(owner), let base = command["url"].flatMap(URL.init(string:)) else {
            return ["refused": true, "window": owner.window?.windowNumber ?? -1, "visible": owner.window?.isVisible ?? false]
        }
        return command["action"] == "restore" ? await restore(owner, base: base) : await qualify(owner, environment: environment, base: base)
    }

    private static func qualify(_ owner: OrbitWindowController, environment: OrbitEnvironment,
                                base: URL) async -> [String: Any] {
        var checks: [String: Any] = [:]
        let page = base.appendingPathComponent("page")
        guard let web = await open(owner, page),
              await settle(web, until: { committed(web) == page }) else { return ["web": false] }
        checks["web"] = await title(web) == "Guard Page"

        // Shell-issued debug page and script loads on a live document: refused before the engine.
        web.navigate(to: URL(string: "chrome://crash")!)
        try? await Task.sleep(for: .milliseconds(1500))
        web.navigate(to: URL(string: "javascript:document.title='hijacked'")!)
        try? await Task.sleep(for: .milliseconds(700))
        checks["crashIgnored"] = await title(web) == "Guard Page" && committed(web) == page && !web.isDisposed

        // A session tab carrying a debug page (the restore and routing path) loads nothing.
        if let killed = await open(owner, URL(string: "chrome://kill")!) {
            try? await Task.sleep(for: .milliseconds(1500))
            checks["sessionKillIgnored"] = !killed.isDisposed && committed(killed)?.scheme != "chrome"
        }
        checks["webStillAlive"] = await title(web) == "Guard Page"

        // Built-in pages the product opens on purpose.
        if let settings = await open(owner, URL(string: "about:blank")!), await settle(settings, until: { true }) {
            BrowserNavigationPolicy.authorizeChromiumSettings(for: settings)
            settings.navigate(to: URL(string: "chrome://settings/")!)
            checks["settings"] = await settle(settings, until: { committed(settings)?.host == "settings" })
        }
        if let manager = environment.engine.extensionManagement,
           let extensions = await open(owner, URL(string: "about:blank")!), await settle(extensions, until: { true }) {
            try? manager.openManagement(on: extensions)
            checks["extensions"] = await settle(extensions, until: { committed(extensions)?.host == "extensions" })
        }
        let pdf = base.appendingPathComponent("doc.pdf")
        if let document = await open(owner, pdf) {
            checks["pdf"] = await settle(document, until: { committed(document) == pdf })
            let type = await OrbitPerformanceProbe.evaluate(document, "({type: document.contentType})")?["type"] as? String
            checks["pdfViewer"] = type == "application/pdf"
        }
        checks["tabs"] = owner.session.snapshot?.tabs.map { [$0.url.scheme ?? "", $0.url.host ?? ""] } ?? []
        return checks
    }

    private static func restore(_ owner: OrbitWindowController, base: URL) async -> [String: Any] {
        var checks: [String: Any] = [:]
        let tabs = owner.session.snapshot?.tabs ?? []
        checks["tabs"] = tabs.map { [$0.url.scheme ?? "", $0.url.host ?? ""] }
        var loaded: [String: Bool] = [:]
        var diagnostics: [String: Any] = [:]
        for tab in tabs {
            owner.session.selectTab(tab.id)
            await owner.session.waitForQueuedCommands()
            guard let surface = owner.session.selectedSurface else { continue }
            let key = "\(tab.url.scheme ?? ""):\(tab.url.host ?? "")\(tab.url.path)"
            switch tab.url.scheme {
            case "chrome" where tab.url.host == "kill":
                try? await Task.sleep(for: .milliseconds(1000))
                loaded[key] = !surface.isDisposed && committed(surface)?.scheme != "chrome"
            case "about":
                continue
            default:
                loaded[key] = await settle(surface, until: { committed(surface)?.host == tab.url.host
                    && (tab.url.scheme == "chrome" || committed(surface)?.path == tab.url.path) }, seconds: 8)
                if loaded[key] != true {
                    let url = committed(surface)
                    diagnostics[key] = ["committed": "\(url?.scheme ?? "nil"):\(url?.host ?? "")\(url?.path ?? "")",
                                        "ready": surface.isReady, "loading": surface.navigationState.isLoading,
                                        "requested": surface.navigationState.url.map { "\($0.scheme ?? ""):\($0.host ?? "")\($0.path)" } ?? "nil"]
                }
            }
        }
        checks["loaded"] = loaded
        checks["unloaded"] = diagnostics
        if let web = tabs.first(where: { $0.url == base.appendingPathComponent("page") }) {
            owner.session.selectTab(web.id)
            await owner.session.waitForQueuedCommands()
            if let surface = owner.session.selectedSurface { checks["webTitle"] = await title(surface) ?? "" }
        }
        return checks
    }
}
