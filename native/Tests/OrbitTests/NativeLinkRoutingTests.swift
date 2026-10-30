import AppKit
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeLinkRoutingTests {
    @Test("External host and path overlaps follow saved order, then the default after deletion")
    func overlappingRules() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        let window = try #require(app.windows.selectedWindow)
        let hostSpace = try #require(window.session.snapshot?.activeSpaceID)
        let profile = try #require(window.session.activeProfileID)
        let pathSpace = try await environment.store.createSpace(name: "Path Destination", profileID: profile)
        let host = BrowserLinkRoute(match: .host, value: "example.org", spaceID: hostSpace)
        let path = BrowserLinkRoute(value: "/docs", spaceID: pathSpace)
        try await environment.settings.store.saveLinkRoute(host)
        try await environment.settings.store.saveLinkRoute(path)
        await environment.settings.refresh()
        let url = URL(string: "https://example.org/docs/start")!
        app.application(NSApp, open: [url])
        await app.waitForQuickWindowCommands()
        #expect(window.session.snapshot?.activeSpaceID == hostSpace)
        try await environment.settings.store.moveLinkRoute(path.id, offset: -1)
        await environment.settings.refresh()
        app.application(NSApp, open: [url])
        await app.waitForQuickWindowCommands()
        #expect(window.session.snapshot?.activeSpaceID == pathSpace)
        #expect(window.session.activeProfileID == profile)
        try await environment.settings.store.removeLinkRoute(path.id)
        try await environment.settings.store.removeLinkRoute(host.id)
        try await environment.settings.store.setLinkDefaultDestination(.mostRecentSpace)
        await environment.settings.refresh()
        app.application(NSApp, open: [url])
        await app.waitForQuickWindowCommands()
        #expect(window.session.snapshot?.activeSpaceID == pathSpace)
        #expect(environment.quickWindows.isEmpty)
        try await environment.settings.store.setLinkDefaultDestination(.quickWindow)
        await environment.settings.refresh()
        app.application(NSApp, open: [url])
        await app.waitForQuickWindowCommands()
        #expect(environment.quickWindows.count == 1)
        #expect(environment.quickWindows.values.first?.sourceSpaceID == pathSpace)
        #expect(app.unroutedQuickWindowURLs.isEmpty)
    }

    @Test("External matching links switch Space, while internal links keep their source Space")
    func routesOnlyExternalLinks() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        let window = try #require(app.windows.selectedWindow)
        let a = try #require(window.session.snapshot?.activeSpaceID)
        let profile = try #require(window.session.activeProfileID)
        let b = try await environment.store.createSpace(name: "Space B", profileID: profile)
        try await environment.settings.store.saveLinkRoute(.init(value: "example.org", spaceID: b))
        await environment.settings.refresh()
        let url = URL(string: "https://example.org/external")!
        window.session.openTab(url: url)
        await window.session.waitForPendingCommands()
        #expect(window.session.snapshot?.activeSpaceID == a)
        app.application(NSApp, open: [url])
        await app.waitForQuickWindowCommands()
        #expect(window.session.snapshot?.activeSpaceID == b)
        #expect(window.session.snapshot?.tabs.last?.url == url)
        #expect(app.unroutedQuickWindowURLs.isEmpty)
        #expect(environment.quickWindows.isEmpty)
        app.application(NSApp, open: [URL(string: "https://other.invalid/default")!])
        await app.waitForQuickWindowCommands()
        #expect(environment.quickWindows.count == 1)
        #expect(environment.quickWindows.values.first?.sourceSpaceID == b)
    }

    @Test("A route to a different profile creates the proper window and reuses it on later delivery")
    func foreignProfile() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        defer { app.windows.shutdown() }
        app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        let original = try #require(app.windows.selectedWindow)
        let originalSpace = original.session.snapshot?.activeSpaceID
        let profile = await environment.store.createProfile(name: "Routing Profile B")
        let space = try await environment.store.createSpace(name: "Routing Space B", profileID: profile)
        try await environment.settings.store.saveLinkRoute(.init(match: .host, value: "example.org", spaceID: space))
        await environment.settings.refresh()
        let first = URL(string: "https://example.org/first")!, second = URL(string: "https://example.org/second")!
        app.application(NSApp, open: [first, second])
        await app.waitForQuickWindowCommands()
        let target = try #require(app.windows.selectedWindow)
        #expect(target.id != original.id)
        #expect(target.session.activeProfileID == profile)
        #expect(target.session.snapshot?.activeSpaceID == space)
        #expect(target.session.snapshot?.tabs.map(\.url) == [first, second])
        #expect(original.session.snapshot?.activeSpaceID == originalSpace)
        #expect(app.windows.windows.count == 2)
        #expect(app.unroutedQuickWindowURLs.isEmpty)
    }

    @Test("Cold external delivery honors a fixed default Space without Little Circa")
    func fixedDefaultAndDeletedRule() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let initial = try await environment.initialContext.value
        let b = try await environment.store.createSpace(name: "Default Space B", profileID: initial.1)
        try await environment.settings.store.setLinkDefaultDestination(.space(b))
        // A stale deleted route must never deliver to an unrelated profile or lose the URL.
        try await environment.settings.store.saveLinkRoute(.init(value: "example.org", spaceID: SpaceID()))
        await environment.settings.refresh()
        let app = OrbitApplication(environment: environment, externalURLStartupComplete: false, windowPresenter: { _, _ in })
        defer { app.windows.shutdown() }
        let url = URL(string: "https://example.org/cold")!
        app.application(NSApp, open: [url])
        app.finishExternalURLStartup()
        await app.waitForQuickWindowCommands()
        #expect(app.windows.selectedWindow?.session.snapshot?.activeSpaceID == b)
        #expect(app.windows.selectedWindow?.session.snapshot?.tabs.last?.url == url)
        #expect(environment.quickWindows.isEmpty)
        #expect(app.unroutedQuickWindowURLs.isEmpty)
    }
}
}
