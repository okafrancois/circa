import AppKit
import BrowserCore

struct BrowserLaunchNewTab {
    private var pendingSpaceID: SpaceID?

    mutating func restore(spaceID: SpaceID, hasSelectedTab: Bool) {
        pendingSpaceID = hasSelectedTab ? nil : spaceID
    }

    mutating func reconcile(spaceID: SpaceID?, hasSelectedTab: Bool) {
        if hasSelectedTab || spaceID != pendingSpaceID { pendingSpaceID = nil }
    }

    mutating func shouldPresent(isKeyWindow: Bool, isApplicationActive: Bool) -> Bool {
        guard pendingSpaceID != nil, isKeyWindow, isApplicationActive else { return false }
        pendingSpaceID = nil
        return true
    }
}

extension BrowserWindowController {
    func prepareLaunchNewTab() {
        guard !isPrivateWindow, let snapshot = session.snapshot, !snapshot.isStandalone else { return }
        launchNewTab.restore(spaceID: snapshot.activeSpaceID, hasSelectedTab: snapshot.selectedOccurrenceID != nil)
    }

    func reconcileLaunchNewTab() {
        launchNewTab.reconcile(spaceID: session.snapshot?.activeSpaceID,
                               hasSelectedTab: session.snapshot?.selectedOccurrenceID != nil)
    }

    func presentLaunchNewTabIfReady() {
        guard acceptsCommands, !session.isClosed, let window,
              launchNewTab.shouldPresent(isKeyWindow: window.isKeyWindow, isApplicationActive: NSApp.isActive) else { return }
        if !palette.isPresented { palette.present(.newTab) }
    }

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
