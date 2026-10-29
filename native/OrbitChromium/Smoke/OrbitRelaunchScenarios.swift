import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Foundation

/// DBG-CH4: hidden regression scenarios, compiled only into the synthetic smoke bundle.
@MainActor
enum OrbitRelaunchScenarios {
    typealias Record = (String, String, [String: Any]) -> Void

    static func until(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    /// Schedules a replacement from CLOSED. Also moves the last tab away and recreates one
    /// synchronously, before the empty source Browser's posted deletion can run.
    static func lastTabRace(fixture: URL, record: Record) async {
        let engine = ChromiumBrowserEngine(persistence: .persistent, hostedWhenAvailable: true)
        let native = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        guard let window = engine.makeWindow(for: native) else {
            record("last-tab.window", "failed", [:]); return
        }
        let profile = ProfileID()
        await engine.profileReady(profile)
        let delegate = InertSmokeDelegate()
        var current: ChromiumSurface?
        for cycle in 0..<20 {
            if current == nil { current = engine.makeTabSurface(profileID: profile, in: window, delegate: delegate) }
            guard let old = current, await until({ old.isReady }) else {
                record("last-tab.ready", "failed", ["cycle": cycle]); break
            }
            // Navigation is unnecessary to provoke the lifetime race. An empty native tab
            // still owns a WebContents and must be replaced without reusing a dying Browser.
            var replacement: ChromiumSurface?
            engine.onSurfaceEvent = { name, _ in
                if name == "closed", replacement == nil {
                    Task { @MainActor in
                        replacement = engine.makeTabSurface(profileID: profile, in: window, delegate: delegate)
                    }
                }
            }
            // Surface callbacks were bound at creation, so bind this existing surface too.
            old.onEngineEvent = engine.onSurfaceEvent
            old.dispose()
            let ready = await until { replacement?.isReady == true || replacement?.creationFailed == true }
            record("last-tab.recreate.\(cycle)", ready && replacement?.isReady == true && replacement?.profileID == profile
                    && replacement?.tabIdentity?.windowToken == window.token ? "proven" : "failed",
                   ["oldClosed": old.isTeardownComplete, "logicalBrowsers": window.logicalBrowserCount,
                    "refused": replacement?.creationFailed ?? false])
            current = replacement
            if !ready || replacement?.creationFailed == true { break }
        }
        engine.onSurfaceEvent = nil
        current?.onEngineEvent = nil
        current?.dispose()
        let sourceID = WindowID(), destinationID = WindowID()
        let destination = NSWindow(contentRect: native.frame, styleMask: [.titled], backing: .buffered, defer: false)
        destination.isReleasedWhenClosed = false
        // A second registration of the same hidden NSWindow is allowed by the side API; use a
        // new source token so the earlier close scenario cannot influence this source Browser.
        engine.shellWindowDidOpen(sourceID, window: native)
        engine.shellWindowDidOpen(destinationID, window: destination)
        var retainedMoves: [ChromiumSurface] = []
        var moving = engine.makeSurface(profileID: profile, delegate: delegate)
        moving.placement = BrowserSurfacePlacement(container: .tab, windowID: sourceID)
        for cycle in 0..<20 {
            guard await until({ moving.isReady }) else { record("last-tab.move-ready", "failed", [:]); break }
            let oldIdentity = moving.tabIdentity
            let moved = engine.shellWillMoveSurfaces([moving], toWindow: destinationID)
            record("last-tab.move-source-emptied.\(cycle)", moved ? "proven" : "failed",
                   ["oldWindowID": Int(oldIdentity?.windowID ?? -1)])
            retainedMoves.append(moving)
            // No await: the empty source Browser has scheduled its deletion but is still in
            // Orbit's registry. The old bridge synchronously adds a tab to that exact Browser.
            moving = engine.makeSurface(profileID: profile, delegate: delegate)
            moving.placement = BrowserSurfacePlacement(container: .tab, windowID: sourceID)
            let ready = await until { moving.isReady || moving.creationFailed }
            record("last-tab.move-recreate.\(cycle)", ready && moving.isReady && moving.profileID == profile
                    && moving.tabIdentity?.windowToken == oldIdentity?.windowToken
                    && moving.tabIdentity?.windowToken != retainedMoves.last?.tabIdentity?.windowToken ? "proven" : "failed",
                   ["newWindowID": Int(moving.tabIdentity?.windowID ?? -1), "refused": moving.creationFailed])
            if !ready || moving.creationFailed { break }
        }
        retainedMoves.append(moving)
        let concurrentProfiles = [profile, ProfileID(), ProfileID()]
        let concurrent = concurrentProfiles.compactMap {
            engine.makeTabSurface(profileID: $0, in: window, delegate: delegate)
        }
        let concurrentReady = await until { concurrent.count == 3 && concurrent.allSatisfy { $0.isReady } }
        let identitiesMatch = concurrent.count == 3 && zip(concurrent, concurrentProfiles).allSatisfy { surface, profile in
            surface.profileID == profile && surface.tabIdentity?.windowToken == window.token
        }
        record("last-tab.concurrent-profiles", concurrentReady && identitiesMatch ? "proven" : "failed", [:])
        let nativeBeforeCancellation = engine.liveNativeTokens.count
        let cancelled = engine.makeTabSurface(profileID: ProfileID(), in: window, delegate: delegate)
        let surfaceWasPending = cancelled?.isCreationPending == true && cancelled?.isBrowserCreated == false
        var surfaceReason = ""
        cancelled?.onEngineEvent = { name, fields in if name == "create-aborted" { surfaceReason = fields["reason"] ?? "" } }
        cancelled?.dispose()
        let surfaceEnded = await until { cancelled?.isTeardownComplete == true && engine.liveNativeTokens.count == nativeBeforeCancellation }
        record("last-tab.cancel-pending-surface", surfaceWasPending && surfaceEnded
               && surfaceReason == "hosted-creation-cancelled-by-surface-close" ? "proven" : "failed", ["reason": surfaceReason])
        let closedWindow = engine.makeTabSurface(profileID: ProfileID(), in: window, delegate: delegate)
        let windowWasPending = closedWindow?.isCreationPending == true && closedWindow?.isBrowserCreated == false
        var windowReason = ""
        closedWindow?.onEngineEvent = { name, fields in if name == "create-aborted" { windowReason = fields["reason"] ?? "" } }
        window.close()
        let windowEnded = await until { closedWindow?.isTeardownComplete == true && engine.liveNativeTokens.count == nativeBeforeCancellation }
        record("last-tab.cancel-pending-window", windowWasPending && windowEnded
               && windowReason == "hosted-window-closed-before-creation" ? "proven" : "failed", ["reason": windowReason])
        // Cancel browsers without waiting for their newly created request contexts. Quit must
        // retain those contexts and pump their initialization before it releases CEF's keepalive.
        let shutdownWindow = engine.makeWindow(for: native)
        let initializing = (0..<4).compactMap { _ in
            shutdownWindow.flatMap { engine.makeTabSurface(profileID: ProfileID(), in: $0, delegate: delegate) }
        }
        let allPending = initializing.count == 4 && initializing.allSatisfy { $0.isCreationPending && !$0.isBrowserCreated }
        initializing.forEach { $0.dispose() }
        record("last-tab.cancel-profiles-before-quit", allPending ? "proven" : "failed", ["count": initializing.count])
        await engine.shutdown()
        shutdownWindow?.close()
        window.close()
        native.close()
        destination.close()
        record("last-tab.shutdown", engine.liveNativeTokens.isEmpty ? "proven" : "failed", [:])
    }

    /// The same real session is saved and reopened across process launches. Little Orbit is
    /// transient by product design: recreate and exercise it on every launch, keep it through quit.
    static func session(application: OrbitApplication, environment: OrbitEnvironment,
                        engine: ChromiumBrowserEngine, fixture: URL, root: URL, restored: Int, restoring: Bool, archiveRoundTrip: Bool = false, record: Record) async {
        func page(_ name: String) -> URL { URL(string: "/page?case=\(name)", relativeTo: fixture)!.absoluteURL }
        func check(_ name: String, _ ok: Bool, _ fields: [String: Any] = [:]) {
            record("relaunch." + name, ok ? "proven" : "failed", fields)
        }
        guard let first = application.windows.windows.values.first else {
            check("window", false); return
        }
        if restoring && restored != 2 { check("restore-count", false, ["restored": restored]); return }
        if restoring {
            let favorite = first.favorites.grid.items.first?.tab
            check("favicon-before-navigation", favorite.map {
                environment.sidebarIconMemory.image(profile: first.session.activeProfileID!, home: $0.pinnedURL ?? $0.url) != nil
            } ?? false)
        }
        if !restoring {
            first.submitAddress(page("relaunch-favorite").absoluteString)
            let loaded = await until {
                first.session.selectedSurface?.navigationState.committedURL == page("relaunch-favorite")
                    && first.session.selectedSurface?.navigationState.isLoading == false
                    && first.session.organization?.selectedTab?.url == page("relaunch-favorite")
            }
            check("seed-navigation", loaded)
            if let tab = first.session.organization?.allTabs.first(where: { $0.url == page("relaunch-favorite") }) {
                first.session.addToFavorites([tab.id])
                await first.session.waitForPendingCommands()
                let seeded = await until { first.favorites.grid.items.contains { $0.tab.id == tab.id } }
                check("seed-favorite", seeded)
            } else { check("seed-favorite", false) }
            first.openTab(url: page("relaunch-pin-home"))
            _ = await until { first.session.organization?.selectedTab?.url == page("relaunch-pin-home")
                && first.session.selectedSurface?.navigationState.isLoading == false }
            if let tab = first.session.organization?.selectedTab, let space = first.session.snapshot?.activeSpaceID {
                first.session.pinTabs([tab.id])
                first.session.renameTab(tab.id, to: "Synthetic custom title")
                if let parent = await first.session.createFolder(title: "Synthetic Parent", at: .init(.pinned(space))).value,
                   let child = await first.session.createFolder(title: "Synthetic Child", at: .init(.folder(parent))).value {
                    first.session.moveItems([.tab(tab.id)], to: .init(.folder(child)))
                }
                await first.session.waitForPendingCommands()
                first.submitAddress(page("relaunch-pin-away").absoluteString)
                _ = await until { first.session.organization?.selectedTab?.url == page("relaunch-pin-away")
                    && first.session.selectedSurface?.navigationState.isLoading == false }
            } else { check("seed-pin", false) }
            var splitTabs: [TabID] = []
            for name in ["relaunch-split-left", "relaunch-split-right"] {
                first.openTab(url: page(name))
                _ = await until {
                    first.session.selectedSurface?.navigationState.committedURL == page(name)
                        && first.session.selectedSurface?.navigationState.isLoading == false
                        && first.session.organization?.selectedTab?.url == page(name)
                }
                if let tab = first.session.organization?.allTabs.first(where: { $0.url == page(name) }) { splitTabs.append(tab.id) }
            }
            first.session.createSplit(splitTabs)
            await first.session.waitForPendingCommands()
            if let split = first.session.activeSplit {
                first.session.orientSplit(split.group.id, to: .vertical)
                first.session.resizeSplit(split.group.id, ratios: [0.35, 0.65])
                await first.session.waitForPendingCommands()
            }
            application.windows.newWindow()
            _ = await until { application.windows.windows.count == 2 }
            if let second = application.windows.windows.values.first(where: { $0 !== first }) {
                second.submitAddress(page("relaunch-second").absoluteString)
            }
        }
        let windows = Array(application.windows.windows.values)
        let loaded = await until {
            windows.count == 2 && windows.allSatisfy {
                $0.session.selectedSurface?.isReady == true
                    && $0.session.selectedSurface?.navigationState.committedURL?.host == "127.0.0.1"
                    && $0.session.selectedSurface?.navigationState.isLoading == false
                    && $0.session.organization?.selectedTab?.url == $0.session.selectedSurface?.navigationState.committedURL
                    && !$0.favorites.grid.items.isEmpty
            }
        }
        let split = await until { windows.contains { $0.session.activeSplit?.tabs.count == 2 } }
        check("split", split)
        check("split-layout", windows.contains { $0.session.activeSplit?.group.orientation == .vertical
            && $0.session.activeSplit?.group.ratios == [0.35, 0.65] })
        check("nested-pin", windows.contains { window in
            window.session.organization?.pinned.contains { item in
                guard case .folder(let parent) = item, parent.title == "Synthetic Parent" else { return false }
                return parent.children.contains { item in
                    guard case .folder(let child) = item, child.title == "Synthetic Child" else { return false }
                    return child.children.contains { item in
                        guard case .tab(let tab) = item else { return false }
                        return tab.customTitle == "Synthetic custom title" && tab.pinnedURL == page("relaunch-pin-home")
                            && tab.url == page("relaunch-pin-away")
                    }
                }
            } == true
        })
        let splitDocuments = await until {
            windows.contains { window in
                guard let group = window.session.activeSplit, group.tabs.count == 2 else { return false }
                let expected = [page("relaunch-split-left"), page("relaunch-split-right")]
                return zip(group.tabs, expected).allSatisfy { tab, url in
                    guard let occurrence = tab.occurrenceID, let surface = window.session.surface(for: occurrence) else { return false }
                    return surface.isReady && surface.navigationState.committedURL == url
                        && !surface.navigationState.isLoading
                }
            }
        }
        check("split-documents", splitDocuments)
        let favorite = await until { windows.contains { !$0.favorites.grid.items.isEmpty } }
        check("favorites", favorite)
        check("favicon-cache", await until {
            windows.contains { window in
                guard let tab = window.favorites.grid.items.first?.tab, let profile = window.session.activeProfileID else { return false }
                return environment.sidebarIconMemory.image(profile: profile, home: tab.pinnedURL ?? tab.url) != nil
            }
        })
        if archiveRoundTrip, let window = windows.first(where: { $0.session.activeSplit != nil }),
           let organization = window.session.organization {
            let before = await environment.store.sessionDocument().organization
            let selected = organization.selectedTab?.id
            func checkArchiveSelection(_ step: String) async {
                let ready = await until {
                    windows.allSatisfy { candidate in
                        guard candidate.session.organization?.allTabs.isEmpty == false else { return true }
                        return candidate.session.snapshot?.selectedOccurrenceID != nil
                            && candidate.session.selectedSurface?.isReady == true
                            && candidate.session.selectedSurface?.navigationState.isLoading == false
                            && candidate.session.selectedSurface?.navigationState.committedURL == candidate.session.organization?.selectedTab?.url
                            && candidate.session.selectedSurface?.tabIdentity?.isHosted == true
                    } && engine.holdingWindowTabCount == 0
                }
                check("archive-selection-" + step, ready)
            }
            let ids = organization.allTabs.filter { tab in
                if case .favorites = tab.section { return false }
                return true
            }.map(\.id)
            window.session.archiveTabs(ids)
            await window.session.waitForPendingCommands()
            await checkArchiveSelection("archived")
            let records = await window.session.archivedTabs().value
            check("archive-identities", Set(records.map(\.id)).isSuperset(of: ids))
            for (index, id) in ids.enumerated() {
                window.session.restoreArchivedTab(id, activate: false)
                await window.session.waitForPendingCommands()
                check("archive-insertion-\(index)", window.session.organization?.today.first?.node == .tab(id))
                await checkArchiveSelection("restored-\(index)")
            }
            let reopened = await environment.store.sessionDocument().organization
            check("archive-reopen-titles", ids.allSatisfy { id in
                reopened.tabs.first { $0.id == id }?.customTitle == before.tabs.first { $0.id == id }?.customTitle
                    && reopened.tabs.first { $0.id == id }?.url == before.tabs.first { $0.id == id }?.url
            })
            for index in 0...ids.count {
                check("archive-replay-\(index)", await window.session.undoOrganization().value != nil)
                await checkArchiveSelection("undo-\(index)")
            }
            await window.session.waitForPendingCommands()
            let undone = await environment.store.sessionDocument().organization
            check("archive-undo-layout", undone.spaces == before.spaces && undone.folders == before.folders && undone.splits == before.splits)
            check("archive-undo-selection", selected != nil && window.session.organization?.selectedTab?.id == selected)
            check("archive-undo-split-documents", await until {
                guard let group = window.session.activeSplit, group.tabs.count == 2 else { return false }
                return group.tabs.allSatisfy { tab in
                    guard let occurrence = tab.occurrenceID, let surface = window.session.surface(for: occurrence) else { return false }
                    return surface.isReady && !surface.navigationState.isLoading
                        && surface.navigationState.committedURL == tab.url && surface.tabIdentity?.isHosted == true
                }
            })
        }
        check(archiveRoundTrip ? "archive-undo-hosted" : "hosted",
              await until { windows.allSatisfy { $0.session.selectedSurface?.tabIdentity?.isHosted == true }
                  && engine.holdingWindowTabCount == 0 },
              ["holdingTabs": engine.holdingWindowTabCount, "selected": windows.map {
                  ["surface": $0.session.selectedSurface != nil, "ready": $0.session.selectedSurface?.isReady == true,
                   "hosted": $0.session.selectedSurface?.tabIdentity?.isHosted == true,
                   "occurrence": $0.session.snapshot?.selectedOccurrenceID != nil]
              }])
        check("private-not-restored", application.privateWindows.isEmpty && windows.count == 2)
        application.createPrivateCommandWindow()
        await application.waitForPrivateWindowCommands()
        if let privateWindow = application.windows.windows.values.first(where: \.isPrivateWindow) {
            privateWindow.palette.dismiss(returnFocus: false)
            privateWindow.openTab(url: page("relaunch-private"))
            check("private-document", await until {
                privateWindow.session.selectedSurface?.navigationState.committedURL == page("relaunch-private")
                    && privateWindow.session.selectedSurface?.navigationState.isLoading == false
            })
        } else { check("private-document", false) }
        application.quickWindowPresenter = { _ in }
        application.openQuickWindow(url: page("relaunch-little"), source: first)
        await application.waitForQuickWindowCommands()
        let little = await until {
            environment.quickWindows.values.contains {
                !$0.isClosed && $0.surface?.isReady == true
                    && $0.surface?.navigationState.committedURL == page("relaunch-little")
                    && $0.surface?.profileID == first.session.activeProfileID
                    && $0.surface?.tabIdentity?.isHosted == true
            }
        }
        check("little-orbit", little, ["count": environment.quickWindows.count])
        first.focusAddress()
        await first.session.waitForPendingCommands()
        first.showFind()
        await first.session.waitForPendingCommands()
        let findWasEditing = first.findBar.searchField.currentEditor() != nil
        first.setSidebarVisible(false, animated: false)
        first.closeFind()
        let focusReturned = (first.window?.firstResponder as? NSView).map { responder in
            first.session.selectedSurface.map { surface in responder.isDescendant(of: surface.hostView) } ?? false
        } ?? false
        check("find-hidden-sidebar-focus", findWasEditing && first.findBar.isHidden && focusReturned,
              ["findWasEditing": findWasEditing, "focusReturned": focusReturned])
        first.setSidebarVisible(true, animated: false)
        let placementFile = root.deletingLastPathComponent().appendingPathComponent("window-placement.json")
        if restoring {
            let saved = (try? Data(contentsOf: placementFile)).flatMap {
                try? JSONDecoder().decode([String: [Double]].self, from: $0)
            } ?? [:]
            for window in windows {
                let frame = window.window!.frame
                let expected = saved[window.session.snapshot!.id.rawValue.uuidString]
                let actual = [frame.origin.x, frame.origin.y, frame.width, frame.height,
                              window.windowShell.preferredSidebarWidth].map(Double.init)
                check("placement-" + window.id.uuidString, expected == actual,
                      ["expected": expected ?? [], "actual": actual])
            }
        } else {
            var saved: [String: [Double]] = [:]
            for (index, window) in windows.sorted(by: { $0.id.uuidString < $1.id.uuidString }).enumerated() {
                let frame = NSRect(x: 70 + index * 30, y: 80 + index * 20, width: 850 + index * 40, height: 610 + index * 20)
                window.window?.setFrame(frame, display: false)
                window.windowShell.setSidebarWidth(CGFloat(280 + index * 30))
                saved[window.session.snapshot!.id.rawValue.uuidString] = [frame.origin.x, frame.origin.y, frame.width, frame.height,
                                             window.windowShell.preferredSidebarWidth].map(Double.init)
            }
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: placementFile) }
        }
        // The product termination saves again synchronously; let the ordinary debounce run too.
        try? await Task.sleep(for: .milliseconds(500))
        // Read a settled store snapshot, rather than the UI projection between actor updates.
        for window in windows {
            window.session.synchronizeOrganization()
            await window.session.waitForPendingCommands()
        }
        var selectedURLs: [String: String] = [:]
        var profileIDs: [String: String] = [:]
        var favoriteIDs: [String: [String]] = [:]
        var splitTabIDs: [String: [String]] = [:]
        var tabIDs: [String: [String]] = [:]
        var tabURLs: [String: [String]] = [:]
        for window in windows {
            let id = window.session.snapshot?.id.rawValue.uuidString ?? "none"
            selectedURLs[id] = window.session.selectedSurface?.navigationState.committedURL?.absoluteString ?? "none"
            profileIDs[id] = window.session.activeProfileID?.rawValue.uuidString ?? "none"
            favoriteIDs[id] = window.favorites.grid.items.map { $0.tab.id.rawValue.uuidString }.sorted()
            splitTabIDs[id] = window.session.activeSplit?.tabs.map { $0.id.rawValue.uuidString } ?? []
            tabIDs[id] = window.session.organization?.allTabs.map { $0.id.rawValue.uuidString }.sorted() ?? []
            tabURLs[id] = window.session.organization?.allTabs.map { $0.url.absoluteString }.sorted() ?? []
        }
        check("windows-and-documents", loaded, ["windows": windows.count, "restored": restored,
            "windowIDs": windows.compactMap { $0.session.snapshot?.id.rawValue.uuidString }.sorted(), "selectedURLs": selectedURLs,
            "profileIDs": profileIDs, "favoriteIDs": favoriteIDs, "splitTabIDs": splitTabIDs,
            "tabIDs": tabIDs, "tabURLs": tabURLs])
    }
}
