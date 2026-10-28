import BrowserEngine

/// Commands of the window shell (Themes & motion lot), bound into the Commands lot's registry.
enum OrbitShellCommands {
    @MainActor
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        // View › Show/Hide Sidebar, ⌘S (catalog M-33): pin or hide the sidebar.
        try! registry.register(.showHideSidebar) { controller, _ in controller.toggleSidebar() }
    }
}
