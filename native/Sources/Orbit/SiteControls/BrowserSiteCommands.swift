import BrowserEngine
import BrowserCore

enum BrowserSiteCommands {
    static let definitions: [BrowserCommandDefinition] = [
        .init(id: .showSiteControls, title: "Site Controls…", menu: "View", shortcuts: [],
              scope: .browser, requirement: .surface, owner: "SITE",
              sources: ["Browser command"])
    ]

    @MainActor
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        try! registry.register(.toggleDeveloperMode, validate: { controller in
            guard let surface = controller.session.selectedSurface else { return false }
            return controller.acceptsCommands && BrowserSitePreferenceStore.host(surface.navigationState.committedURL) != nil
        }) { controller, _ in
            guard let surface = controller.session.selectedSurface else { return }
            let url = surface.navigationState.committedURL
            var preferences = controller.siteControls.preferences.preferences(url: url, profileID: surface.profileID)
            preferences.developerMode.toggle()
            do {
                try controller.siteControls.preferences.set(preferences, url: url, profileID: surface.profileID)
                controller.siteControls.onPreferencesChange?()
            } catch { controller.session.onError?(error) }
        }
        try! registry.register(.showSiteControls, validate: { $0.siteControls.canShow }) { controller, _ in
            guard let source = controller.session.selectedSurface else { return }
            let generation = source.documentGeneration
            controller.session.performOnSelectedSurface { [weak controller, weak source] surface in
                guard let controller, let source, source === surface, surface.documentGeneration == generation,
                      controller.owns(surface), controller.session.selectedSurface === surface else { return }
                controller.siteControls.show()
            }
        }
    }
}
