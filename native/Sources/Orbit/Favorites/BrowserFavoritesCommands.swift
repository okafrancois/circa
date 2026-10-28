import BrowserEngine

enum BrowserFavoritesCommands {
    static let definitions: [BrowserCommandDefinition] = [
        .init(id: .removeFavorite, title: "Remove from Favorites", menu: "FavoritesContext", shortcuts: [],
              scope: .browser, requirement: .window, owner: "FAVORITES", sources: ["Browser command"]),
        .init(id: .renameFavorite, title: "Rename", menu: "FavoritesContext", shortcuts: [],
              scope: .browser, requirement: .window, owner: "FAVORITES", sources: ["Browser command"]),
        .init(id: .copyFavoriteLink, title: "Copy URL", menu: "FavoritesContext", shortcuts: [],
              scope: .browser, requirement: .window, owner: "FAVORITES", sources: ["Browser command"]),
        .init(id: .resetFavorite, title: "Reset Tab to Original URL", menu: "FavoritesContext", shortcuts: [],
              scope: .browser, requirement: .window, owner: "FAVORITES", sources: ["menu.declaration.context"])
    ]
    static let numbered: [BrowserCommandID] = [.selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
                                               .selectTab6, .selectTab7, .selectTab8, .selectTab9]
    @MainActor
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        for (index, id) in numbered.enumerated() {
            try! registry.register(id, validate: { [weak registry] controller in
                guard let preferences = registry?.shortcutPreferences.document else { return false }
                let tabs = controller.session.organization?.tabNavigationItems.filter {
                    preferences.includeFavorites || $0.section != .favorites(controller.session.organization!.profileID)
                } ?? []
                return index == 8 && preferences.nineSelectsLast ? !tabs.isEmpty : tabs.indices.contains(index)
            }) { [weak registry] controller, _ in
                guard let preferences = registry?.shortcutPreferences.document else { return }
                controller.hideLibrary()
                controller.session.selectSidebarTab(at: index == 8 && preferences.nineSelectsLast ? -1 : index,
                    includeFavorites: preferences.includeFavorites) { [weak controller] surface in
                        guard let controller else { return }
                        if controller.window?.isKeyWindow == true { surface.focusDocument() }
                    }
            }
        }
        for (id, offset): (BrowserCommandID, Int) in [(.nextTab, 1), (.previousTab, -1),
                                                     (.cycleTabForward, 1), (.cycleTabBackward, -1)] {
            try! registry.register(id, validate: { $0.session.organization?.tabNavigationItems.isEmpty == false }) { controller, _ in
                controller.hideLibrary()
                controller.session.selectSidebarTab(offset: offset) { [weak controller] surface in
                    guard let controller else { return }
                    if controller.window?.isKeyWindow == true { surface.focusDocument() }
                }
            }
        }
        for definition in definitions {
            try! registry.register(definition.id, validate: { controller in
                guard let tab = controller.favorites.currentMenuTab else { return false }
                return definition.id != .resetFavorite || tab.isAwayFromPinnedURL
            }) { controller, origin in controller.favorites.performMenuCommand(definition.id, origin: origin) }
        }
    }
}
