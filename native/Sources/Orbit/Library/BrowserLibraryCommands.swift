import BrowserEngine

@MainActor
enum BrowserLibraryCommands {
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        let pageCommands: [BrowserCommandID] = [.find, .findNext, .findPrevious, .zoomIn, .zoomOut, .zoomToActualSize, .copyURL, .stopLoading]
        for id in pageCommands {
            registry.registerPrerequisite(id) { controller, _ in
                guard let controller else { return true }
                return !controller.library.isPresented || controller.isPeekPresented
            }
        }
        registry.registerPrerequisite(.archiveTab) { controller, state in
            guard let controller else { return true }
            return state.hasPendingCommands || controller.library.isPresented || controller.isPeekPresented || controller.session.selectedSurface != nil
        }
        try! registry.register(.viewLibrary) { controller, _ in
            if controller.library.isPresented { controller.hideLibrary() }
            else { controller.showLibrary() }
        }
        try! registry.register(.viewMedia) { controller, _ in controller.showLibrary(.media) }
        try! registry.register(.viewHistory) { controller, _ in controller.showLibrary(.history) }
        try! registry.register(.viewDownloads) { controller, _ in controller.showLibrary(.downloads) }
    }
}
