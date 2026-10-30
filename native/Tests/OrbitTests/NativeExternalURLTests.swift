import AppKit
import BrowserCore
@testable import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeExternalURLTests {
    private func tabRoutingEnvironment() async throws -> PreviewEnvironment {
        let environment = PreviewEnvironment()
        try await environment.settings.store.setOpensExternalLinksInQuickWindow(false)
        await environment.settings.refresh()
        return environment
    }

    @Test("Cold launch retains multiple URL events until restored windows have been scheduled")
    func coldLaunch() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = try await tabRoutingEnvironment()
        var presented = 0
        let app = OrbitApplication(environment: environment, externalURLStartupComplete: false,
                                  windowPresenter: { _, _ in presented += 1 })
        defer { app.windows.shutdown() }
        let first = URL(string: "https://synthetic.invalid/#cold-first")!
        let second = URL(string: "https://synthetic.invalid/#cold-second")!
        app.application(NSApp, open: [first])
        app.application(NSApp, open: [second])
        #expect(app.windows.selectedWindowID == nil)
        app.windows.newWindow() // The real startup schedules restoration before draining URL events.
        app.finishExternalURLStartup()
        await app.windows.waitForPendingCommands()
        let controller = try #require(app.activeBrowserWindow)
        await controller.session.waitForPendingCommands()
        let urls = try #require(controller.session.snapshot).tabs.map(\.url)
        #expect(Array(urls.suffix(2)) == [first, second])
        #expect(app.windows.windows.count == 1)
        #expect(presented == 2)
        #expect(controller.window?.isVisible == false)
        #expect(!NSApp.isActive)
    }

    @Test("Warm URL delivery captures the last activated window and preserves URL order")
    func warmLaunch() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let app = OrbitApplication(environment: try await tabRoutingEnvironment(), windowPresenter: { _, _ in })
        defer { app.windows.shutdown() }
        let firstID = try #require(app.windows.newWindow())
        let secondID = try #require(app.windows.newWindow())
        await app.windows.waitForPendingCommands()
        app.windows.activate(firstID)
        let urls = [URL(string: "https://synthetic.invalid/#warm-first")!, URL(string: "https://synthetic.invalid/#warm-second")!]
        app.application(NSApp, open: urls)
        app.windows.activate(secondID)
        let first = try #require(app.windows.windows[firstID])
        let second = try #require(app.windows.windows[secondID])
        await first.session.waitForPendingCommands()
        await second.session.waitForPendingCommands()
        #expect(Array(try #require(first.session.snapshot).tabs.map(\.url).suffix(2)) == urls)
        #expect(second.session.snapshot?.tabs.count == 1)
        #expect(first.window?.isVisible == false && second.window?.isVisible == false)
    }

    @Test("External URLs create a window when none exists, including a pending creation")
    func noWindow() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let app = OrbitApplication(environment: try await tabRoutingEnvironment(), windowPresenter: { _, _ in })
        defer { app.windows.shutdown() }
        let first = URL(string: "https://synthetic.invalid/#new-first")!
        let second = URL(string: "https://synthetic.invalid/#new-second")!
        app.application(NSApp, open: [first])
        app.application(NSApp, open: [second])
        await app.windows.waitForPendingCommands()
        let controller = try #require(app.activeBrowserWindow)
        await controller.session.waitForPendingCommands()
        #expect(app.windows.windows.count == 1)
        #expect(Array(try #require(controller.session.snapshot).tabs.map(\.url).suffix(2)) == [first, second])
        #expect(controller.window?.isVisible == false)
    }
    @Test("An external URL received during a failed quit is replayed after cancellation")
    func failedQuitRetainsExternalURL() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let app = OrbitApplication(environment: try await tabRoutingEnvironment(), windowPresenter: { _, _ in })
        defer { app.windows.shutdown() }
        app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        let controller = try #require(app.activeBrowserWindow)
        let entered = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        controller.session.enqueue { _ in
            entered.continuation.yield(())
            entered.continuation.finish()
            for await _ in gate.stream { return }
        }
        for await _ in entered.stream { break }
        let url = URL(string: "https://synthetic.invalid/#during-quit")!
        let delivery = Task { @MainActor in
            while !app.isPreparingToQuit { await Task.yield() }
            app.application(NSApp, open: [url])
        }
        await #expect(throws: BrowserTerminationPreparationError.commandsDidNotSettle) {
            try await app.completeTermination(timeout: .milliseconds(50))
        }
        await delivery.value
        gate.continuation.finish()
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.tabs.last?.url == url)
        #expect(controller.window?.isVisible == false)
    }

    @Test("External delivery rejects internal schemes and nonlocal file authorities")
    func allowedExternalSchemes() {
        for text in ["chrome://settings", "javascript:alert(1)", "about:blank", "data:text/html,test", "https:///", "relative"] {
            #expect(ExternalURLResolver.resolve(URL(string: text)!) == nil)
        }
        #expect(ExternalURLResolver.resolve(URL(string: "https://synthetic.invalid/")!) != nil)
        #expect(ExternalURLResolver.resolve(URL(string: "http://synthetic.invalid/")!) != nil)
        #expect(ExternalURLResolver.resolve(URL(string: "file://remote.invalid/synthetic.html")!) == nil)
        #expect(ExternalURLResolver.resolve(URL(fileURLWithPath: "/tmp/synthetic.txt")) == nil)
        #expect(ExternalURLResolver.resolve(URL(fileURLWithPath: "/nonexistent/synthetic.html")) == nil)
    }

    @Test("Internet shortcut documents resolve only bounded HTTP and HTTPS destinations")
    func shortcutDocuments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let webloc = directory.appendingPathComponent("synthetic.webloc")
        let target = URL(string: "https://synthetic.invalid/external")!
        try PropertyListSerialization.data(fromPropertyList: ["URL": target.absoluteString], format: .xml, options: 0).write(to: webloc)
        #expect(ExternalURLResolver.resolve(webloc) == target)
        let shortcut = directory.appendingPathComponent("synthetic.url")
        try "[InternetShortcut]\r\nURL=\(target.absoluteString)\r\n".write(to: shortcut, atomically: true, encoding: .utf8)
        #expect(ExternalURLResolver.resolve(shortcut) == target)
        try "[InternetShortcut]\nURL=javascript:alert(1)".write(to: shortcut, atomically: true, encoding: .utf8)
        #expect(ExternalURLResolver.resolve(shortcut) == nil)
        try Data(repeating: 65, count: 65_537).write(to: webloc)
        #expect(ExternalURLResolver.resolve(webloc) == nil)
        let html = directory.appendingPathComponent("synthetic.html")
        try Data().write(to: html)
        #expect(ExternalURLResolver.resolve(html) == html)
    }

}
}
