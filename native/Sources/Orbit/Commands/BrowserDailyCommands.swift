import AppKit
import BrowserEngine

/// Product routes reuse the command authority and engine services; no extension API is emulated.
@MainActor
enum BrowserDailyCommands {
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        registry.registerInputHandler("assistant") { controller, event in
            if controller?.palette.handleAssistantKey(event) == true { return true }
            guard let controller, event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  event.charactersIgnoringModifiers == "e", controller.assistantEnabled else { return false }
            controller.toggleAssistant()
            return true
        }
        BrowserPasswordCommands.install(in: registry)
        weak var cyclingOwner: BrowserWindowController<Engine>?
        registry.registerInputHandler("extensions") { [weak registry] controller, event in
            guard let active = cyclingOwner, active.extensionControls.isCycling else { return false }
            guard controller === active, event.window == nil || event.window === active.window else {
                active.extensionControls.cancelCycle()
                return false
            }
            if event.type == .flagsChanged, !event.modifierFlags.contains(.command) {
                active.extensionControls.finishCycle()
                return false
            }
            if event.type == .leftMouseDown { active.extensionControls.cancelCycle(); return false }
            guard event.type == .keyDown else { return false }
            if event.keyCode == 53 { active.extensionControls.cancelCycle(); return true }
            if registry?.resolve(event) == .cycleExtensions {
                if !event.isARepeat { active.extensionControls.cycle(holding: event.modifierFlags) }
                return true
            }
            active.extensionControls.cancelCycle()
            return false
        }
        try! registry.register(.cycleExtensions, validate: { $0.extensionControls.canCycle }) { controller, origin in
            cyclingOwner = controller
            let event = NSApp.currentEvent
            let holding: NSEvent.ModifierFlags? = origin == .keyboard
                ? (event?.type == .keyDown ? event?.modifierFlags : .command) : nil
            controller.extensionControls.cycle(holding: holding)
        }
        try! registry.register(.releaseNotes, validate: { _ in OrbitReleaseNotes.runningVersionURL() != nil }) { controller, _ in
            guard let url = OrbitReleaseNotes.runningVersionURL(), let context = controller.session.paletteContext else { return }
            controller.hideLibrary()
            controller.session.openTab(url: url, from: context)
        }
        try! registry.register(.manageExtensions, validate: {
            $0.engine.extensionManagement != nil && $0.session.selectedSurface != nil
        }) { controller, _ in
            guard let source = controller.session.selectedSurface, let manager = controller.engine.extensionManagement else { return }
            let generation = source.documentGeneration
            controller.session.performOnSelectedSurface { [weak controller, weak source] surface in
                guard let controller, let source, source === surface, controller.owns(surface),
                      controller.session.selectedSurface === surface, surface.documentGeneration == generation else { return }
                do { try manager.openManagement(on: surface) }
                catch { controller.session.onError?(error) }
            }
        }
        try! registry.register(.addExtension) { controller, _ in
            // Opening the Store is a separate browsing task; preserve the current document.
            guard let context = controller.session.paletteContext else { return }
            controller.hideLibrary()
            controller.session.openTab(url: URL(string: "https://chromewebstore.google.com/")!, from: context)
        }
    }

    static func priority(_ id: BrowserCommandID) -> Int {
        switch id {
        case .newWindow: 0
        case .newIncognitoWindow: 1
        case .manageExtensions: 2
        case .addExtension: 3
        default: 4
        }
    }

    static func detail(_ id: BrowserCommandID) -> String {
        switch id {
        case .newWindow: "⌘N"
        case .newIncognitoWindow: "⇧⌘N"
        case .manageExtensions: uiText("Current profile")
        case .addExtension: uiText("Chrome Web Store")
        default: uiText("Circa action")
        }
    }

    static func aliases(_ id: BrowserCommandID) -> String {
        switch id {
        case .releaseNotes: "What's New|What’s New|See What’s New"
        case .newBoost: "New Boost|Create Boost"
        case .viewBoosts: "View Boosts"
        case .newWindow: "New Window|Nouvelle fenêtre|Ouvrir une nouvelle fenêtre"
        case .newIncognitoWindow: "New Incognito Window|New Private Window|Nouvelle fenêtre privée|Navigation privée"
        case .newQuickWindowWindow: "New Little Circa|New Little Circa Window|Nouveau Little Circa|Nouvelle fenêtre Little Circa"
        case .newSpace: "New Space|Nouvel Espace|Créer un Espace"
        case .addSplitView: "New Split View|Add Split View|Nouvelle vue scindée|Écran partagé|Split screen"
        case .manageExtensions: "Extensions|Manage Extensions|Gérer les extensions|Gestion des extensions"
        case .addExtension: "Add Extension|Ajouter une extension|Chrome Web Store|Boutique extensions"
        case .preferences: "Settings|Preferences|Réglages|Paramètres|Préférences"
        case .viewHistory: "History|View History|Historique"
        case .viewDownloads: "Downloads|View Downloads|Téléchargements"
        case .viewLibrary: "Library|View Library|Bibliothèque"
        case .copyURL: "Copy URL|Copy Link|Copier l'URL|Copier le lien|Copier l’adresse"
        case .refreshThePage: "Reload|Refresh|Recharger|Actualiser"
        case .archiveTab: "Close Tab|Archive Tab|Fermer l'onglet|Fermer l’onglet|Archiver l’onglet"
        case .pinUnpinTab: "Pin Tab|Unpin Tab|Épingler l'onglet|Désépingler l'onglet|Épingler|Désépingler"
        case .showHideSidebar: "Show Sidebar|Hide Sidebar|Toggle Sidebar|Afficher la barre latérale|Masquer la barre latérale"
        case .importFromArc: "Import from Arc|Importer depuis Circa|Import Circa"
        default: ""
        }
    }

    nonisolated static func symbol(_ id: BrowserCommandID) -> String {
        switch id {
        case .newWindow: "macwindow.badge.plus"
        case .newIncognitoWindow: "eyeglasses"
        case .newQuickWindowWindow: "macwindow"
        case .newSpace: "square.grid.2x2"
        case .addSplitView: "rectangle.split.2x1"
        case .manageExtensions: "puzzlepiece.extension"
        case .addExtension: "plus.app"
        case .preferences: "gearshape"
        case .viewHistory: "clock.arrow.circlepath"
        case .viewDownloads: "arrow.down.circle"
        case .viewLibrary: "tray"
        case .copyURL: "link"
        case .refreshThePage: "arrow.clockwise"
        case .archiveTab: "xmark"
        case .pinUnpinTab: "pin"
        case .showHideSidebar: "sidebar.left"
        case .importFromArc: "square.and.arrow.down"
        default: "command"
        }
    }
}
