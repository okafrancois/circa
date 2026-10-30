import AppKit
import BrowserCore
import ChromiumEngine
import BrowserShell

extension OrbitSmokeDriver {
    /// Bounded proof using the owned Chromium window and the production menu dispatch paths.
    func spaceConversion(_ environment: OrbitEnvironment, _ owner: OrbitWindowController) async {
        guard let window = owner.window else { check("conversion.window", false); return }
        window.setContentSize(NSSize(width: 1200, height: 800))
        owner.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        let home = fixture.appendingPathComponent("beta")
        owner.submitAddress(home.absoluteString)
        guard await committed(owner, home) != nil, let tab = owner.session.organization?.selectedTab,
              let source = owner.session.organization?.spaceID, let profile = owner.session.activeProfileID else {
            check("conversion.fixture", false); return
        }
        let output = runRoot!
        func ownsWindow() -> Bool {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
            return rows?.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() } == true
        }
        func capture(_ name: String) {
            guard ownsWindow(), CGPreflightScreenCaptureAccess() else { check("conversion.capture-" + name, false); return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent(name + ".png").path]
            try? process.run(); process.waitUntilExit()
        }
        func pause(_ milliseconds: Int = 650) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func settle() async { await owner.session.waitForPendingCommands(); await pause() }
        owner.session.renameSpace(source, name: "Source")
        owner.session.pinTabs([tab.id])
        await settle()
        owner.session.createSpace(name: "Destination", profileID: profile)
        await settle()
        let destination = (owner.session.organization?.spaceID)!
        owner.session.activateSpace(source)
        await settle()
        guard ownsWindow() else { check("conversion.ownership", false); return }
        let video = Process()
        video.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        video.arguments = ["-x", "-v", "-V", "14", "-l", String(window.windowNumber), output.appendingPathComponent("conversion.mov").path]
        try? video.run()
        capture("export-before")
        await pause(500)
        if ownsWindow(), let item = SidebarSpaceExportMenu.make(owner: owner, source: source),
           let menu = item.submenu, let row = menu.items.first(where: { $0.title == "Destination" }) {
            check("conversion.export-menu", item.title == uiFormat("Export “%@” into Folder", "Source"))
            menu.performActionForItem(at: menu.index(of: row))
        } else { check("conversion.export-menu", false) }
        await settle()
        capture("export-settled")
        check("conversion.export-result", owner.session.organization?.spaceID == destination && owner.session.catalog?.spaces.contains { $0.id == source } == false)
        guard let folder = owner.session.organization?.pinned.first?.node.folderID else { check("conversion.folder", false); return }
        owner.session.undoOrganization()
        await settle()
        capture("export-undo")
        check("conversion.export-undo", owner.session.organization?.spaceID == source && owner.session.organization?.tab(tab.id) != nil)
        owner.session.redoOrganization()
        await settle()
        capture("export-redo")
        check("conversion.export-redo", owner.session.organization?.spaceID == destination && owner.session.organization?.pinned.first?.node == .folder(folder))
        // The promotion fixture contains a child folder and no selected page in its new Space.
        owner.session.deleteFolder(folder, contents: .keepContents)
        await settle()
        let childTask = owner.session.createFolder(title: "Child", at: .init(.pinned(destination)), containing: [.tab(tab.id)])
        guard let child = await childTask.value else { check("conversion.child", false); return }
        owner.session.setFolderCollapsed(child, true)
        let outerTask = owner.session.createFolder(title: "Source", at: .init(.pinned(destination)), containing: [.folder(child)])
        guard let outer = await outerTask.value else { check("conversion.outer", false); return }
        await settle()
        capture("folder-before")
        guard ownsWindow() else { check("conversion.ownership", false); return }
        _ = owner.sidebar.prepareContextMenu(for: .folder(outer))
        if let built = owner.makeSidebarContextMenu(for: [.folder(outer)]),
           let index = built.menu.items.firstIndex(where: { $0.identifier?.rawValue == BrowserCommandID.sidebarConvertFolderToSpace.rawValue }) {
            check("conversion.folder-menu", built.menu.items[index].title == uiFormat("Turn “%@” into Space", "Source"))
            built.menu.performActionForItem(at: index)
        } else { check("conversion.folder-menu", false) }
        owner.sidebar.endContextMenu()
        await settle()
        let promoted = owner.session.organization?.spaceID
        capture("folder-settled")
        check("conversion.folder-result", promoted != destination && owner.session.organization?.pinned.first?.node == .folder(child) && owner.session.organization?.selectedTab == nil)
        owner.session.activateSpace(destination)
        await settle()
        capture("folder-source")
        owner.session.activateSpace(promoted!)
        await settle()
        owner.session.undoOrganization()
        await settle()
        capture("folder-undo")
        check("conversion.folder-undo", owner.session.organization?.spaceID == destination && owner.session.organization?.pinned.first?.node == .folder(outer))
        owner.session.redoOrganization()
        await settle()
        capture("folder-redo")
        check("conversion.folder-redo", owner.session.organization?.spaceID == promoted && owner.session.organization?.pinned.first?.node == .folder(child))
        do { try await environment.saveNow(); check("conversion.persisted", true) }
        catch { check("conversion.persisted", false) }
        await pause(9000)
        if video.isRunning { video.terminate() }
    }
}
