import Foundation
@MainActor protocol BrowserEngineSurface: AnyObject {}
@MainActor protocol BrowserExtensionManagement: AnyObject {
    func openManagement(on surface: any BrowserEngineSurface) throws
}
@MainActor protocol BrowserEngine: AnyObject {
    var extensionManagement: (any BrowserExtensionManagement)? { get }
}
enum BrowserCommandID { case manageExtensions, addExtension, newWindow, other }
func uiText(_ text: String) -> String { text }
@MainActor final class Surface: BrowserEngineSurface { var documentGeneration = 1 }
@MainActor final class Session {
    var paletteContext: Int? = 1
    var selectedSurface: Surface? = Surface()
    var onError: ((Error) -> Void)?
    var pending: ((Surface) -> Void)?
    func performOnSelectedSurface(_ action: @escaping (Surface) -> Void) { pending = action }
    func ready(_ surface: Surface) { let action = pending; pending = nil; action?(surface) }
    func openTab(url: URL, from context: Int) {}
}
@MainActor final class BrowserWindowController<Engine: BrowserEngine> {
    let engine: Engine
    let session = Session()
    var owned = true
    init(_ engine: Engine) { self.engine = engine }
    func owns(_ surface: Surface) -> Bool { owned }
    func submitAddress(_ text: String) {}
    func openTab(url: URL) {}
    func hideLibrary() {}
}
@MainActor final class BrowserCommandRegistry<Controller> {
    var validate: ((Controller) -> Bool)?
    var execute: ((Controller, Int) -> Void)?
    func register(_ id: BrowserCommandID, validate: @escaping (Controller) -> Bool = { _ in true },
                  _ action: @escaping (Controller, Int) -> Void) throws {
        if id == .manageExtensions { self.validate = validate; execute = action }
    }
}
@MainActor final class Manager: BrowserExtensionManagement {
    var calls: [ObjectIdentifier] = []
    func openManagement(on surface: any BrowserEngineSurface) throws { calls.append(ObjectIdentifier(surface)) }
}
@MainActor final class Engine: BrowserEngine {
    var extensionManagement: (any BrowserExtensionManagement)?
    // Deliberately no extension inventory/action service.
}
/* COMMANDS */
@main struct Test {
    @MainActor static func main() {
        let engine = Engine(), manager = Manager()
        let controller = BrowserWindowController(engine)
        let registry = BrowserCommandRegistry<BrowserWindowController<Engine>>()
        BrowserDailyCommands.install(in: registry)
        precondition(!registry.validate!(controller))
        engine.extensionManagement = manager
        precondition(registry.validate!(controller))
        let source = controller.session.selectedSurface!
        registry.execute!(controller, 0)
        precondition(manager.calls.isEmpty) // Readiness defers execution.
        controller.session.ready(source)
        precondition(manager.calls == [ObjectIdentifier(source)])
        func stale(_ mutate: () -> Void, delivered: Surface? = nil) {
            registry.execute!(controller, 0)
            mutate()
            controller.session.ready(delivered ?? source)
            precondition(manager.calls.count == 1)
        }
        stale({ source.documentGeneration += 1 })
        stale({ controller.owned = false }); controller.owned = true
        stale({ controller.session.selectedSurface = Surface() }); controller.session.selectedSurface = source
        stale({}, delivered: Surface())
        controller.session.selectedSurface = nil
        precondition(!registry.validate!(controller))
        engine.extensionManagement = nil
        controller.session.selectedSurface = source
        precondition(!registry.validate!(controller))
        print("PASS actual command: manager-only availability, readiness, exact surface, ownership and document generation")
    }
}
