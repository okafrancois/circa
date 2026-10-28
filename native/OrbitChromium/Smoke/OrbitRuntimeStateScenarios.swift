import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import ChromiumEngine
import Foundation

extension OrbitSmokeDriver {
    /// Runs against real WebContents and a packaged MV3 fixture on a disposable profile.
    func runtimeStateScenarios(_ window: OrbitWindowController, _ home: ChromiumSurface,
                               _ engine: ChromiumBrowserEngine) async {
        guard let host = engine.extensions else { check("runtime.host", false); return }
        var changes = 0
        let observation = try? host.observeChanges(in: home.profileID) { changes += 1 }
        defer { observation?.cancel() }
        let first = URL(string: "/page?case=engine-r4&badge=T1", relativeTo: fixture)!.absoluteURL
        window.submitAddress(first.absoluteString)
        guard let tab = await committed(window, first) else { check("runtime.page", false); return }
        func summary(_ surface: ChromiumSurface) -> BrowserExtensionSummary? {
            (try? host.installedExtensions(on: surface))?.first { $0.name == "Orbit Runtime State Fixture" }
        }
        let gotFirst = await until(10) { summary(tab)?.actionState?.badgeText == "T1" }
        let one = summary(tab)
        check("runtime.action-tab-default", gotFirst && one?.actionState?.title == "Tab T1"
              && one?.actionState?.badgeBackgroundColor == 0xff123456 && one?.actionState?.isEnabled == true
              && one?.defaultActionState?.badgeText == "D" && one?.defaultActionState?.title == "Default action"
              && one?.defaultActionState?.badgeBackgroundColor == 0xff654321
              && one?.defaultActionState?.isEnabled == true && one?.actionState?.iconPNGBase64?.isEmpty == false,
              ["notifications": changes])
        let second = URL(string: "/page?case=engine-r4&badge=T2", relativeTo: fixture)!.absoluteURL
        window.openTab(url: second)
        if let other = await committed(window, second) {
            let gotSecond = await until(10) { summary(other)?.actionState?.badgeText == "T2" && summary(other)?.actionState?.isEnabled == false }
            check("runtime.action-isolation", gotSecond && summary(tab)?.actionState?.badgeText == "T1"
                  && summary(other)?.defaultActionState == one?.defaultActionState && changes > 0)
            _ = window.session.closeOwnedSurface(other)
        } else { check("runtime.action-isolation", false) }
        if let id = window.session.occurrenceID(for: tab) { window.session.selectOccurrence(id) }
        func evaluate(_ script: String) async {
            _ = try? await engine.conformanceProbe?.evaluateScript(script, in: tab)
        }
        await evaluate("let m=document.createElement('meta');m.name='theme-color';m.content='#123456';document.head.append(m);document.body.style.backgroundColor='#abcdef';document.body.innerHTML='<h1>engine-r4-complete</h1>';1")
        let colors = await until(5) { tab.pageThemeColor == 0xff123456 && tab.pageBackgroundColor == 0xffabcdef }
        check("runtime.colors-initial", colors)
        await evaluate("document.querySelector('meta[name=theme-color]').content='#654321';document.body.style.backgroundColor='#fedcba';1")
        check("runtime.colors-change", await until(5) { tab.pageThemeColor == 0xff654321 && tab.pageBackgroundColor == 0xfffedcba })
        await evaluate("document.querySelector('meta[name=theme-color]').remove();1")
        check("runtime.colors-clear", await until(5) { tab.pageThemeColor == nil })
        await evaluate("window.ctx=new AudioContext();window.osc=ctx.createOscillator();osc.frequency.value=330;osc.connect(ctx.destination);osc.start();ctx.resume();1")
        var audible = false
        for _ in 0..<50 {
            if await tab.requestMediaState().isAudible == true { audible = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        check("runtime.audio-audible", audible && engine.capabilities.contains(.audibleState))
        try? tab.setAudioMuted(true)
        check("runtime.audio-muted", await tab.requestMediaState().isAudioMuted == true)
        try? tab.setAudioMuted(false)
        check("runtime.audio-unmuted", await tab.requestMediaState().isAudioMuted == false)
        await evaluate("osc.stop();ctx.close();1")
        var quiet = false
        for _ in 0..<50 {
            if await tab.requestMediaState().isAudible == false { quiet = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        check("runtime.audio-quiet", quiet)
        let destination = runRoot.appendingPathComponent("native-save.html")
        var chooserSeen = false
        BrowserFileChooserPresenter.shared.responder = { request in
            chooserSeen = request.mode == .save
            return [destination]
        }
        defer { BrowserFileChooserPresenter.shared.responder = nil }
        do { try tab.savePageWithNativeDialog() }
        catch { check("runtime.native-save-command", false, ["error": String(describing: error)]) }
        let saved = await until(10) {
            (try? String(contentsOf: destination, encoding: .utf8))?.contains("engine-r4-complete") == true
        }
        check("runtime.native-save-complete", saved && chooserSeen)
        let archive = try? await tab.archivePage(documentGeneration: tab.documentGeneration)
        check("runtime.mhtml", archive.map { String(decoding: $0, as: UTF8.self).contains("engine-r4-complete") } == true)
        if let snapshot = try? await tab.captureSnapshot(BrowserSnapshotRequest()),
           let png = NSBitmapImageRep(cgImage: snapshot.image).representation(using: .png, properties: [:]) {
            try? png.write(to: runRoot.appendingPathComponent("runtime-page.png"))
        }
    }
}
