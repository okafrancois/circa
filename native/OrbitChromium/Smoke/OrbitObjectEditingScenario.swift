import AppKit
import BrowserCore
import ChromiumEngine

extension OrbitSmokeDriver {
    /// Visible, bounded integration proof on the confined Chromium bundle. Calls the same
    /// captured-row commands as the menus; no events are delivered to another application.
    func objectEditing(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        guard let window = owner.window else { check("editing.window", false); return }
        window.setContentSize(NSSize(width: 1200, height: 800))
        owner.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        let home = fixture.appendingPathComponent("alpha")
        let changed = fixture.appendingPathComponent("replaced")
        owner.submitAddress(home.absoluteString)
        guard await committed(owner, home) != nil, let tab = owner.session.organization?.selectedTab else {
            check("editing.fixture", false); return
        }
        let output = runRoot!
        func owns(_ candidate: NSWindow) -> Bool {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(candidate.windowNumber)) as? [[String: Any]]
            return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        func capture(_ name: String, _ candidate: NSWindow? = nil) {
            let candidate = candidate ?? window
            guard owns(candidate), CGPreflightScreenCaptureAccess() else { check("editing.capture-" + name, false); return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(candidate.windowNumber), output.appendingPathComponent(name + ".png").path]
            try? process.run(); process.waitUntilExit()
        }
        func pause(_ milliseconds: Int = 350) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func target() { _ = owner.sidebar.prepareContextMenu(for: .tab(tab.id)) }
        func iconEditor() async {
            target()
            if let built = owner.makeSidebarContextMenu(for: [.tab(tab.id)]),
               let index = built.menu.items.firstIndex(where: { $0.identifier?.rawValue == BrowserCommandID.sidebarChangeTabIcon.rawValue }) {
                built.menu.performActionForItem(at: index)
                await owner.session.waitForPendingCommands()
            }
        }
        func urlEditor() async {
            target()
            if let built = owner.makeSidebarContextMenu(for: [.tab(tab.id)]),
               let menu = built.menu.items.first(where: { $0.identifier?.rawValue == BrowserCommandID.sidebarEditPinnedURL.rawValue })?.submenu {
                menu.performActionForItem(at: 0)
                await owner.session.waitForPendingCommands()
            }
        }
        func captureMenu(_ name: String) {
            let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            guard let row = rows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int) == 101 }),
                  let id = row[kCGWindowNumber as String] as? Int, CGPreflightScreenCaptureAccess() else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(id), output.appendingPathComponent(name + ".png").path]
            try? process.run(); process.waitUntilExit()
        }
        let video = Process()
        if owns(window), CGPreflightScreenCaptureAccess() {
            video.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            video.arguments = ["-x", "-v", "-V", "18", "-l", String(window.windowNumber), output.appendingPathComponent("editing.mov").path]
            try? video.run()
        }
        await pause(600)
        target()
        if let menu = owner.makeSidebarContextMenu(for: [.tab(tab.id)]) {
            let captureTimer = Timer(timeInterval: 0.25, repeats: false) { _ in
                MainActor.assumeIsolated { captureMenu(owner.session.organization?.tab(tab.id)?.pinnedURL == nil ? "today-menu" : "pinned-menu") }
            }
            RunLoop.main.add(captureTimer, forMode: .eventTracking)
            let timer = Timer(timeInterval: 0.7, target: menu.menu, selector: #selector(NSMenu.cancelTracking), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .eventTracking)
            menu.menu.popUp(positioning: nil, at: NSPoint(x: 150, y: 300), in: owner.sidebar)
            timer.invalidate()
            captureTimer.invalidate()
        }
        owner.sidebar.endContextMenu()
        await iconEditor()
        await pause()
        capture("icon-picker", owner.tabIconPicker?.popup.window)
        owner.tabIconPicker?.choose(.grapheme("😀"))
        await owner.session.waitForPendingCommands()
        await pause()
        check("editing.icon-applied", owner.session.organization?.tab(tab.id)?.customIcon == .grapheme("😀"))
        capture("icon-applied")
        capture("icon-applied-picker", owner.tabIconPicker?.popup.window)
        owner.tabIconPicker?.removeIcon(nil)
        await owner.session.waitForPendingCommands()
        await pause()
        capture("icon-reset")
        check("editing.icon-reset", owner.session.organization?.tab(tab.id)?.customIcon == nil)
        owner.tabIconPicker?.cancel()
        await iconEditor()
        await pause()
        owner.tabIconPicker?.cancel()
        check("editing.icon-cancel", owner.session.organization?.tab(tab.id)?.customIcon == nil)
        owner.sidebar.endContextMenu()
        owner.session.pinTabs([tab.id])
        await owner.session.waitForPendingCommands()
        target()
        if let menu = owner.makeSidebarContextMenu(for: [.tab(tab.id)]) {
            let captureTimer = Timer(timeInterval: 0.25, repeats: false) { _ in
                MainActor.assumeIsolated { captureMenu(owner.session.organization?.tab(tab.id)?.pinnedURL == nil ? "today-menu" : "pinned-menu") }
            }
            RunLoop.main.add(captureTimer, forMode: .eventTracking)
            let timer = Timer(timeInterval: 0.7, target: menu.menu, selector: #selector(NSMenu.cancelTracking), userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .eventTracking)
            menu.menu.popUp(positioning: nil, at: NSPoint(x: 150, y: 300), in: owner.sidebar)
            timer.invalidate()
            captureTimer.invalidate()
        }
        owner.sidebar.endContextMenu()
        await urlEditor()
        await pause()
        capture("pinned-editor")
        check("editing.selection", (window.firstResponder as? NSTextView)?.selectedRange().length == home.absoluteString.utf16.count)
        owner.pinnedURLEditor?.field.stringValue = changed.absoluteString
        owner.pinnedURLEditor?.complete(save: false)
        await pause()
        check("editing.pinned-cancel", owner.session.organization?.tab(tab.id)?.pinnedURL == home)
        capture("pinned-cancel")
        await urlEditor()
        await pause()
        owner.pinnedURLEditor?.field.stringValue = changed.absoluteString
        owner.pinnedURLEditor?.complete(save: true)
        await owner.session.waitForPendingCommands()
        _ = await committed(owner, changed)
        await pause()
        check("editing.pinned-save", owner.session.organization?.tab(tab.id)?.pinnedURL == changed)
        capture("pinned-saved")
        await urlEditor()
        await pause()
        capture("pinned-restore-draft")
        owner.pinnedURLEditor?.field.stringValue = home.absoluteString
        owner.pinnedURLEditor?.complete(save: true)
        await owner.session.waitForPendingCommands()
        _ = await committed(owner, home)
        await pause()
        check("editing.pinned-restored", owner.session.organization?.tab(tab.id)?.pinnedURL == home)
        capture("pinned-restored")
        owner.sidebar.endContextMenu()
        do { try await environment.saveNow(); check("editing.persisted", true) }
        catch { check("editing.persisted", false) }
        await pause(10000)
        if video.isRunning { video.waitUntilExit() }
    }
}
