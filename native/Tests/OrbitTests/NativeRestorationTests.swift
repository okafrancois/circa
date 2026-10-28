import AppKit
import BrowserCore
import BrowserShell
import Foundation
import Testing
import WebKit
@testable import Orbit
import BrowserEngine
import WebKitEngine

private enum RestorationTestError: Error { case timedOut(String) }

@MainActor
private func waitForRestoration(_ phase: String = "condition", _ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(12)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw RestorationTestError.timedOut(phase) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private func restorationDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "/private/tmp/OrbitRestoration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    return directory
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeRestorationTests {
    @Test("Ending address editing with Return preserves the destination until its action is dispatched")
    func returnSubmitsEditedAddress() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        controller.submitAddress("http://127.0.0.1:\(port)/first")
        await controller.session.waitForPendingCommands()
        let view = try #require(controller.session.selectedSurface?.webView)
        try await waitForRestoration { view.title == "First" }
        let address = controller.addressControl
        let destination = "http://127.0.0.1:\(port)/second"
        address.stringValue = destination
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
            object: address, userInfo: ["NSTextMovement": NSTextMovement.return.rawValue]))
        #expect(address.stringValue == destination)
        let action = try #require(address.action)
        #expect(address.sendAction(action, to: address.target))
        await controller.session.waitForPendingCommands()
        try await waitForRestoration { view.title == "Second" }
    }

    @Test("Disk restoration preserves each window frame and preferred sidebar width")
    func windowPlacementRelaunch() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try restorationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let environment = try await PreviewEnvironment.open(sessionFile: file)
        let first = try await environment.makeWindow()
        let second = try await environment.makeWindow()
        let expected: [(PreviewWindowController, NSRect, CGFloat)] = [
            (first, NSRect(x: 70, y: 80, width: 850, height: 610), 280),
            (second, NSRect(x: 100, y: 100, width: 890, height: 630), 310)
        ]
        for (controller, frame, width) in expected {
            controller.window?.setFrame(frame, display: false)
            controller.windowShell.setSidebarWidth(width)
        }
        try await environment.finalize()
        let reopened = try await PreviewEnvironment.open(sessionFile: file)
        for (controller, frame, width) in expected {
            let restored = try await reopened.makeWindow(id: try #require(controller.session.snapshot?.id.rawValue))
            #expect(restored.window?.frame == frame)
            #expect(restored.windowShell.preferredSidebarWidth == width)
            restored.prepareForTermination()
            restored.window?.close()
            controller.prepareForTermination()
            controller.window?.close()
        }
        try await reopened.finalize()
    }

    @Test("Disk restoration recreates exact window identities, selected tabs and isolated WebKit profiles")
    func restoredWindowsAndProfiles() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try restorationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let original = BrowserStore()
        let firstProfile = await original.createProfile(name: "Synthetic A")
        let secondProfile = await original.createProfile(name: "Synthetic B")
        let firstSpace = try await original.createSpace(name: "Synthetic A", profileID: firstProfile)
        let secondSpace = try await original.createSpace(name: "Synthetic B", profileID: secondProfile)
        let firstID = try await original.createWindow(activeSpaceID: firstSpace)
        let secondID = try await original.createWindow(activeSpaceID: secondSpace)
        let firstURL = URL(string: "http://127.0.0.1:\(port)/first")!
        let secondURL = URL(string: "http://127.0.0.1:\(port)/second")!
        let otherURL = URL(string: "http://127.0.0.1:\(port)/other")!
        let firstTab = try await original.openTab(url: firstURL, from: original.captureContext(in: firstID), activate: true)
        _ = try await original.openTab(url: secondURL, from: original.captureContext(in: firstID), activate: false)
        _ = try await original.openTab(url: otherURL, from: original.captureContext(in: secondID), activate: true)
        let document = await original.sessionDocument()
        try BrowserSessionFileStore().save(document, to: file)
        let environment = try await PreviewEnvironment.open(sessionFile: file)
        let first = try await environment.makeWindow(id: firstID.rawValue)
        let second = try await environment.makeWindow(id: secondID.rawValue)
        defer { first.window?.close(); second.window?.close() }
        #expect(first.session.snapshot?.id == firstID)
        #expect(second.session.snapshot?.id == secondID)
        #expect(first.session.snapshot?.tabs.count == 2)
        #expect(first.session.snapshot?.selectedOccurrenceID == firstTab)
        #expect(first.session.selectedSurface?.profileID == firstProfile)
        #expect(second.session.selectedSurface?.profileID == secondProfile)
        #expect(!first.window!.isVisible && !second.window!.isVisible)
        let firstView = try #require(first.session.selectedSurface?.webView)
        let secondView = try #require(second.session.selectedSurface?.webView)
        try await waitForRestoration { firstView.title == "First" && secondView.title == "Other" }
        _ = try await firstView.evaluateJavaScript("document.cookie='restoration=profile-a; path=/'")
        #expect(try await secondView.evaluateJavaScript("document.cookie") as? String == "")
        let sameProfile = try await environment.makeWindow(spaceID: firstSpace)
        sameProfile.submitAddress(firstURL.absoluteString)
        await sameProfile.session.waitForPendingCommands()
        let sharedView = try #require(sameProfile.session.selectedSurface?.webView)
        try await waitForRestoration { sharedView.title == "First" }
        #expect(try await sharedView.evaluateJavaScript("document.cookie") as? String == "restoration=profile-a")
        sameProfile.window?.close()
        await sameProfile.session.waitForPendingCommands()
        await first.session.waitForPendingCommands()
        await second.session.waitForPendingCommands()
        try await environment.finalize()
        first.window?.close()
        second.window?.close()
        await first.session.waitForPendingCommands()
        await second.session.waitForPendingCommands()
        let saved = try BrowserSessionFileStore().load(from: file)
        #expect(saved.windows.count == 2)
        #expect(saved.tabs.count == 3)
        #expect(Set(saved.windows.map(\.id)) == [firstID, secondID])
    }

    @Test("Background navigation and same-document history autosave then restore the actual destinations")
    func navigationAutosaveAndRelaunch() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try restorationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = try await PreviewEnvironment.open(sessionFile: file)
        let first = try await environment.makeWindow()
        defer { first.window?.close() }
        first.submitAddress("http://127.0.0.1:\(port)/first")
        await first.session.waitForPendingCommands()
        let firstView = try #require(first.session.selectedSurface?.webView)
        let firstTab = try #require(first.session.snapshot?.selectedOccurrenceID)
        try await waitForRestoration { firstView.title == "First" }
        first.openTab(url: URL(string: "http://127.0.0.1:\(port)/second")!)
        await first.session.waitForPendingCommands()
        let selected = try #require(first.session.snapshot?.selectedOccurrenceID)
        let secondView = try #require(first.session.selectedSurface?.webView)
        try await waitForRestoration { secondView.title == "Second" }
        _ = try await firstView.evaluateJavaScript("history.pushState({}, '', '/background-updated'); document.title='Synthetic history';")
        try await waitForRestoration {
            guard let saved = try? BrowserSessionFileStore().load(from: file) else { return false }
            return saved.tabs.first(where: { $0.occurrenceID == firstTab })?.url.path == "/background-updated"
                && saved.windows.first?.spaces.first?.selectedOccurrenceID == selected
        }
        first.prepareForTermination()
        await first.session.waitForPendingCommands()
        let id = try #require(first.session.snapshot?.id)
        try await environment.finalize()
        first.window?.close()
        await first.session.waitForPendingCommands()
        let reopened = try await PreviewEnvironment.open(sessionFile: file)
        let restored = try await reopened.makeWindow(id: id.rawValue)
        defer { restored.window?.close() }
        #expect(restored.session.snapshot?.tabs.count == 2)
        #expect(restored.session.snapshot?.selectedOccurrenceID == selected)
        #expect(restored.session.snapshot?.tabs.first?.occurrenceID == firstTab)
        #expect(restored.session.snapshot?.tabs.first?.url.path == "/background-updated")
        try await reopened.finalize()
    }

    @Test("An empty restored window stays empty without a bootstrap tab")
    func emptyWindow() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try restorationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let id = try await store.createWindow(activeSpaceID: space)
        try BrowserSessionFileStore().save(await store.sessionDocument(), to: file)
        let environment = try await PreviewEnvironment.open(sessionFile: file)
        let controller = try await environment.makeWindow(id: id.rawValue)
        defer { controller.window?.close() }
        #expect(controller.session.snapshot?.tabs.isEmpty == true)
        #expect(controller.session.selectedSurface == nil)
        #expect(controller.displayedTabTitles.isEmpty)
        try await environment.finalize()
        #expect(try BrowserSessionFileStore().load(from: file).tabs.isEmpty)
    }

    @Test("Corrupt startup input is surfaced and remains byte-for-byte unchanged")
    func corruptSessionIsPreserved() async throws {
        let directory = try restorationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let original = Data("{invalid synthetic session}".utf8)
        try original.write(to: file)
        await #expect(throws: BrowserSessionFileError.corruptDocument) {
            try await PreviewEnvironment.open(sessionFile: file)
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("An accepted address command is saved when termination starts before the command drains")
    func queuedNavigationBeforeTermination() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try restorationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = try await PreviewEnvironment.open(sessionFile: file)
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        controller.submitAddress("http://127.0.0.1:\(port)/first")
        await controller.session.waitForPendingCommands()
        let view = try #require(controller.session.selectedSurface?.webView)
        try await waitForRestoration { view.title == "First" }
        controller.submitAddress("http://127.0.0.1:\(port)/second")
        controller.freezeCommandsForTermination()
        controller.openTab()
        await controller.session.waitForPendingCommands()
        controller.prepareForTermination()
        await controller.session.waitForPendingCommands()
        try await environment.finalize()
        let saved = try BrowserSessionFileStore().load(from: file)
        #expect(saved.tabs.count == 1)
        #expect(saved.tabs.first?.url.path == "/second")
    }

    @Test("Finalization drains a closed window's retirement before taking the disk snapshot")
    func closedWindowIsNotResurrected() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try restorationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let environment = try await PreviewEnvironment.open(sessionFile: file)
        let closed = try await environment.makeWindow()
        let survivor = try await environment.makeWindow()
        defer { survivor.window?.close() }
        let closedID = try #require(closed.session.snapshot?.id)
        let survivorID = try #require(survivor.session.snapshot?.id)
        closed.openTab()
        closed.window?.close()
        try await environment.finalize()
        let saved = try BrowserSessionFileStore().load(from: file)
        #expect(!saved.windows.contains(where: { $0.id == closedID }))
        #expect(saved.windows.map(\.id) == [survivorID])
    }

    @Test("A router command accepted for a pending window drains after the window input is frozen")
    func pendingRouterCommandBeforeTermination() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try restorationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let environment = try await PreviewEnvironment.open(sessionFile: file)
        let router = BrowserWindowRouter<PreviewWindowController>(create: { id in
            await Task.yield()
            let controller = try await environment.makeWindow(id: id)
            controller.freezeCommandsForTermination()
            return controller
        }, present: { _, _ in }, dispose: { $0.window?.close() })
        router.newWindow()
        router.perform { controller in controller.performAcceptedCommand { controller.openTab() } }
        await router.waitForPendingCommands()
        let controller = try #require(router.selectedWindow)
        await controller.session.waitForPendingCommands()
        controller.prepareForTermination()
        await controller.session.waitForPendingCommands()
        try await environment.finalize()
        #expect(try BrowserSessionFileStore().load(from: file).tabs.count == 2)
        router.shutdown()
    }

    @Test("A failed address navigation cannot mask a later page-driven navigation")
    func navigationAfterProvisionalFailure() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try restorationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = try await PreviewEnvironment.open(sessionFile: file)
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        controller.submitAddress("http://127.0.0.1:\(port)/first")
        await controller.session.waitForPendingCommands()
        let surface = try #require(controller.session.selectedSurface)
        try await waitForRestoration { surface.webView.title == "First" }
        controller.submitAddress("http://127.0.0.1:\(port)/drop")
        await controller.session.waitForPendingCommands()
        try await waitForRestoration { !surface.webView.isLoading }
        _ = try await surface.webView.evaluateJavaScript("location.href='/second'")
        try await waitForRestoration { surface.webView.title == "Second" && surface.currentURL?.path == "/second" }
        await controller.session.waitForPendingCommands()
        try await environment.finalize()
        #expect(try BrowserSessionFileStore().load(from: file).tabs.first?.url.path == "/second")
    }

    @Test("Cancelling quit after a save failure releases the stopped request before later page navigation")
    func saveFailureCancelsQuitWithoutStickyDestination() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try restorationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let prior = directory.appendingPathComponent("prior.json")
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = try await PreviewEnvironment.open(sessionFile: file)
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        controller.submitAddress("http://127.0.0.1:\(port)/first")
        await controller.session.waitForPendingCommands()
        let surface = try #require(controller.session.selectedSurface)
        try await waitForRestoration { surface.webView.title == "First" }
        try BrowserSessionFileStore().save(await environment.store.sessionDocument(), to: file)
        try FileManager.default.moveItem(at: file, to: prior)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: prior)
        controller.submitAddress("http://127.0.0.1:\(port)/drop")
        controller.freezeCommandsForTermination()
        await controller.session.waitForPendingCommands()
        controller.prepareForTermination()
        await controller.session.waitForPendingCommands()
        await #expect(throws: BrowserSessionFileError.symbolicLink) { try await environment.finalize() }
        controller.cancelTerminationPreparation()
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: prior, to: file)
        _ = try await surface.webView.evaluateJavaScript("location.href='/second'")
        try await waitForRestoration("page navigation after cancelled quit") {
            surface.webView.title == "Second" && surface.currentURL?.path == "/second"
        }
        await controller.session.waitForPendingCommands()
        try await environment.finalize()
        #expect(try BrowserSessionFileStore().load(from: file).tabs.first?.url.path == "/second")
    }
}

}
