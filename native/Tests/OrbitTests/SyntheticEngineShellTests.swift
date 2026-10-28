import AppKit
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
@testable import BrowserShell
import Foundation
import Testing
@testable import Orbit

private enum SyntheticShellTestError: Error { case timedOut(String) }

@MainActor
private func waitForShell(_ phase: String, _ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw SyntheticShellTestError.timedOut(phase) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func shellTestDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "/private/tmp/OrbitSyntheticShell-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    return directory
}

private typealias SyntheticEnvironment = BrowserEnvironment<SyntheticEngine>
private typealias SyntheticWindow = BrowserWindowController<SyntheticEngine>

private final class ShellStoreGate: @unchecked Sendable {
    let entered = AsyncStream<Void>.makeStream()
    private let signal = DispatchSemaphore(value: 0)

    func hold() {
        entered.continuation.yield(())
        entered.continuation.finish()
        #expect(signal.wait(timeout: .now() + 5) == .success)
    }
    func release() { signal.signal() }
    func waitUntilEntered() async { for await _ in entered.stream { return } }
}

@MainActor
private final class ShellCommandGate {
    let entered = AsyncStream<Void>.makeStream()
    private let released = AsyncStream<Void>.makeStream()

    func hold() async {
        entered.continuation.yield(())
        entered.continuation.finish()
        for await _ in released.stream { return }
    }

    func release() { released.continuation.yield(()); released.continuation.finish() }
    func waitUntilEntered() async { for await _ in entered.stream { return } }
}

private extension BrowserStore {
    func holdSyntheticShellExecutor(_ gate: ShellStoreGate) { gate.hold() }
}

/// The window controller and environment driven by the reference synthetic engine, which models
/// stock CEF: no response policy, synchronous navigation policy, asynchronous native close.
extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SyntheticEngineShellTests {
    private func loadedWindow(_ environment: SyntheticEnvironment, _ url: String) async throws -> (SyntheticWindow, SyntheticSurface) {
        let controller = try await environment.makeWindow()
        controller.submitAddress(url)
        await controller.session.waitForPendingCommands()
        let surface = try #require(controller.session.selectedSurface)
        try await waitForShell("load \(url)") { surface.navigationState.committedURL?.absoluteString == url }
        return (controller, surface)
    }

    /// The application's termination sequence, as `applicationShouldTerminate` runs it.
    private func saveForTermination(_ environment: SyntheticEnvironment) async throws {
        try await environment.prepareToSaveForTermination()
        try await environment.finalize()
    }

    @Test("Termination saves, detaches without touching the saved model, and awaits a delayed native close")
    func terminationAwaitsDelayedClose() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try shellTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionFile = directory.appendingPathComponent("session.json")
        let engine = SyntheticEngine(teardown: .delayed(.milliseconds(300)))
        let environment = try await SyntheticEnvironment.open(engine: engine, sessionFile: sessionFile)
        let (first, _) = try await loadedWindow(environment, "https://quit.test/first")
        let (second, _) = try await loadedWindow(environment, "https://quit.test/second")
        defer { first.window?.close(); second.window?.close() }

        try await saveForTermination(environment)
        let saved = try Data(contentsOf: sessionFile)
        let savedModel = await environment.store.sessionDocument()
        let started = ContinuousClock.now
        let outcome = await environment.shutDown(timeout: .seconds(5))
        let elapsed = ContinuousClock.now - started

        #expect(outcome == .engineShutDown)
        #expect(elapsed >= .milliseconds(250), "shutdown must wait for the delayed native close")
        #expect(engine.isShutDown)
        #expect(!engine.surfaces.isEmpty)
        #expect(engine.surfaces.allSatisfy { $0.isDisposed && $0.isTeardownComplete })
        #expect(first.session.isClosed && second.session.isClosed)
        #expect(try Data(contentsOf: sessionFile) == saved, "teardown must not rewrite the saved session")
        #expect(await environment.store.sessionDocument() == savedModel, "teardown must not mutate the model")
        first.window?.close()
        second.window?.close()
        await Task.yield()
        #expect(await environment.store.sessionDocument() == savedModel, "closing retired windows must not mutate the model")

        // The saved session restores both windows and their documents.
        let reopened = try await SyntheticEnvironment.open(engine: SyntheticEngine(), sessionFile: sessionFile)
        #expect(reopened.restoredWindowIDs.count == 2)
        #expect(await reopened.store.sessionDocument() == savedModel)
    }

    @Test("A hung engine delays quitting only up to the bound")
    func hungEngineIsBounded() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SyntheticEngine(teardown: .never)
        let environment = SyntheticEnvironment(engine: engine)
        let (controller, surface) = try await loadedWindow(environment, "https://quit.test/hung")
        defer { controller.window?.close() }
        try await saveForTermination(environment)
        let started = ContinuousClock.now
        let outcome = await environment.shutDown(timeout: .milliseconds(300))
        #expect(outcome == .engineShutdownTimedOut)
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(surface.isDisposed)
        #expect(!surface.isTeardownComplete)
    }

    @Test("A stalled command cancels termination preparation without retiring its window or losing queued work")
    func terminationPreparationTimesOutSafely() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = SyntheticEnvironment(engine: SyntheticEngine())
        let (controller, surface) = try await loadedWindow(environment, "https://quit.test/preserved")
        defer { controller.window?.close() }
        let before = controller.session.snapshot
        let gate = ShellStoreGate()
        let blocker = Task.detached { await environment.store.holdSyntheticShellExecutor(gate) }
        await gate.waitUntilEntered()
        defer { gate.release() }
        let queued = URL(string: "https://quit.test/queued")!
        controller.session.openTab(url: queued)
        let started = ContinuousClock.now
        await #expect(throws: BrowserTerminationPreparationError.commandsDidNotSettle) {
            try await environment.prepareToSaveForTermination(timeout: .milliseconds(100))
        }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(controller.acceptsCommands && controller.session.hasPendingCommands)
        #expect(controller.session.snapshot == before)
        #expect(!controller.session.isClosed && !surface.isDisposed && !environment.engine.isShutDown)
        gate.release()
        await blocker.value
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.tabs.contains { $0.url == queued } == true)
        #expect(controller.session.ownedSurfaces.contains { $0 === surface })
    }

    @Test("Without a response policy, a foreground new target is promoted at its first commit")
    func popupPromotedAtCommit() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = SyntheticEnvironment(engine: SyntheticEngine())
        let (controller, source) = try await loadedWindow(environment, "https://opener.test/")
        defer { controller.window?.close() }
        #expect(!environment.engine.capabilities.contains(.navigationResponsePolicy))
        let popup = try #require(source.openNewTarget(URL(string: "https://popup.test/")!))
        try await waitForShell("promotion") { controller.session.selectedSurface === popup }
        let occurrence = try #require(controller.session.occurrenceID(for: popup))
        try await waitForShell("promotion settled") { !controller.hasPendingNativePromotion }

        // After its first commit the target owns its downloads and stays open.
        popup.startDownload(suggestedFilename: "after-commit.bin")
        await controller.session.waitForPendingCommands()
        let record = try #require(environment.downloads.snapshots(profileID: popup.profileID).first)
        #expect(record.owner.sourceOccurrenceID == occurrence)
        #expect(!popup.isDisposed)
        #expect(controller.session.ownedSurfaces.contains { $0 === popup })
        environment.downloads.shutdown()
    }

    @Test("A background new target is recorded without stealing selection")
    func backgroundPopupNotPromoted() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = SyntheticEnvironment(engine: SyntheticEngine())
        let (controller, source) = try await loadedWindow(environment, "https://opener.test/background")
        defer { controller.window?.close() }
        let popup = try #require(source.openNewTarget(URL(string: "https://popup.test/background")!, modifiers: [.command]))
        try await waitForShell("adoption") { controller.session.occurrenceID(for: popup) != nil }
        await controller.session.waitForPendingCommands()
        #expect(controller.session.selectedSurface === source)
    }

    @Test("Downloads and close requests during a move's recording are attributed and honoured")
    func eventsDuringMoveAreReconciled() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = SyntheticEnvironment(engine: SyntheticEngine())
        let (source, surface) = try await loadedWindow(environment, "https://move.test/events")
        let destination = try await environment.makeWindow()
        defer { source.window?.close(); destination.window?.close(); environment.downloads.shutdown() }

        let move = try #require(source.moveSurface(surface, to: destination))
        #expect(surface.delegate === destination)
        #expect(destination.session.occurrenceID(for: surface) == nil, "the tab is not recorded yet")
        let download = surface.startDownload(suggestedFilename: "during-move.bin")
        #expect(!download.isCancelled, "a download during recording is adopted provisionally, not cancelled")
        let provisional = try #require(environment.downloads.snapshots(profileID: surface.profileID).first)
        #expect(provisional.owner.sourceOccurrenceID == nil)
        #expect(provisional.owner.sourceWindowID == destination.session.snapshot?.id)

        let occurrence = try #require(await move.value)
        try await waitForShell("attribution") {
            environment.downloads.snapshots(profileID: surface.profileID).first?.owner.sourceOccurrenceID == occurrence
        }

        // A close request during a second move's recording runs once the tab is recorded.
        let back = try #require(destination.moveSurface(surface, to: source))
        surface.requestClose()
        #expect(!surface.isDisposed)
        _ = await back.value
        try await waitForShell("provisional close") { surface.isDisposed }
        await source.session.waitForPendingCommands()
        #expect(!source.session.ownedSurfaces.contains { $0 === surface })
    }

    @Test("A move whose destination closes before recording returns the live document to its tab")
    func failedMoveReturnsToSourceTab() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = SyntheticEnvironment(engine: SyntheticEngine())
        let (source, surface) = try await loadedWindow(environment, "https://move.test/returns")
        let occurrence = try #require(source.session.occurrenceID(for: surface))
        let requests = surface.requestedURLs
        let destination = try await environment.makeWindow()
        defer { source.window?.close() }
        let move = try #require(source.moveSurface(surface, to: destination))
        destination.window?.close()
        #expect(await move.value == nil)
        #expect(!surface.isDisposed)
        #expect(source.session.occurrenceID(for: surface) == occurrence)
        #expect(surface.delegate === source)
        #expect(surface.requestedURLs == requests, "a returned document is not reloaded")
        await source.session.waitForPendingCommands()
        #expect(source.session.selectedSurface === surface)
        #expect(source.session.snapshot?.tabs.map(\.occurrenceID) == [occurrence])
    }

    @Test("A closed receiver survives only until its deferred download and close events are reconciled",
          arguments: [false, true])
    func closedReceiverReconcilesBeforeDeallocation(closeRequested: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = SyntheticEnvironment(engine: SyntheticEngine())
        let initial = URL(string: "https://receiver-lifetime.test/a")!
        let latest = URL(string: "https://receiver-lifetime.test/b")!
        let (source, surface) = try await loadedWindow(environment, initial.absoluteString)
        defer { source.window?.close(); environment.downloads.shutdown() }
        let occurrence = try #require(source.session.occurrenceID(for: surface))
        let sourceWindow = try #require(source.session.snapshot?.id)
        let tabID = try #require(source.session.snapshot?.tabs.first { $0.occurrenceID == occurrence }?.id)
        var receiver: SyntheticWindow? = try await environment.makeWindow()
        weak let weakReceiver = receiver
        let receiverSession = try #require(receiver?.session)
        let receiverWindow = try #require(receiverSession.snapshot?.id)
        let gate = ShellCommandGate()
        // Enter the queued command before moving or closing: the test then owns its release.
        receiverSession.enqueue { _ in await gate.hold() }
        await gate.waitUntilEntered()
        defer { gate.release() }
        let move = try #require(source.moveSurface(surface, to: receiver!))
        var observedReturn = false
        var disposals = 0
        let originalChange = source.session.onChange
        source.session.onChange = { [weak source, weak surface] in
            originalChange?()
            guard let source, let surface, !observedReturn,
                  source.session.occurrenceID(for: surface) == occurrence,
                  surface.delegate === source else { return }
            observedReturn = true
            let originalDispose = surface.onDispose
            surface.onDispose = { disposals += 1; originalDispose?() }
        }
        surface.navigate(to: latest)
        let download = surface.startDownload(suggestedFilename: "receiver-lifetime.bin")
        if closeRequested { surface.requestClose() }
        receiver?.window?.close()
        receiver = nil
        await Task.yield()
        #expect(receiverSession.isClosed)
        #expect(weakReceiver != nil, "the reconciliation task must retain the closed receiver until adoption resolves")
        #expect(!surface.isDisposed && !download.isCancelled)
        let provisional = try #require(environment.downloads.snapshots(profileID: surface.profileID).first)
        #expect(provisional.owner.sourceWindowID == receiverWindow && provisional.owner.sourceOccurrenceID == nil)

        gate.release()
        #expect(await move.value == nil)
        try await waitForShell("receiver reconciliation and release") {
            let owner = environment.downloads.snapshots(profileID: surface.profileID).first?.owner
            return weakReceiver == nil && owner == BrowserDownloadOwner(profileID: surface.profileID,
                sourceWindowID: sourceWindow, sourceOccurrenceID: occurrence)
                && (!closeRequested || surface.isDisposed)
        }
        await source.session.waitForPendingCommands()
        #expect(observedReturn)
        #expect(surface.requestedURLs == [initial, latest], "the return must never replay the document")
        #expect(disposals == (closeRequested ? 1 : 0))
        if closeRequested {
            let archived = (await source.session.archivedTabs().value).filter { $0.id == tabID }
            #expect(archived.count == 1 && archived.first?.tab.url == latest,
                    "the deferred native close must archive the returned latest destination exactly once")
            #expect(source.session.occurrenceID(for: surface) == nil)
        } else {
            #expect(!surface.isDisposed && surface.delegate === source)
            #expect(source.session.snapshot?.tabs.first { $0.occurrenceID == occurrence }?.url == latest)
        }
    }

    @Test("A failed move reconciles its changed destination and downloads to its return owner",
          arguments: [true, false])
    func failedMoveReconcilesLiveState(sourceSurvives: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = SyntheticEnvironment(engine: SyntheticEngine())
        let (source, surface) = try await loadedWindow(environment, "https://rollback.test/a")
        let occurrence = try #require(source.session.occurrenceID(for: surface))
        let sourceWindow = try #require(source.session.snapshot?.id)
        let profileID = surface.profileID
        let destination = try await environment.makeWindow()
        defer { source.window?.close(); destination.window?.close(); environment.downloads.shutdown(); environment.rescue.close() }
        let otherProfile = await environment.store.createProfile(name: "Other Synthetic Profile")
        let otherSpace = try await environment.store.createSpace(name: "Other Synthetic Space", profileID: otherProfile)
        destination.session.activateSpace(otherSpace)
        let move = try #require(source.moveSurface(surface, to: destination))
        let latest = URL(string: "https://rollback.test/b")!
        surface.navigate(to: latest)
        let download = surface.startDownload(suggestedFilename: "rollback.bin")
        #expect(!download.isCancelled)
        if !sourceSurvives { source.window?.close() }

        #expect(await move.value == nil)
        #expect(!surface.isDisposed)
        #expect(surface.requestedURLs.map(\.absoluteString) == ["https://rollback.test/a", latest.absoluteString])
        let expectedWindow: WindowID? = sourceSurvives ? sourceWindow : nil
        let expectedOccurrence: TabOccurrenceID? = sourceSurvives ? occurrence : nil
        try await waitForShell("rollback download provenance") {
            guard let record = environment.downloads.snapshots(profileID: profileID).first else { return false }
            return record.owner == BrowserDownloadOwner(profileID: profileID, sourceWindowID: expectedWindow,
                                                        sourceOccurrenceID: expectedOccurrence)
        }
        #expect(environment.downloads.snapshots(profileID: otherProfile).isEmpty)
        if sourceSurvives {
            await source.session.waitForPendingCommands()
            #expect(surface.delegate === source)
            #expect(source.session.occurrenceID(for: surface) == occurrence)
            #expect(source.session.snapshot?.tabs.first { $0.occurrenceID == occurrence }?.url == latest)
        } else {
            #expect(environment.rescue.owns(surface))
        }
    }

    @Test("When both windows of a failed move are gone, the environment rescues and rehomes the document")
    func failedMoveIsRescuedIntoAnotherWindow() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = SyntheticEnvironment(engine: SyntheticEngine())
        let (source, surface) = try await loadedWindow(environment, "https://move.test/rescued")
        let tabID = try #require(source.session.snapshot?.tabs.first?.id)
        let destination = try await environment.makeWindow()
        let survivor = try await environment.makeWindow()
        defer { survivor.window?.close() }
        let move = try #require(source.moveSurface(surface, to: destination))
        source.window?.close()
        destination.window?.close()
        #expect(await move.value == nil)
        #expect(!surface.isDisposed, "a failed move never disposes a live document")
        try await waitForShell("rehome") { survivor.session.occurrenceID(for: surface) != nil }
        let occurrence = try #require(survivor.session.occurrenceID(for: surface))
        #expect(survivor.session.snapshot?.tabs.first { $0.occurrenceID == occurrence }?.id == tabID,
                "rescue must preserve the logical tab as well as the live document")
        #expect(surface.delegate === survivor)
        #expect(environment.rescue.surfaces.isEmpty)
        #expect(!surface.isDisposed)
    }

    @Test("Same-document navigations reach feature hooks and the tab destination without a commit")
    func sameDocumentNavigationReachesHooks() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = SyntheticEnvironment(engine: SyntheticEngine())
        let (controller, surface) = try await loadedWindow(environment, "https://history.test/page")
        defer { controller.window?.close() }
        var events: [BrowserSurfaceEvent] = []
        let observation = controller.engineEventHooks.observe { _, event in events.append(event) }
        defer { observation.cancel() }
        let generation = surface.documentGeneration
        surface.navigateWithinDocument(to: URL(string: "https://history.test/page#section")!)
        surface.navigateWithinDocument(to: URL(string: "https://history.test/pushed")!)
        #expect(events.contains(.navigatedWithinDocument(.fragment)))
        #expect(events.contains(.navigatedWithinDocument(.historyState)))
        #expect(!events.contains(.navigationCommitted))
        #expect(surface.documentGeneration == generation)
        await controller.session.waitForPendingCommands()
        let occurrence = try #require(controller.session.occurrenceID(for: surface))
        #expect(controller.session.snapshot?.tabs.first { $0.occurrenceID == occurrence }?.url
                == URL(string: "https://history.test/pushed"))
    }

    @Test("Navigation metadata reaches feature navigation routes")
    func navigationMetadataReachesRoutes() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = SyntheticEnvironment(engine: SyntheticEngine())
        let (controller, surface) = try await loadedWindow(environment, "https://routes.test/")
        defer { controller.window?.close() }
        var routed: [BrowserNavigationAction] = []
        let registration = controller.engineEventHooks.routeNavigations { _, action in
            routed.append(action)
            return .declined
        }
        defer { registration.cancel() }
        surface.simulateNavigation(to: URL(string: "https://routes.test/form")!, kind: .formSubmission,
                                   httpMethod: "POST", hasBody: true, modifiers: [.option])
        surface.reload()
        let form = try #require(routed.first)
        #expect(form.kind == .formSubmission && form.httpMethod == "POST" && form.hasBody == true)
        #expect(form.isUserGesture == true && form.modifiers == [.option] && form.disposition == .currentTab)
        #expect(routed.last?.kind == .reload)
    }

    @Test("A session whose surface factory fails reports it instead of crashing")
    func factoryFailureIsExplicit() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic Factory")
        let space = try await store.createSpace(name: "Synthetic Factory", profileID: profile)
        var errors: [any Error] = []
        let session = BrowserWindowSession<SyntheticSurface>(store: store, spaceID: space, makeSurface: { _, _ in nil })
        session.onError = { errors.append($0) }
        session.openTab(url: URL(string: "https://factory.test/")!)
        await session.waitForPendingCommands()
        #expect(session.snapshot?.tabs.count == 1)
        #expect(session.ownedSurfaces.isEmpty)
        #expect(errors.contains { ($0 as? BrowserWindowSessionError) == .surfaceUnavailable })
        session.close()
        await session.waitForPendingCommands()
    }

    // MARK: Engine-native moves (CHROMIUM-APP-R2)

    @Test("An engine refusing the native move leaves the tab in place, live and unreloaded")
    func refusedNativeMoveChangesNothing() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SyntheticEngine()
        let environment = SyntheticEnvironment(engine: engine)
        let (source, surface) = try await loadedWindow(environment, "https://move.test/refused")
        let occurrence = try #require(source.session.occurrenceID(for: surface))
        let requests = surface.requestedURLs
        let destination = try await environment.makeWindow()
        defer { source.window?.close(); destination.window?.close() }
        engine.refusesMoves = true
        #expect(source.moveSurface(surface, to: destination) == nil)
        let destinationID = try #require(destination.session.snapshot?.id)
        #expect(engine.announcedMoves.map(\.windowID) == [destinationID])
        #expect(engine.announcedMoves.first?.surfaces == [ObjectIdentifier(surface)])
        #expect(engine.shellWindows[destinationID] != nil, "the destination window is announced first")
        #expect(source.session.occurrenceID(for: surface) == occurrence)
        #expect(surface.delegate === source && !surface.isDisposed)
        #expect(surface.placement.windowID == source.session.snapshot?.id)
        #expect(surface.requestedURLs == requests, "no reload")
        #expect(!destination.session.ownedSurfaces.contains { $0 === surface })

        #expect(engine.finishedMoves.isEmpty, "a refused announcement needs no settlement")

        engine.refusesMoves = false
        let move = try #require(source.moveSurface(surface, to: destination))
        #expect(await move.value != nil)
        #expect(engine.announcedMoves.count == 2)
        try await waitForShell("settled") { engine.finishedMoves.count == 1 }
        #expect(engine.finishedMoves.first?.committed == true && engine.finishedMoves.first?.windowID == destinationID)
        #expect(surface.delegate === destination && surface.requestedURLs == requests)
        #expect(surface.placement.windowID == destinationID)
    }

    @Test("Each window publishes its live tabs in sidebar order when it changes")
    func tabOrderIsPublished() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SyntheticEngine()
        let environment = SyntheticEnvironment(engine: engine)
        let (window, first) = try await loadedWindow(environment, "https://order.test/first")
        defer { window.window?.close() }
        window.openTab(url: URL(string: "https://order.test/second")!)
        await window.session.waitForPendingCommands()
        window.openTab(url: URL(string: "https://order.test/third")!)
        await window.session.waitForPendingCommands()
        let windowID = try #require(window.session.snapshot?.id)
        try await waitForShell("three live tabs") { window.session.ownedSurfaces.count == 3 }
        func sidebarOrder() -> [ObjectIdentifier] {
            let items = (window.session.organization?.pinned ?? []) + (window.session.organization?.today ?? [])
            return items.compactMap { item -> ObjectIdentifier? in
                guard case let .tab(tab) = item, let occurrence = tab.occurrenceID,
                      let surface = window.session.surface(for: occurrence) else { return nil }
                return ObjectIdentifier(surface)
            }
        }
        try await waitForShell("published order") { engine.tabOrders[windowID]?.count == 3 }
        #expect(engine.tabOrders[windowID] == sidebarOrder())
        #expect(engine.tabOrders[windowID]?.contains(ObjectIdentifier(first)) == true)
    }

    @Test("R3: a move whose destination closes before recording settles as not committed")
    func failedMoveSettlesUncommitted() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SyntheticEngine()
        let environment = SyntheticEnvironment(engine: engine)
        let (source, surface) = try await loadedWindow(environment, "https://move.test/settles")
        let destination = try await environment.makeWindow()
        defer { source.window?.close() }
        let destinationID = try #require(destination.session.snapshot?.id)
        let move = try #require(source.moveSurface(surface, to: destination))
        destination.window?.close()
        #expect(await move.value == nil)
        try await waitForShell("settled") { engine.finishedMoves.count == 1 }
        #expect(engine.finishedMoves.first?.committed == false && engine.finishedMoves.first?.windowID == destinationID)
        #expect(engine.finishedMoves.first?.surfaces == [ObjectIdentifier(surface)])
        #expect(surface.delegate === source && !surface.isDisposed)
    }
}
}
