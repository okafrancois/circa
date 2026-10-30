import AppKit
import BrowserCore
import BrowserShell

extension OrbitSmokeDriver {
    /// Exercises merged menu handlers against hosted documents without global input or clipboard writes.
    func dailyQA8(_ application: OrbitApplication, _ environment: OrbitEnvironment,
                  _ owner: OrbitWindowController) async {
        func check(_ name: String, _ value: Bool) { self.check("daily8." + name, value) }
        func settle() async {
            await owner.session.waitForPendingCommands()
            try? await Task.sleep(for: .milliseconds(100))
            await owner.session.waitForPendingCommands()
        }
        func menu(_ node: BrowserOrganizationNode, _ command: BrowserCommandID) async -> Bool {
            guard let window = owner.window, window.windowController === owner,
                  NSApp.windows.contains(where: { $0 === window }),
                  NSRunningApplication.current.processIdentifier == getpid() else { return false }
            let nodes = owner.sidebar.prepareContextMenu(for: node)
            defer { owner.sidebar.endContextMenu() }
            guard let built = owner.makeSidebarContextMenu(for: nodes),
                  let item = built.menu.items.first(where: { $0.identifier?.rawValue == command.rawValue }),
                  item.isEnabled else { return false }
            built.menu.performActionForItem(at: built.menu.index(of: item))
            await settle()
            return true
        }
        let registry = application.commands.registry
        let bindings: [(BrowserShortcut, BrowserCommandID)] = [
            (.init(key: "c", modifiers: [.command, .shift]), .copyURL),
            (.init(key: "e", modifiers: .command), .cycleExtensions),
            (.init(key: "\t", modifiers: .control), .tabSwitcherForward),
            (.init(key: "`", modifiers: .control), .tabSwitcherBackward),
            (.init(key: "v", modifiers: [.command, .option]), .pasteAsNewTab),
            (.init(key: "d", modifiers: .control), .toggleDeveloperMode)
        ]
        for (index, binding) in bindings.enumerated() {
            check("shortcut-\(index)", OrbitCommandCatalog.definitions.filter { $0.scope == .browser && $0.shortcuts.contains(binding.0) }.map(\.id) == [binding.1])
        }
        await settle()
        check("new-tab", registry.dispatch(.newTab, origin: .menu, target: registry.captureTarget(windowID: owner.id)))
        await settle()
        check("command-bar", owner.palette.isPresented)
        let firstURL = page("daily8-first")
        owner.palette.query(firstURL.absoluteString)
        await owner.palette.waitForResults()
        check("suggestion", owner.palette.results.contains { $0.url == firstURL })
        owner.palette.accept()
        await owner.palette.waitForAcceptance()
        guard await committed(owner, firstURL) != nil,
              let first = owner.session.organization?.selectedTab?.id,
              let space = owner.session.organization?.spaceID else { check("first-document", false); return }
        check("first-document", true)
        let count = owner.session.organization!.allTabs.count
        check("duplicate-tab-action", await menu(.tab(first), .sidebarDuplicate))
        check("duplicate-tab", await until(5) {
            owner.session.organization!.allTabs.count == count + 1 && owner.session.organization?.selectedTab?.id != first
        })
        owner.session.selectTab(first)
        owner.session.pinTabs([first])
        await settle()
        check("pin", owner.session.organization?.tab(first)?.pinnedURL == firstURL)
        check("pin-home", owner.session.organization?.tab(first)?.isAwayFromPinnedURL == false)
        let child = page("daily8-child")
        owner.session.selectedSurface?.navigate(to: child)
        _ = await committed(owner, child)
        await settle()
        check("pin-subpage", owner.session.organization?.tab(first)?.isAwayFromPinnedURL == true)
        owner.session.resetTabToPinnedURL(first) { $0.navigate(to: $1) }
        _ = await committed(owner, firstURL)
        await settle()
        check("pin-reset", owner.session.organization?.tab(first)?.isAwayFromPinnedURL == false)
        owner.session.unpinTabs([first])
        await settle()
        check("unpin", owner.session.organization?.tab(first)?.pinnedURL == nil)
        owner.openTab(url: page("daily8-second"))
        guard await committed(owner, page("daily8-second")) != nil,
              let second = owner.session.organization?.selectedTab?.id else { check("second-document", false); return }
        owner.session.createSplit([first, second], orientation: .vertical)
        await settle()
        guard let split = owner.session.activeSplit else { check("split-create", false); return }
        check("split-create", split.tabs.count == 2)
        let beforeSplit = owner.session.organization!.allTabs.count
        check("duplicate-split-action", await menu(.split(split.group.id), .sidebarDuplicate))
        check("duplicate-split", owner.session.organization!.allTabs.count == beforeSplit + 2
              && owner.session.activeSplit?.group.id != split.group.id && owner.session.activeSplit?.tabs.count == 2)
        owner.openTab(url: page("daily8-below"))
        guard await committed(owner, page("daily8-below")) != nil,
              let below = owner.session.organization?.selectedTab?.id else { check("below-document", false); return }
        owner.session.moveItems([.tab(below)], to: .init(.today(space), position: .end))
        await settle()
        check("archive-below-action", await menu(.split(split.group.id), .sidebarArchiveTabsBelow))
        check("archive-below", owner.session.organization?.tab(below) == nil
              && owner.session.organization?.tab(first) != nil && owner.session.organization?.tab(second) != nil)
        owner.session.restoreArchivedTab(below, activate: false)
        await settle()
        check("archive-restore", owner.session.organization?.tab(below) != nil)
        owner.session.unsplit(split.group.id)
        await settle()
        check("split-separate", owner.session.organization?.item(for: .split(split.group.id)) == nil
              && owner.session.organization?.tab(first) != nil && owner.session.organization?.tab(second) != nil)
        guard let folder = await owner.session.createFolder(title: "Synthetic folder", at: .init(.pinned(space)),
                                                            containing: [.tab(first), .tab(second)]).value else {
            check("folder", false); return
        }
        await settle()
        let beforeFolder = owner.session.organization!.allTabs.count
        check("duplicate-folder-action", await menu(.folder(folder), .sidebarDuplicate))
        check("duplicate-folder", owner.session.organization!.allTabs.count == beforeFolder + 2)
        let peekURL = page("daily8-peek")
        if let peek = owner.openPeek(peekURL) {
            check("peek", await until(5) { peek.navigationState.committedURL == peekURL })
            let promotion = owner.promotePeekToTab()
            check("peek-promote-accepted", promotion != nil)
            _ = await promotion?.value
            await settle()
            check("peek-promote-document", owner.session.selectedSurface === peek && !owner.isPeekPresented)
        } else { check("peek", false) }
        application.quickWindowPresenter = { _ in }
        let littleURL = page("daily8-little")
        application.openQuickWindow(url: littleURL, source: owner)
        await application.waitForQuickWindowCommands()
        if let little = environment.quickWindows.values.first {
            check("little", await until(5) { little.surface?.navigationState.committedURL == littleURL })
            let live = little.surface
            application.promoteQuickWindow(little)
            await application.waitForQuickWindowCommands()
            await settle()
            check("little-promote-document", little.isClosed && environment.liveControllers.contains { $0.session.selectedSurface === live })
        } else { check("little", false) }
        if let profile = owner.session.activeProfileID {
            let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
            await model.reload()
            let settings = BrowserSettingsWindowController(model: model)
            check("settings-open", settings.window?.contentView != nil)
            settings.close()
        }
        do {
            let destination = try await environment.store.createSpace(name: "Synthetic switch", profileID: owner.session.activeProfileID!)
            owner.activateSpace(destination)
            await settle()
            check("space-switch", owner.session.organization?.spaceID == destination)
            owner.activateSpace(space)
            await settle()
            try await environment.saveNow()
            let document = await environment.store.sessionDocument()
            try document.validate()
            let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(document.encoded()))
            check("session-round-trip", await restored.sessionDocument().organization == document.organization)
        } catch { check("persistence", false) }
    }
}
