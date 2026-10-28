import Foundation
struct Context { var profileID = 1, spaceID = 2, selectedOccurrenceID = 3 }
struct Capture { let windowID = 1; var surface = 10, document = 1 }
enum Command { case manageExtensions, addExtension }
enum Mode { case newTab, currentTab }
enum Requirement { case application, surface }
enum Origin { case palette }
struct Definition { let requirement = Requirement.surface }
@MainActor final class Session {
    var paletteContext: Context? = Context()
    var capture = Capture()
    var drain: (() -> Void)?
    func waitForPendingCommands() async { let work = drain; drain = nil; work?(); await Task.yield() }
}
@MainActor final class Router {
    var selectedWindowID = 1, hasPendingSelectedWindowCommands = false
    func waitForPendingCommands() async {}
}
@MainActor final class Responder {}
@MainActor final class Window { var firstResponder: Responder? }
@MainActor final class Input { func currentEditor() -> Responder? { nil } }
@MainActor final class View { let input = Input() }
@MainActor final class Owner {
    let id = 1, session = Session()
    var window: Window? = Window()
    func hideLibrary(focus: Bool) {}
}
@MainActor final class Registry {
    let owner: Owner, router = Router()
    var calls: [Capture] = []
    init(owner: Owner) { self.owner = owner }
    func capturePaletteTarget(windowID: Int? = nil) -> Capture? { owner.session.capture }
    func definition(_ id: Command) -> Definition? { Definition() }
    func dispatch(_ id: Command, origin: Origin, target: Capture?, onDelivered: () -> Void) -> Bool {
        calls.append(target!); onDelivered(); return true
    }
}
@MainActor final class Palette {
    var registry: Registry?
    var isPresented = true
    var presentation = 1, inputRevision = 1
    var target: Capture?
    let view = View()
    func finishAccept(ticket: Int, returnFocus: Bool) { isPresented = false }
    func command(owner: Owner, context: Context, id: Command = .manageExtensions,
                 capturedMode: Mode = .newTab, ticket: Int = 1, queryToken: Int = 1) async {
        /* COMMAND CASE */
    }
}
@main struct Test {
    @MainActor static func main() async {
        func run(_ mutate: @escaping (Owner) -> Void) async -> [Capture] {
            let owner = Owner(), palette = Palette()
            // The adapter registry is bound to the exact owner; no global fallback.
            let bound = Registry(owner: owner)
            palette.registry = bound
            let expected = owner.session.paletteContext!
            owner.session.drain = { mutate(owner) }
            await palette.command(owner: owner, context: expected)
            return bound.calls
        }
        let foreignProfile = await run { $0.session.paletteContext?.profileID = 9 }
        precondition(foreignProfile.isEmpty)
        let foreignOccurrence = await run { $0.session.paletteContext?.selectedOccurrenceID = 9 }
        precondition(foreignOccurrence.isEmpty)
        let changedDocument = await run { $0.session.capture.document += 1 }
        precondition(changedDocument.count == 1 && changedDocument[0].document == 2)
        if ProcessInfo.processInfo.environment["ORBIT_REVIEW_REQUIRE_ORIGINAL_DOCUMENT"] == "1" {
            precondition(changedDocument.isEmpty, "REVIEW original document must survive queue drain")
        }
        let replacedSurface = await run { $0.session.capture.surface = 20 }
        precondition(replacedSurface.count == 1 && replacedSurface[0].surface == 20)
        print("REPRODUCED inherited palette authority gap: after queue drain, same occurrence can dispatch to a new document or replacement surface; profile/occurrence changes are refused")
    }
}
