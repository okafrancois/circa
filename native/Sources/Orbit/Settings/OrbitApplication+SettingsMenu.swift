import AppKit
import BrowserCore

extension OrbitApplication {
    func installSettingsCommands(in registry: BrowserCommandRegistry<OrbitWindowController>) {
        try! registry.registerApplication(.aboutOrbit) { [weak self] in self?.showSettings(section: .about) }
        try! registry.registerApplication(.preferences) { [weak self] in self?.showSettings() }
        try! registry.registerApplication(.essentialKeyboardShortcuts) { [weak self] in self?.showSettings(section: .shortcuts) }
        try! registry.registerApplication(.newProfile) { [weak self] in
            self?.showSettings(section: .profiles)
            self?.settingsWindow?.model.focusNewProfile = true
        }
        try! registry.register(.changeProfile) { controller, _ in controller.presentSpaceProfileMenu() }
        try! registry.registerApplication(.manageSpaces) { [weak self] in
            guard let self else { return }
            showSettings(section: .spaces, profileID: activeBrowserWindow?.session.activeProfileID)
        }
        try! registry.registerApplication(.setAsDefaultBrowser) { [weak self] in
            guard let self, let environment, !isPreparingToQuit else { return }
            let service = BrowserDefaultBrowserService()
            guard environment.engine.kind == .chromium, service.canRequest() else { showSettings(); return }
            showSettings()
            settingsWindow?.model.perform {
                guard !environment.isFinalizing else { return }
                try await self.settingsWindow?.model.requestDefaultBrowser()
            }
        }
    }

    func showSettings(section: BrowserSettingsSection? = nil, profileID: ProfileID? = nil) {
        guard let environment, !isPreparingToQuit else { return }
        if settingsWindow == nil {
            let model = BrowserSettingsModel(environment: environment,
                profileID: activeBrowserWindow?.session.activeProfileID,
                shortcuts: commands.registry.defaultDefinitions)
            model.shortcutIsImplemented = { [weak self] id in
                self?.commands.registry.isImplemented(id) == true
            }
            settingsWindow = BrowserSettingsWindowController(model: model)
            model.presentBrowserForProfile = { [weak self] profile in
                guard let self, let environment = self.environment, !self.isPreparingToQuit else { throw CancellationError() }
                if let controller = self.windows.windows.values.first(where: {
                    !$0.session.isClosed && $0.session.activeProfileID == profile
                }) {
                    self.windowPresenter(controller, true)
                    return controller
                }
                let catalog = await environment.store.catalogSnapshot()
                guard let space = catalog.spaces.first(where: { $0.profileID == profile }) else { throw BrowserStoreError.spaceMissing }
                let id = UUID()
                self.quickWindowDestinationSpaces[id] = space.id
                defer { self.quickWindowDestinationSpaces[id] = nil }
                guard self.windows.newWindow(id: id) != nil else { throw CancellationError() }
                await self.windows.waitForPendingCommands()
                guard let controller = self.windows.windows[id], controller.session.activeProfileID == profile else { throw CancellationError() }
                return controller
            }
        }
        if let profileID { settingsWindow?.model.selectProfile(profileID) }
        if let section { settingsWindow?.model.navigate(to: section) }
        settingsWindow?.model.perform { [weak self] in await self?.settingsWindow?.model.reload() }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
}
