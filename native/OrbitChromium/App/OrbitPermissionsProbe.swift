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

    /// Exercises Chromium's own window, including its native key dispatch, offscreen.
    private static func pictureInPicture(_ owner: OrbitWindowController, url: URL, mode: String) async -> [String: Any] {
        guard ["camera", "microphone", "global-off", "site-off", "manual"].contains(mode) else { return ["refused": true] }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let observers = [NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard !existing.contains(ObjectIdentifier(window)),
                          window.level == .floating, window.frame.origin.x > -2000 else { return }
                    window.setFrameOrigin(NSPoint(x: -2400, y: -1600))
                }
            }
        }
        defer { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
        let previousPrompt = owner.siteControls.permissionPrompt
        owner.siteControls.permissionPrompt = { _, _ in .allowOnce }
        defer { owner.siteControls.permissionPrompt = previousPrompt }
        guard let settings = owner.settingsPreferences?.runtime else { return ["missingSettings": true] }
        try? await settings.store.setAutomaticPictureInPicture(mode != "global-off" && mode != "manual")
        await settings.refresh()
        owner.session.openTab(url: url)
        await owner.session.waitForQueuedCommands()
        guard let tab = owner.session.selectedSurface else { return ["missingSurface": true] }
        await loaded(tab)
        var site = BrowserSitePreferences()
        site.automaticPictureInPicture = mode != "site-off"
        try? owner.siteControls.preferences.set(site, url: url, profileID: tab.profileID)
        let constraints = mode == "microphone" ? "audio:true" : "video:true"
        let setup = """
        (()=>{globalThis.callState='pending';globalThis.autoEntries=0;
        const v=document.querySelector('video');v.muted=true;v.play();
        navigator.mediaSession.setActionHandler('play',()=>v.play());
        navigator.mediaSession.setActionHandler('pause',()=>v.pause());
        navigator.mediaSession.setActionHandler('seekbackward',()=>v.currentTime-=10);
        navigator.mediaSession.setActionHandler('seekforward',()=>v.currentTime+=10);
        try { navigator.mediaSession.setActionHandler('enterpictureinpicture',async()=>{
          ++autoEntries;const w=await documentPictureInPicture.requestWindow();
          w.document.body.append(document.createElement('p'));}); } catch(e) {globalThis.registrationError=e.name;}
        navigator.mediaDevices.getUserMedia({\(constraints)}).then(s=>{
          globalThis.callStream=s;globalThis.callState='active';},e=>globalThis.callState=e.name);
        return {requested:true,documentPiP:typeof documentPictureInPicture!=='undefined'};})()
        """
        var result = await OrbitPerformanceProbe.evaluate(tab, setup) ?? [:]
        for _ in 0..<80 {
            let state = await OrbitPerformanceProbe.evaluate(tab, "({call:globalThis.callState})")
            if state?["call"] as? String != "pending" { result["call"] = state; break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(400))
        let media = await tab.requestMediaState()
        result["cameraActive"] = media.camera == .active
        result["microphoneActive"] = media.microphone == .active
        _ = await OrbitPerformanceProbe.evaluate(tab, "(()=>{document.querySelector('video').currentTime=20;return {positioned:true}})()")
        result["foreground"] = await OrbitPerformanceProbe.evaluate(tab, "({pip:!!document.pictureInPictureElement})")
        if mode == "manual" {
            _ = await OrbitPerformanceProbe.evaluate(tab, "(()=>{document.querySelector('video').requestPictureInPicture();return {requested:true}})()")
        }
        owner.session.openTab(url: url.appendingPathComponent("background"))
        await owner.session.waitForQueuedCommands()
        try? await Task.sleep(for: .milliseconds(700))
        func playback() async -> [String: Any] {
            await OrbitPerformanceProbe.evaluate(tab, "({pip:!!document.pictureInPictureElement,paused:document.querySelector('video').paused,time:document.querySelector('video').currentTime,autoEntries,registrationError:globalThis.registrationError||''})") ?? [:]
        }
        result["leftTab"] = await playback()
        if let pip = NSApp.windows.first(where: { !existing.contains(ObjectIdentifier($0)) && $0.level == .floating && $0.isVisible }) {
            pip.setFrameOrigin(NSPoint(x: -2400, y: -1600))
            result["nativeWindow"] = String(describing: type(of: pip))
            result["offscreen"] = pip.frame.maxX < 0 && pip.frame.maxY < 0
            // Dispatch directly to the owned native window. No global input or keyboard layout mapping.
            func press(_ character: String, code: UInt16) -> Bool {
                guard owns(owner), NSApp.windows.contains(where: { $0 === pip }),
                      let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(pip.windowNumber)) as? [[String: Any]],
                      rows.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }),
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: pip.windowNumber,
                          context: nil, characters: character, charactersIgnoringModifiers: character,
                          isARepeat: false, keyCode: code) else { return false }
                pip.makeKey()
                pip.sendEvent(event)
                return true
            }
            result["spaceSent"] = press(" ", code: 49)
            try? await Task.sleep(for: .milliseconds(150))
            result["afterSpace"] = await playback()
            result["leftSent"] = press(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123)
            try? await Task.sleep(for: .milliseconds(150))
            result["afterLeft"] = await playback()
            result["rightSent"] = press(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
            try? await Task.sleep(for: .milliseconds(150))
            result["afterRight"] = await playback()
            try? await settings.store.setAutomaticPictureInPicture(false)
            await settings.refresh()
            owner.siteControls.render()
            try? await Task.sleep(for: .milliseconds(300))
            result["disabledWhileOpen"] = await playback()
        }
        if let occurrence = owner.session.occurrenceID(for: tab) {
            owner.session.selectOccurrence(occurrence)
            await owner.session.waitForQueuedCommands()
        }
        _ = await OrbitPerformanceProbe.evaluate(tab, "(()=>{globalThis.callStream?.getTracks().forEach(t=>t.stop());if(document.pictureInPictureElement)document.exitPictureInPicture();return {stopped:true}})()")
        return result
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
        if command["kind"] == "pip" { return await pictureInPicture(owner, url: url, mode: command["mode"] ?? "camera") }
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
