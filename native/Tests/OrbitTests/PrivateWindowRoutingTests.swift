import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Private window product routing", .serialized)
@MainActor
struct PrivateWindowRoutingTests {
    @Test("File command works without a source window and private domains remain separate until cleanup")
    func menuAndLifetime() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let normal = PreviewEnvironment()
        var key: NSWindow?
        let app = OrbitApplication(environment: normal, commandKeyWindow: { key }, windowPresenter: { _, _ in })
        #expect(app.commands.registry.dispatch(.newIncognitoWindow, origin: .menu))
        await app.waitForPrivateWindowCommands()
        let first = try #require(app.windows.selectedWindow)
        key = first.window
        let firstDomain = try #require(app.privateWindows[first.id])
        #expect(first.isPrivateWindow && !first.savesSessionLocally)
        #expect(first.engine !== normal.engine && firstDomain.environment.sessionFile == nil)
        #expect(first.resolvedSpaceTheme(for: nil) == OrbitSpaceThemes.privateWindow)
        first.window?.contentView?.layoutSubtreeIfNeeded()
        let indicator = try #require(first.sidebar.subviews.first { $0.accessibilityIdentifier() == "private-window-indicator" })
        #expect(!indicator.isHidden && first.sidebar.bounds.contains(indicator.frame))
        #expect(first.contentCard.displayedEmptyTitle == "Private")
        #expect(first.window?.isOpaque == false)
        #expect(app.commands.registry.dispatch(.newIncognitoWindow, origin: .keyboard))
        await app.waitForPrivateWindowCommands()
        let second = try #require(app.windows.selectedWindow)
        let secondDomain = try #require(app.privateWindows[second.id])
        #expect(first.engine !== second.engine && first.session.activeProfileID != second.session.activeProfileID)
        #expect(firstDomain.environment.downloads !== secondDomain.environment.downloads)
        #expect(firstDomain.environment.store !== normal.store)
        #expect(await normal.store.sessionDocument().windows.isEmpty)
        key = second.window
        #expect(!app.commands.registry.isEnabled(.newSpace))
        #expect(!app.commands.registry.isEnabled(.newQuickWindowWindow))
        #expect(!app.commands.registry.isEnabled(.manageExtensions))
        await app.closePrivateWindows()
        #expect(firstDomain.scope.isClosed && secondDomain.scope.isClosed)
        #expect(app.privateWindows.isEmpty && app.windows.windows.isEmpty)
        #expect(app.privateWindowFactory?.quarantinedScopes.isEmpty == true)
        normal.autoArchive.scheduler.stop()
        app.windows.shutdown()
    }

    @Test("French palette action opens a private window; New Window does not inherit its profile")
    func paletteAndNormalWindow() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let normal = PreviewEnvironment()
        var key: NSWindow?
        let app = OrbitApplication(environment: normal, commandKeyWindow: { key }, windowPresenter: { _, _ in })
        let normalID = try #require(app.windows.newWindow())
        await app.windows.waitForPendingCommands()
        let source = try #require(app.windows.windows[normalID])
        key = source.window
        source.palette.present(.newTab)
        await source.palette.waitForResults()
        source.palette.query("nouvelle fenêtre privée")
        let index = try #require(source.palette.results.firstIndex { $0.action == .command(.newIncognitoWindow) })
        source.palette.move(index - source.palette.selection.index)
        source.palette.accept()
        await source.palette.waitForAcceptance()
        await app.waitForPrivateWindowCommands()
        let memory = try #require(app.windows.selectedWindow)
        #expect(memory.isPrivateWindow && memory.session.activeProfileID != source.session.activeProfileID)
        key = memory.window
        memory.palette.dismiss()
        #expect(app.commands.registry.dispatch(.newWindow, origin: .keyboard))
        await app.windows.waitForPendingCommands()
        let created = try #require(app.windows.selectedWindow)
        #expect(!created.isPrivateWindow && created.engine === normal.engine)
        #expect(created.session.activeProfileID == source.session.activeProfileID)
        await app.closePrivateWindows()
        normal.autoArchive.scheduler.stop()
        app.windows.shutdown()
    }
}
}
