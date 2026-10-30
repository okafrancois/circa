import AppKit
import BrowserEngine
import ChromiumEngine

/// Confined engine qualification; synthetic content, mock Keychain, no OS input.
@MainActor
enum OrbitEngineSecurityProbe {
    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard ["lab.orbit.orbit.engine-r13", "lab.orbit.orbit.engine-r14"].contains(Bundle.main.bundleIdentifier ?? ""),
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              Bundle.main.infoDictionary?["OrbitUseMockKeychain"] as? Bool == true,
              let window = owner.window, NSApp.windows.contains(where: { $0 === window }) else { return false }
        if !window.isVisible { return true }
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    }
    private static func loaded(_ tab: ChromiumSurface) async {
        for _ in 0..<160 {
            if tab.isReady && !tab.navigationState.isLoading { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(200))
    }
    static func run(_ owner: OrbitWindowController, command: [String: String]) async -> [String: Any] {
        guard owns(owner), let text = command["url"], let url = URL(string: text), url.host == "127.0.0.1",
              url.scheme == "http" else { return ["ownershipOrFixtureRefused": true] }
        owner.session.openTab(url: url)
        await owner.session.waitForQueuedCommands()
        guard let tab = owner.session.selectedSurface else { return ["missingSurface": true] }
        await loaded(tab)
        guard let api = tab.nativePageServices else { return ["apiUnavailable": true] }
        var result: [String: Any] = [:]
        let version = await tab.devToolsCall("Browser.getVersion")
        result["version"] = String(data: version.1, encoding: .utf8) ?? ""
        func encode<T: Encodable>(_ value: T?) -> String {
            value.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        func evaluate(_ expression: String) async -> [String: Any]? {
            guard owns(owner) else { return nil }
            return await OrbitPerformanceProbe.evaluate(tab, expression)
        }
        var securityEvents = 0
        let securityStream = api.securityChanges()
        let securityTask = Task { for await _ in securityStream { securityEvents += 1 } }
        defer { securityTask.cancel() }
        result["httpSecurity"] = encode(api.securityState())
        result["committedURL"] = api.committedURL()?.absoluteString ?? ""
        result["idn"] = api.securityDisplay(for: URL(string: "https://xn--pple-43d.com/path?q=synthetic")!, scheme: .show) ?? ""
        result["asciiDisplay"] = api.securityDisplay(for: URL(string: "https://example.invalid/path?q=synthetic")!, scheme: .omitHTTPAndHTTPS) ?? ""
        tab.navigate(to: url.appendingPathComponent("history-second"))
        await loaded(tab)
        result["history"] = encode(api.navigationHistory())
        if let history = api.navigationHistory(), history.currentIndex > 0 {
            result["goBack"] = api.goToEntry(index: history.currentIndex - 1)
            await loaded(tab)
            result["historyBack"] = api.committedURL() == url
        }
        result["invalidIndexRefused"] = !api.goToEntry(index: -1) && !api.goToEntry(index: Int.max)
        let previousDelegate = tab.delegate
        let permissions = PermissionDelegate()
        // Keep the engine transition observable without asking the shell for native fullscreen.
        tab.delegate = permissions
        var fullscreen: [BrowserPageFullscreenChange] = []
        let fullscreenStream = api.fullscreenChanges()
        let fullscreenTask = Task { for await event in fullscreenStream { fullscreen.append(event) } }
        _ = await evaluate("(()=>{document.documentElement.requestFullscreen();return {requested:true}})()")
        try? await Task.sleep(for: .milliseconds(300))
        _ = await evaluate("(()=>{if(document.fullscreenElement)document.exitFullscreen();return {requested:true}})()")
        try? await Task.sleep(for: .milliseconds(300))
        fullscreenTask.cancel()
        result["fullscreen"] = fullscreen.map { ["entered": $0.entered, "origin": $0.origin] }
        _ = await tab.devToolsCall("Emulation.setGeolocationOverride", params: #"{"latitude":0,"longitude":0,"accuracy":1}"#)
        let request = "(()=>{globalThis.permissionResult='pending';navigator.geolocation.getCurrentPosition(()=>permissionResult='granted',e=>permissionResult='error:'+e.code);return {requested:true}})()"
        _ = await evaluate(request)
        try? await Task.sleep(for: .milliseconds(500))
        result["onceInitialPrompts"] = permissions.prompts
        result["onceInitial"] = await evaluate("({value:globalThis.permissionResult})")
        tab.reload()
        await loaded(tab)
        _ = await evaluate(request)
        try? await Task.sleep(for: .milliseconds(500))
        result["onceReloadPrompts"] = permissions.prompts
        result["onceReload"] = await evaluate("({value:globalThis.permissionResult})")
        tab.delegate = previousDelegate
        tab.navigate(to: url.appendingPathComponent("media"))
        await loaded(tab)
        var mediaEvents = 0
        let mediaStream = api.mediaChanges()
        let mediaTask = Task { for await _ in mediaStream { mediaEvents += 1 } }
        _ = await evaluate("(()=>{startMedia();return {started:true}})()")
        try? await Task.sleep(for: .milliseconds(500))
        result["media"] = encode(api.mediaState())
        result["pause"] = api.mediaAction(.pause, seconds: 0)
        try? await Task.sleep(for: .milliseconds(100))
        result["mediaPaused"] = encode(api.mediaState())
        result["pausedPlayer"] = await evaluate("({paused:audio.paused})")
        result["play"] = api.mediaAction(.play, seconds: 0)
        try? await Task.sleep(for: .milliseconds(100))
        result["playingPlayer"] = await evaluate("({paused:audio.paused})")
        result["seek"] = api.mediaAction(.seek, seconds: 2)
        try? await Task.sleep(for: .milliseconds(150))
        result["seekPlayer"] = await evaluate("({time:audio.currentTime})")
        result["next"] = api.mediaAction(.next, seconds: 0)
        result["previous"] = api.mediaAction(.previous, seconds: 0)
        try? await Task.sleep(for: .milliseconds(200))
        result["mediaActions"] = await evaluate("({next:nextCount,previous:previousCount,time:audio.currentTime})")
        _ = await evaluate("(()=>{audio.pause();return {paused:true}})()")
        mediaTask.cancel()
        result["mediaEvents"] = mediaEvents
        if let tls = command["tls"], let fixture = URL(string: tls), fixture.host == "127.0.0.1", fixture.scheme == "https" {
            tab.navigate(to: fixture)
            await loaded(tab)
            result["certificateSecurity"] = encode(api.securityState())
            _ = await tab.devToolsCall("Security.setIgnoreCertificateErrors", params: #"{"ignore":true}"#)
            tab.navigate(to: fixture.appendingPathComponent("mixed"))
            await loaded(tab)
            result["mixedSecurity"] = encode(api.securityState())
            result["mixedExecuted"] = await evaluate("({ran:globalThis.mixedExecuted===true})")
            _ = await tab.devToolsCall("Security.setIgnoreCertificateErrors", params: #"{"ignore":false}"#)
        }
        result["securityEvents"] = securityEvents
        return result
    }
    static func weekly(_ owner: OrbitWindowController, root: URL) async -> [String: Any] {
        guard owns(owner), Bundle.main.bundleIdentifier == "lab.orbit.orbit.engine-r14" else {
            return ["ownershipRefused": true]
        }
        owner.session.openTab(url: URL(string: "about:blank")!)
        await owner.session.waitForQueuedCommands()
        guard let tab = owner.session.selectedSurface, let api = tab.nativePageServices,
              let extensions = owner.engine.extensions else { return ["unavailable": true] }
        await loaded(tab)
        var checks: [String: Any] = [:]
        func ownedWindow(_ window: NSWindow) -> Bool {
            let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
            return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        }
        checks["taskCapability"] = api.supportsTaskManager
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        guard owns(owner) else { return checks }
        checks["taskAccepted"] = api.openTaskManager()
        try? await Task.sleep(for: .milliseconds(500))
        let created = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
        checks["taskOwnedWindow"] = created.count == 1 && created.allSatisfy(ownedWindow)
        for window in created where ownedWindow(window) {
            // Direct AppKit operation on this process's verified native window.
            window.performClose(nil)
        }
        try? await Task.sleep(for: .milliseconds(100))
        checks["taskClosed"] = created.allSatisfy { !$0.isVisible }
        checks["traceCapability"] = api.supportsTracing
        checks["traceStarted"] = await api.beginTracing(categories: "browser,toplevel")
        checks["duplicateBeginRefused"] = !(await api.beginTracing(categories: "browser"))
        checks["escapeRefused"] = !(await api.endTracing(to: root.appendingPathComponent("escape.json")))
        try? await Task.sleep(for: .milliseconds(200))
        let profile = root.appendingPathComponent("Chromium/profile-" + tab.profileID.rawValue.uuidString.lowercased())
        let trace = profile.appendingPathComponent("weekly-trace.json")
        checks["traceCompleted"] = await api.endTracing(to: trace)
        checks["tracePath"] = trace.path
        checks["traceBytes"] = (try? Data(contentsOf: trace).count) ?? 0
        checks["duplicateEndRefused"] = !(await api.endTracing(to: profile.appendingPathComponent("duplicate.json")))
        checks["optionsCapability"] = extensions.supportsOptionsPages
        checks["incognitoCapability"] = extensions.supportsIncognitoPreference
        var fixture: BrowserExtensionSummary?
        for _ in 0..<40 {
            fixture = (try? extensions.installedExtensions(in: tab.profileID))?.first { $0.name == "Weekly fixture" }
            if fixture != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let fixture else { checks["extensionMissing"] = true; return checks }
        checks["extensionID"] = fixture.id
        checks["hasOptionsPage"] = fixture.hasOptionsPage
        checks["optionsURL"] = fixture.optionsURL?.absoluteString
        checks["canAllowIncognito"] = fixture.canAllowIncognito
        checks["incognitoInitiallyOff"] = fixture.isAllowedInIncognito == false
        do {
            guard owns(owner) else { return checks }
            try extensions.openOptions(extensionID: fixture.id, on: tab)
            checks["optionsOpened"] = true
            try? await Task.sleep(for: .milliseconds(500))
            checks["optionsNavigated"] = owner.session.ownedSurfaces.contains {
                $0.profileID == tab.profileID && $0.nativePageServices?.committedURL() == fixture.optionsURL
            }
        } catch { checks["optionsOpened"] = false }
        do {
            guard owns(owner) else { return checks }
            try extensions.setAllowedInIncognito(true, extensionID: fixture.id, in: tab.profileID)
            for _ in 0..<40 {
                if (try? extensions.installedExtensions(in: tab.profileID))?.first(where: { $0.id == fixture.id })?.isAllowedInIncognito == true {
                    checks["incognitoEnabled"] = true; break
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            try extensions.setAllowedInIncognito(false, extensionID: fixture.id, in: tab.profileID)
            for _ in 0..<40 {
                if (try? extensions.installedExtensions(in: tab.profileID))?.first(where: { $0.id == fixture.id })?.isAllowedInIncognito == false {
                    checks["incognitoReset"] = true; break
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        } catch { checks["incognitoError"] = true }
        return checks
    }
    @MainActor
    private final class PermissionDelegate: BrowserEngineSurfaceDelegate {
        typealias Surface = ChromiumSurface
        var prompts = 0
        func surfaceDidStartNavigation(_ surface: Surface) {}
        func surfaceDidCommitNavigation(_ surface: Surface) {}
        func surfaceDidFinishNavigation(_ surface: Surface) {}
        func surfaceDidFailNavigation(_ surface: Surface) {}
        func surface(_ surface: Surface, decidePolicyFor action: BrowserNavigationAction,
                     decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
        func surface(_ surface: Surface, createSurfaceFor request: BrowserNewSurfaceRequest, make: () -> Surface) -> Surface? { nil }
        func surfaceDidRequestClose(_ surface: Surface) {}
        func surface(_ surface: Surface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
        func surface(_ surface: Surface, requestsPermission request: BrowserPermissionRequest) async -> BrowserPermissionDecision {
            prompts += 1
            return .grantOnce
        }
    }
}
