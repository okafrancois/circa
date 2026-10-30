import AppKit
import BrowserEngine

/// Pointer and Escape gestures share the window's ordered command delivery.
@MainActor
enum BrowserTabErgonomics {
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        registry.registerInputHandler("tab-ergonomics") { [weak registry] owner, event in
            guard let registry, registry.activeScope == .browser, let owner,
                  event.window === owner.window, owner.acceptsCommands else { return false }
            return handle(event, in: owner)
        }
    }

    static func handle<Engine: BrowserEngine>(_ event: NSEvent, in owner: BrowserWindowController<Engine>) -> Bool {
        if event.type == .otherMouseDown, event.buttonNumber == 3 || event.buttonNumber == 4 {
            owner.submitInput { $0.activateAdjacentSpace(offset: event.buttonNumber == 3 ? -1 : 1) }
            return true
        }
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection(BrowserShortcut.commandModifiers).isEmpty,
           !(owner.window?.firstResponder is NSTextView), !owner.library.isPresented,
           owner.pageCommandSurface()?.navigationState.isLoading == true {
            owner.submitInput { $0.session.performOnSelectedSurface { $0.stopLoading() } }
            return true
        }
        guard event.type == .leftMouseDown, let root = owner.window?.contentView,
              let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)) else { return false }
        if hit === owner.reloadButton || hit.isDescendant(of: owner.reloadButton) {
            if event.modifierFlags.contains(.command) {
                owner.submitInput { $0.duplicateSidebarTab() }
                return true
            }
            if event.clickCount == 2, owner.pageCommandSurface()?.navigationState.isLoading == true {
                owner.submitInput { $0.session.performOnSelectedSurface { $0.stopLoading() } }
                return true
            }
        }
        if event.clickCount == 2, event.modifierFlags.intersection(BrowserShortcut.commandModifiers).isEmpty,
           hit === owner.sidebar.page.list {
            owner.sidebar.onNewTab?()
            return true
        }
        return false
    }
}
