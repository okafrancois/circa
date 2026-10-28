import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing
import WebKit
import WebKitEngine
@testable import Orbit

private enum QuickWindowWebKitError: Error { case timedOut }

@MainActor
private func waitForQuickWindowWebKit(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw QuickWindowWebKitError.timedOut }
        try await Task.sleep(for: .milliseconds(20))
    }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeQuickWindowWebKitTests {
    @Test("A real Little Orbit promotes with DOM, JS, history and request counts intact")
    func webKitLivePromotion() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        let main = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let first = URL(string: "http://127.0.0.1:\(port)/first")!, second = URL(string: "http://127.0.0.1:\(port)/second")!
        let little = try await environment.makeQuickWindow(spaceID: main.session.snapshot?.activeSpaceID, url: first)
        let surface = try #require(little.surface)
        try await waitForQuickWindowWebKit { surface.webView.title == "First" && !surface.webView.isLoading }
        surface.navigate(to: second)
        try await waitForQuickWindowWebKit { surface.webView.title == "Second" && !surface.webView.isLoading }
        _ = try await surface.webView.evaluateJavaScript("document.getElementById('draft').value='synthetic draft';window.littleMarker=73;void 0")
        let generation = surface.documentGeneration
        let history = surface.webView.backForwardList.backList.map(\.url)
        let requests = [server.matchingRequests(path: "/first"), server.matchingRequests(path: "/second")]
        let task = try #require(little.promote(to: main))
        let occurrence = try #require(await task.value)
        await main.session.waitForPendingCommands()
        #expect(little.isClosed && environment.quickWindows.isEmpty)
        #expect(main.session.selectedSurface === surface)
        #expect(surface.webView.window === main.window && surface.delegate === main)
        #expect(surface.documentGeneration == generation)
        #expect(surface.webView.backForwardList.backList.map(\.url) == history)
        #expect(surface.placement == .tab(windowID: try #require(main.session.snapshot?.id), occurrenceID: occurrence))
        #expect(try await surface.webView.evaluateJavaScript("document.getElementById('draft').value+':'+window.littleMarker") as? String == "synthetic draft:73")
        #expect([server.matchingRequests(path: "/first"), server.matchingRequests(path: "/second")] == requests)
        #expect(main.window?.isVisible == false && !NSApp.isActive)
        surface.goBack()
        try await waitForQuickWindowWebKit { surface.webView.title == "First" && !surface.webView.isLoading }
    }

    @Test("Cold external delivery can create only Little Orbits, without a main browser window")
    func externalWithoutMainWindow() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, externalURLStartupComplete: false, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        app.application(NSApp, open: [URL(string: "http://127.0.0.1:\(port)/first")!])
        app.finishExternalURLStartup()
        await app.waitForQuickWindowCommands()
        #expect(environment.quickWindows.count == 1)
        #expect(app.windows.windows.isEmpty && !app.windows.hasPendingWindow)
        #expect(environment.quickWindows.values.first?.window?.isVisible == false)
    }

    @Test("The external route captures the last Space, preserves order and obeys Open Links")
    func externalRouting() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, externalURLStartupComplete: false, windowPresenter: { _, _ in })
        var presented: [WindowID] = []
        app.quickWindowPresenter = { presented.append($0.id) }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        let first = URL(string: "http://127.0.0.1:\(port)/first")!, second = URL(string: "http://127.0.0.1:\(port)/second")!
        app.application(NSApp, open: [first])
        app.application(NSApp, open: [second])
        #expect(environment.quickWindows.isEmpty)
        app.windows.newWindow()
        app.finishExternalURLStartup()
        await app.windows.waitForPendingCommands()
        await app.waitForQuickWindowCommands()
        #expect(presented.count == 2 && environment.quickWindows.count == 2)
        let main = try #require(app.activeBrowserWindow)
        #expect(main.session.snapshot?.tabs.count == 1)
        #expect(environment.quickWindows.values.allSatisfy { $0.profileID == main.session.activeProfileID && $0.sourceSpaceID == main.session.snapshot?.activeSpaceID })
        #expect(presented.compactMap { environment.quickWindows[$0]?.surface?.currentURL } == [first, second])
        #expect(environment.quickWindows.values.allSatisfy { $0.window?.isVisible == false })
        try await environment.settings.store.setOpensExternalLinksInQuickWindow(false)
        await environment.settings.refresh()
        app.application(NSApp, open: [first])
        await main.session.waitForPendingCommands()
        #expect(main.session.snapshot?.tabs.last?.url == first)
        #expect(presented.count == 2)
        #expect(main.window?.isVisible == false && !NSApp.isActive)
    }

    @Test("A later main-window activation cannot retarget an accepted external URL to another profile")
    func externalProfileCapture() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        let firstID = try #require(app.windows.newWindow())
        let secondID = try #require(app.windows.newWindow())
        await app.windows.waitForPendingCommands()
        let first = try #require(app.windows.windows[firstID])
        let second = try #require(app.windows.windows[secondID])
        let profile = await environment.store.createProfile(name: "Synthetic alternate profile")
        let space = try await environment.store.createSpace(name: "Synthetic alternate Space", profileID: profile)
        second.session.activateSpace(space)
        await second.session.waitForPendingCommands()
        app.windows.activate(firstID)
        app.application(NSApp, open: [URL(string: "http://127.0.0.1:\(port)/first")!])
        app.windows.activate(secondID)
        await app.waitForQuickWindowCommands()
        let little = try #require(environment.quickWindows.values.first)
        #expect(little.sourceSpaceID == first.session.snapshot?.activeSpaceID)
        #expect(little.profileID == first.session.activeProfileID && little.profileID != profile)
        // The current main window has a foreign profile. Promotion must create a window in the
        // original Space instead of reloading or moving into the foreign profile.
        app.promoteQuickWindow(little)
        await app.waitForQuickWindowCommands()
        #expect(little.isClosed)
        #expect(app.activeBrowserWindow?.session.activeProfileID == first.session.activeProfileID)
        #expect(second.session.activeProfileID == profile)
        #expect(app.windows.windows.count == 3)
    }

    @Test("The Open in label follows the actual current Space while the captured source profile stays fixed")
    func promotionDestinationLabel() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        let main = try #require(app.activeBrowserWindow)
        let profile = try #require(main.session.activeProfileID)
        app.openQuickWindow()
        await app.waitForQuickWindowCommands()
        let little = try #require(environment.quickWindows.values.first)
        let sourceSpace = little.sourceSpaceID
        let destinationSpace = try await environment.store.createSpace(name: "Synthetic destination", profileID: profile)
        main.session.activateSpace(destinationSpace)
        await main.session.waitForPendingCommands()
        #expect(little.openButton.title == "Open in Synthetic destination")
        #expect(little.openButton.shortcut == "⌘O")
        #expect(little.sourceSpaceID == sourceSpace && little.profileID == profile)
        app.promoteQuickWindow(little)
        await app.waitForQuickWindowCommands()
        #expect(little.isClosed)
        #expect(main.session.snapshot?.activeSpaceID == destinationSpace)
    }

    @Test("The New Little Orbit command opens an unloaded document in the last selected Space")
    func newQuickWindowCommand() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        #expect(app.commands.registry.resolve(.init(key: "n", modifiers: [.option, .command])) == .newQuickWindowWindow)
        #expect(app.commands.registry.dispatch(.newQuickWindowWindow, origin: .keyboard))
        await app.waitForQuickWindowCommands()
        let little = try #require(environment.quickWindows.values.first)
        #expect(little.surface?.currentURL == nil)
        #expect(little.profileID == app.activeBrowserWindow?.session.activeProfileID)
        #expect(little.window?.isVisible == false)
    }

    @Test("Promotion creates a main window without an extra blank tab when none is open")
    func promotesWithoutMainWindow() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        app.openQuickWindow()
        await app.waitForQuickWindowCommands()
        let little = try #require(environment.quickWindows.values.first)
        let surface = try #require(little.surface)
        app.promoteQuickWindow(little)
        await app.waitForQuickWindowCommands()
        let main = try #require(app.activeBrowserWindow)
        #expect(main.session.snapshot?.tabs.count == 1)
        #expect(main.session.selectedSurface === surface)
        #expect(little.isClosed && !surface.isDisposed)
        #expect(main.window?.isVisible == false)
    }
}
}
