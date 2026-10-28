import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Synthetic daily-use probes on the product controllers and real hosted documents.
    func dailyFlowScenario(_ application: OrbitApplication, _ environment: OrbitEnvironment,
                           _ owner: OrbitWindowController, _ engine: ChromiumBrowserEngine,
                           downloadsOnly: Bool) async {
        func check(_ name: String, _ value: Bool) { self.check("daily." + name, value) }
        func page(_ name: String) -> URL { URL(string: "/page?case=\(name)", relativeTo: fixture)!.absoluteURL }
        func load(_ url: URL) async -> ChromiumSurface? {
            owner.submitAddress(url.absoluteString)
            return await committed(owner, url)
        }
        guard let source = await load(page("daily-source")), let profile = owner.session.activeProfileID,
              let originalSpace = owner.session.snapshot?.activeSpaceID else { check("source", false); return }
        if downloadsOnly {
            environment.downloads.destinationProvider = { [runRoot] _, name in runRoot.appendingPathComponent(name) }
            for name in ["slow-source-tab", "slow-source-window"] {
                owner.openTab(url: page(name))
                await owner.session.waitForPendingCommands()
                guard let tab = owner.session.selectedSurface else { check(name, false); return }
                _ = await until(5) { tab.navigationState.committedURL == page(name) && !tab.navigationState.isLoading }
                tab.navigate(to: URL(string: "/download?case=\(name)", relativeTo: fixture)!.absoluteURL)
                let running = await until(5) {
                    environment.downloads.snapshots(profileID: profile).contains { $0.suggestedFilename.contains(name) && $0.receivedBytes > 0 }
                }
                check(name + "-started", running)
                if name == "slow-source-tab", let occurrence = owner.session.snapshot?.selectedOccurrenceID {
                    owner.session.closeOccurrence(occurrence)
                    await owner.session.waitForPendingCommands()
                } else {
                    owner.window?.close()
                    await owner.session.waitForPendingCommands()
                }
                let continued = await until(8) {
                    environment.downloads.snapshots(profileID: profile).contains { $0.suggestedFilename.contains(name) && $0.state == .complete }
                }
                check(name + "-completed", continued)
                if owner.session.isClosed { break }
            }
            application.windows.newWindow()
            await application.windows.waitForPendingCommands()
            guard let last = application.activeBrowserWindow else { check("download-quit-window", false); return }
            last.submitAddress(page("daily-quit").absoluteString)
            guard let tab = await committed(last, page("daily-quit")) else { check("download-quit-page", false); return }
            tab.navigate(to: URL(string: "/download?case=slow-quit", relativeTo: fixture)!.absoluteURL)
            check("download-quit-started", await until(5) {
                environment.downloads.snapshots(profileID: profile).contains { $0.suggestedFilename.contains("slow-quit") && $0.receivedBytes > 0 }
            })
            application.confirmDownloadQuit = { false }
            let cancelled = application.applicationShouldTerminate(NSApp) == .terminateCancel
            let bytes = environment.downloads.snapshots(profileID: profile).first { $0.suggestedFilename.contains("slow-quit") }?.receivedBytes ?? 0
            let continued = await until(2) {
                environment.downloads.snapshots(profileID: profile).contains { $0.suggestedFilename.contains("slow-quit") && $0.receivedBytes > bytes }
            }
            check("download-quit-cancel", cancelled && !application.isPreparingToQuit && continued)
            // The driver's normal finish takes the real accepted termination path.
            application.confirmDownloadQuit = { [weak self] in self?.check("daily.download-quit-accepted", true); return true }
            return
        }
        if let empty = try? await environment.store.createSpace(name: "Synthetic pending Space", profileID: profile),
           let occurrence = owner.session.snapshot?.selectedOccurrenceID {
            check("known-favicon", await until(5) { owner.sidebar.listContent.tabs.first { $0.occurrenceID == occurrence }?.activity.favicon != nil })
            source.navigate(to: fixture.appendingPathComponent("essentials/daily-pending"))
            check("pending-load", await until(2) { source.navigationState.isLoading })
            for _ in 0..<12 { owner.activateSpace(empty); owner.activateSpace(originalSpace) }
            await owner.session.waitForPendingCommands()
            let row = owner.sidebar.listContent.tabs.first { $0.occurrenceID == occurrence }
            check("pending-known-metadata", row?.title == "Synthetic daily-source" && row?.activity.favicon != nil)
            self.check("daily.pending-address", !owner.displayedAddress.isEmpty
                && owner.displayedAddress == source.navigationState.url?.absoluteString,
                ["address": owner.displayedAddress, "engineURL": source.navigationState.url?.absoluteString ?? "none"])
            _ = await until(5) { !source.navigationState.isLoading }
            _ = await load(page("daily-source"))
        } else { check("pending-space", false) }
        owner.createBoost()
        await owner.boostTask?.value
        guard let editor = owner.boostEditor else { check("boost-created", false); return }
        owner.beginBoostZap(editor)
        guard let picker = editor.zapView else { check("zap-started", false); return }
        picker.onDone?()
        check("zap-focus", (owner.window?.firstResponder as? NSView)?.isDescendant(of: source.hostView) == true
              && picker.superview == nil && editor.zapView == nil)
        owner.openTab(url: page("daily-second"))
        await owner.session.waitForPendingCommands()
        check("boost-selection-retired", owner.boostEditor == nil && editor.session.isClosed)
        owner.createSpace(name: "Synthetic empty one", profileID: profile)
        await owner.session.waitForPendingCommands()
        let emptyOne = owner.session.snapshot?.activeSpaceID
        owner.showLibrary(.boosts)
        await owner.session.waitForPendingCommands()
        owner.openLibraryBoost(editor.session.boost, profile: profile)
        await owner.boostTask?.value
        let overlay = owner.presentedPeekSurface
        check("empty-space-overlay-opened", overlay != nil)
        owner.createSpace(name: "Synthetic empty two", profileID: profile)
        await owner.session.waitForPendingCommands()
        let emptyTwo = owner.session.snapshot?.activeSpaceID
        check("empty-space-overlay-retired", !owner.isPeekPresented && owner.boostEditor == nil && overlay?.isDisposed == true)
        owner.openLibraryBoost(editor.session.boost, profile: profile)
        let pendingOpen = owner.boostTask
        if let emptyOne { owner.activateSpace(emptyOne) }
        await owner.session.waitForPendingCommands()
        await pendingOpen?.value
        check("pending-library-open-retired", !owner.isPeekPresented && owner.boostEditor == nil)
        owner.hideLibrary()
        for _ in 0..<12 {
            owner.activateSpace(originalSpace)
            if let emptyOne { owner.activateSpace(emptyOne) }
            if let emptyTwo { owner.activateSpace(emptyTwo) }
        }
        owner.activateSpace(originalSpace)
        await owner.session.waitForPendingCommands()
        check("space-churn-selection", owner.session.snapshot?.activeSpaceID == originalSpace
              && owner.session.selectedSurface?.navigationState.url == page("daily-second"))
        check("source-retained", !source.isDisposed && source.navigationState.title == "Synthetic daily-source")
        // Normal and cold-start URL delivery share this AppKit delegate entry point.
        try? await environment.settings.store.setOpensExternalLinksInQuickWindow(false)
        await environment.settings.refresh()
        application.application(NSApp, open: [page("daily-external-one"), page("daily-external-two")])
        await application.windows.waitForPendingCommands()
        await owner.session.waitForPendingCommands()
        check("external-url-order", Array(owner.session.snapshot?.tabs.suffix(2).map(\.url) ?? [])
              == [page("daily-external-one"), page("daily-external-two")])
        let cold = OrbitApplication(environment: environment, externalURLStartupComplete: false, windowPresenter: { _, _ in })
        cold.application(NSApp, open: [page("daily-cold-one")])
        cold.application(NSApp, open: [page("daily-cold-two")])
        check("cold-url-queue", cold.windows.windows.isEmpty && !cold.windows.hasPendingWindow)
        cold.windows.newWindow()
        cold.finishExternalURLStartup()
        await cold.windows.waitForPendingCommands()
        if let destination = cold.activeBrowserWindow {
            await destination.session.waitForPendingCommands()
            check("cold-url-delivery", Array(destination.session.snapshot?.tabs.suffix(2).map(\.url) ?? [])
                == [page("daily-cold-one"), page("daily-cold-two")])
        } else { check("cold-url-delivery", false) }
        cold.windows.shutdown()
    }
}
