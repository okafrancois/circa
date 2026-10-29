import AppKit
import BrowserCore
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Combined flows use only the confined synthetic document and fake transport.
    func dailyQA4(_ environment: OrbitEnvironment, _ owner: OrbitWindowController,
                  _ engine: ChromiumBrowserEngine) async {
        func check(_ name: String, _ value: Bool) { self.check("daily4." + name, value) }
        func evaluate(_ source: String, _ tab: ChromiumSurface) async -> String? {
            try? await engine.conformanceProbe?.evaluateScript(source, in: tab)
        }
        func settle(_ windows: [OrbitWindowController]) async {
            for _ in 0..<4 { for window in windows { await window.session.waitForPendingCommands() }; await Task.yield() }
        }
        owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let url = fixture.appendingPathComponent("fixture")
        owner.submitAddress(url.absoluteString)
        guard let tab = await committed(owner, url), let profile = owner.session.activeProfileID,
              let home = owner.session.snapshot?.activeSpaceID else { check("fixture", false); return }
        do {
            // The production bridge supplies originals; deterministic translations avoid model downloads.
            let other = try await environment.makeWindow()
            defer { other.window?.close() }
            other.showWindow(nil)
            other.openTab(url: url.appendingPathComponent("other"))
            await settle([owner, other])
            guard let second = await committed(other, url.appendingPathComponent("other")) else { check("second", false); return }
            for (window, surface) in [(owner, tab), (other, second)] {
                _ = await evaluate("document.documentElement.lang='de'; document.body.innerHTML='<p id=phrase>Ein Baum hat viele grüne Blätter.</p>'; 'ready'", surface)
                let texts = try await surface.translationTexts()
                try await surface.applyTranslation(texts.map { .init(id: $0.id, text: "A tree has many green leaves.") })
                window.translation.render()
                guard let page = window.translation.page else { check("page", false); return }
                page.detection?.cancel()
                page.state.detect(source: "de", preferred: ["en"], supported: true)
                _ = page.state.begin(); page.state.complete()
            }
            let menu = owner.translation.makeOptionsMenu()
            // Native action call; no synthetic pointer or keyboard events.
            if let item = menu?.items[1], let action = item.action { _ = NSApp.sendAction(action, to: item.target, from: item) }
            _ = await until(3) { owner.translation.page?.state.phase == .original && other.translation.page?.state.phase == .original }
            check("never-site-all-original", await evaluate("document.querySelector('#phrase').textContent", second) == "Ein Baum hat viele grüne Blätter.")
            check("never-site-all-state", other.translation.page?.state.phase == .original)
            if let menu = owner.translation.makeOptionsMenu(), let action = menu.items[1].action {
                _ = NSApp.sendAction(action, to: menu.items[1].target, from: menu.items[1])
            }
            check("never-site-undo", other.translation.page?.state.siteSuppressed == false)
            other.window?.close()

            try await environment.settings.markBoostsIntroductionSeen()
            owner.createBoost(); await owner.boostTask?.value
            guard let editor = owner.boostEditor else { check("boost-created", false); return }
            let store = editor.session.store
            let session = await environment.store.sessionDocument()
            let settings = await environment.settings.store.snapshot()
            let expected = await store.snapshot()
            let cloud = BrowserSyncMemoryCloud()
            let transport = BrowserSyncMemoryTransport(cloud: cloud, account: "synthetic")
            var replica = BrowserSyncReplica(device: "synthetic")
            try replica.capture(BrowserSyncMapping.project(session: session, settings: settings, boosts: [expected]), now: Date())
            try replica.merge(await transport.exchange(Array(replica.records.values)))
            let replay = try BrowserSyncMapping.materialize(replica.visible, local: session, settings: settings, boosts: [expected])
            try await store.applySync(replay.boosts.first!, expected: expected)
            owner.showLibrary(.boosts); await owner.library.boostsTask?.value
            editor.session.rename(to: "Renamed after replay")
            editor.session.edit { $0.customCSS = "body { background-color: rgb(1, 2, 3) !important }" }
            await editor.session.pending?.value
            await owner.library.boostsTask?.value
            check("boost-replay-rename", editor.session.error == nil && editor.session.boost.title == "Renamed after replay")
            check("boost-library-rename", owner.library.boostsView.displayed.contains { $0.title == "Renamed after replay" })
            check("boost-replay-css", await evaluate("getComputedStyle(document.body).backgroundColor", tab) == "rgb(1, 2, 3)")
            editor.session.rename(to: "Rapid rename"); editor.session.delete(); editor.session.rename(to: "Ignored")
            await editor.session.pending?.value
            let deleted = await store.snapshot()
            check("boost-replay-delete", editor.session.isDeleted && deleted.boosts.isEmpty)
            editor.close(); owner.hideLibrary()

            _ = try await environment.store.createSpace(name: "Synthetic remaining", profileID: profile)
            let standalone = try await environment.makeWindow(spaceID: home, opensInitialTab: false, standalone: true)
            defer { standalone.window?.close() }
            standalone.showWindow(nil)
            _ = await evaluate("globalThis.qaMarker=42; 'ready'", tab)
            let move = owner.moveSurface(tab, to: standalone)
            check("standalone-move", await move?.value != nil)
            await settle([owner, standalone])
            try await environment.store.removeSettingsSpace(home)
            await settle([owner, standalone])
            check("standalone-home-live", standalone.session.selectedSurface === tab && !tab.isDisposed)
            check("standalone-home-document", await evaluate("String(globalThis.qaMarker)", tab) == "42")
            let saved = await environment.store.sessionDocument()
            try saved.validate()
            let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(saved.encoded()))
            check("standalone-home-restored", try await restored.snapshot(of: standalone.session.snapshot!.id).tabs.count == 1)
        } catch { check("combined-flow", false); event("daily4.error", ["type": String(describing: error)]) }
    }
}
