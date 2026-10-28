import Foundation
@MainActor protocol BrowserExtensionManagement: AnyObject {
    func openManagement(on surface: Surface) throws
}
@MainActor final class Surface {
    var findDocumentGeneration: UInt64 = 4
    let profileID: Int
    init(profileID: Int) { self.profileID = profileID }
}
@MainActor final class Engine { var extensionManagement: (any BrowserExtensionManagement)? }
@MainActor final class Owner {
    let engine = Engine()
    var isPreparingForTermination = false
    var target: Surface?
    func isSitePermissionTarget(_ surface: Surface) -> Bool { target === surface }
}
@MainActor class NSView {}
@MainActor final class SiteControlButton: NSView {
    let press: () -> Void
    init(_ title: String, identifier: String, _ action: @escaping () -> Void) { press = action }
}
@MainActor final class Panel { func close() {} }
func siteText(_ key: String, _ fallback: String) -> String { fallback }
@MainActor final class Manager: BrowserExtensionManagement {
    var calls: [Surface] = []
    func openManagement(on surface: Surface) throws { calls.append(surface) }
}
@MainActor final class Controls {
    weak var owner: Owner?
    let panel = Panel()
    var epoch: UInt64 = 1
    init(owner: Owner) { self.owner = owner }
    func showMessage(_ text: String) {}
    /* CURRENT */
    func rows(surface: Surface) -> [NSView] {
        let generation = surface.findDocumentGeneration, epoch = self.epoch
        /* VALID */
        var rows: [NSView] = []
        /* MANAGER */
        return rows
    }
}
@main struct Test {
    @MainActor static func main() {
        let owner = Owner(), manager = Manager(), source = Surface(profileID: 1)
        owner.target = source
        let controls = Controls(owner: owner)
        precondition(controls.rows(surface: source).isEmpty)
        owner.engine.extensionManagement = manager
        func button() -> SiteControlButton { controls.rows(surface: source).first! as! SiteControlButton }
        button().press()
        precondition(manager.calls.count == 1 && manager.calls[0] === source)
        let document = button(); source.findDocumentGeneration += 1; document.press()
        let selection = button(); controls.epoch += 2; selection.press() // A -> B -> A never revives.
        let foreign = button(); owner.target = Surface(profileID: 2); foreign.press(); owner.target = source
        let shutdown = button(); owner.isPreparingForTermination = true; shutdown.press()
        owner.isPreparingForTermination = false
        precondition(manager.calls.count == 1)
        let detached = button(); owner.target = nil; detached.press()
        precondition(manager.calls.count == 1)
        print("PASS independent actual site-control manager row/current/valid bodies: manager-only, document, selection epoch, foreign profile surface, termination, detached target")
    }
}
