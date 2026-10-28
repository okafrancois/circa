import BrowserEngine

@MainActor
enum BrowserArchiveCommands {
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        try! registry.register(.restoreLastClosedTab) { controller, _ in controller.session.restoreMostRecentArchivedTab() }
        try! registry.register(.viewArchive) { controller, _ in controller.showArchive() }
        try! registry.register(.clearArchive) { controller, _ in controller.confirmClearArchive() }
        try! registry.register(.clearUnpinnedTabs) { controller, _ in controller.clearTodayFromArchiveCommand() }
    }
}
