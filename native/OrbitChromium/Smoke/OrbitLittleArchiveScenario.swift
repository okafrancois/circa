import AppKit
import BrowserCore
import BrowserShell
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Confined product proof: Dock items for Little windows, the Archive Little filter and the Archive preview.
    /// Captures are native content-view renders of this process's own windows; no events target another process.
    func littleArchive(_ application: OrbitApplication, _ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        func check(_ name: String, _ passed: Bool) { self.check("little-archive." + name, passed) }
        guard let window = owner.window else { check("context", false); return }
        environment.autoArchive.scheduler.stop()
        let bundle = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        application.quickWindowPresenter = { little in
            little.window?.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            little.showWindow(nil)
        }
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
            do { try png.write(to: runRoot.appendingPathComponent(name + ".png")) } catch { check("capture-write", false) }
        }
        func captureMenu(_ name: String) {
            let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            guard let row = rows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int) == 101 }),
                  let id = row[kCGWindowNumber as String] as? Int else { check("menu-owner-" + name, false); return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(id), runRoot.appendingPathComponent(name + ".png").path]
            try? process.run(); process.waitUntilExit()
            check("menu-captured-" + name, process.terminationStatus == 0)
        }
        func showMenu(_ menu: NSMenu, _ name: String) {
            let timer = Timer(timeInterval: 0.25, repeats: false) { _ in MainActor.assumeIsolated { captureMenu(name) } }
            let dismiss = Timer(timeInterval: 0.6, target: menu, selector: #selector(NSMenu.cancelTracking), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(dismiss, forMode: .eventTracking)
            menu.popUp(positioning: nil, at: NSPoint(x: 40, y: 200), in: owner.library.view)
            timer.invalidate(); dismiss.invalidate()
        }
        func external(_ url: URL) throws {
            guard let owned = NSRunningApplication(processIdentifier: pid), owned.bundleURL?.standardizedFileURL == bundle.standardizedFileURL,
                  Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true else { throw BrowserStoreError.windowMissing }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-g", "-a", bundle.path, url.absoluteString]
            try task.run()
        }
        func find(_ identifier: String, in parent: NSView) -> NSView? {
            if parent.accessibilityIdentifier() == identifier { return parent }
            for child in parent.subviews { if let found = find(identifier, in: child) { return found } }
            return nil
        }
        func click(_ identifier: String) -> Bool {
            guard let button = find(identifier, in: window.contentView!) as? NSButton, !button.isHidden else { return false }
            button.performClick(nil)
            return true
        }
        do {
            window.setFrame(NSRect(x: -8000, y: 0, width: 1100, height: 780), display: false)
            window.orderFront(nil)
            // One ordinary archived tab.
            let ordinaryURL = fixture.appendingPathComponent("ordinary-archive")
            owner.session.openTab(url: ordinaryURL)
            await owner.session.waitForPendingCommands()
            owner.session.closeSelectedTab()
            await owner.session.waitForPendingCommands()

            // Dock items with no Little window: present but disabled.
            func dockItems() -> [NSMenuItem] { application.applicationDockMenu(NSApp)?.items ?? [] }
            func item(_ title: String) -> NSMenuItem? { dockItems().first { $0.title == title } }
            check("dock-none-disabled", item("Show Little Circa Windows")?.isEnabled == false && item("Close Little Circa Windows")?.isEnabled == false)
            check("dock-standard-items", item("New Window") != nil && item("New Incognito Window") != nil)
            if let menu = application.applicationDockMenu(NSApp) { showMenu(menu, "dock-hidden-light") }

            // Two Little windows.
            try external(fixture.appendingPathComponent("little-first"))
            guard await until(8, { environment.quickWindows.count == 1 }) else { check("first-open", false); return }
            try external(fixture.appendingPathComponent("little-second"))
            guard await until(8, { environment.quickWindows.count == 2 }) else { check("second-open", false); return }
            _ = await until(8, { environment.quickWindows.values.allSatisfy { $0.surface?.isReady == true && $0.surface?.navigationState.isLoading == false } })
            check("window-titles", environment.quickWindows.values.allSatisfy { $0.window?.title.hasPrefix("Little Circa") == true })
            check("dock-enabled", item("Show Little Circa Windows")?.isEnabled == true && item("Close Little Circa Windows")?.isEnabled == true)
            if let menu = application.applicationDockMenu(NSApp) { showMenu(menu, "dock-visible-light") }
            for little in environment.quickWindows.values { little.window?.orderOut(nil) }
            if let show = item("Show Little Circa Windows") { _ = NSApp.sendAction(show.action!, to: show.target, from: show) }
            check("dock-show-all", environment.quickWindows.values.allSatisfy { $0.window?.isVisible == true })
            if let close = item("Close Little Circa Windows") { _ = NSApp.sendAction(close.action!, to: close.target, from: close) }
            check("dock-close-all", await until(8, { environment.quickWindows.isEmpty }))
            check("dock-disabled-after-close", item("Close Little Circa Windows")?.isEnabled == false)
            try await environment.saveNow()
            var littleRecords = await environment.store.sessionDocument().organization.archive.filter(\.isLittleWindow)
            for _ in 0..<20 where littleRecords.count != 2 {
                try await Task.sleep(for: .milliseconds(250))
                try await environment.saveNow()
                littleRecords = await environment.store.sessionDocument().organization.archive.filter(\.isLittleWindow)
            }
            check("little-archived", littleRecords.count == 2)

            // Archive filter and preview, light then dark.
            let previousAppearance = NSApp.appearance
            defer { NSApp.appearance = previousAppearance }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                event("step", ["at": "appearance-" + name])
                NSApp.appearance = NSAppearance(named: appearance)
                window.appearance = NSAppearance(named: appearance)
                owner.showArchive()
                await owner.session.waitForPendingCommands()
                await owner.archive.task?.value
                owner.library.view.acceptsLibraryInput = true
                try await Task.sleep(for: .milliseconds(300))
                let all = owner.archive.view.rows.filter { if case .tab = $0 { return true }; return false }.count
                capture(name + "-archive-all", window)
                check(name + "-filter-click", click("archive-filter"))
                try await Task.sleep(for: .milliseconds(200))
                capture(name + "-archive-filter-open", window)
                check(name + "-little-chip", click("archive-filter-little"))
                let little = owner.archive.view.rows.compactMap { row -> BrowserArchivedTab? in if case let .tab(record) = row { return record }; return nil }
                check(name + "-little-only", !little.isEmpty && little.allSatisfy(\.isLittleWindow) && little.count < all)
                try await Task.sleep(for: .milliseconds(200))
                capture(name + "-archive-filter-little", window)
                check(name + "-chip-off", click("archive-filter-little") && owner.archive.view.rows.filter { if case .tab = $0 { return true }; return false }.count == all)
                check(name + "-done", click("archive-filter-done") && find("archive-filter-done", in: window.contentView!)?.isHiddenOrHasHiddenAncestor != false)

                // Preview: a click on a row opens the Peek-style preview without a Split button.
                let table = owner.archive.view.table
                guard let row = owner.archive.view.rows.firstIndex(where: { if case .tab = $0 { return true }; return false }) else { check(name + "-row", false); return }
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if let action = table.action { _ = NSApp.sendAction(action, to: table.target, from: table) }
                check(name + "-preview-open", await until(6, { owner.isPeekPresented }))
                check(name + "-no-split", owner.peek.overlay.toolbar.splitButton.isHidden)
                check(name + "-library-retained", owner.library.isPresented)
                try await Task.sleep(for: .milliseconds(900))
                capture(name + "-archive-preview", window)
                // The offscreen test window is not key; the command targets it explicitly.
                let registry = application.commands.registry
                let target = registry.captureTarget(windowID: application.windows.selectedWindowID)
                let handled = registry.dispatch(.archiveTab, origin: .keyboard, target: target)
                let closed = await until(6, { !owner.isPeekPresented })
                check(name + "-cmd-w", handled && closed && owner.library.isPresented)
                record("little-archive.cmd-w-state-" + name, "proven", ["handled": handled, "closed": closed,
                    "target": target != nil, "library": owner.library.isPresented, "peek": owner.isPeekPresented])
                event("step", ["at": "before-hide-library"])
                owner.hideLibrary()
                event("step", ["at": "after-hide-library"])
                await owner.session.waitForPendingCommands()
                event("step", ["at": "after-pending"])
            }
        } catch { check("operation", false) }
    }
}
