import BrowserShell
import Foundation
import Testing

@MainActor
private final class RoutedWindow {
    let id: UUID
    var commands = 0
    var disposed = false
    init(_ id: UUID) { self.id = id }
}

@Test("New Window followed by New Tab targets the newly requested window even before creation completes")
@MainActor
func pendingWindowReceivesSubsequentCommand() async throws {
    var presented: [UUID] = []
    let router = BrowserWindowRouter(create: { id in
        await Task.yield()
        return RoutedWindow(id)
    }, present: { window, active in if active { presented.append(window.id) } }, dispose: { $0.disposed = true })
    let firstID = try #require(router.newWindow())
    await router.waitForPendingCommands()
    let secondID = try #require(router.newWindow())
    router.perform { $0.commands += 1 }
    await router.waitForPendingCommands()
    #expect(router.windows[firstID]?.commands == 0)
    #expect(router.windows[secondID]?.commands == 1)
    #expect(presented == [firstID, secondID])
    router.shutdown()
}

@Test("Commands for a ready window are submitted immediately and never redirected after closure")
@MainActor
func retiredWindowDoesNotRedirectCommands() async throws {
    let router = BrowserWindowRouter(create: { RoutedWindow($0) }, present: { _, _ in }, dispose: { $0.disposed = true })
    let firstID = try #require(router.newWindow())
    let secondID = try #require(router.newWindow())
    await router.waitForPendingCommands()
    let first = try #require(router.windows[firstID])
    let second = try #require(router.windows[secondID])
    router.activate(firstID)
    router.perform { $0.commands += 1 }
    router.remove(firstID)
    await router.waitForPendingCommands()
    #expect(router.selectedWindowID == secondID)
    #expect(first.commands == 1 && second.commands == 0)
    router.perform { $0.commands += 1 }
    await router.waitForPendingCommands()
    #expect(second.commands == 1)
    router.shutdown()
}

@Test("Shutdown during asynchronous creation retires the late window without presenting it")
@MainActor
func shutdownDuringCreationPreventsPresentation() async {
    var gate: CheckedContinuation<Void, Never>?
    var started = false
    var created: RoutedWindow?
    var presentations = 0
    let router = BrowserWindowRouter(create: { id in
        started = true
        await withCheckedContinuation { gate = $0 }
        let window = RoutedWindow(id)
        created = window
        return window
    }, present: { _, _ in presentations += 1 }, dispose: { $0.disposed = true })
    router.newWindow()
    while !started { await Task.yield() }
    router.shutdown()
    gate?.resume()
    await router.waitForPendingCommands()
    #expect(created?.disposed == true)
    #expect(presentations == 0)
    #expect(router.windows.isEmpty)
    #expect(router.newWindow() == nil)
}

@Test("A failed window creation cannot redirect its command to an earlier window")
@MainActor
func failedWindowDoesNotBorrowAnotherTarget() async throws {
    enum CreationError: Error { case expected }
    var creations = 0
    var errors = 0
    let router = BrowserWindowRouter(create: { id in
        creations += 1
        if creations == 2 { throw CreationError.expected }
        return RoutedWindow(id)
    }, present: { _, _ in }, dispose: { $0.disposed = true })
    router.onError = { _ in errors += 1 }
    let firstID = try #require(router.newWindow())
    await router.waitForPendingCommands()
    router.newWindow()
    router.perform { $0.commands += 1 }
    await router.waitForPendingCommands()
    #expect(errors == 1)
    #expect(router.windows.count == 1)
    #expect(router.windows[firstID]?.commands == 0)
    #expect(router.selectedWindowID == firstID)
    router.shutdown()
}

@Test("Restored window identities are preserved and cannot be published twice or resurrected")
@MainActor
func restoredWindowIdentityIsSingleUse() async throws {
    let id = UUID()
    var creations = 0
    let router = BrowserWindowRouter(create: { requestedID in
        creations += 1
        await Task.yield()
        return RoutedWindow(requestedID)
    }, present: { _, _ in }, dispose: { $0.disposed = true })
    #expect(router.newWindow(id: id) == id)
    #expect(router.newWindow(id: id) == nil)
    router.perform { $0.commands += 1 }
    await router.waitForPendingCommands()
    #expect(router.windows[id]?.id == id)
    #expect(router.windows[id]?.commands == 1)
    #expect(creations == 1)
    router.remove(id)
    #expect(router.newWindow(id: id) == nil)
    router.shutdown()
}

@Test("A ready source is prepared synchronously while the new destination is immediately reserved")
@MainActor
func readySourcePreparationReservesDestination() async throws {
    var prepared: UUID?
    let router = BrowserWindowRouter(create: { RoutedWindow($0) }, present: { _, _ in }, dispose: { $0.disposed = true })
    let source = try #require(router.newWindow())
    await router.waitForPendingCommands()
    let requested = router.newWindow(prepare: { prepared = $0?.id })
    let destination = try #require(requested)
    #expect(prepared == source)
    #expect(router.selectedWindowID == destination)
    router.perform { $0.commands += 1 }
    await router.waitForPendingCommands()
    #expect(router.windows[source]?.commands == 0)
    #expect(router.windows[destination]?.commands == 1)
    router.shutdown()
}

@Test("Pending source preparation follows its accepted commands and precedes destination creation")
@MainActor
func pendingSourcePreparationFollowsItsCommands() async throws {
    var commandsAtPreparation: Int?
    var preparationFinished = false
    var count = 0
    let router = BrowserWindowRouter(create: { id in
        count += 1
        if count == 2 { #expect(preparationFinished) }
        await Task.yield()
        return RoutedWindow(id)
    }, present: { _, _ in }, dispose: { $0.disposed = true })
    let source = try #require(router.newWindow())
    router.perform { $0.commands += 1 }
    let requested = router.newWindow(prepare: {
        commandsAtPreparation = $0?.commands
        preparationFinished = true
    })
    let destination = try #require(requested)
    router.perform { $0.commands += 10 }
    #expect(router.selectedWindowID == destination)
    await router.waitForPendingCommands()
    #expect(commandsAtPreparation == 1)
    #expect(router.windows[source]?.commands == 1)
    #expect(router.windows[destination]?.commands == 10)
    router.shutdown()
}

@Test("Failed source preparation cancels its destination without redirecting queued commands")
@MainActor
func failedPreparationDoesNotRedirectCommands() async throws {
    enum PreparationError: Error { case expected }
    var errors = 0
    var count = 0
    let router = BrowserWindowRouter(create: { id in
        count += 1
        return RoutedWindow(id)
    }, present: { _, _ in }, dispose: { $0.disposed = true })
    router.onError = { _ in errors += 1 }
    let source = try #require(router.newWindow())
    let requested = router.newWindow(prepare: { _ in throw PreparationError.expected })
    let destination = try #require(requested)
    router.perform { $0.commands += 1 }
    await router.waitForPendingCommands()
    #expect(errors == 1 && count == 1)
    #expect(router.windows[destination] == nil)
    #expect(router.windows[source]?.commands == 0)
    #expect(router.selectedWindowID == source)
    router.shutdown()
}

@Test("Publication cannot let later input or new-window preparation overtake accepted source commands")
@MainActor
func publicationKeepsPerWindowCommandOrder() async throws {
    var router: BrowserWindowRouter<RoutedWindow>!
    let sourceID = UUID()
    let destinationID = UUID()
    var inheritedCount: Int?
    var countAtLaterInput: Int?
    router = BrowserWindowRouter(create: { RoutedWindow($0) }, present: { window, _ in
        guard window.id == sourceID else { return }
        #expect(router.hasPendingSelectedWindowCommands)
        router.newWindow(id: destinationID, prepare: { inheritedCount = $0?.commands })
        router.perform(in: sourceID) {
            countAtLaterInput = $0.commands
            $0.commands += 10
        }
    }, dispose: { $0.disposed = true })
    router.newWindow(id: sourceID)
    router.perform { $0.commands += 1 }
    await router.waitForPendingCommands()
    #expect(inheritedCount == 1)
    #expect(countAtLaterInput == 1)
    #expect(router.windows[sourceID]?.commands == 11)
    #expect(router.windows[destinationID] != nil)
    router.shutdown()
}

@Test("Undeliverable window commands explicitly report abandonment once", arguments: ["failure", "retirement", "shutdown"])
@MainActor
func windowCommandAbandonment(reason: String) async throws {
    enum CreationError: Error { case expected }
    let entered = AsyncStream<Void>.makeStream(), gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    let router = BrowserWindowRouter(create: { id in
        entered.continuation.yield(())
        for await _ in gate.stream { break }
        if reason == "failure" { throw CreationError.expected }
        return RoutedWindow(id)
    }, present: { _, _ in }, dispose: { $0.disposed = true })
    let id = try #require(router.newWindow())
    for await _ in entered.stream { break }
    var abandoned = 0, delivered = 0
    router.perform(in: id, onAbandon: { abandoned += 1 }) { _ in delivered += 1 }
    if reason == "shutdown" { router.shutdown() }
    gate.continuation.finish()
    if reason == "retirement" {
        // A command accepted before retirement succeeds; the subsequent request is abandoned.
        await router.waitForPendingCommands()
        router.remove(id)
        router.perform(in: id, onAbandon: { abandoned += 1 }) { _ in delivered += 1 }
        await router.waitForPendingCommands()
        #expect(abandoned == 1 && delivered == 1)
    } else {
        await router.waitForPendingCommands()
        #expect(abandoned == 1 && delivered == 0)
    }
    router.shutdown()
    var afterShutdown = 0
    router.perform(onAbandon: { afterShutdown += 1 }) { _ in Issue.record("Retired router delivered a command") }
    #expect(afterShutdown == 1)
}
