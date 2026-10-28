import AppKit
import BrowserEngine

@MainActor
enum BrowserSwitcherCommands {
    static func install<Engine: BrowserEngine>(in registry: BrowserCommandRegistry<BrowserWindowController<Engine>>) {
        registry.registerScopeProvider("switcher", priority: 300) { controller in
            controller?.tabSwitcher.model.isActive == true ? .switcher : nil
        }
        registry.registerInputHandler("switcher") { [weak registry] controller, event in
            guard let controller, controller.tabSwitcher.model.isActive,
                  event.window == nil || event.window === controller.window else { return false }
            if controller.tabSwitcher.handle(event) { return true }
            if event.type == .keyDown {
                if let id = registry?.resolve(event) { _ = registry?.dispatch(id, origin: .keyboard) }
                return true // A disabled mode binding must not leak into the page either.
            }
            return false
        }
        try! registry.register(.tabSwitcherForward) { controller, _ in controller.tabSwitcher.cycle(holding: NSApp.currentEvent?.modifierFlags) }
        try! registry.register(.tabSwitcherBackward) { controller, _ in controller.tabSwitcher.cycle(backward: true, holding: NSApp.currentEvent?.modifierFlags) }
        try! registry.register(.closeSwitcherTab, validate: { $0.tabSwitcher.model.isActive }) { controller, _ in
            controller.tabSwitcher.closeHighlighted()
        }
    }
}
