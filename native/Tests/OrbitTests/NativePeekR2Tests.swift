import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing
@testable import Orbit

private typealias R2Window = BrowserWindowController<PeekSyntheticEngine>

private enum PeekR2TestError: Error { case timedOut }

@MainActor
private func waitForR2(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw PeekR2TestError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// PEEK-R2: organization triggers, focused-page commands, history, permissions, exit lifetime.
extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativePeekR2Tests {
    private let escape = BrowserShortcut(key: "\u{1b}", modifiers: [])

    private func makeWindow(engine: PeekSyntheticEngine = PeekSyntheticEngine(),
                            source: String = "https://app.example.com/inbox") async throws
        -> (BrowserEnvironment<PeekSyntheticEngine>, R2Window, PeekSyntheticSurface) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment<PeekSyntheticEngine>(engine: engine)
        let controller = try await environment.makeWindow()
        controller.submitAddress(source)
        await controller.session.waitForPendingCommands()
        return (environment, controller, try #require(controller.session.selectedSurface))
    }

    private func makeRegistry(_ controller: R2Window) async throws
        -> (BrowserCommandRegistry<R2Window>, BrowserWindowRouter<R2Window>) {
        let router = BrowserWindowRouter<R2Window>(create: { _ in controller },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        _ = router.newWindow(id: controller.id)
        await router.waitForPendingCommands()
        let registry = try BrowserCommandRegistry(router: router, state: { window in
            var state = window?.commandState ?? BrowserCommandState()
            window?.applyPeekCommandState(to: &state)
            return state
        }, deliver: { window, action in window.performAcceptedCommand(action) })
        BrowserWindowCommands.install(in: registry)
        BrowserPeekCommands.install(in: registry)
        return (registry, router)
    }

    // MARK: ORG-MODEL classification

    @Test("Pinned tabs and Favorites from the organization model open other-site links in Peek; Today tabs do not")
    func organizationTriggers() async throws {
        let (_, controller, tab) = try await makeWindow()
        defer { controller.window?.close() }
        let occurrence = try #require(controller.session.occurrenceID(for: tab))
        #expect(controller.peekSourceClassification(for: occurrence)?.role == .unpinned)
        tab.openNewTarget(URL(string: "https://other.org/today")!)
        await controller.session.waitForPendingCommands()
        #expect(!controller.isPeekPresented)
        controller.session.selectOccurrence(occurrence)
        await controller.session.waitForPendingCommands()

        let tabID = try #require(controller.session.organization?.allTabs.first { $0.occurrenceID == occurrence }?.id)
        controller.session.pinTabs([tabID])
        await controller.session.waitForPendingCommands()
        let pinned = try #require(controller.peekSourceClassification(for: occurrence))
        #expect(pinned.role == .pinned)
        #expect(pinned.homeURL?.host == "app.example.com")
        let peeked = try #require(tab.openNewTarget(URL(string: "https://other.org/story")!))
        #expect(controller.presentedPeekSurface === peeked)
        #expect(controller.peek.presentation?.trigger == .pinnedSourceLeavingSite)
        controller.dismissPeek(animated: false)
        tab.openNewTarget(URL(string: "https://docs.example.com/same-site")!)
        await controller.session.waitForPendingCommands()
        #expect(!controller.isPeekPresented, "same registrable domain")
        controller.session.selectOccurrence(occurrence)
        await controller.session.waitForPendingCommands()

        controller.session.addToFavorites([tabID])
        await controller.session.waitForPendingCommands()
        #expect(controller.peekSourceClassification(for: occurrence)?.role == .favorite)
        let favoritePeek = try #require(tab.openNewTarget(URL(string: "https://third.net/x")!))
        #expect(controller.presentedPeekSurface === favoritePeek)
    }

    // MARK: Focused page

    @Test("Find, zoom and history commands follow the focused page; the find bar sits in the Peek card")
    func focusedPageCommands() async throws {
        let (_, controller, tab) = try await makeWindow()
        defer { controller.window?.close() }
        let (registry, router) = try await makeRegistry(controller)
        defer { _ = router }
        let peeked = try #require(tab.openNewTarget(URL(string: "https://other.org/one")!, modifiers: [.shift]))
        peeked.clickLink(to: URL(string: "https://other.org/two")!)
        #expect(controller.pageCommandSurface() === peeked)

        #expect(registry.dispatch(.zoomIn, origin: .keyboard))
        await router.waitForPendingCommands()
        await controller.session.waitForPendingCommands()
        #expect(peeked.pageZoom > 1 && tab.pageZoom == 1)
        #expect(controller.zoomControl.title == "110%")

        #expect(registry.dispatch(.find, origin: .keyboard))
        await router.waitForPendingCommands()
        await controller.session.waitForPendingCommands()
        #expect(controller.findSession.state(for: peeked)?.isVisible == true)
        #expect(controller.findSession.state(for: tab)?.isVisible != true)
        #expect(controller.findBar.superview === controller.peekOverlay, "the find bar is not covered by the Peek")
        #expect(!controller.findBar.isHidden)
        // Typing in the find bar keeps the Peek as the searched page; Esc closes the find bar first.
        #expect(controller.isTextFieldEditing)
        #expect(controller.pageCommandSurface() === peeked)
        #expect(registry.activeScope == .peek, "the find bar disables Esc, not the Peek scope")
        #expect(registry.resolve(escape) == nil)

        #expect(registry.dispatch(.goBack, origin: .keyboard))
        await router.waitForPendingCommands()
        #expect(peeked.currentURL?.path == "/one")

        // Focus in the tab below: page commands target the tab.
        controller.window?.makeFirstResponder(tab.documentView)
        #expect(controller.pageCommandSurface() === tab)
        #expect(registry.dispatch(.zoomIn, origin: .keyboard))
        await router.waitForPendingCommands()
        await controller.session.waitForPendingCommands()
        #expect(tab.pageZoom > 1)
        controller.window?.makeFirstResponder(peeked.documentView)
        #expect(controller.pageCommandSurface() === peeked)
        #expect(registry.resolve(escape) == .dismissPeek)

        controller.dismissPeek(animated: false)
        #expect(controller.pageCommandSurface() === tab)
        #expect(controller.findBar.superview === controller.peekOverlay.superview, "back over the content card")
        #expect(controller.findSession.state(for: peeked) == nil)
    }

    // MARK: History

    @Test("Peek visits are recorded to history in persistent profiles and never in private ones")
    func peekHistory() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-peek-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = PeekSyntheticEngine()
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: { engine.profile(for: $0) })
        let model = BrowserStore()
        let persistent = await model.createProfile(name: "Persistent synthetic profile")
        let privateProfile = await model.createProfile(name: "Private synthetic profile")
        engine.persistentProfiles = [persistent]
        var windows: [R2Window] = []
        defer { for window in windows { window.window?.close() } }
        for profile in [persistent, privateProfile] {
            let space = try await model.createSpace(name: "Synthetic", profileID: profile)
            let controller = BrowserWindowController(id: UUID(), store: model, spaceID: space, engine: engine,
                                                     history: recorder, onClose: {}, onActivate: {})
            windows.append(controller)
            await controller.session.waitForPendingCommands()
            controller.submitAddress("https://app.example.com/\(profile == persistent ? "persistent" : "private")")
            await controller.session.waitForPendingCommands()
            let tab = try #require(controller.session.selectedSurface)
            let peeked = try #require(tab.openNewTarget(URL(string: "https://other.org/peek-visit")!, modifiers: [.shift]))
            peeked.clickLink(to: URL(string: "https://other.org/peek-next")!)
        }
        await recorder.flush()
        let visits = try await recorder.visits(for: persistent).map(\.url.path)
        #expect(visits.contains("/peek-visit") && visits.contains("/peek-next"))
        #expect(try await recorder.visits(for: privateProfile).isEmpty)
        try await recorder.close()
    }

    // MARK: Permissions

    @Test("Permission requests of the Peek document are decided by the window's site controls")
    func peekPermissions() async throws {
        let (environment, controller, tab) = try await makeWindow()
        defer { controller.window?.close() }
        let peeked = try #require(tab.openNewTarget(URL(string: "https://other.org/call")!, modifiers: [.shift]))
        let origin = try #require(BrowserSiteOrigin(requestOrigin: "https://other.org"))
        let request = BrowserPermissionRequest(kind: .camera, origin: origin.value, isMainFrame: true)
        var prompts: [String] = []
        controller.siteControls.permissionPrompt = { origin, _ in
            prompts.append(origin.value)
            return .allowOnce
        }
        #expect(await peeked.requestPermission(request) == .grantOnce)
        #expect(prompts == [origin.value], "the Peek document reached the prompt, it was not refused outright")
        controller.siteControls.permissionPrompt = { _, _ in .dismiss }
        try await controller.siteControls.policy.store.set(.allow, for: [.camera], origin: origin, profileID: peeked.profileID)
        #expect(await peeked.requestPermission(request) == .grant)
        #expect(await peeked.requestPermission(BrowserPermissionRequest(kind: .camera, origin: "https://app.example.com",
                                                                        isMainFrame: true)) == .deny, "another origin")

        // A pending prompt of the Peek closes with it.
        var resume: CheckedContinuation<BrowserSitePermissionChoice, Never>?
        controller.siteControls.permissionPrompt = { _, _ in await withCheckedContinuation { resume = $0 } }
        try await controller.siteControls.policy.store.set(.ask, for: [.microphone], origin: origin, profileID: peeked.profileID)
        let pending = Task { await peeked.requestPermission(BrowserPermissionRequest(kind: .microphone, origin: origin.value, isMainFrame: true)) }
        try await waitForR2 { controller.siteControls.hasPendingPermission(for: peeked) }
        controller.dismissPeek(animated: false)
        resume?.resume(returning: .alwaysAllow)
        #expect(await pending.value == .deny)
        #expect(await peeked.requestPermission(request) == .deny, "a closed Peek has no permissions")

        // A Peek document of another profile is never attributed to this window.
        let foreign = environment.engine.makeSurface(profileID: ProfileID(), delegate: controller.peek)
        #expect(controller.peek.claim(foreign))
        controller.peek.present(foreign, source: tab, sourceOccurrenceID: controller.session.occurrenceID(for: tab),
                                trigger: .command, animated: false)
        foreign.navigate(to: URL(string: "https://other.org/foreign")!)
        #expect(await foreign.requestPermission(request) == .deny)
    }

    // MARK: Exit lifetime

    @Test("A closed Peek stays alive and inert during its exit animation, then is destroyed")
    func destructionAfterCloseAnimation() async throws {
        let (_, controller, tab) = try await makeWindow()
        defer { controller.window?.close() }
        let peeked = try #require(tab.openNewTarget(URL(string: "https://other.org/a")!, modifiers: [.shift]))
        // The hidden test window disables animation in `dismissPeek`; ask the controller directly.
        controller.peek.dismiss(animated: true, remember: true)
        #expect(controller.peekOverlay.isExiting)
        #expect(!peeked.isDisposed, "the card still shows its page while it fades out")
        peeked.clickLink(to: URL(string: "https://other.org/b")!)
        #expect(peeked.currentURL?.path == "/a", "a closing Peek starts no navigation")
        #expect(peeked.openNewTarget(URL(string: "https://other.org/popup")!) == nil, "nor a popup")
        try await waitForR2 { peeked.isDisposed }
        #expect(!controller.peekOverlay.isExiting && controller.peekOverlay.isHidden)
        #expect(controller.peek.container.surfaces.isEmpty)
    }
}
}
