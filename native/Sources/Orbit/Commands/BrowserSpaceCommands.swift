import BrowserEngine

enum BrowserSpaceCommands {
    static let numbered: [BrowserCommandID] = [
        .selectSpace1, .selectSpace2, .selectSpace3, .selectSpace4, .selectSpace5,
        .selectSpace6, .selectSpace7, .selectSpace8, .selectSpace9
    ]

    static func shortcutLabel(at index: Int, definitions: [BrowserCommandDefinition] = OrbitCommandCatalog.definitions) -> String? {
        guard numbered.indices.contains(index) else { return nil }
        return definitions.first { $0.id == numbered[index] }?.shortcuts.first?.displayLabel
    }

    @MainActor
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        for (index, command) in numbered.enumerated() {
            try! registry.register(command, validate: { controller in
                controller.isPrivateWindow == false && controller.session.catalog?.spaces.indices.contains(index) == true
            }) { controller, _ in
                guard let spaces = controller.session.catalog?.spaces, spaces.indices.contains(index) else { return }
                controller.hideLibrary()
                let target = spaces[index].id
                if !controller.sidebar.spaceSwipe.switchToSpace(target) { controller.activateSpace(target) }
            }
        }
    }
}
