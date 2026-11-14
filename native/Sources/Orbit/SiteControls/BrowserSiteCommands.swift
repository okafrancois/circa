import Foundation
import BrowserEngine
import BrowserCore

enum BrowserSiteCommands {
    static let definitions: [BrowserCommandDefinition] = [
        .init(id: .showSiteControls, title: "Site Controls…", menu: "View", shortcuts: [],
              scope: .browser, requirement: .surface, owner: "SITE",
              sources: ["Browser command"]),
        .init(id: .reloadWithWebKit, title: "Reload with WebKit", menu: "View", shortcuts: [],
              scope: .browser, requirement: .surface, owner: "SITE", sources: ["Browser command"]),
        .init(id: .reloadWithChromium, title: "Reload with Chromium", menu: "View", shortcuts: [],
              scope: .browser, requirement: .surface, owner: "SITE", sources: ["Browser command"])
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
        installSiteEngineCommands(in: registry)
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

    /// "Reload with WebKit/Chromium": only engines whose tabs can switch (the Chromium product).
    /// The choice is remembered for the host in the site preferences store.
    @MainActor
    static func installSiteEngineCommands<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        guard Engine.hostsSiteEngineSwitching else { return }
        for (id, target) in [(BrowserCommandID.reloadWithWebKit, BrowserSiteEngine.webKit), (.reloadWithChromium, .chromium)] {
            try! registry.register(id, validate: { controller in
                guard controller.acceptsCommands, let surface = controller.session.selectedSurface,
                      let switching = surface.siteEngineSwitching else { return false }
                return switching.siteEngine != target && siteEngineURL(surface.navigationState) != nil
            }) { controller, _ in
                guard let surface = controller.session.selectedSurface,
                      let switching = surface.siteEngineSwitching,
                      let url = siteEngineURL(surface.navigationState) else { return }
                // A store that cannot save (private windows) still switches this tab.
                try? controller.siteControls.preferences.setSiteEngine(target, for: url, profileID: surface.profileID)
                switching.reload(with: target)
            }
        }
    }

    static func siteEngineURL(_ state: BrowserNavigationState) -> URL? {
        let url = state.committedURL ?? state.url
        return BrowserSitePreferenceStore.host(url) == nil ? nil : url
    }
}
