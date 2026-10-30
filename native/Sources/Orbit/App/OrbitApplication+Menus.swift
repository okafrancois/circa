import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Shared registry composition. Later lots replace/register handlers here or in their own
/// menu extension; they do not add competing keyboard monitors or direct menu actions.
@MainActor
final class OrbitCommandSystem {
    let registry: BrowserCommandRegistry<OrbitWindowController>
    let menus: BrowserCommandMenus<OrbitWindowController>
    let globalQuickWindowShortcut = BrowserGlobalQuickWindowShortcut()
    let keyboard: BrowserCommandKeyboard

    init(registry: BrowserCommandRegistry<OrbitWindowController>, acceptsKeyboard: @escaping () -> Bool,
         keyWindow: @escaping () -> NSWindow? = { NSApp?.keyWindow }) {
        self.registry = registry
        menus = BrowserCommandMenus(registry: registry, keyWindow: keyWindow)
        keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: acceptsKeyboard,
                                          firstResponder: { keyWindow()?.firstResponder })
    }
}

extension OrbitApplication {
    func installMenus() {
        commands.menus.profileMenuProvider = { [weak self] in
            guard let controller = self?.activeBrowserWindow,
                  let id = controller.session.snapshot?.activeSpaceID else { return nil }
            return controller.makeSpaceProfileMenu(for: id)
        }
        let bar = commands.menus.makeMenuBar()
        NSApp.mainMenu = bar
        NSApp.windowsMenu = bar.items.first { $0.title == uiText("Window") }?.submenu
        NSApp.helpMenu = bar.items.first { $0.title == uiText("Help") }?.submenu
        NSApp.servicesMenu = bar.items.first?.submenu?.items.first { $0.identifier?.rawValue == BrowserCommandID.services.rawValue || $0.title == uiText("Services") }?.submenu
        commands.keyboard.install()
    }

    func makeCommandSystem() -> OrbitCommandSystem {
        let keyWindow = commandKeyWindow
        let registry = try! BrowserCommandRegistry(router: windows, state: { [weak self] controller in
            var state = controller?.commandState ?? BrowserCommandState()
            controller?.applyPeekCommandState(to: &state)
            state.isAvailable = state.isAvailable && self?.isPreparingToQuit == false && self?.environment != nil
            state.isModal = state.isModal || NSApp?.modalWindow != nil || keyWindow()?.sheetParent != nil
            return state
        }, currentWindowID: { [weak self] in
            guard let self else { return nil }
            return BrowserCommandWindowRouting.route(router: windows, keyWindow: keyWindow(),
                                                      nativeWindow: { $0.window }).windowID
        }, permitsMissingWindow: { [weak self] in
            guard let self else { return false }
            return BrowserCommandWindowRouting.route(router: windows, keyWindow: keyWindow(),
                                                      nativeWindow: { $0.window }).allowsMissingWindowHandling
        }, deliver: { controller, action in controller.performAcceptedCommand(action) })
        let system = OrbitCommandSystem(registry: registry, acceptsKeyboard: { [weak self] in
            guard let self else { return false }
            return !isPreparingToQuit && environment != nil
        }, keyWindow: keyWindow)
        func application(_ id: BrowserCommandID, allowsDuringModal: Bool = false, _ action: @escaping () -> Void) {
            try! registry.registerApplication(id, allowsDuringModal: allowsDuringModal, handler: action)
        }
        registry.onShortcutsChanged = { [weak self, weak registry] in
            guard let self, let registry else { return }
            do {
                try commands.globalQuickWindowShortcut.update(enabled: registry.shortcutPreferences.document.globalQuickWindowEnabled,
                    shortcut: registry.definition(.newQuickWindowWindow)?.shortcuts.first)
            } catch {
                commands.globalQuickWindowShortcut.uninstall()
                registry.shortcutPreferences.errorMessage = error.localizedDescription
            }
            installMenus()
        }
        system.globalQuickWindowShortcut.onOpen = { [weak self] in
            guard let self, !isPreparingToQuit else { return }
            NSApp.activate(ignoringOtherApps: true)
            openQuickWindow()
        }
        BrowserDataCommands.install(in: registry, dataRoot: { [weak self] in
            self?.environment?.sessionFile?.deletingLastPathComponent()
        })
        installSettingsCommands(in: registry)
        BrowserWindowCommands.install(in: registry, commandKeyWindow: keyWindow)
        BrowserPeekCommands.install(in: registry)
        installQuickWindowCommands(in: registry)
        try! registry.registerWhenWindowMissing(.undo, withOrigin: { [weak self] _ in self?.undo(nil) })
        registry.registerPrerequisite(.undo) { [weak self] controller, _ in
            controller != nil || self?.environment?.lastClosedWindowDate != nil
        }
        application(.openFile) { [weak self] in self?.presentOpenFile() }
        application(.newWindow) { [weak self] in self?.createCommandWindow() }
        application(.newIncognitoWindow) { [weak self] in self?.createPrivateCommandWindow() }
        try! registry.registerWhenWindowMissing(.newTab, withOrigin: { [weak self] origin in
            self?.performMissingWindowCommand(.newTab, origin: origin)
        })
        try! registry.registerWhenWindowMissing(.openCommandBar, withOrigin: { [weak self] origin in
            self?.performMissingWindowCommand(.openCommandBar, origin: origin)
        })
        // Orbit's own entry (Orbit menu, ) and Orbit's File entry run the same Orbit import.
        application(.importArcConnections) { [weak self] in self?.startArcSiteSessionImport() }
        application(.restoreArcConnections) { [weak self] in self?.startArcSiteSessionImport(restoring: true) }
        application(.importFromArc) { [weak self] in self?.startArcImport() }
        application(.importFromAnotherBrowser) { [weak self] in self?.startBrowserImport() }
        application(.checkForUpdates) { [weak self] in self?.updater.checkForUpdates() }
        registry.registerPrerequisite(.checkForUpdates) { [weak self] _, _ in self?.updater.canCheckForUpdates == true }
        application(.quitOrbit, allowsDuringModal: true) { NSApp.terminate(nil) }
        application(.hideOrbit, allowsDuringModal: true) { NSApp.hide(nil) }
        application(.hideOtherWindows, allowsDuringModal: true) { NSApp.hideOtherApplications(nil) }
        application(.showAll, allowsDuringModal: true) { NSApp.unhideAllApplications(nil) }
        for id: BrowserCommandID in [.newSpace, .newQuickWindowWindow, .newFolder, .pinUnpinTab, .manageExtensions, .addExtension] {
            registry.registerPrerequisite(id) { controller, _ in controller?.isPrivateWindow != true }
        }
        return system
    }

    private func performMissingWindowCommand(_ id: BrowserCommandID, origin: BrowserCommandOrigin) {
        BrowserCommandWindowRouting.performWhenWindowMissing(router: windows, keyWindow: commandKeyWindow(),
            nativeWindow: { $0.window }, action: { [weak self] controller in
                self?.commands.registry.performRestoredWindowCommand(id, in: controller, origin: origin)
            }, create: { [weak self] in
                guard let self else { return }
                withBrowserWindow { [weak self] controller in
                    guard let registry = self?.commands.registry else { return }
                    controller.palette.registry = registry
                    switch id {
                    case .newTab: controller.palette.present(.newTab)
                    case .openCommandBar: controller.palette.present(.currentTab)
                    default: break
                    }
                }
            })
    }

    private func createCommandWindow() {
        guard !isPreparingToQuit, environment != nil else { return }
        let id = UUID()
        let hasSource = windows.selectedWindowID != nil
            && windows.selectedWindowID.flatMap { privateWindows[$0] } == nil
            && windows.selectedWindow?.isPrivateWindow != true
        if hasSource {
            inheritedWindowProfiles[id] = windows.selectedWindow?.session.activeProfileID
                ?? windows.selectedWindowID.flatMap { inheritedWindowProfiles[$0] }
        }
        let requested = windows.newWindow(id: id, prepare: { [weak self] source in
            guard let self else { throw CancellationError() }
            if hasSource {
                guard let source else { inheritedWindowProfiles[id] = nil; throw CancellationError() }
                inheritedWindowProfiles[id] = source.session.activeProfileID ?? inheritedWindowProfiles[id]
                inheritedContexts[id] = source.session.captureContextInCommandOrder()
            }
        })
        if requested == nil { inheritedWindowProfiles[id] = nil }
    }
}
