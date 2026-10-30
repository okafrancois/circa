import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

/// Loopback-only permission qualification. No OS input or real hardware authorization.
@MainActor
enum OrbitPermissionsProbe {
    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.sec-permissions",
              let configuration = activeSiteSessionConfiguration(), configuration.syntheticGuard != nil,
              configuration.usesMockKeychain, let window = owner.window,
              NSApp.windows.contains(where: { $0 === window }) else { return false }
        if !window.isVisible { return true }
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    }

    private static func loaded(_ surface: ChromiumSurface) async {
        for _ in 0..<160 {
            if surface.isReady && !surface.navigationState.isLoading { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    static func run(_ owner: OrbitWindowController, environment: OrbitEnvironment, root: URL,
                    command: [String: String]) async -> [String: Any] {
        guard owns(owner), let url = command["url"].flatMap(URL.init(string:)),
              url.scheme == "http", url.host == "127.0.0.1", let origin = BrowserSiteOrigin(url: url) else { return ["refused": true] }
        if command["kind"] == "captures" { return captures(owner, root: root, origin: origin) }
        let kind = command["kind"] ?? "geolocation"
        guard ["geolocation", "camera", "microphone", "combined", "notifications"].contains(kind) else { return ["refused": true] }
        owner.session.openTab(url: url)
        await owner.session.waitForPendingCommands()
        guard var tab = owner.session.selectedSurface else { return ["missingSurface": true] }
        await loaded(tab)
        var prompts = 0
        var choice = BrowserSitePermissionChoice.allowOnce
        let previousPrompt = owner.siteControls.permissionPrompt
        let previousAuthorization = owner.siteControls.authorizeNotifications
        owner.siteControls.permissionPrompt = { _, _ in prompts += 1; return choice }
        owner.siteControls.authorizeNotifications = { false }
        defer {
            owner.siteControls.permissionPrompt = previousPrompt
            owner.siteControls.authorizeNotifications = previousAuthorization
        }
        var result: [String: Any] = ["pid": getpid(), "kind": kind, "offscreen": true]
        result["maskAudit"] = (0..<30).map { bit in
            ["bit": String(bit), "kind": String(describing: ChromiumSurface.permissionKind(mask: 1 << bit, media: false))]
        }
        result["mediaMaskAudit"] = (0..<4).map { bit in
            ["bit": String(bit), "kind": String(describing: ChromiumSurface.permissionKind(mask: 1 << bit, media: true))]
        }
        result["mixedMaskRefused"] = ChromiumSurface.permissionKind(mask: (1 << 2) | (1 << 1), media: false) == .other("cef-permission-6")
        func request(_ surface: ChromiumSurface, host: OrbitWindowController) async -> [String: Any] {
            guard owns(host) else { return ["refused": true] }
            if kind == "geolocation" {
                _ = await surface.devToolsCall("Emulation.setGeolocationOverride", params: #"{"latitude":0,"longitude":0,"accuracy":1}"#)
            }
            let expression: String
            switch kind {
            case "geolocation": expression = "navigator.geolocation.getCurrentPosition(()=>permissionResult='granted',e=>permissionResult='error:'+e.code)"
            case "notifications": expression = "Notification.requestPermission().then(v=>permissionResult=v)"
            default:
                let constraints = kind == "camera" ? "video:true" : kind == "microphone" ? "audio:true" : "video:true,audio:true"
                expression = "navigator.mediaDevices.getUserMedia({\(constraints)}).then(s=>{s.getTracks().forEach(t=>t.stop());permissionResult='granted'},e=>permissionResult=e.name)"
            }
            _ = await OrbitPerformanceProbe.evaluate(surface, "(()=>{globalThis.permissionResult='pending';\(expression);return {requested:true}})()")
            var response: [String: Any] = [:]
            for _ in 0..<60 {
                guard owns(host) else { return ["refused": true] }
                response = await OrbitPerformanceProbe.evaluate(surface, "({value:globalThis.permissionResult})") ?? [:]
                if response["value"] as? String != "pending" { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            response["prompts"] = prompts
            return response
        }
        if command["mode"] == "persistent" {
            choice = .alwaysAllow
            result["initial"] = await request(tab, host: owner)
            tab.reload(); await loaded(tab)
            result["reload"] = await request(tab, host: owner)
            result["configuredOrigins"] = await owner.siteControls.policy.store.configuredOrigins(profileID: tab.profileID).count
            return result
        }
        result["initial"] = await request(tab, host: owner)
        tab.reload(); await loaded(tab)
        result["reload"] = await request(tab, host: owner)
        tab.navigate(to: url.appendingPathComponent("away")); await loaded(tab)
        tab.goBack(); await loaded(tab)
        result["navigateBack"] = await request(tab, host: owner)
        tab.navigate(to: URL(string: "about:blank")!); await loaded(tab)
        tab.navigate(to: url); await loaded(tab)
        result["unload"] = await request(tab, host: owner)
        if let occurrence = owner.session.snapshot?.selectedOccurrenceID {
            owner.session.openTab(url: url.appendingPathComponent("background"))
            await owner.session.waitForPendingCommands()
            result["discarded"] = tab.suspendInPlace() == .suspended
            owner.session.selectOccurrence(occurrence)
            await owner.session.waitForPendingCommands()
            tab.hostDidChange(hidden: false)
            await loaded(tab)
            result["discardRestored"] = !tab.isSuspended
            result["discard"] = await request(tab, host: owner)
        }
        let profileID = tab.profileID
        owner.session.closeTabs([owner.session.organization!.selectedTab!.id])
        await owner.session.waitForPendingCommands()
        owner.session.openTab(url: url)
        await owner.session.waitForPendingCommands()
        guard let replacement = owner.session.selectedSurface else { return result }
        tab = replacement; await loaded(tab)
        result["close"] = await request(tab, host: owner)
        do {
            let profile = await environment.store.createProfile(name: "Synthetic permissions")
            _ = try await environment.store.createSpace(name: "Synthetic permissions", profileID: profile)
            let catalog = await environment.store.catalogSnapshot()
            if let space = catalog.spaces.first(where: { $0.profileID == profile }) {
                let other = try await environment.makeWindow(spaceID: space.id)
                defer { other.session.close(); other.window?.close() }
                other.siteControls.permissionPrompt = { _, _ in prompts += 1; return .allowOnce }
                other.siteControls.authorizeNotifications = { false }
                other.submitAddress(url.absoluteString)
                await other.session.waitForPendingCommands()
                if let foreign = other.session.selectedSurface {
                    await loaded(foreign)
                    result["separateProfile"] = foreign.profileID != profileID
                    result["profile"] = await request(foreign, host: other)
                }
            }
        } catch { result["profileError"] = true }
        choice = .dismiss
        tab.reload(); await loaded(tab)
        result["notNow"] = await request(tab, host: owner)
        tab.reload(); await loaded(tab)
        result["notNowReload"] = await request(tab, host: owner)
        tab.navigate(to: url.appendingPathComponent("next")); await loaded(tab)
        result["notNowNavigate"] = await request(tab, host: owner)
        result["configuredOrigins"] = await owner.siteControls.policy.store.configuredOrigins(profileID: profileID).count
        return result
    }

    private static func captures(_ owner: OrbitWindowController, root: URL, origin: BrowserSiteOrigin) -> [String: Any] {
        guard owns(owner), let hostWindow = owner.window else { return ["refused": true] }
        let directory = root.appendingPathComponent("captures")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let kinds: [(String, [BrowserSitePermission])] = [("camera", [.camera]), ("microphone", [.microphone]),
            ("combined", [.camera, .microphone]), ("geolocation", [.geolocation]),
            ("clipboard", [.clipboardRead]), ("notifications", [.notifications])]
        var paths: [String] = []
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            hostWindow.appearance = NSApp.appearance
            for (kind, permissions) in kinds {
                guard owns(owner) else { return ["refused": true] }
                let prompt = SitePermissionPromptView(origin: origin, permissions: permissions, onChoice: { _ in })
                prompt.appearance = NSApp.appearance
                let panel = BrowserSitePopover()
                panel.popover.appearance = NSApp.appearance
                panel.popover.animates = false
                owner.presentSiteControls(panel, rows: [prompt], button: owner.contentCard)
                prompt.window?.displayIfNeeded()
                if let image = prompt.bitmapImageRepForCachingDisplay(in: prompt.bounds) {
                    prompt.effectiveAppearance.performAsCurrentDrawingAppearance {
                        prompt.cacheDisplay(in: prompt.bounds, to: image)
                    }
                    let file = directory.appendingPathComponent("\(kind)-\(name).png")
                    if let png = image.representation(using: .png, properties: [:]) {
                        try? png.write(to: file); paths.append(file.lastPathComponent)
                    }
                }
                panel.close(animating: false)
            }
        }
        return ["captures": paths, "pid": getpid(), "offscreen": true]
    }
}
