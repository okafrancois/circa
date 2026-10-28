import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing
@testable import Orbit

private typealias PeekEnvironment = BrowserEnvironment<PeekSyntheticEngine>
private typealias PeekWindow = BrowserWindowController<PeekSyntheticEngine>

private enum NativePeekTestError: Error { case timedOut }

@MainActor
private func waitForPeek(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw NativePeekTestError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// A hidden window of the synthetic engine whose selected tab shows `source`.
@MainActor
private func makePeekWindow(source: String = "https://app.example.com/inbox") async throws
    -> (PeekEnvironment, PeekWindow, PeekSyntheticSurface) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let environment = PeekEnvironment(engine: PeekSyntheticEngine())
    let controller = try await environment.makeWindow()
    controller.submitAddress(source)
    await controller.session.waitForPendingCommands()
    let tab = try #require(controller.session.selectedSurface)
    #expect(tab.currentURL?.absoluteString == source)
    return (environment, controller, tab)
}

@MainActor
private func makeRegistry(_ environment: PeekEnvironment, _ controller: PeekWindow)
    async throws -> (BrowserCommandRegistry<PeekWindow>, BrowserWindowRouter<PeekWindow>) {
    let router = BrowserWindowRouter<PeekWindow>(create: { _ in controller },
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

/// A receiver standing in for SPLIT: accepts or leaves the transfer pending.
@MainActor
private final class SplitReceiver {
    let container = BrowserSurfaceContainer<PeekSyntheticSurface>()
    var accepts = true
    func receive(_ transfer: BrowserSurfaceTransfer<PeekSyntheticSurface>) -> Bool {
        guard accepts else { return false }
        return container.accept(transfer) { _ in }
    }
}

private let escape = BrowserShortcut(key: "\u{1b}", modifiers: [])

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativePeekTests {
    // MARK: Routing

    @Test("Shift-click on a new target opens the engine-created surface in Peek, never as a tab")
    func shiftClickOpensPeek() async throws {
        let (_, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        let destination = URL(string: "https://app.example.com/thread/42")!
        let child = try #require(tab.openNewTarget(destination, modifiers: [.shift]))
        await controller.session.waitForPendingCommands()

        #expect(controller.isPeekPresented)
        #expect(controller.presentedPeekSurface === child)
        #expect(controller.peek.presentation?.trigger == .shiftClick)
        #expect(child.delegate === controller.peek)
        #expect(child.placement == BrowserSurfacePlacement(container: .peek, windowID: controller.session.snapshot?.id))
        #expect(child.requestedURLs == [destination], "the engine loads the original request once")
        #expect(controller.session.ownedSurfaces.count == 1, "the Peek is not a tab")
        #expect(child.hostView.isDescendant(of: controller.peekOverlay))
        #expect(controller.peekOverlay.isShown && !controller.peekOverlay.isHidden)
        #expect(controller.peekOverlay.displayedAddress == "app.example.com/thread/42")
        #expect(controller.window?.firstResponder === child.documentView, "focus enters the Peek document")
    }

    @Test("⌘-, ⌥⌘- and middle-clicked targets keep their tab behaviour")
    func otherClicksAreNotRouted() async throws {
        let (_, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        controller.peek.sourceClassifier = { _ in (.pinned, nil) }
        tab.openNewTarget(URL(string: "https://other.org/a")!, modifiers: [.command])
        tab.openNewTarget(URL(string: "https://other.org/b")!, modifiers: [.command, .option])
        tab.openNewTarget(URL(string: "https://other.org/c")!, buttonNumber: 2)
        await controller.session.waitForPendingCommands()
        #expect(!controller.isPeekPresented)
        #expect(controller.session.ownedSurfaces.count == 4)
    }

    @Test("Pinned and Favorite tabs open other-site targets in Peek; same-site and Today targets become tabs")
    func pinnedSourceRouting() async throws {
        let (_, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        tab.openNewTarget(URL(string: "https://other.org/unclassified")!)
        await controller.session.waitForPendingCommands()
        #expect(!controller.isPeekPresented, "a Today tab never routes automatically")

        controller.peek.sourceClassifier = { _ in (.pinned, URL(string: "https://app.example.com/")) }
        tab.openNewTarget(URL(string: "https://docs.example.com/same-site")!)
        await controller.session.waitForPendingCommands()
        #expect(!controller.isPeekPresented)

        let peeked = try #require(tab.openNewTarget(URL(string: "https://other.org/story")!))
        #expect(controller.presentedPeekSurface === peeked)
        #expect(controller.peek.presentation?.trigger == .pinnedSourceLeavingSite)

        controller.peek.settings.opensPinnedLinksInPeek = false
        controller.dismissPeek(animated: false)
        tab.openNewTarget(URL(string: "https://other.org/setting-off")!)
        await controller.session.waitForPendingCommands()
        #expect(!controller.isPeekPresented)
        #expect(controller.session.ownedSurfaces.count == 4)
    }

    // MARK: Promotion

    @Test("Open in tab moves the live Peek document into a selected tab without reloading it")
    func promotionWithoutReload() async throws {
        let (_, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        let peeked = try #require(tab.openNewTarget(URL(string: "https://other.org/form")!, modifiers: [.shift]))
        peeked.documentState = "unsaved draft"
        let generation = peeked.documentGeneration
        let requests = peeked.requestedURLs

        let adoption = try #require(controller.promotePeekToTab())
        #expect(peeked.delegate === controller, "owner and delegate move in the same turn")
        #expect(!controller.isPeekPresented)
        let occurrence = try #require(await adoption.value)
        await controller.session.waitForPendingCommands()

        #expect(controller.session.selectedSurface === peeked)
        #expect(controller.session.occurrenceID(for: peeked) == occurrence)
        #expect(peeked.placement == .tab(windowID: try #require(controller.session.snapshot?.id), occurrenceID: occurrence))
        #expect(peeked.requestedURLs == requests, "no reload, no replay")
        #expect(peeked.documentGeneration == generation)
        #expect(peeked.documentState == "unsaved draft")
        #expect(!peeked.isDisposed)
        #expect(controller.peek.container.surfaces.isEmpty)
        #expect(peeked.hostView.isDescendant(of: controller.contentCard))
        #expect(controller.session.snapshot?.tabs.count == 2)
        #expect(controller.window?.firstResponder === peeked.documentView)

        // The promoted tab is a normal tab: its links navigate in place, the window answers policy.
        peeked.clickLink(to: URL(string: "https://other.org/next")!)
        #expect(peeked.currentURL?.path == "/next")
        #expect(controller.session.selectedSurface === peeked)
    }

    @Test("⌘O promotes the Peek through the registry")
    func commandPromotion() async throws {
        let (environment, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        let (registry, router) = try await makeRegistry(environment, controller)
        defer { _ = router }
        #expect(!registry.isEnabled(.openQuickWindowOrPeekIn))
        let peeked = try #require(tab.openNewTarget(URL(string: "https://other.org/x")!, modifiers: [.shift]))
        #expect(registry.resolve(BrowserShortcut(key: "o", modifiers: [.command])) == .openQuickWindowOrPeekIn)
        #expect(registry.dispatch(.openQuickWindowOrPeekIn, origin: .keyboard))
        await router.waitForPendingCommands()
        await controller.session.waitForPendingCommands()
        #expect(controller.session.selectedSurface === peeked)
        #expect(!controller.isPeekPresented)
    }

    // MARK: Failure paths: the document survives

    @Test("A Split hand-off that declines leaves the live document in Peek, beyond the current turn")
    func declinedSplitKeepsDocument() async throws {
        let (_, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        let peeked = try #require(tab.openNewTarget(URL(string: "https://other.org/a")!, modifiers: [.shift]))
        peeked.documentState = "draft"
        controller.peek.splitHandoff = nil // Exercise an absent receiver after SPLIT is installed by default.
        controller.peek.refreshToolbar()
        #expect(!controller.openPeekInSplit(), "no SPLIT handler for this failure scenario")
        #expect(!controller.peekOverlay.toolbar.splitButton.isEnabled)

        let receiver = SplitReceiver()
        receiver.accepts = false
        controller.peek.splitHandoff = { transfer in
            guard receiver.receive(transfer) else { return nil }
            // This receiver records in a feature container, so it has no window occurrence.
            return Task { nil }
        }
        #expect(!controller.openPeekInSplit())
        // CONTRACT-R2 returns a declined transfer in the same turn; a later turn cannot dispose it.
        await Task.yield()
        #expect(!peeked.isDisposed)
        #expect(controller.presentedPeekSurface === peeked)
        #expect(controller.peek.owns(peeked))
        #expect(peeked.delegate === controller.peek)
        #expect(peeked.documentState == "draft")

        receiver.accepts = true
        #expect(controller.openPeekInSplit())
        #expect(!controller.isPeekPresented)
        #expect(receiver.container.owns(peeked))
        await Task.yield()
        #expect(!peeked.isDisposed)
        #expect(peeked.documentState == "draft")
    }

    @Test("A promotion refused synchronously leaves the live document in Peek")
    func refusedPromotionKeepsDocument() async throws {
        let (environment, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        // A Peek document of another profile cannot become a tab of this Space.
        let foreign = environment.engine.makeSurface(profileID: ProfileID(), delegate: controller.peek)
        #expect(controller.peek.claim(foreign))
        controller.peek.present(foreign, source: tab, sourceOccurrenceID: controller.session.occurrenceID(for: tab),
                                trigger: .command, animated: false)
        foreign.navigate(to: URL(string: "https://other.org/foreign")!)
        foreign.documentState = "draft"

        #expect(controller.promotePeekToTab() == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!foreign.isDisposed)
        #expect(controller.presentedPeekSurface === foreign)
        #expect(foreign.delegate === controller.peek)
        #expect(foreign.documentState == "draft")
        #expect(controller.session.ownedSurfaces.count == 1)
    }

    @Test("A promotion whose adoption fails after acceptance keeps the document (CONTRACT-R2)")
    func failedAdoptionKeepsDocument() async throws {
        let (environment, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        let peeked = try #require(tab.openNewTarget(URL(string: "https://other.org/a")!, modifiers: [.shift]))
        let otherProfile = await environment.store.createProfile(name: "Other")
        let otherSpace = try await environment.store.createSpace(name: "Other", profileID: otherProfile)
        // The Space switch is queued: acceptance still sees this profile, adoption does not.
        controller.session.activateSpace(otherSpace)
        let promotion = try #require(controller.promotePeekToTab())
        #expect(await promotion.value == nil)
        await controller.session.waitForPendingCommands()
        // CONTRACT-R2: the live document returns to Peek, rebound and shown again.
        #expect(!peeked.isDisposed)
        #expect(controller.peek.owns(peeked))
        #expect(peeked.delegate === controller.peek)
        try await Task.sleep(for: .milliseconds(20))
        #expect(controller.presentedPeekSurface === peeked)
        #expect(!controller.session.ownedSurfaces.contains { $0 === peeked })
    }

    // MARK: Dismissal

    @Test("Esc, ⌘W, the close button and a click outside close the Peek and dispose its document")
    func dismissal() async throws {
        let (environment, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        let (registry, router) = try await makeRegistry(environment, controller)
        defer { _ = router }
        func open(_ path: String) throws -> PeekSyntheticSurface {
            try #require(tab.openNewTarget(URL(string: "https://other.org/\(path)")!, modifiers: [.shift]))
        }
        #expect(registry.activeScope == .browser)
        #expect(registry.resolve(escape) == nil, "Esc is free without a Peek")

        let first = try open("esc")
        #expect(registry.activeScope == .peek)
        #expect(registry.isEnabled(.dismissPeek))
        #expect(registry.resolve(escape) == .dismissPeek)
        #expect(registry.dispatch(.dismissPeek, origin: .keyboard))
        await router.waitForPendingCommands()
        #expect(first.isDisposed && !controller.isPeekPresented)
        #expect(controller.window?.firstResponder === tab.documentView, "focus returns to the tab")

        let second = try open("cmd-w")
        #expect(registry.resolve(BrowserShortcut(key: "w", modifiers: [.command])) == .archiveTab)
        #expect(registry.dispatch(.archiveTab, origin: .keyboard))
        await router.waitForPendingCommands()
        await controller.session.waitForPendingCommands()
        #expect(second.isDisposed)
        #expect(controller.session.selectedSurface === tab, "⌘W closes the Peek, not the tab under it")

        let third = try open("close-button")
        controller.peekOverlay.toolbar.closeButton.performClick(nil)
        #expect(third.isDisposed)

        let fourth = try open("outside")
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let overlay = controller.peekOverlay
        let corner = NSPoint(x: overlay.frame.minX + 4, y: overlay.frame.minY + 4)
        let center = NSPoint(x: overlay.frame.midX, y: overlay.frame.midY)
        #expect(overlay.hitTest(corner) === overlay)
        #expect(overlay.hitTest(center).map { $0 !== overlay && $0.isDescendant(of: overlay) } == true)
        overlay.onClickOutside?()
        #expect(fourth.isDisposed)
        #expect(overlay.hitTest(center) == nil, "a closed Peek lets clicks through")

        let fifth = try open("window-close")
        fifth.requestClose()
        #expect(fifth.isDisposed)

        let sixth = try open("address")
        controller.window?.makeFirstResponder(controller.addressControl)
        let editor = try #require(controller.addressControl.currentEditor())
        NotificationCenter.default.post(name: NSControl.textDidBeginEditingNotification, object: controller.addressControl)
        #expect(sixth.isDisposed, "the command bar replaces the Peek")
        #expect(controller.window?.firstResponder === editor, "typing in the address field keeps its focus")
        #expect(controller.session.ownedSurfaces.count == 1)
    }

    @Test("Selecting another tab or Space closes the Peek; closing the window disposes it")
    func contextChanges() async throws {
        let (_, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        let first = try #require(tab.openNewTarget(URL(string: "https://other.org/a")!, modifiers: [.shift]))
        controller.openTab(url: URL(string: "https://app.example.com/second")!)
        await controller.session.waitForPendingCommands()
        #expect(first.isDisposed && !controller.isPeekPresented)

        let selected = try #require(controller.session.selectedSurface)
        let second = try #require(selected.openNewTarget(URL(string: "https://other.org/b")!, modifiers: [.shift]))
        controller.window?.close()
        #expect(second.isDisposed)
    }

    // MARK: Commands inside Peek

    @Test("While a Peek is shown, back, forward and reload act on the Peek document")
    func pageCommandsTargetPeek() async throws {
        let (environment, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        let (registry, router) = try await makeRegistry(environment, controller)
        defer { _ = router }
        let peeked = try #require(tab.openNewTarget(URL(string: "https://other.org/one")!, modifiers: [.shift]))
        peeked.clickLink(to: URL(string: "https://other.org/two")!)
        #expect(controller.peekOverlay.displayedAddress == "other.org/two")
        #expect(registry.isEnabled(.goBack))
        #expect(registry.dispatch(.goBack, origin: .keyboard))
        await router.waitForPendingCommands()
        #expect(peeked.currentURL?.path == "/one")
        #expect(tab.currentURL?.path == "/inbox")
        #expect(registry.dispatch(.goForward, origin: .keyboard))
        await router.waitForPendingCommands()
        #expect(peeked.currentURL?.path == "/two")
        let tabLoads = tab.requestedURLs.count
        #expect(registry.dispatch(.refreshThePage, origin: .keyboard))
        await router.waitForPendingCommands()
        #expect(peeked.requestedURLs.last?.path == "/two")
        #expect(tab.requestedURLs.count == tabLoads)
    }

    @Test("⇧⌘T reopens a closed Peek over the same tab")
    func reopenClosedPeek() async throws {
        let (environment, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        let (registry, router) = try await makeRegistry(environment, controller)
        defer { _ = router }
        let first = try #require(tab.openNewTarget(URL(string: "https://other.org/article")!, modifiers: [.shift]))
        controller.dismissPeek(animated: false)
        #expect(first.isDisposed)
        #expect(controller.canReopenPeek)
        #expect(registry.isEnabled(.restoreLastClosedTab))
        #expect(registry.dispatch(.restoreLastClosedTab, origin: .keyboard))
        await router.waitForPendingCommands()
        await controller.session.waitForPendingCommands()
        let reopened = try #require(controller.presentedPeekSurface)
        #expect(reopened !== first)
        #expect(reopened.currentURL?.path == "/article")
        #expect(!controller.canReopenPeek)
        controller.dismissPeek(animated: false)
        controller.openTab(url: URL(string: "https://app.example.com/other")!)
        await controller.session.waitForPendingCommands()
        #expect(!controller.canReopenPeek, "the closed Peek belongs to the tab it was opened from")
    }

    // MARK: Attribution

    @Test("Downloads from a Peek belong to its window and source tab")
    func downloadsAttributedToSource() async throws {
        let (_, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        controller.downloads.destinationProvider = { _, _ in nil }
        let peeked = try #require(tab.openNewTarget(URL(string: "https://other.org/report")!, modifiers: [.shift]))
        let download = peeked.startDownload(named: "report.pdf")
        #expect(!download.isCancelled)
        let snapshot = try #require(controller.downloads.snapshots(profileID: tab.profileID).first)
        #expect(snapshot.owner == BrowserDownloadOwner(profileID: tab.profileID, sourceWindowID: controller.session.snapshot?.id,
                                                       sourceOccurrenceID: controller.session.occurrenceID(for: tab)))
        #expect(controller.isPeekPresented, "a Peek that rendered stays open")
    }

    @Test("New targets of the Peek document become tabs next to its source; ⌘-click keeps the Peek")
    func popupsFromPeek() async throws {
        let (_, controller, tab) = try await makePeekWindow()
        defer { controller.window?.close() }
        let peeked = try #require(tab.openNewTarget(URL(string: "https://other.org/list")!, modifiers: [.shift]))
        let background = try #require(peeked.openNewTarget(URL(string: "https://other.org/item")!, modifiers: [.command]))
        await controller.session.waitForPendingCommands()
        #expect(controller.session.occurrenceID(for: background) != nil)
        #expect(background.delegate === controller)
        #expect(controller.presentedPeekSurface === peeked, "a background tab keeps the Peek")
        #expect(controller.session.selectedSurface === tab)

        let shifted = try #require(peeked.openNewTarget(URL(string: "https://other.org/nested")!, modifiers: [.shift]))
        try await waitForPeek { controller.session.selectedSurface === shifted }
        #expect(controller.session.occurrenceID(for: shifted) != nil, "a Peek never opens a Peek")
        #expect(!controller.isPeekPresented, "a foreground tab replaces the Peek")
        #expect(peeked.isDisposed)
    }

    // MARK: Appearance

    @Test("Peek fills the panel without an internal toolbar and keeps its controls outside the page")
    func overlayGeometry() {
        let overlay = BrowserPeekOverlayView()
        overlay.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let page = NSView()
        overlay.show(page, animated: false)
        overlay.layoutSubtreeIfNeeded()
        #expect(overlay.cardFrame == NSRect(x: 80, y: 12, width: 640, height: 576))
        #expect(!overlay.cardFrame.intersects(overlay.toolbar.frame))
        #expect(page.isDescendant(of: overlay) && page.frame.height == overlay.cardFrame.height)
        #expect(overlay.toolbar.closeButton.frame.minY < overlay.toolbar.openInTabButton.frame.minY)
        #expect(overlay.toolbar.openInTabButton.frame.minY < overlay.toolbar.splitButton.frame.minY)
        let closeFrame = overlay.toolbar.closeButton.frame
        let closePoint = overlay.toolbar.convert(NSPoint(x: closeFrame.midX, y: closeFrame.midY), to: overlay)
        #expect(overlay.hitTest(overlay.convert(closePoint, to: overlay.superview)) === overlay.toolbar.closeButton)
        #expect(overlay.placedView === page)
        let identifiers = [overlay.toolbar.splitButton, overlay.toolbar.openInTabButton, overlay.toolbar.closeButton]
            .map { $0.accessibilityIdentifier() }
        #expect(identifiers == ["peek-open-in-split", "peek-open-in-tab", "peek-close"])
        overlay.toolbar.update(url: URL(string: "https://example.org/a/b?q=1"), title: "B")
        #expect(overlay.displayedAddress == "example.org/a/b")
        overlay.hide(animated: false)
        #expect(overlay.isHidden && !overlay.isShown)
        overlay.frame = NSRect(x: 0, y: 0, width: 150, height: 150)
        #expect(overlay.cardFrame == overlay.bounds, "a tiny content card shows the Peek edge to edge")
    }
}

}
