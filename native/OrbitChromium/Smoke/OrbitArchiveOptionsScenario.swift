import AppKit
import BrowserCore
import BrowserShell
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Confined product proof and appearance captures. No events target another process.
    func archiveOptions(_ application: OrbitApplication, _ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        func check(_ name: String, _ passed: Bool) { self.check("archive-options." + name, passed) }
        guard let window = owner.window, let profile = owner.session.activeProfileID else { check("context", false); return }
        environment.autoArchive.scheduler.stop()
        func owns(_ candidate: NSWindow) -> Bool {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(candidate.windowNumber)) as? [[String: Any]]
            return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        func capture(_ name: String, _ candidate: NSWindow) {
            guard owns(candidate), let view = candidate.contentView else { check("capture-owner", false); return }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { check("bitmap", false); return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { check("png", false); return }
            do { try png.write(to: runRoot.appendingPathComponent(name + ".png")) }
            catch { check("capture-write", false) }
        }
        func captureMenu(_ name: String) {
            let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            guard let row = rows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int) == 101 }),
                  let id = row[kCGWindowNumber as String] as? Int else { check("menu-owner", false); return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(id), runRoot.appendingPathComponent(name + ".png").path]
            try? process.run(); process.waitUntilExit()
            check("menu-captured", process.terminationStatus == 0)
        }
        do {
            window.setFrame(NSRect(x: -8000, y: 0, width: 1100, height: 780), display: false)
            window.orderFront(nil)
            let destination = try await environment.store.createSpace(name: "Synthetic Route", profileID: profile)
            let url = fixture.appendingPathComponent("archive-routed")
            owner.session.openTab(url: url)
            await owner.session.waitForPendingCommands()
            guard let id = owner.session.organization?.selectedTab?.id else { check("tab", false); return }
            owner.session.closeSelectedTab()
            await owner.session.waitForPendingCommands()
            try await environment.settings.store.saveLinkRoute(.init(value: "archive-routed", spaceID: destination))
            await environment.settings.refresh()
            owner.showArchive()
            await owner.session.waitForPendingCommands()
            await owner.archive.task?.value
            check("search", await owner.session.archivedTabs(matching: "archive-routed").value.map(\.id) == [id])
            owner.archive.view.onRestore?(id)
            await application.windows.waitForPendingCommands()
            await owner.session.waitForPendingCommands()
            record("archive-options.routing-state", "proven", [
                "configuredRules": environment.settings.document.linkRouting.rules.count,
                "providedRules": owner.session.archiveLinkRouting().rules.count,
                "spaceMatches": owner.session.snapshot?.activeSpaceID == destination,
                "identityMatches": owner.session.organization?.selectedTab?.id == id])
            check("route", owner.session.snapshot?.activeSpaceID == destination && owner.session.organization?.selectedTab?.id == id)
            check("engine-document", await until(5) { owner.session.selectedSurface?.isReady == true && owner.session.selectedSurface?.currentURL == url })
            owner.session.closeSelectedTab()
            await owner.session.waitForPendingCommands()
            let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
            try await model.setArchiveThreshold(.never, profile: profile)
            await model.reload()
            check("never", model.archiveThreshold == .never && BrowserArchiveSettingsChange.options(current: .twelveHours).contains(.never))
            let settings = BrowserSettingsWindowController(model: model, appearanceOverride: nil)
            defer { settings.window?.close() }
            _ = settings.selectSection(.profiles)
            guard let settingsWindow = settings.window else { check("settings", false); return }
            settingsWindow.setFrameOrigin(NSPoint(x: -6000, y: 0))
            settingsWindow.orderFront(nil)
            let previousAppearance = NSApp.appearance
            defer { NSApp.appearance = previousAppearance }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                window.appearance = NSAppearance(named: appearance)
                settingsWindow.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(180))
                capture(name + "-profile-settings", settingsWindow)
                owner.showArchive()
                await owner.session.waitForPendingCommands()
                await owner.archive.task?.value
                try await Task.sleep(for: .milliseconds(250))
                owner.library.view.acceptsLibraryInput = true
                if let menu = owner.library.view.archiveContextMenu(), owns(window) {
                    let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                        MainActor.assumeIsolated { captureMenu(name + "-archive-menu") }
                    }
                    RunLoop.main.add(timer, forMode: .eventTracking)
                    let dismiss = Timer(timeInterval: 0.45, target: menu, selector: #selector(NSMenu.cancelTracking), userInfo: nil, repeats: false)
                    RunLoop.main.add(dismiss, forMode: .eventTracking)
                    menu.popUp(positioning: nil, at: NSPoint(x: 20, y: 120), in: owner.library.view)
                    timer.invalidate(); dismiss.invalidate()
                }
                guard let alert = owner.makeClearArchiveAlert() as? OrbitFrostAlert else { check("alert", false); return }
                let panel = alert.preparedWindow(for: window)
                panel.setFrameOrigin(NSPoint(x: -4000, y: 0)); panel.orderFront(nil)
                try await Task.sleep(for: .milliseconds(120))
                capture(name + "-clear-confirmation", panel)
                panel.close()
            }
            owner.archive.confirmation = { _ in .alertSecondButtonReturn }
            owner.confirmClearArchive()
            await application.windows.waitForPendingCommands()
            await owner.session.waitForPendingCommands(); await owner.archive.confirmationTask?.value
            await application.windows.waitForPendingCommands()
            await owner.session.waitForPendingCommands()
            check("cancel-keeps", owner.session.organization?.archivedTabCount == 1)
            owner.archive.confirmation = { _ in .alertFirstButtonReturn }
            owner.confirmClearArchive()
            await application.windows.waitForPendingCommands()
            await owner.session.waitForPendingCommands(); await owner.archive.confirmationTask?.value
            await application.windows.waitForPendingCommands()
            await owner.session.waitForPendingCommands()
            check("confirm-clears", owner.session.organization?.archivedTabCount == 0)
            try await environment.saveNow()
        } catch { check("operation", false) }
    }
}


extension OrbitSmokeDriver {
    /// Captures the real shell with inert onboarding services and invented Space data.
    func brandSurfaces(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        guard let window = owner.window, let profile = owner.session.activeProfileID else {
            check("brand.context", false); return
        }
        environment.autoArchive.scheduler.stop()
        NSApp.appearance = NSAppearance(named: .aqua)
        func capture(_ name: String, _ target: NSWindow) async {
            target.setFrameOrigin(NSPoint(x: 60, y: 60))
            target.orderFront(nil)
            target.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(400))
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(target.windowNumber)) as? [[String: Any]]
            guard rows?.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }) == true else {
                check("brand.capture-owner", false); return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(target.windowNumber), runRoot.appendingPathComponent(name + ".png").path]
            do {
                try process.run(); process.waitUntilExit()
                if process.terminationStatus == 0 { check("brand." + name, true); return }
            } catch {}
            // WindowServer can refuse a window during an asynchronous settings resize.
            guard let view = target.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                check("brand." + name, false); return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            do {
                guard let png = bitmap.representation(using: .png, properties: [:]) else { check("brand." + name, false); return }
                try png.write(to: runRoot.appendingPathComponent(name + ".png"))
                check("brand." + name, true)
            } catch { check("brand." + name, false) }
        }
        do {
            owner.openTab(url: fixture)
            await owner.session.waitForPendingCommands()
            check("brand.chromium-page", await until(5) { owner.session.selectedSurface?.isReady == true })
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: 1200, height: 800))
            await capture("main-work", window)
            let home = try await environment.store.createSpace(name: "Home", profileID: profile)
            owner.session.activateSpace(home)
            await owner.session.waitForPendingCommands()
            await capture("main-home", window)
            window.appearance = NSAppearance(named: .darkAqua)
            await capture("main-night", window)
            window.appearance = NSAppearance(named: .aqua)
            owner.palette.present(.newTab)
            await capture("command-bar", window)
            owner.palette.dismiss()
            if let id = owner.session.snapshot?.activeSpaceID,
               let button = owner.sidebar.footer.spaceButtons.first(where: { $0.space.id == id }),
               let picker = owner.makeSpaceIconPicker(for: id), picker.show(relativeTo: button) {
                if let panel = picker.popup.window { await capture("space-icon-picker", panel) }
                picker.cancel()
            } else { check("brand.space-icon-picker", false) }
            let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
            let settings = BrowserSettingsWindowController(model: model, appearanceOverride: .aqua)
            defer { settings.window?.close() }
            for (name, section) in [("general", BrowserSettingsSection.general), ("spaces", .spaces), ("about", .about)] {
                _ = settings.selectSection(section)
                if let target = settings.window { await capture("settings-" + name, target) }
            }
            for (name, step) in [("welcome", BrowserOnboardingRecord.Step.welcome), ("import", .importSource)] {
                let flow = OrbitOnboardingFlow(step: step, sources: [], syncAvailability: .unavailable)
                let onboarding = OrbitOnboardingWindowController(flow: flow, services: .init(), themeTarget: nil)
                onboarding.present()
                try? await Task.sleep(for: .seconds(2))
                if let target = onboarding.window { await capture("onboarding-" + name, target); target.orderOut(nil) }
            }
        } catch { check("brand.scenario", false) }
    }
}
