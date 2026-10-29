import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Exercises document ownership with deterministic text through the actual Chromium bridge.
    func dailyQA3Translation(_ environment: OrbitEnvironment, _ owner: OrbitWindowController,
                             _ engine: ChromiumBrowserEngine) async {
        func check(_ name: String, _ value: Bool) { self.check("daily3." + name, value) }
        func evaluate(_ source: String, _ tab: ChromiumSurface) async -> String? {
            try? await engine.conformanceProbe?.evaluateScript(source, in: tab)
        }
        owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
        let url = fixture.appendingPathComponent("fixture")
        owner.submitAddress(url.absoluteString)
        guard let tab = await committed(owner, url) else { check("fixture", false); return }
        _ = await evaluate("document.documentElement.lang='de'; document.body.innerHTML='<h1 id=phrase>Ein Baum hat viele grüne Blätter.</h1>'; globalThis.phrase=document.querySelector('#phrase'); 'ready'", tab)
        do {
            let texts = try await tab.translationTexts()
            guard let text = texts.first(where: { $0.text.contains("Baum") }) else { check("extract", false); return }
            try await tab.applyTranslation([.init(id: text.id, text: "A tree has many green leaves.")])
            _ = await evaluate("phrase.remove(); 'detached'", tab)
            _ = try await tab.translationTexts()
            _ = await evaluate("document.body.append(phrase); 'reattached'", tab)
            try await tab.restoreTranslation()
            check("detached-original-restored", await evaluate("phrase.textContent", tab) == text.text)
            // Translate the live document, then move it and close its former owner.
            _ = await evaluate("phrase.textContent='Ein Baum hat viele grüne Blätter.'; 'ready'", tab)
            let next = try await tab.translationTexts()
            try await tab.applyTranslation(next.map { .init(id: $0.id, text: "A tree has many green leaves.") })
            owner.translation.render()
            guard let page = owner.translation.page else { check("page-state", false); return }
            page.detection?.cancel()
            page.state.detect(source: "de", preferred: ["en"], supported: true)
            _ = page.state.begin(); page.state.complete()
            let destination = try await environment.makeWindow()
            destination.showWindow(nil); destination.window?.makeKeyAndOrderFront(nil)
            let move = owner.moveSurface(tab, to: destination)
            check("live-move", await move?.value != nil)
            await destination.session.waitForPendingCommands()
            owner.window?.close()
            destination.translation.render()
            check("moved-translation-state", destination.translation.page === page && page.state.phase == .translated)
            await destination.translation.page?.restore()
            check("moved-original-restored", await evaluate("phrase.textContent", tab) == "Ein Baum hat viele grüne Blätter.")
            // A new document must not inherit the translated state.
            tab.navigate(to: fixture.appendingPathComponent("fixture?next=1"))
            _ = await until(5) { !tab.navigationState.isLoading && !page.isCurrent }
            destination.translation.render()
            check("navigation-retires-state", destination.translation.page !== page)
            destination.window?.close()
        } catch { check("translation-bridge", false) }
    }
}

extension OrbitSmokeDriver {
    func dailyQA3Surfaces(_ environment: OrbitEnvironment, _ owner: OrbitWindowController,
                           _ engine: ChromiumBrowserEngine) async {
        func check(_ name: String, _ value: Bool) { self.check("daily3." + name, value) }
        func evaluate(_ source: String, _ tab: ChromiumSurface) async -> String? {
            try? await engine.conformanceProbe?.evaluateScript(source, in: tab)
        }
        owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let url = fixture.appendingPathComponent("fixture")
        owner.submitAddress(url.absoluteString)
        guard let tab = await committed(owner, url), let occurrence = owner.session.snapshot?.selectedOccurrenceID,
              let profile = owner.session.activeProfileID,
              let tabID = owner.session.snapshot?.tabs.first(where: { $0.occurrenceID == occurrence })?.id else { check("fixture", false); return }
        for _ in 0..<20 { owner.palette.present(.newTab); owner.palette.dismiss() }
        owner.palette.present(.newTab)
        check("palette-focus", owner.palette.isPresented && owner.palette.view.input.currentEditor() === owner.window?.firstResponder)
        owner.palette.view.refreshMaterial(reduceTransparency: true)
        check("palette-opaque", owner.palette.view.material.isHidden && !owner.palette.view.usesMaterial)
        owner.palette.view.refreshMaterial(reduceTransparency: false)
        check("palette-material", !owner.palette.view.material.isHidden && owner.palette.view.usesMaterial)
        owner.palette.dismiss()
        check("palette-return-focus", !owner.palette.isPresented && (owner.window?.firstResponder as? NSView)?.isDescendant(of: tab.hostView) == true)
        check("sync-unavailable", !environment.sync.available && environment.sync.showsSettings)
        do {
            try await environment.sync.setEnabled(true)
            check("sync-refuses-enable", !environment.sync.enabled)
            let visit = BrowserHistoryVisit(url: URL(string: "https://synthetic-history.test/remote")!, title: "Synthetic remote history", visitedAt: Date())
            let remote = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: runRoot.appendingPathComponent("fake-history"))
            try await remote.record(visit)
            let cloud = BrowserHistorySyncMemoryCloud()
            let incoming = try await cloud.exchange(try await remote.historySyncBatches(), now: Date())
            try await remote.close()
            try await environment.historyRecorder.applySync(incoming, for: profile)
            try await environment.historyRecorder.applySync(incoming, for: profile)
            let visits = try await environment.historyRecorder.visits(for: profile)
            check("history-replay", visits.filter { $0.url == visit.url }.count == 1)
        } catch { check("fake-history", false) }
        let extensionItem = await until(5) { try? engine.extensions?.installedExtensions(on: tab).first(where: { $0.name == "Daily QA badges" }) }
        if let extensionItem {
            do {
                try engine.extensions?.setPinned(true, extensionID: extensionItem.id, in: profile)
                owner.extensionControls.render()
                check("badge-first", try engine.extensions?.installedExtensions(on: tab).first(where: { $0.id == extensionItem.id })?.actionState?.badgeText == "A1")
            } catch { check("badge-pin", false) }
        } else { check("badge-fixture", false) }
        var copies = 0
        owner.capture.copyImage = { image in copies += 1; return image.size.width > 1 }
        owner.performSiteAction(.captureFullPage, on: tab)
        check("site-full-capture", await until(5) { copies == 1 })
        owner.performSiteAction(.captureRegion, on: tab)
        let overlay = await until(5) { tab.hostView.subviews.compactMap { $0 as? BrowserCaptureSelectionView }.first }
        overlay?.onFinish?(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        check("site-region-capture", copies == 2)
        owner.performSiteAction(.newBoost, on: tab)
        await owner.boostTask?.value
        check("site-boost", owner.boostEditor != nil)
        owner.boostEditor?.close()
        // A muted generated stream supplies moving video without media downloads or audio changes.
        _ = await evaluate("globalThis.canvas=document.createElement('canvas'); canvas.width=640; canvas.height=360; globalThis.video=document.createElement('video'); video.muted=true; video.srcObject=canvas.captureStream(30); document.body.prepend(video); globalThis.paint=setInterval(()=>{let c=canvas.getContext('2d');c.fillStyle='teal';c.fillRect(0,0,640,360)},30); video.play(); 'ready'", tab)
        let playing = await until(5) { tab.navigationState.isLoading == false }
        try? await Task.sleep(for: .seconds(1))
        let videoReady = await evaluate("String(!video.paused && video.videoWidth>0)", tab)
        check("pip-video", playing && videoReady == "true")
        owner.openTab(url: fixture.appendingPathComponent("fixture?background=1"))
        await owner.session.waitForPendingCommands()
        _ = await until(5) { !owner.session.selectedSurface!.navigationState.isLoading }
        try? await Task.sleep(for: .seconds(1))
        if let background = owner.session.selectedSurface, let extensionItem {
            check("badge-second", (try? engine.extensions?.installedExtensions(on: background).first(where: { $0.id == extensionItem.id })?.actionState?.badgeText) == "B2")
        }
        check("pip-open", await evaluate("String(document.pictureInPictureElement===video)", tab) == "true")
        owner.session.selectTab(tabID)
        await owner.session.waitForPendingCommands()
        try? await Task.sleep(for: .seconds(1))
        if let extensionItem {
            check("badge-return", (try? engine.extensions?.installedExtensions(on: tab).first(where: { $0.id == extensionItem.id })?.actionState?.badgeText) == "A1")
        }
        check("pip-return", await evaluate("String(document.pictureInPictureElement===null && !video.paused)", tab) == "true")
        _ = await evaluate("video.requestPictureInPicture(); 'requested'", tab)
        try? await Task.sleep(for: .seconds(0.5))
        owner.openTab(url: fixture.appendingPathComponent("fixture?manual=1"))
        await owner.session.waitForPendingCommands()
        owner.session.selectTab(tabID)
        await owner.session.waitForPendingCommands()
        try? await Task.sleep(for: .seconds(0.5))
        check("pip-manual-retained", await evaluate("String(document.pictureInPictureElement===video)", tab) == "true")
        _ = await evaluate("document.exitPictureInPicture();clearInterval(paint);video.srcObject.getTracks().forEach(t=>t.stop()); 'done'", tab)
    }
}

extension OrbitSmokeDriver {
    func dailyQA3Moves(_ application: OrbitApplication, _ environment: OrbitEnvironment,
                       _ owner: OrbitWindowController, _ engine: ChromiumBrowserEngine) async {
        func check(_ name: String, _ value: Bool) { self.check("daily3." + name, value) }
        func settle(_ windows: [OrbitWindowController]) async {
            for _ in 0..<3 { for window in windows { await window.session.waitForPendingCommands() }; await Task.yield() }
        }
        let url = fixture.appendingPathComponent("fixture")
        owner.showWindow(nil); owner.window?.makeKeyAndOrderFront(nil)
        owner.submitAddress(url.absoluteString)
        guard let tab = await committed(owner, url), let tabID = owner.session.organization?.selectedTab?.id,
              let profile = owner.session.activeProfileID else { check("move-fixture", false); return }
        _ = try? await engine.conformanceProbe?.evaluateScript("globalThis.moveMarker=42; 'ready'", in: tab)
        do {
            let destination = try await environment.makeWindow()
            destination.showWindow(nil)
            let space = try await environment.store.createSpace(name: "Synthetic destination", profileID: profile)
            destination.session.activateSpace(space)
            await settle([owner, destination])
            guard let payload = owner.sidebar.list(owner.sidebar.page.list, dragPayloadFor: .tab(tabID), grabOffsetX: 0) else { check("move-payload", false); return }
            destination.performSidebarDrop(payload, to: .init(.today(space)), changesOrganization: true)
            await settle([owner, destination])
            check("cross-space-live", destination.session.selectedSurface === tab && owner.session.organization?.tab(tabID) == nil)
            _ = await destination.session.undoOrganization().value
            await settle([owner, destination])
            check("move-undo-placement", owner.session.organization?.tab(tabID) != nil && destination.session.organization?.tab(tabID) == nil)
            check("undo-document", !tab.isDisposed)
            _ = await destination.session.redoOrganization().value
            await settle([owner, destination])
            check("move-redo-placement", destination.session.organization?.tab(tabID) != nil && owner.session.organization?.tab(tabID) == nil)
            destination.session.selectTab(tabID)
            await settle([owner, destination])
            if let current = destination.session.selectedSurface {
                let marker = try? await engine.conformanceProbe?.evaluateScript("String(globalThis.moveMarker)", in: current)
                check("redo-document", marker == "42")
            }
            destination.session.pinTabs([tabID])
            await settle([owner, destination])
            if let pinned = destination.session.selectedSurface {
                let move = destination.moveSurface(pinned, to: owner)
                check("pinned-live-move", await move?.value != nil)
                await settle([owner, destination])
                check("pinned-identity", owner.session.selectedSurface === pinned)
            }
            let folder = await owner.session.createFolder(title: "Synthetic folder", at: .init(.pinned(space)), containing: [.tab(tabID)]).value
            check("folder", folder != nil)
            // A payload whose source closed cannot copy/reload its former live tab.
            owner.openTab(url: fixture.appendingPathComponent("fixture?closing=1"))
            await settle([owner, destination])
            if let closingID = owner.session.organization?.selectedTab?.id,
               let stale = owner.sidebar.list(owner.sidebar.page.list, dragPayloadFor: .tab(closingID), grabOffsetX: 0) {
                owner.window?.close()
                destination.performSidebarDrop(stale, to: .init(.today(space)), changesOrganization: true)
                await settle([destination])
                check("closed-source-refused", destination.session.organization?.tab(closingID) == nil)
            }
            destination.window?.close()
        } catch { check("move-scenario", false) }
        application.createPrivateCommandWindow()
        await application.waitForPrivateWindowCommands()
        if let privateWindow = application.windows.windows.values.first(where: { $0.isPrivateWindow }) {
            privateWindow.palette.dismiss()
            privateWindow.submitAddress(url.absoluteString)
            if let tab = await committed(privateWindow, url) {
                _ = try? await engine.conformanceProbe?.evaluateScript("document.documentElement.lang='de';document.body.innerHTML='<p>Ein Baum ist eine verholzte Pflanze mit einer Wurzel, einem Stamm und einer Krone. Die meisten Bäume haben viele grüne Blätter.</p>'; 'ready'", in: tab)
                privateWindow.translation.render()
                let page = privateWindow.translation.page
                page?.detect(privateWindow: true, preferred: ["en"])
                check("private-offer-installed", await until(8) { page?.state.phase == .available })
                if let root = privateWindow.window?.contentView { page?.begin(in: root) }
                check("private-translation", await until(12) { page?.state.phase == .translated })
                await page?.restore()
                check("private-original", page?.state.phase == .original)
                check("private-isolated-state", privateWindow.translationPages !== owner.translationPages)
            } else { check("private-load", false) }
        } else { check("private-window", false) }
        await application.closePrivateWindows()
    }
}
