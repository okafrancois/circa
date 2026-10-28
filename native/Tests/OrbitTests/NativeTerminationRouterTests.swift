import AppKit
import BrowserCore
@testable import BrowserShell
import Foundation
import WebKitEngine
import Testing
@testable import Orbit

@MainActor
private final class QuitRouterGate {
    let entered = AsyncStream<Void>.makeStream()
    private let released = AsyncStream<Void>.makeStream()
    private(set) var isReleased = false

    func hold() async {
        entered.continuation.yield(())
        entered.continuation.finish()
        for await _ in released.stream { return }
    }

    func release() {
        isReleased = true
        released.continuation.yield(())
        released.continuation.finish()
    }

    func waitUntilEntered() async { for await _ in entered.stream { return } }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeTerminationRouterTests {
    @Test("Quit drains accepted mutations and an export beyond the old deadline, then restores exactly")
    func quitDrainsSlowAcceptedWork() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: "/private/tmp/OrbitQuit-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let environment = try await PreviewEnvironment.open(engine: WebKitBrowserEngine(), sessionFile: file)
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        defer { app.windows.shutdown() }
        let windowID = try #require(app.windows.newWindow())
        #expect(await app.windows.waitForPendingCommands(timeout: .seconds(5)))
        let controller = try #require(app.windows.windows[windowID])
        let tab = try #require(controller.session.organization?.selectedTab?.id)
        let space = try #require(controller.session.snapshot?.activeSpaceID)
        let gate = QuitRouterGate()
        controller.session.enqueue { _ in await gate.hold() }
        await gate.waitUntilEntered()
        defer { gate.release() }
        controller.session.pinTabs([tab])
        controller.session.createFolder(title: "Quit folder", at: .init(.pinned(space)), containing: [.tab(tab)])
        controller.session.renameTab(tab, to: "Accepted before Quit")
        controller.session.addToFavorites([tab])
        let exportGate = QuitRouterGate()
        let exportedFile = directory.appendingPathComponent("bookmarks.html")
        let export = Task { @MainActor in
            try await controller.session.finishAcceptedBookmarkExport {
                await exportGate.hold()
                try Data("Synthetic accepted export".utf8).write(to: exportedFile, options: .atomic)
            }
        }
        await exportGate.waitUntilEntered()
        defer { exportGate.release() }
        let quit = Task { @MainActor in try await app.completeTermination() }
        // This is deliberately longer than the former production budget. Neither accepted
        // model mutations nor a user-confirmed file write may be abandoned to satisfy Quit.
        try await Task.sleep(for: .milliseconds(2200))
        #expect(app.isPreparingToQuit && !controller.acceptsCommands)
        #expect(!controller.session.isClosed && !environment.isFinalizing)
        gate.release()
        await controller.session.waitForQueuedCommands()
        let expected = await environment.store.sessionDocument()
        #expect(expected.organization.tabs.first { $0.id == tab }?.customTitle == "Accepted before Quit")
        #expect(expected.organization.folders.contains { $0.title == "Quit folder" })
        // Exports are independent of the command queue, but still must finish before teardown.
        await Task.yield()
        #expect(!controller.session.isClosed)
        exportGate.release()
        try await export.value
        try await quit.value
        #expect(try String(contentsOf: exportedFile, encoding: .utf8) == "Synthetic accepted export")
        #expect(controller.session.isClosed && app.windows.windows.isEmpty)
        let saved = try BrowserSessionDocument.decode(Data(contentsOf: file))
        #expect(saved == expected)
        let restored = try await PreviewEnvironment.open(engine: WebKitBrowserEngine(), sessionFile: file)
        #expect(await restored.store.sessionDocument() == expected)
    }

    @Test("Quit bounds pending New Window inheritance, preserves accepted work, and succeeds on retry")
    func quitWithBlockedInheritedContext() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        var publications = 0
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in publications += 1 })
        defer { app.windows.shutdown() }
        let sourceID = try #require(app.windows.newWindow())
        #expect(await app.windows.waitForPendingCommands(timeout: .seconds(2)))
        let source = try #require(app.windows.windows[sourceID])
        let surface = try #require(source.session.selectedSurface)
        let sourceSpace = try #require(source.session.snapshot?.activeSpaceID)
        let gate = QuitRouterGate()
        source.session.enqueue { _ in await gate.hold() }
        await gate.waitUntilEntered()
        defer { gate.release() }

        // Use the production command binding and its captureContextInCommandOrder boundary.
        #expect(app.commands.registry.dispatch(.newWindow, origin: .menu))
        let destinationID = try #require(app.windows.selectedWindowID)
        #expect(destinationID != sourceID && app.windows.hasPendingWindow)
        #expect(app.inheritedContexts[destinationID] != nil)
        var acceptedCommands = 0
        app.windows.perform { controller in
            acceptedCommands += 1
            controller.performAcceptedCommand { controller.session.openTab() }
        }

        // A failed regression remains bounded by the test itself, without cancelling the work
        // whose production lifetime is under test. Normally this watchdog never releases it.
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            gate.release()
        }
        defer { watchdog.cancel() }
        let started = ContinuousClock.now
        await #expect(throws: BrowserTerminationPreparationError.commandsDidNotSettle) {
            try await app.completeTermination(timeout: .milliseconds(100))
        }
        watchdog.cancel()
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(!gate.isReleased, "quit must time out before the predecessor is released")
        #expect(!app.isPreparingToQuit && source.acceptsCommands)
        #expect(source.window?.ignoresMouseEvents == false)
        #expect(!environment.isFinalizing, "final-save must not start after a routing timeout")
        #expect(!source.session.isClosed && !surface.isDisposed)
        #expect(app.windows.windows.count == 1 && app.windows.hasPendingWindow)
        #expect(publications == 1 && acceptedCommands == 0)

        gate.release()
        #expect(await app.windows.waitForPendingCommands(timeout: .seconds(2)))
        let destination = try #require(app.windows.windows[destinationID])
        await destination.session.waitForPendingCommands()
        #expect(acceptedCommands == 1 && publications == 2)
        #expect(destination.session.snapshot?.activeSpaceID == sourceSpace)
        #expect(destination.session.snapshot?.tabs.count == 2)
        #expect(source.acceptsCommands && destination.acceptsCommands)
        #expect(source.window?.isVisible == false && destination.window?.isVisible == false)

        let readyModel = await environment.store.sessionDocument()
        try await app.completeTermination(timeout: .seconds(2))
        #expect(environment.isFinalizing && app.isPreparingToQuit)
        #expect(app.windows.windows.isEmpty)
        #expect(source.session.isClosed && destination.session.isClosed && surface.isDisposed)
        #expect(await environment.store.sessionDocument() == readyModel,
                "successful retry must preserve the saved model through detach and router shutdown")
    }
}
}
