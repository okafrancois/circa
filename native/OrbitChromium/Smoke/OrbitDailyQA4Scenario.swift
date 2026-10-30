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

extension OrbitSmokeDriver {
    /// Exercises installer races and persisted Space state in the real synthetic product.
    func dailyQA5(_ application: OrbitApplication, _ environment: OrbitEnvironment,
                  _ owner: OrbitWindowController, _ engine: ChromiumBrowserEngine) async {
        func check(_ name: String, _ value: Bool) { self.check("daily5." + name, value) }
        let updater = environment.settings.updater
        defer {
            updater.fetchLatestVersion = nil; updater.discardPendingUpdate = nil
            updater.downloadLatestUpdate = nil; updater.installPendingUpdate = nil
        }
        var firstReply: CheckedContinuation<String, Never>?
        var requests = 0
        updater.fetchLatestVersion = {
            requests += 1
            if requests == 1 { return await withCheckedContinuation { firstReply = $0 } }
            return "27"
        }
        updater.prepared(version: "25")
        guard await until(2, { firstReply != nil }), let reply = firstReply else { check("feed-started", false); return }
        updater.prepared(version: "27")
        _ = await until(2) { updater.readyVersion == "27" }
        reply.resume(returning: "25")
        for _ in 0..<10 { await Task.yield() }
        check("superseded-feed", requests == 2 && updater.readyVersion == "27")
        var cancellation: CheckedContinuation<Void, Never>?
        updater.fetchLatestVersion = { "29" }
        updater.discardPendingUpdate = { await withCheckedContinuation { cancellation = $0 } }
        updater.prepared(version: "27")
        guard await until(2, { cancellation != nil }), let cancelled = cancellation else { check("cancel-started", false); return }
        updater.prepared(version: "29")
        _ = await until(2) { updater.readyVersion == "29" }
        cancelled.resume()
        for _ in 0..<10 { await Task.yield() }
        check("superseded-cancel", updater.pendingVersion == "29" && updater.readyVersion == "29")

        do {
            owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
            let url = fixture.appendingPathComponent("fixture")
            owner.submitAddress(url.absoluteString)
            guard let surface = await committed(owner, url), let home = owner.session.snapshot?.activeSpaceID,
                  let profile = owner.session.activeProfileID, let selected = owner.session.organization?.selectedTab else {
                check("fixture", false); return
            }
            owner.session.pinTabs([selected.id])
            owner.session.setPinnedSectionCollapsed(true)
            await owner.session.waitForPendingCommands()
            owner.sidebar.updateReady = true // Exercise the card without enabling a synthetic updater feed.
            owner.sidebar.layoutSubtreeIfNeeded()
            check("collapsed-card", owner.sidebar.page.disclosure.isCollapsed && !owner.sidebar.updateCard.isHidden
                  && owner.sidebar.updateCard.frame.maxY <= owner.sidebar.footer.frame.minY)
            let second = try await environment.store.createSpace(name: "Synthetic second", profileID: profile)
            owner.session.activateSpace(second)
            await owner.session.waitForPendingCommands()
            check("space-card", owner.sidebar.updateReady && owner.session.organization?.isPinnedSectionCollapsed == false)
            owner.session.activateSpace(home)
            await owner.session.waitForPendingCommands()
            check("collapse-return", owner.session.organization?.isPinnedSectionCollapsed == true && owner.session.selectedSurface === surface)
            let saved = await environment.store.sessionDocument()
            let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(saved.encoded()))
            check("collapse-restart", await restored.sessionDocument().organization.spaces.first { $0.spaceID == home }?.isPinnedCollapsed == true)

            let foreign = await environment.store.createProfile(name: "Synthetic destination")
            let destination = try await environment.store.createSpace(name: "Synthetic foreign Space", profileID: foreign)
            let little = try await environment.makeQuickWindow(spaceID: home, url: url)
            application.configureQuickWindow(little)
            little.showWindow(nil)
            let original = little.surface
            application.showQuickWindowSpaces(little)
            _ = await until(2) { little.spaceChooser?.rows.contains { $0.id == destination.rawValue.uuidString } == true }
            check("all-profile-chooser", little.spaceChooser?.rows.contains { $0.id == destination.rawValue.uuidString } == true)
            application.promoteQuickWindow(little, to: destination)
            await application.waitForQuickWindowCommands()
            let target = application.windows.windows.values.first { $0.session.snapshot?.activeSpaceID == destination }
            check("foreign-selection", target?.session.activeProfileID == foreign
                  && target?.session.selectedSurface?.profileID == foreign && target?.session.selectedSurface !== original)
            if let target { _ = await committed(target, url) }
            check("foreign-load", target?.session.selectedSurface?.navigationState.committedURL == url && little.isClosed)
        } catch { check("interaction", false) }
    }
}
