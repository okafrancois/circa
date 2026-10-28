import AppKit
import BrowserCore
import Testing
@testable import BrowserShell
@testable import Orbit

extension NativeWebKitTests {
@Suite("Independent Library admission review", .serialized)
@MainActor
struct IndependentLibraryAdmissionReviewTests {
    private typealias Controller = BrowserWindowController<SiteSyntheticEngine>
    private func fixture(onInput: ((@escaping @MainActor (Controller) -> Void) -> Void)? = nil) async throws
        -> (Controller, BrowserStore, SpaceID, SpaceID) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic admission review")
        let first = try await store.createSpace(name: "First", profileID: profile)
        let target = try await store.createSpace(name: "Target", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: first)
        let controller = Controller(id: UUID(), store: store, spaceID: first, engine: SiteSyntheticEngine(),
            restoringWindowID: window, onInput: onInput, onClose: {}, onActivate: {})
        await controller.session.waitForPendingCommands()
        return (controller, store, first, target)
    }

    @Test("Concurrent admission and revocation have one irreversible winner")
    func oneShotRace() {
        for _ in 0..<100 {
            let token = CatalogSelectionAdmission()
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                if index.isMultiple(of: 2) { token.revoke() } else { _ = token.admit() }
            }
            #expect(token.state != .pending)
            let settled = token.state
            #expect(!token.revoke() && !token.admit() && token.state == settled)
        }
    }

    @Test("Presentation and profile replacement revoke pending intent but equal assignments retain it",
          arguments: ["presentation", "profile"])
    func projectionReplacement(kind: String) {
        let presentation = BrowserLibraryPresentation()
        presentation.displayedProfileID = ProfileID()
        let (_, token) = presentation.beginSelection()
        let ticket = presentation.presentationID
        let profile = presentation.displayedProfileID
        presentation.presentationID = ticket
        presentation.displayedProfileID = profile
        #expect(token.state == .pending)
        if kind == "presentation" { presentation.presentationID = UUID() }
        else { presentation.displayedProfileID = ProfileID() }
        #expect(token.state == .revoked)
    }

    @Test("A dropped outer action and stale completion cannot consume the latest actual row intent")
    func actualOuterReplacement() async throws {
        var actions: [@MainActor (Controller) -> Void] = []
        let (controller, _, first, target) = try await fixture(onInput: { actions.append($0) })
        defer { controller.session.close(); controller.window?.close() }
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        let view = controller.library.spacesView
        let catalog = try #require(controller.session.catalog)
        let ticket = controller.library.presentationID
        // The first action is deliberately dropped by the outer router.
        view.onOpen?(first, catalog, ticket)
        actions.removeAll()
        view.onOpen?(first, catalog, ticket)
        view.onOpen?(target, catalog, ticket)
        #expect(actions.count == 2)
        actions[0](controller)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.activeSpaceID == first && controller.library.isPresented)
        actions[1](controller)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.activeSpaceID == target && !controller.library.isPresented)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Rejected session and actor preconditions revoke their token without mutation",
          arguments: ["missing", "callback", "catalog", "source", "closed"])
    func rejectedPreconditions(kind: String) async throws {
        let (controller, store, first, target) = try await fixture()
        defer { controller.session.close(); controller.window?.close() }
        let catalog = try #require(controller.session.catalog)
        if kind == "catalog" { try await store.renameSpace(target, name: "Changed") }
        if kind == "source" {
            try await store.activateSpace(target, in: try #require(controller.session.snapshot?.id))
        }
        if kind == "closed" { controller.session.retireForApplicationTermination() }
        let token = CatalogSelectionAdmission()
        var accepted: Bool?
        controller.session.activateCatalogSpace(kind == "missing" ? SpaceID() : target,
            catalog: catalog, admission: token, isCurrent: { kind != "callback" },
            completion: { accepted = $0 })
        await controller.session.waitForPendingCommands()
        #expect(accepted == false && token.state == .revoked)
        let windows = await store.sessionDocument().windows
        #expect(windows.first?.activeSpaceID == (kind == "source" ? target : first))
    }
}
}
