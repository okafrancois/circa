import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Foundation

/// Runs against the shipped bridge and Chromium, using only an explicit loopback fixture.
@MainActor
enum OrbitSiteDataScenarios {
    static func run(environment: OrbitEnvironment, window: OrbitWindowController, fixture: URL,
                    record: (String, String, [String: Any]) -> Void) async {
        func check(_ name: String, _ value: Bool) { record("site." + name, value ? "proven" : "failed", [:]) }
        let engine = environment.engine
        let page = fixture.appendingPathComponent("site-fixture")
        guard let origin = BrowserSiteOrigin(url: page) else { return }
        window.submitAddress(page.absoluteString)
        await window.session.waitForQueuedCommands()
        guard let tab = window.session.selectedSurface, await loaded(tab), let probe = engine.conformanceProbe else {
            check("navigation", false); return
        }
        let delegate = ProbeDelegate()
        let other = engine.makeSurface(profileID: ProfileID(), delegate: delegate)
        defer { other.dispose() }
        other.navigate(to: page)
        guard await loaded(other) else { check("second-profile", false); return }
        do {
            let seed = """
                (async () => {
                  document.cookie='session=connected; path=/';
                  document.cookie='nested=connected; path=/site-fixture';
                  localStorage.setItem('session','connected');
                  await new Promise((resolve,reject)=>{ const r=indexedDB.open('site-data-fixture',1);
                    r.onupgradeneeded=()=>r.result.createObjectStore('items'); r.onsuccess=()=>{r.result.close();resolve()}; r.onerror=reject; });
                  await (await caches.open('site-data-fixture')).put('/cached',new Response('fixture'));
                  await navigator.serviceWorker.register('/worker.js');
                  return true;
                })()
                """
            let seeded = await evaluate(tab, seed)
            let otherSeeded = await evaluate(other, seed)
            check("seed", seeded == "true" && otherSeeded == "true")
            let summary = await engine.siteData(origin: origin, profileID: tab.profileID)
            check("summary", summary.isAvailable && summary.cookieCount == 2 && summary.hasStorage == true)
            let before = await evaluate(tab, "fetch('/cookie-state').then(r=>r.text())")
            check("server-connected", before == "connected")
            // Same profile, different origin: its localStorage must survive the clear.
            var components = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
            components.host = "localhost"
            let foreignPage = components.url!.appendingPathComponent("site-fixture")
            let foreignOrigin = BrowserSiteOrigin(url: foreignPage)!
            let foreign = engine.makeSurface(profileID: tab.profileID, delegate: delegate)
            defer { foreign.dispose() }
            foreign.navigate(to: foreignPage)
            guard await loaded(foreign) else { check("foreign-origin", false); return }
            _ = await evaluate(foreign, "localStorage.setItem('session','foreign');true")
            try await engine.clearSiteData(origin: origin, profileID: tab.profileID, expectedDomains: summary.domains)
            _ = await loaded(tab)
            let after = await evaluate(tab, "fetch('/cookie-state').then(r=>r.text())")
            check("server-signed-out", after == "disconnected")
            let empty = await evaluate(tab, "(async()=>!localStorage.getItem('session') && (await indexedDB.databases()).length===0 && (await caches.keys()).length===0 && (await navigator.serviceWorker.getRegistrations()).length===0)()")
            check("origin-storage-cleared", empty == "true")
            let retained = await engine.siteData(origin: origin, profileID: other.profileID)
            let otherServer = await evaluate(other, "fetch('/cookie-state').then(r=>r.text())")
            check("profile-isolated", retained.cookieCount == 2 && retained.hasStorage == true && otherServer == "connected")
            check("other-origin-retained", await evaluate(foreign, "localStorage.getItem('session')") == "foreign" && foreignOrigin != origin)

            // An eTLD+1 clear removes sibling-host and parent-domain cookies, including HttpOnly.
            var domainURL = URLComponents(url: fixture, resolvingAgainstBaseURL: false)!
            domainURL.host = "a.site-data.localhost"
            let domainPage = domainURL.url!.appendingPathComponent("site-fixture")
            let domainOrigin = BrowserSiteOrigin(url: domainPage)!
            let domainTab = engine.makeSurface(profileID: tab.profileID, delegate: delegate)
            defer { domainTab.dispose() }
            domainTab.navigate(to: domainPage)
            guard await loaded(domainTab) else { check("etld-navigation", false); return }
            _ = await domainTab.devToolsCall("Network.setCookie", params: #"{"name":"parent","value":"fixture","domain":".site-data.localhost","path":"/","httpOnly":true}"#)
            _ = await domainTab.devToolsCall("Network.setCookie", params: #"{"name":"sibling","value":"fixture","domain":"b.site-data.localhost","path":"/"}"#)
            let domainSummary = await engine.siteData(origin: domainOrigin, profileID: tab.profileID)
            check("etld-summary", domainSummary.domains == ["site-data.localhost"] && domainSummary.cookieCount == 2)
            try await engine.clearSiteData(origin: domainOrigin, profileID: tab.profileID, expectedDomains: domainSummary.domains)
            _ = await loaded(domainTab)
            let clearedDomain = await engine.siteData(origin: domainOrigin, profileID: tab.profileID)
            check("etld-cookies-cleared", clearedDomain.isAvailable && clearedDomain.cookieCount == 0)

            var prompts = 0
            window.siteControls.permissionPrompt = { _, _ in prompts += 1; return .alwaysAllow }
            // Hidden engine checks must never present an OS authorization dialog.
            let authorizeNotifications = window.siteControls.authorizeNotifications
            window.siteControls.authorizeNotifications = { true }
            defer {
                window.siteControls.permissionPrompt = nil
                window.siteControls.authorizeNotifications = authorizeNotifications
            }
            try await window.siteControls.policy.store.reset(origin: origin, profileID: tab.profileID)
            await engine.revokeSitePermission(nil, origin: origin, profileID: tab.profileID)
            _ = await loaded(tab)
            let capture = "navigator.mediaDevices.getUserMedia({video:true,audio:true}).then(s=>{window.fixtureStream=s;return s.getTracks().length}).catch(e=>e.name)"
            check("media-allow", await evaluate(tab, capture) == "2")
            let choices = await window.siteControls.policy.store.snapshot(origin: origin, profileID: tab.profileID)
            check("media-persisted", choices[.camera] == .allow && choices[.microphone] == .allow && prompts > 0)
            if let file = environment.sessionFile?.appendingPathExtension("site-permissions.json") {
                let reopened = try BrowserSitePermissionStore(destination: file)
                let saved = await reopened.snapshot(origin: origin, profileID: tab.profileID)
                check("permission-disk-reopen", saved[.camera] == .allow && saved[.microphone] == .allow)
            }
            await engine.setSitePermission(.block, permission: .camera, origin: origin, profileID: tab.profileID)
            _ = await loaded(tab)
            check("media-revoked", await evaluate(tab, "!window.fixtureStream || window.fixtureStream.getTracks().every(t=>t.readyState==='ended')") == "true")
            try await window.siteControls.policy.store.set(.block, for: [.camera], origin: origin, profileID: tab.profileID)
            check("media-block", await evaluate(tab, capture) == "NotAllowedError")
            try await window.siteControls.policy.store.reset(origin: origin, profileID: tab.profileID)
            await engine.revokeSitePermission(nil, origin: origin, profileID: tab.profileID)
            _ = await loaded(tab)
            let previous = prompts
            check("media-ask-again", await evaluate(tab, capture) == "2" && prompts > previous)
            // DevTools provides a position, while permission still goes through the real shell.
            _ = await tab.devToolsCall("Emulation.setGeolocationOverride", params: #"{"latitude":48.85,"longitude":2.35,"accuracy":10}"#)
            check("location-allow", await evaluate(tab, "new Promise(r=>navigator.geolocation.getCurrentPosition(p=>r(p.coords.latitude),e=>r(e.code),{timeout:2000}))") == "48.85")
            try await window.siteControls.policy.store.set(.block, for: [.geolocation], origin: origin, profileID: tab.profileID)
            await engine.setSitePermission(.block, permission: .geolocation, origin: origin, profileID: tab.profileID)
            _ = await loaded(tab)
            check("location-block", await evaluate(tab, "new Promise(r=>navigator.geolocation.getCurrentPosition(()=>r('unexpected'),e=>r(e.code),{timeout:2000}))") == "1")
            check("notification-allow", await evaluate(tab, "Notification.requestPermission()") == "granted")
            try await window.siteControls.policy.store.set(.block, for: [.notifications], origin: origin, profileID: tab.profileID)
            await engine.setSitePermission(.block, permission: .notifications, origin: origin, profileID: tab.profileID)
            check("notification-block", await evaluate(tab, "Notification.requestPermission()") == "denied")
            let untouched = await window.siteControls.policy.store.snapshot(origin: origin, profileID: other.profileID)
            check("permission-profile-isolated", [BrowserSitePermission.camera, .microphone, .geolocation, .notifications].allSatisfy { untouched[$0] == .ask })
        } catch { record("site.operation", "failed", ["error": String(describing: error)]) }
    }

    private static func loaded(_ surface: ChromiumSurface) async -> Bool {
        try? await Task.sleep(for: .milliseconds(150))
        let deadline = ContinuousClock.now + .seconds(5)
        while (!surface.isReady || surface.navigationState.isLoading || surface.navigationState.committedURL == nil), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return surface.isReady && !surface.navigationState.isLoading
    }

    private static func evaluate(_ surface: ChromiumSurface, _ expression: String) async -> String? {
        let parameters: [String: Any] = ["expression": expression, "awaitPromise": true, "returnByValue": true, "userGesture": true]
        guard let data = try? JSONSerialization.data(withJSONObject: parameters) else { return nil }
        let (ok, result) = await surface.devToolsCall("Runtime.evaluate", params: String(decoding: data, as: UTF8.self), timeout: .seconds(5))
        guard ok, let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              object["exceptionDetails"] == nil, let value = (object["result"] as? [String: Any])?["value"] else { return nil }
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return CFGetTypeID(value) == CFBooleanGetTypeID() ? (value.boolValue ? "true" : "false") : value.stringValue }
        return nil
    }

    private final class ProbeDelegate: BrowserEngineSurfaceDelegate {
        func surfaceDidStartNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidFinishNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidFailNavigation(_ surface: ChromiumSurface) {}
        func surfaceDidRequestClose(_ surface: ChromiumSurface) {}
        func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                     decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
        func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                     make: () -> ChromiumSurface) -> ChromiumSurface? { nil }
        func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
    }
}
