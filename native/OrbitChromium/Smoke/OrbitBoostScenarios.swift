import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import ChromiumEngine
import Foundation

extension OrbitSmokeDriver {
    func boostScenarios(_ application: OrbitApplication, _ environment: OrbitEnvironment,
                        _ window: OrbitWindowController, _ engine: ChromiumBrowserEngine) async {
        guard let host = engine.boosts, let probe = engine.conformanceProbe else { check("boosts.capability", false); return }
        check("boosts.capability", engine.capabilities.contains(.boosts))
        let initialProfile = try? await environment.initialContext.value.1
        guard let profile = window.session.selectedSurface?.profileID ?? initialProfile else { check("boosts.profile", false); return }
        let url = URL(string: "/boosts/main", relativeTo: fixture)!.absoluteURL
        func evaluate(_ source: String, _ surface: ChromiumSurface) async -> String? { try? await probe.evaluateScript(source, in: surface) }
        do {
            // Compile the actual model, including declarative Zap and explicit JS opt-in.
            var content = BrowserBoostContent()
            content.customCSS = ":root { --boost: installed; background-color: rgb(40, 90, 120) !important; }"
            content.zapSelectors = ["#zap"]
            content.customJavaScript = "globalThis.boostSecret = 42; document.documentElement.dataset.binding = String(typeof chrome === 'undefined' || !chrome.runtime || !chrome.runtime.id); document.documentElement.dataset.started = 'yes'; fetch('/boosts/forbidden').then(()=>document.documentElement.dataset.network='escaped',()=>document.documentElement.dataset.network='blocked');"
            let store = try environment.boosts.store(for: profile)
            let firstID = BrowserBoostID(), childID = BrowserBoostID()
            for (id, domain) in [(firstID, "127.0.0.1"), (childID, "localhost")] {
                let pattern = try BrowserBoostHostPattern(host: domain, schemes: [.http], port: fixture.port)
                try await store.save(BrowserBoost(id: id, title: "Synthetic registration", hostPattern: pattern, content: content, javaScriptOptIn: true))
            }
            var second = BrowserBoostContent()
            second.customJavaScript = "document.documentElement.dataset.otherWorld = typeof globalThis.boostSecret"
            try await store.save(.init(title: "Independent world", hostPattern: try .init(host: "127.0.0.1", schemes: [.http], port: fixture.port), content: second, javaScriptOptIn: true))
            try await environment.boosts.synchronize(profileID: profile, enabled: true, engine: engine)
            check("boosts.initial-ack", environment.boosts.acknowledgements[profile] != nil)
            window.submitAddress(url.absoluteString)
            guard let tab = await committed(window, url) else { check("boosts.navigation", false); return }
            let (_, diagnostics) = await tab.devToolsCall("Runtime.evaluate", params: "{\"expression\":\"JSON.stringify({url:location.href,early:window.early,isolation:window.pageIsolation,binding:window.chromeBinding,attributes:document.documentElement.dataset,html:document.documentElement.outerHTML})\",\"returnByValue\":true}")
            check("boosts.fixture-page-script", await evaluate("String(document.documentElement.dataset.pageProbe)", tab) == "loaded", ["diagnostic": String(decoding: diagnostics, as: UTF8.self)])
            check("boosts.document-start", await evaluate("String(early === 'installed' && document.documentElement.dataset.started === 'yes' && getComputedStyle(document.querySelector('#zap')).display === 'none')", tab) == "true")
            check("boosts.world-per-registration", await evaluate("String(Object.hasOwn(document.documentElement.dataset, 'otherWorld') && document.documentElement.dataset.otherWorld === 'undefined')", tab) == "true")
            check("boosts.isolated-dom-only", await evaluate("String(pageIsolation === 'undefined' && chromeBinding === 'true')", tab) == "true")
            for _ in 0..<50 {
                if await evaluate("String(!!window.childResult)", tab) == "true" { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let child = await evaluate("JSON.stringify(window.childResult)", tab)
            check("boosts.nested-cross-origin", child?.contains("\"early\":\"installed\"") == true && child?.contains("\"zap\":\"none\"") == true && child?.contains("\"isolation\":\"undefined\"") == true, ["result": child ?? "missing"])
            let (targetsOK, targets) = await tab.devToolsCall("Target.getTargets", params: "{}")
            let targetList = (try? JSONSerialization.jsonObject(with: targets) as? [String: Any])?["targetInfos"] as? [[String: Any]]
            check("boosts.oopif", targetsOK && targetList?.contains { ($0["type"] as? String) == "iframe" && ($0["url"] as? String)?.contains("localhost") == true } == true)
            check("boosts.extension-coexists", await evaluate("String(document.documentElement.dataset.extension === 'working' && window.childResult?.extension === 'working')", tab) == "true")
            if let capture = try? await tab.captureSnapshot(.init(width: 1000)),
               let png = NSBitmapImageRep(cgImage: capture.image).representation(using: .png, properties: [:]) {
                try png.write(to: runRoot.appendingPathComponent("boost-applied.png"))
            }
            check("boosts.world-csp", await evaluate("String(document.documentElement.dataset.network)", tab) == "blocked")
            var changed = (await store.snapshot().boosts).first { $0.id == firstID }!
            changed.content.customCSS = ":root { --boost: updated; background-color: rgb(110, 40, 80) !important; }"
            changed.content.customJavaScript = "document.documentElement.dataset.reran = 'bad'"
            try await store.save(changed, expectedRevision: changed.revision)
            var changedChild = (await store.snapshot().boosts).first { $0.id == childID }!
            changedChild.content.customCSS = changed.content.customCSS
            try await store.save(changedChild, expectedRevision: changedChild.revision)
            try await environment.boosts.synchronize(profileID: profile, enabled: true, engine: engine)
            _ = await evaluate("window.childResult=null;frames[0].frames[0].postMessage('report','*');'ok'", tab)
            try? await Task.sleep(for: .milliseconds(100))
            check("boosts.live-oopif", await evaluate("String(window.childResult?.live)", tab) == "updated")
            check("boosts.live-ack", await evaluate("String(getComputedStyle(document.documentElement).getPropertyValue('--boost').trim() === 'updated' && !document.documentElement.dataset.reran)", tab) == "true")
            // A frame created after the update gets its own URL's registration before page scripts.
            _ = await evaluate("(()=>{const f=document.createElement('iframe');f.src='/boosts/later';document.body.append(f);return 'ok'})()", tab)
            try? await Task.sleep(for: .milliseconds(400))
            check("boosts.later-frame", await evaluate("String(document.querySelectorAll('iframe')[1]?.contentWindow.early)", tab) == "updated")
            do {
                _ = try await host.replaceBoosts(.init(profileID: profile, revision: 1, boosts: []))
                check("boosts.stale-rejected", false)
            } catch { check("boosts.stale-rejected", true) }
            let freshDelegate = BoostProbeDelegate()
            let freshProfile = ProfileID()
            let existing = engine.makeSurface(profileID: freshProfile, delegate: freshDelegate)
            let freshURL = URL(string: "/boosts/later", relativeTo: fixture)!.absoluteURL
            existing.navigate(to: freshURL)
            _ = await until(5) { existing.navigationState.committedURL == freshURL && !existing.navigationState.isLoading }
            check("boosts.other-profile-unaffected", await evaluate("String(early === '' && !document.documentElement.dataset.started)", existing) == "true")
            let freshBoost = try BrowserBoostCompiler.compile(.init(title: "Live registration", hostPattern: try .init(host: "127.0.0.1", schemes: [.http], port: fixture.port), content: content))
            _ = try await host.replaceBoosts(.init(profileID: freshProfile, revision: 1, boosts: [freshBoost]))
            check("boosts.register-existing-frame", await evaluate("String(getComputedStyle(document.documentElement).getPropertyValue('--boost').trim())", existing) == "installed")
            existing.dispose()
            // Exercise the actual application private-window command and its ephemeral context.
            application.createPrivateCommandWindow()
            await application.waitForPrivateWindowCommands()
            guard let (privateID, owned) = application.privateWindows.first,
                  let privateWindow = application.windows.windows[privateID] else { check("boosts.private-window", false); return }
            privateWindow.submitAddress(url.absoluteString)
            guard let privateTab = await committed(privateWindow, url) else { check("boosts.private-navigation", false); return }
            let memory = owned.environment
            let privateValue = try? await memory.engine.conformanceProbe?.evaluateScript("String(early === '' && !document.documentElement.dataset.started && getComputedStyle(document.querySelector('#zap')).display !== 'none')", in: privateTab)
            check("boosts.private-unaffected", privateWindow.isPrivateWindow && privateValue == "true" && memory.engine.boosts == nil)
            await application.closePrivateWindows()
            check("boosts.normal-survives-private", await evaluate("String(getComputedStyle(document.documentElement).getPropertyValue('--boost').trim())", tab) == "updated")
            let ack = try await host.removeBoosts(profileID: profile, revision: 100)
            let removed = await evaluate("String(getComputedStyle(document.documentElement).getPropertyValue('--boost').trim() === '' && getComputedStyle(document.querySelector('#zap')).display !== 'none')", tab) == "true"
            check("boosts.removal-ack", ack.revision == 100 && removed)
            _ = await evaluate("window.childResult=null;frames[0].frames[0].postMessage('report','*');'ok'", tab)
            try? await Task.sleep(for: .milliseconds(100))
            check("boosts.removal-oopif", await evaluate("String(window.childResult?.live === '' && window.childResult?.zap !== 'none')", tab) == "true")
            window.reload()
            try? await Task.sleep(for: .milliseconds(600))
            check("boosts.removal-next-document", await evaluate("String(early === '' && !document.documentElement.dataset.started && document.documentElement.dataset.extension === 'working')", tab) == "true")
        } catch { record("boosts.operation", "failed", ["error": String(describing: error)]) }
    }
}

@MainActor
private final class BoostProbeDelegate: BrowserEngineSurfaceDelegate {
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
