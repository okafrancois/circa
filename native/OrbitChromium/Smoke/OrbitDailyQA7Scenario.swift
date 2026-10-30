import AppKit
import BrowserCore
import BrowserShell

extension OrbitSmokeDriver {
    /// Hidden regression checks preserve real Chromium documents across catalog edits.
    func dailyQA7(_ application: OrbitApplication, _ environment: OrbitEnvironment,
                  _ owner: OrbitWindowController) async {
        func check(_ name: String, _ value: Bool) { self.check("daily7." + name, value) }
        guard let source = owner.session.organization?.spaceID,
              let profile = owner.session.activeProfileID else { check("context", false); return }
        do {
            let destination = try await environment.store.createSpace(name: "Destination", profileID: profile)
            let other = try await environment.makeWindow(spaceID: source, opensInitialTab: false)
            let local = try await environment.makeWindow(spaceID: source, opensInitialTab: false, standalone: true)
            defer { other.window?.close(); local.window?.close() }
            let sharedURL = page("daily7-shared")
            let localURL = page("daily7-local")
            other.openTab(url: sharedURL)
            local.openTab(url: localURL)
            guard let sharedSurface = await committed(other, sharedURL),
                  let localSurface = await committed(local, localURL) else { check("documents", false); return }
            let selected = other.session.organization?.selectedTab?.id
            application.quickWindowPresenter = { _ in }
            application.openQuickWindow(url: localURL, source: owner)
            await application.waitForQuickWindowCommands()
            guard let quick = environment.quickWindows.values.first,
                  await until(5, { quick.surface?.navigationState.committedURL == localURL }) else {
                check("little-document", false); return
            }
            let quickSurface = quick.surface
            owner.session.exportSpace(source, to: destination)
            await owner.session.waitForPendingCommands()
            check("export-publication", await until(5, {
                other.session.snapshot?.activeSpaceID == destination && local.session.snapshot?.activeSpaceID == destination
            }))
            check("other-selection", other.session.organization?.selectedTab?.id == selected)
            check("other-live-document", other.session.selectedSurface === sharedSurface && !sharedSurface.isDisposed)
            check("standalone-live-document", local.session.selectedSurface === localSurface && !localSurface.isDisposed)
            check("little-live-document", quick.surface === quickSurface && quickSurface?.isDisposed == false)
            check("live-peer-undo-conflict", owner.session.organization?.undoAction != .exportSpace)
            other.session.close()
            owner.session.undoOrganization()
            await owner.session.waitForPendingCommands()
            check("export-undo", owner.session.catalog?.spaces.contains { $0.id == source } == true)
            owner.session.redoOrganization()
            await owner.session.waitForPendingCommands()
            check("export-redo", owner.session.catalog?.spaces.contains { $0.id == source } == false)
            guard let folder = await owner.session.createFolder(title: "Promoted", at: .init(.pinned(destination))).value else {
                check("promotion-folder", false); return
            }
            owner.session.convertFolderToSpace(folder)
            await owner.session.waitForPendingCommands()
            let promoted = owner.session.organization!.spaceID
            let attached = try await environment.makeWindow(spaceID: promoted, opensInitialTab: false, standalone: true)
            defer { attached.window?.close() }
            attached.openTab(url: localURL)
            guard let attachedSurface = await committed(attached, localURL) else { check("promoted-document", false); return }
            owner.session.undoOrganization()
            await owner.session.waitForPendingCommands()
            check("promotion-undo", await until(5, { attached.session.snapshot?.activeSpaceID == destination }))
            check("promotion-live-document", attached.session.selectedSurface === attachedSurface && !attachedSurface.isDisposed)
            owner.session.redoOrganization()
            await owner.session.waitForPendingCommands()
            try await environment.saveNow()
            let document = await environment.store.sessionDocument()
            try document.validate()
            let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(document.encoded()))
            check("session-restored", await restored.sessionDocument().organization == document.organization)
            check("system-copy", BrandFonts.onboardingBody(15) == NSFont.systemFont(ofSize: 15))
        } catch {
            check("integration", false)
            event("daily7.error", ["type": String(describing: error)])
        }
    }
}
