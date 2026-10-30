import AppKit
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Little Orbit Space destinations", .serialized)
@MainActor
struct QuickWindowSpaceChooserTests {
    @Test("A cross-profile choice opens the current URL in the destination account and focuses it once",
          arguments: [false, true])
    func crossProfile(existingWindow: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        var presented: [UUID] = []
        let app = OrbitApplication(environment: environment, windowPresenter: { target, _ in presented.append(target.id) })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        _ = try await environment.initialContext.value
        if existingWindow {
            app.windows.newWindow()
            await app.windows.waitForPendingCommands()
        }
        let previousTarget = app.windows.selectedWindow
        let foreign = await environment.store.createProfile(name: "Synthetic destination account")
        _ = try await environment.store.createSpace(name: "Synthetic second Space", profileID: foreign)
        let destination = try await environment.store.createSpace(name: "Synthetic third Space", profileID: foreign)
        let little = try await environment.makeQuickWindow(url: URL(string: "https://synthetic.invalid/initial")!)
        app.configureQuickWindow(little)
        let original = try #require(little.surface)
        let url = URL(string: "https://synthetic.invalid/current")!
        original.navigate(to: url)
        app.showQuickWindowSpaces(little)
        for _ in 0..<10 { await Task.yield() }
        let row = try #require(little.spaceChooser?.rows.first { $0.id == destination.rawValue.uuidString })
        presented.removeAll()
        row.accept()
        row.accept() // Queued duplicate acceptance must not open another tab.
        await app.waitForQuickWindowCommands()
        let target = try #require(app.windows.windows.values.first { $0.session.snapshot?.activeSpaceID == destination })
        if let previousTarget { #expect(target === previousTarget) }
        let copy = try #require(target.session.selectedSurface)
        #expect(copy !== original && copy.profileID == foreign)
        #expect(copy.currentURL == url)
        #expect(copy.webView.configuration.websiteDataStore !== original.webView.configuration.websiteDataStore)
        #expect(target.session.snapshot?.tabs.filter { $0.url == url }.count == 1)
        #expect(target.session.activeProfileID == foreign)
        #expect(original.isDisposed && little.isClosed && environment.quickWindows.isEmpty)
        #expect(presented == [target.id])
    }

    @Test("Non-reloadable cross-profile pages keep their Little document and create no destination tab",
          arguments: ["", "about:blank", "blob:https://synthetic.invalid/id", "data:text/html,synthetic",
                      "file:///tmp/synthetic.html", "javascript:void(0)", "https://user:secret@synthetic.invalid/"])
    func unavailableURL(value: String) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        _ = try await environment.initialContext.value
        let foreign = await environment.store.createProfile(name: "Synthetic destination account")
        let destination = try await environment.store.createSpace(name: "Synthetic destination", profileID: foreign)
        let little = try await environment.makeQuickWindow(url: value.isEmpty ? nil : URL(string: value))
        let original = try #require(little.surface)
        app.promoteQuickWindow(little, to: destination)
        await app.waitForQuickWindowCommands()
        #expect(!little.isClosed && !little.isPromotionInProgress && little.owns(original))
        #expect(!original.isDisposed && app.windows.windows.isEmpty)
        #expect(await environment.store.sessionDocument().tabs.isEmpty)
    }

    @Test("A refusing cross-profile destination leaves the source intact and removes the empty provisional window")
    func rejectedDelivery() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        _ = try await environment.initialContext.value
        let foreign = await environment.store.createProfile(name: "Synthetic destination account")
        let destination = try await environment.store.createSpace(name: "Synthetic destination", profileID: foreign)
        let little = try await environment.makeQuickWindow(url: URL(string: "https://synthetic.invalid/retained")!)
        let original = try #require(little.surface)
        app.quickWindowPromotionWindowPrepared = { $0.freezeCommandsForTermination() }
        app.promoteQuickWindow(little, to: destination)
        await app.waitForQuickWindowCommands()
        #expect(!little.isClosed && little.owns(original) && !original.isDisposed)
        #expect(app.windows.windows.isEmpty)
    }

    @Test("A chooser and promotion never borrow a Little window from another environment",
          arguments: [false, true])
    func environmentIsolation(privateSource: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let normal = PreviewEnvironment(), memory = PreviewEnvironment()
        memory.isPrivate = true
        let source = privateSource ? memory : normal
        let other = privateSource ? normal : memory
        let sourceApp = OrbitApplication(environment: source, windowPresenter: { _, _ in })
        let otherApp = OrbitApplication(environment: other, windowPresenter: { _, _ in })
        defer {
            normal.retireQuickWindows(); memory.retireQuickWindows()
            sourceApp.windows.shutdown(); otherApp.windows.shutdown()
        }
        let little = try await source.makeQuickWindow(url: URL(string: "https://synthetic.invalid/isolated")!)
        let otherContext = try await other.initialContext.value
        otherApp.showQuickWindowSpaces(little)
        for _ in 0..<10 { await Task.yield() }
        #expect(little.spaceChooser == nil)
        otherApp.promoteQuickWindow(little, to: otherContext.0)
        await otherApp.waitForQuickWindowCommands()
        #expect(!little.isClosed && otherApp.windows.windows.isEmpty)
        sourceApp.showQuickWindowSpaces(little)
        for _ in 0..<10 { await Task.yield() }
        let rows = try #require(little.spaceChooser?.rows)
        let ownCatalog = await source.store.catalogSnapshot()
        #expect(rows.map(\.id) == ownCatalog.spaces.map { $0.id.rawValue.uuidString })
        #expect(!rows.contains { $0.id == otherContext.0.rawValue.uuidString })
        sourceApp.promoteQuickWindow(little, to: otherContext.0)
        await sourceApp.waitForQuickWindowCommands()
        #expect(!little.isClosed && sourceApp.windows.windows.isEmpty)
    }
}
}
