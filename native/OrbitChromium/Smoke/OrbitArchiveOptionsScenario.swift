import AppKit
import BrowserCore
import BrowserShell
import ChromiumEngine
import SwiftUI

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
    func brandSurfaces(_ application: OrbitApplication, _ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        guard let window = owner.window, let profile = owner.session.activeProfileID else {
            check("brand.context", false); return
        }
        environment.autoArchive.scheduler.stop()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NSApp.appearance = NSAppearance(named: .aqua)
        func capture(_ name: String, _ target: NSWindow) async {
            target.setFrameOrigin(NSPoint(x: 60, y: 60))
            target.makeKeyAndOrderFront(nil)
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
            let part = CommandLine.arguments.first(where: { $0.hasPrefix("--orbit-brand-part=") }).map { String($0.dropFirst("--orbit-brand-part=".count)) } ?? "chrome"
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: 1200, height: 800))
            try await environment.settings.store.setShowsSpaceAroundPages(true)
            try await environment.settings.store.updateProfile(profile) { $0.showSearchSuggestions = false }
            await environment.settings.refresh()
            var spaces = owner.session.catalog?.spaces ?? []
            if let first = spaces.first {
                try await environment.store.renameSpace(first.id, name: "Work")
            }
            for name in ["Home", "Reading", "Side project"] {
                if !spaces.contains(where: { $0.name == name }) {
                    _ = try await environment.store.createSpace(name: name, profileID: profile)
                }
            }
            await owner.session.waitForPendingCommands()
            owner.session.refreshCatalog()
            await owner.session.waitForPendingCommands()
            spaces = owner.session.catalog?.spaces ?? []
            if part != "onboarding", part != "motion" {
                for name in ["Mail", "Calendar", "Notes", "Design", "Code", "Music"] {
                    owner.openTab(url: fixture.appendingPathComponent("favorite/" + name.lowercased()))
                    await owner.session.waitForPendingCommands()
                    _ = await until(5) { owner.session.selectedSurface?.navigationState.isLoading == false }
                    if let tab = owner.session.organization?.selectedTab {
                        owner.session.renameTab(tab.id, to: name)
                        owner.session.addToFavorites([tab.id])
                        await owner.session.waitForPendingCommands()
                    }
                }
                check("brand.favorite-tiles", owner.favorites.grid.items.count >= 6)
            }
            if part == "settings" {
                if let work = spaces.first, let side = spaces.last {
                    try await environment.settings.store.saveLinkRoute(.init(value: "github.com", spaceID: work.id))
                    try await environment.settings.store.saveLinkRoute(.init(value: "figma.com", spaceID: side.id))
                }
                try await environment.settings.store.setOpensExternalLinksInQuickWindow(true)
                try await environment.settings.store.updateProfile(profile) { $0.opensPinnedLinksInPeek = true }
                await environment.settings.refresh()
                let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: application.commands.registry.defaultDefinitions)
                await model.reload()
                let settings = BrowserSettingsWindowController(model: model, appearanceOverride: .aqua)
                defer { settings.window?.close() }
                for section in BrowserSettingsSection.navigationSections {
                    _ = settings.selectSection(section)
                    if let target = settings.window { await capture("settings-" + section.rawValue, target) }
                }
                let atc = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                atc.isReleasedWhenClosed = false
                atc.contentViewController = NSHostingController(rootView: BrowserAirTrafficControlView(model: model, runtime: model.runtime))
                await capture("settings-air-traffic-control", atc); atc.orderOut(nil)
            } else if part == "motion" {
                if let store = environment.favoriteIcons {
                    await withTaskGroup(of: Void.self) { group in
                        for site in BrowserOnboardingFavourite.starter { group.addTask { _ = await store.image(profile: profile, home: site.url) } }
                        await group.waitForAll()
                    }
                }
                for step in [BrowserOnboardingRecord.Step.welcome, .finish, .favourites, .theme] {
                    let initialStep: BrowserOnboardingRecord.Step = step == .finish ? .defaultBrowser : step == .favourites ? .importSource : step == .theme ? .sync : step
                    let motionSources = step == .favourites ? OrbitOnboardingSource.captureSources : []
                    var flow = OrbitOnboardingFlow(step: initialStep, sources: motionSources, syncAvailability: .available)
                    if let source = motionSources.first { flow.select(source: source) }
                    else { flow.importChoice = BrowserOnboardingRecord.ImportChoice.none }
                    flow.defaultBrowserChoice = true
                    flow.syncChoice = true
                    for index in flow.favourites.indices { flow.favourites[index].selected = [2, 3, 4, 5].contains(index) }
                    var services = OrbitOnboardingServices()
                    services.cachedFavicon = { environment.sidebarIconMemory.image(profile: profile, home: $0) }
                    services.favicon = { url in
                        guard let pixels = await environment.favoriteIcons?.image(profile: profile, home: url) else { return nil }
                        return await pixels.nativeImage()
                    }
                    let themeTarget = spaces.first.map { OrbitOnboardingThemeTarget(spaceID: $0.id, profileID: profile, stored: nil, commit: { _ in }, registry: nil) }
                    let onboarding = OrbitOnboardingWindowController(flow: flow, services: services, themeTarget: themeTarget)
                    guard let target = onboarding.window else { continue }
                    target.setFrameOrigin(NSPoint(x: 60, y: 60))
                    let folder = runRoot.appendingPathComponent("motion-" + step.rawValue)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let presentedAt = CACurrentMediaTime()
                    onboarding.present()
                    target.setFrameOrigin(NSPoint(x: 60, y: 60))
                    if step == .welcome {
                        check("brand.motion-registration", await until(0.35) {
                            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(target.windowNumber)) as? [[String: Any]]
                            return rows?.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }) == true
                        })
                    }
                    let interactive = step == .favourites || step == .theme
                    if interactive || step == .finish {
                        try? await Task.sleep(for: .seconds(1.4))
                        NSApp.activate(ignoringOtherApps: true)
                        target.makeKeyAndOrderFront(nil)
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                    let duration: Double = interactive ? 2.6 : 3.6
                    var transitionAt: CFTimeInterval?
                    if step != .welcome {
                        NSApp.activate(ignoringOtherApps: true)
                        target.makeKeyAndOrderFront(nil)
                        try? await Task.sleep(for: .milliseconds(150))
                        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(target.windowNumber)) as? [[String: Any]]
                        guard target.isKeyWindow, rows?.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }) == true else { check("brand.motion-input-owner", false); continue }
                        transitionAt = CACurrentMediaTime()
                        if step == .favourites { onboarding.card.skipButton.performClick(nil) }
                        else { onboarding.card.primaryButton.performClick(nil) }
                        check("brand.entry-transition-" + step.rawValue, await until(0.5) { onboarding.step == step })
                    }
                    let start = step == .welcome ? presentedAt : transitionAt ?? CACurrentMediaTime()
                    var times: [Double] = []
                    var actionAt: Double?
                    while CACurrentMediaTime() - start < duration {
                        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(target.windowNumber)) as? [[String: Any]]
                        guard rows?.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }) == true else {
                            check("brand.motion-owner", false); break
                        }
                        let elapsed = CACurrentMediaTime() - start
                        if interactive, elapsed >= 1.4, actionAt == nil {
                            NSApp.activate(ignoringOtherApps: true)
                            target.makeKeyAndOrderFront(nil)
                            guard target.isKeyWindow else { check("brand.motion-input-owner", false); break }
                            if step == .favourites, let grid = onboarding.card.rightView?.subviews.compactMap({ $0 as? OrbitOnboardingFavouritesView }).first,
                               let tile = grid.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.tag == 7 }), tile.window === target { tile.performClick(nil) }
                            if step == .theme, let planet = onboarding.card.rightView?.subviews.compactMap({ $0 as? OrbitOnboardingPlanetButton }).first(where: { $0.planetIndex == 1 }) { planet.performClick(nil) }
                            actionAt = CACurrentMediaTime() - start
                        }
                        let before = CACurrentMediaTime() - start
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        process.arguments = ["-x", "-o", "-t", "jpg", "-l", String(target.windowNumber), folder.appendingPathComponent(String(format: "%04d.jpg", times.count)).path]
                        try process.run(); process.waitUntilExit()
                        times.append((before + CACurrentMediaTime() - start) / 2)
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    try JSONEncoder().encode(times).write(to: folder.appendingPathComponent("times.json"))
                    if let actionAt { try JSONEncoder().encode(actionAt).write(to: folder.appendingPathComponent("action.json")) }
                    check("brand.motion-" + step.rawValue,
                          times.count >= (interactive ? 4 : 10) && (!interactive || actionAt != nil) && (times.first ?? 1) < 0.5 && (times.last ?? 0) >= duration - 0.3)
                    target.orderOut(nil)
                }
                window.makeKeyAndOrderFront(nil)
            } else if part == "onboarding" {
                let sources = OrbitOnboardingSource.captureSources
                if let store = environment.favoriteIcons {
                    await withTaskGroup(of: Void.self) { group in
                        for site in BrowserOnboardingFavourite.starter {
                            group.addTask { _ = await store.image(profile: profile, home: site.url) }
                        }
                        await group.waitForAll()
                    }
                }
                let requestedStep = arguments.first { $0.hasPrefix("--orbit-brand-onboarding-step=") }?.split(separator: "=", maxSplits: 1).last.map(String.init)
                for step in OrbitOnboardingFlow.steps where requestedStep == nil || step.rawValue == requestedStep {
                    var flow = OrbitOnboardingFlow(step: step, sources: sources, syncAvailability: .available)
                    for index in flow.favourites.indices { flow.favourites[index].selected = [2, 3, 4, 5].contains(index) }
                    flow.syncChoice = true
                    flow.defaultBrowserChoice = true
                    if step == .importSource { flow.select(source: sources[0]) }
                    let target = spaces.first.map { OrbitOnboardingThemeTarget(spaceID: $0.id, profileID: profile, stored: nil, commit: { _ in }, registry: nil) }
                    var services = OrbitOnboardingServices()
                    services.cachedFavicon = { environment.sidebarIconMemory.image(profile: profile, home: $0) }
                    services.favicon = { url in
                        guard let pixels = await environment.favoriteIcons?.image(profile: profile, home: url) else { return nil }
                        return await pixels.nativeImage()
                    }
                    let onboarding = OrbitOnboardingWindowController(flow: flow, services: services, themeTarget: target)
                    onboarding.present()
                    if step == .defaultBrowser {
                        var importFlow = flow
                        importFlow.select(source: sources[0])
                        let progress = OrbitOnboardingWindowController(flow: importFlow, services: services, themeTarget: target)
                        progress.present()
                        progress.showImportProgress(.init(source: sources[0].name, counts: [4, 23, 4, 6, 118], fraction: 0.65, completedRows: [0, 1, 2]))
                        if let window = progress.window { await capture("onboarding-import-progress", window); window.orderOut(nil) }
                        onboarding.window?.makeKeyAndOrderFront(nil)
                    }
                    try? await Task.sleep(for: .seconds(2))
                    if flow.isCardStep {
                        let button = onboarding.card.primaryButton
                        check("brand.footer-" + step.rawValue, button.frame.width > 0 && button.alphaValue > 0 && button.superview?.isHidden == false,
                            ["painted": button.layer?.contents != nil, "width": button.frame.width])
                    }
                    if let target = onboarding.window {
                        await capture("onboarding-" + step.rawValue, target)
                        func ownsInput() -> Bool {
                            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(target.windowNumber)) as? [[String: Any]]
                            return target.isKeyWindow && rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
                        }
                        if step == .favourites, ownsInput(), let grid = onboarding.card.rightView?.subviews.compactMap({ $0 as? OrbitOnboardingFavouritesView }).first,
                           let tile = grid.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.tag == 6 }), tile.window === target {
                            tile.performClick(nil)
                            await capture("onboarding-favourites-live", target)
                            check("brand.favourite-preview-live", onboarding.flow.selectedFavourites.count == 5)
                            if ownsInput() {
                                onboarding.card.primaryButton.performClick(nil)
                                check("brand.onboarding-primary-click", onboarding.step == .sync)
                                try? await Task.sleep(for: .milliseconds(1400))
                            }
                            if ownsInput(), let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: target.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 0) {
                                target.makeFirstResponder(nil)
                                NSApp.sendEvent(event)
                                check("brand.onboarding-return", onboarding.step == .theme)
                            }
                        }
                        if step == .theme, ownsInput(), let planet = onboarding.card.rightView?.subviews.compactMap({ $0 as? OrbitOnboardingPlanetButton }).first(where: { $0.planetIndex == 1 }) {
                            planet.performClick(nil)
                            try? await Task.sleep(for: .milliseconds(500))
                            await capture("onboarding-theme-cobalt", target)
                            check("brand.planet-preview-live", onboarding.theme?.presetID == "brand.cobalt")
                        }
                        target.orderOut(nil)
                    }
                }
                window.makeKeyAndOrderFront(nil)
            } else {
                for (index, space) in spaces.prefix(4).enumerated() {
                    owner.session.activateSpace(space.id)
                    await owner.session.waitForPendingCommands()
                    owner.openTab(url: fixture)
                    await owner.session.waitForPendingCommands()
                    check("brand.chromium-page-" + String(index), await until(5) { owner.session.selectedSurface?.isReady == true && owner.session.selectedSurface?.navigationState.isLoading == false })
                    window.makeFirstResponder(nil)
                    owner.renderSession()
                    await capture(["main-work", "main-home", "main-reading", "main-side-project"][index], window)
                }
                if let home = spaces.first(where: { $0.name == "Home" }) {
                    owner.session.activateSpace(home.id)
                    await owner.session.waitForPendingCommands()
                    try await environment.store.setSpaceTheme(BrandPalette.spaceGradients[1].theme(mode: .dark), for: home.id)
                    owner.session.refreshCatalog()
                    await owner.session.waitForPendingCommands()
                    owner.renderSession()
                    await capture("main-night", window)
                    try await environment.store.setSpaceTheme(home.theme, for: home.id)
                    owner.session.refreshCatalog()
                    await owner.session.waitForPendingCommands()
                    owner.renderSession()
                }
                owner.openTab(url: fixture.appendingPathComponent("new-space"))
                await owner.session.waitForPendingCommands()
                _ = await until(5) { owner.session.selectedSurface?.navigationState.isLoading == false }
                if let tab = owner.session.organization?.selectedTab {
                    owner.session.renameTab(tab.id, to: "New Space — Project notes")
                    await owner.session.waitForPendingCommands()
                }
                owner.palette.registry = application.commands.registry
                owner.palette.present(.newTab)
                owner.palette.query("new space")
                try? await Task.sleep(for: .milliseconds(700))
                check("brand.command-results-tabs", owner.palette.results.contains { $0.section == .tabs })
                check("brand.command-results-action", owner.palette.results.contains { $0.action == .command(.newSpace) })
                (owner.palette.view.input.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: owner.palette.view.input.stringValue.utf16.count, length: 0))
                await capture("command-bar", window)
                owner.palette.query(fixture.appendingPathComponent("roadmap").absoluteString)
                try? await Task.sleep(for: .milliseconds(400))
                check("brand.command-results-url", owner.palette.results.contains { $0.section == .address })
                (owner.palette.view.input.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: owner.palette.view.input.stringValue.utf16.count, length: 0))
                await capture("command-bar-url", window)
                owner.palette.query("split")
                try? await Task.sleep(for: .milliseconds(400))
                await capture("command-bar-actions", window)
                owner.palette.dismiss()
                owner.session.closeSelectedTab()
                await owner.session.waitForPendingCommands()
                if let id = owner.session.snapshot?.activeSpaceID,
                   let button = owner.sidebar.footer.spaceButtons.first(where: { $0.space.id == id }),
                   let picker = owner.makeSpaceIconPicker(for: id), picker.show(relativeTo: button) {
                    if let panel = picker.popup.window { await capture("space-icon-picker", panel) }; picker.cancel()
                }
                if part == "chrome" {
                    if let side = spaces.first(where: { $0.name == "Side project" }) {
                        owner.session.activateSpace(side.id)
                        await owner.session.waitForPendingCommands()
                    }
                    let favoriteIDs = owner.favorites.grid.items.map { $0.tab.id }
                    owner.session.removeFromFavorites(favoriteIDs)
                    await owner.session.waitForPendingCommands()
                    owner.session.closeTabs(favoriteIDs)
                    await owner.session.waitForPendingCommands()
                    owner.session.closeSelectedTab(); await owner.session.waitForPendingCommands()
                    check("brand.empty-space-state", owner.session.selectedSurface == nil)
                    await capture("empty-space", window)
                } else {
                    if let surface = owner.session.selectedSurface {
                        BrowserPageDialogCenter.shared.showCrashedPage(on: surface.documentView, surface: ObjectIdentifier(surface), termination: .crashed, close: {}, reload: {})
                        await capture("page-crashed", window)
                        BrowserPageDialogCenter.shared.hideCrashedPage(for: ObjectIdentifier(surface))
                    }
                    if let peek = owner.openPeek(fixture.appendingPathComponent("roadmap")) {
                        _ = await until(5) { peek.isReady }
                        await capture("peek", window); owner.dismissPeek(animated: false)
                    }
                    try? await Task.sleep(for: .seconds(1))
                    owner.session.addSplitPane(url: fixture.appendingPathComponent("roadmap"))
                    await owner.session.waitForPendingCommands()
                    _ = await until(5) { owner.session.activeSplit != nil }
                    owner.renderSession()
                    try? await Task.sleep(for: .seconds(1))
                    check("brand.split-active", owner.session.activeSplit != nil)
                    await capture("split-view", window)
                    let toast = BrowserCopiedToast(); toast.show(in: owner.contentCard)
                    await capture("copy-toast", window)
                    owner.showArchive(); await owner.archive.task?.value
                    try? await Task.sleep(for: .seconds(1))
                    await capture("archive", window); owner.hideLibrary()
                    application.openQuickWindow(url: fixture.appendingPathComponent("roadmap"), source: owner)
                    _ = await until(5) { environment.quickWindows.values.contains { $0.surface?.isReady == true && $0.surface?.navigationState.isLoading == false } }
                    if let target = environment.quickWindows.values.first?.window { await capture("little-circa", target); target.orderOut(nil) }
                    application.createPrivateCommandWindow(); await application.waitForPrivateWindowCommands()
                    if let id = application.privateWindows.keys.first, let controller = application.windows.windows[id], let target = controller.window {
                        controller.palette.dismiss()
                        target.makeFirstResponder(nil)
                        await capture("private-window", target); target.orderOut(nil)
                    }
                }
            }
        } catch { check("brand.scenario", false) }
    }
}
