import AppKit

extension BrowserWindowController {
    func installPalette(in root: NSView) {
        palette.view.frame = root.bounds
        palette.view.autoresizingMask = [.width, .height]
        root.addSubview(palette.view)
        sidebar.creationActions = { [weak self] in self?.makeCreationActions() ?? [] }
        sidebar.onNewTab = { [weak self] in
            guard let self else { return }
            submitInput { $0.palette.present(.newTab) }
        }
    }

    func makeCreationActions() -> [SidebarCreationAction] {
        guard acceptsCommands, !session.isClosed, let registry = palette.registry,
              let target = registry.capturePaletteTarget(windowID: id),
              registry.capturePaletteTarget()?.windowID == id else { return [] }
        let items: [(BrowserCommandID, String, String)] = [
            (.newSpace, "square.grid.2x2", ""), (.newFolder, "folder", "⇧⌘N"),
            (.newTab, "plus.square", "⌘T"), (.newWindow, "macwindow.badge.plus", "⌘N"),
            (.newIncognitoWindow, "eyeglasses", "⇧⌘N"),
            (.manageExtensions, "puzzlepiece.extension", ""), (.addExtension, "plus.app", "")
        ]
        return items.compactMap { command, symbol, shortcut in
            guard let definition = registry.definition(command), registry.isImplemented(command) else { return nil }
            let global = definition.requirement == .application
            return SidebarCreationAction(command: command, title: definition.localizedTitle, symbol: symbol,
                shortcut: shortcut, enabled: registry.isEnabled(command, target: global ? nil : target)) { [weak self, weak registry] in
                guard let self, let registry, acceptsCommands, !session.isClosed,
                      let current = registry.capturePaletteTarget(windowID: id), current.context == target.context,
                      registry.capturePaletteTarget()?.windowID == id,
                      !global || (registry.router.selectedWindowID == id && !registry.router.hasPendingSelectedWindowCommands) else { return }
                registry.dispatch(command, origin: .contextMenu, target: global ? nil : target)
            }
        }
    }
}
