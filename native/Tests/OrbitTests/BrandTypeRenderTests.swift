import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

/// Opt-in, offscreen snapshots of the same native views used by the product.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_TYPE_RENDER_DIR"] != nil))
@MainActor
struct BrandTypeRenderTests {
    @Test func surfaces() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORBIT_TYPE_RENDER_DIR"]!)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
            let owner = try await environment.makeWindow()
            defer { owner.session.close(); owner.window?.close() }
            let root = try #require(owner.window?.contentView)
            root.layoutSubtreeIfNeeded()
            try capture(owner.sidebar, to: directory.appendingPathComponent("sidebar-\(name).png"))
            let palette = BrowserPaletteView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
            palette.isHidden = false
            palette.render([
                .init(id: "new", title: "New Tab", detail: "Open a new tab", section: .commands,
                      action: .command(.newTab), shortcut: "⌘T"),
                .init(id: "library", title: "Library", detail: "Browse saved items", section: .commands,
                      action: .command(.newTab), shortcut: "⌘L")
            ], selected: 0)
            try capture(palette, to: directory.appendingPathComponent("command-bar-\(name).png"))
            let menu = SidebarCreationMenu(actions: [
                .init(command: .newSpace, title: "New Space", symbol: "plus", shortcut: "⌘N", enabled: true, perform: {}),
                .init(command: .newTab, title: "New Tab", symbol: "plus", shortcut: "⌘T", enabled: true, perform: {})
            ], accent: .defaultSpace)
            try capture(menu.view, to: directory.appendingPathComponent("sidebar-menu-\(name).png"))
            let empty = BrowserLibraryEmptyView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
            empty.configure(symbol: "tray", title: "No Downloads")
            try capture(empty, to: directory.appendingPathComponent("library-empty-\(name).png"))
            let alert = OrbitFrostAlert()
            alert.messageText = "Remove Space?"
            alert.informativeText = "Tabs in this Space will be archived."
            alert.addButton(withTitle: "Cancel")
            let content = try #require(alert.preparedWindow().contentView)
            try capture(content, to: directory.appendingPathComponent("frost-dialog-\(name).png"))
            let editor = OrbitThemeEditorView(state: .init(theme: BrandPalette.spaceGradients[0].theme()))
            try capture(editor, to: directory.appendingPathComponent("theme-editor-\(name).png"))
        }
        NSApp.appearance = nil
    }

    private func capture(_ view: NSView, to url: URL) throws {
        view.appearance = NSApp.appearance
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.display()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.close()
    }
}
