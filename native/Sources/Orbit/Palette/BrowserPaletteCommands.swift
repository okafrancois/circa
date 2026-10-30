import BrowserEngine

@MainActor
enum BrowserPaletteCommands {
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        try! registry.register(.removeSuggestion, validate: { $0.palette.canDeleteSuggestion }) { controller, _ in
            controller.palette.deleteSuggestion()
        }
        registry.registerScopeProvider("palette", priority: 100) { $0?.palette.isPresented == true ? .palette : nil }
        try! registry.register(.newTab, replace: true) { [weak registry] controller, _ in
            controller.palette.registry = registry
            controller.palette.present(.newTab)
        }
        try! registry.register(.openCommandBar, replace: true) { [weak registry] controller, _ in
            controller.palette.registry = registry
            controller.palette.present(.currentTab)
        }
    }
}
