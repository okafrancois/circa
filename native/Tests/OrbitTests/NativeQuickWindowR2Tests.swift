import AppKit
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
@testable import BrowserShell
import Darwin
import Foundation
import Testing
import WebKit
import WebKitEngine
@testable import Orbit

private enum QuickWindowR2Error: Error { case timedOut }

@MainActor
private func quickWindowR2Wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw QuickWindowR2Error.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func quickWindowR2Root() throws -> URL {
    let canonical = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(canonical) }
    return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        .appendingPathComponent("Orbit-LITTLE-R2-" + UUID().uuidString, isDirectory: true)
}

@MainActor
private final class QuickWindowR2LimitedEngine: BrowserEngine {
    let reference = PeekSyntheticEngine()
    let kind = BrowserEngineKind.synthetic
    let capabilities: BrowserEngineCapabilities = []
    var extensions: (any BrowserExtensionHost)? { nil }
    func profile(for profileID: ProfileID) -> BrowserEngineProfile { reference.profile(for: profileID) }
    func makeSurface(profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<PeekSyntheticSurface>) -> PeekSyntheticSurface {
        reference.makeSurface(profileID: profileID, delegate: delegate)
    }
    func shutdown() async {}
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeQuickWindowR2Tests {
    @Test("Little Circa has normal window level and successive windows cascade without activation")
    func windowLevelAndCascade() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        defer { environment.retireQuickWindows() }
        let one = try await environment.makeQuickWindow(), two = try await environment.makeQuickWindow(), three = try await environment.makeQuickWindow()
        #expect([one, two, three].allSatisfy { $0.window?.level == .normal && $0.window?.isVisible == false })
        #expect(one.window?.frame.origin != two.window?.frame.origin)
        #expect(two.window?.frame.origin != three.window?.frame.origin)
        #expect(!NSApp.isActive)
    }

    @Test("Little Circa history records once, follows transfer metadata, and excludes ephemeral profiles")
    func historyAndPrivacy() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try quickWindowR2Root()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = PeekSyntheticEngine()
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: engine.profile(for:))
        let environment = BrowserEnvironment(engine: engine, history: recorder)
        let main = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let profile = try #require(main.session.activeProfileID)
        engine.persistentProfiles.insert(profile)
        let url = URL(string: "https://little-r2.test/history")!
        let little = try await environment.makeQuickWindow(url: url)
        await recorder.flush()
        #expect(try await recorder.visits(for: profile).filter { $0.url == url }.count == 1)
        let task = try #require(little.promote(to: main))
        #expect(await task.value != nil)
        await recorder.flush()
        #expect(try await recorder.visits(for: profile).filter { $0.url == url }.count == 1)
        let privateProfile = await environment.store.createProfile(name: "Synthetic ephemeral profile")
        let privateSpace = try await environment.store.createSpace(name: "Synthetic ephemeral Space", profileID: privateProfile)
        let ephemeral = try await environment.makeQuickWindow(spaceID: privateSpace, url: URL(string: "https://little-r2.test/private")!)
        ephemeral.window?.performClose(nil)
        await recorder.flush()
        try await environment.flushQuickWindowArchives()
        #expect(try await recorder.visits(for: privateProfile).isEmpty)
        #expect(await environment.store.sessionDocument().organization.archive.allSatisfy { $0.profileID != privateProfile })
        try await recorder.close()
    }

    @Test("The shared SITE policy honors stored decisions, rejects foreign origins and revokes pending prompts")
    func permissions() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let permissions = BrowserSitePermissionStore.ephemeral()
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine(), permissions: permissions)
        defer { environment.retireQuickWindows() }
        let url = URL(string: "https://little-r2.test/page")!
        let little = try await environment.makeQuickWindow(url: url)
        let surface = try #require(little.surface)
        let origin = try #require(BrowserSiteOrigin(url: url))
        let request = BrowserPermissionRequest(kind: .camera, origin: origin.value, isMainFrame: true)
        try await permissions.set(.block, for: [.camera], origin: origin, profileID: little.profileID)
        #expect(await little.surface(surface, requestsPermission: request) == .deny)
        try await permissions.set(.allow, for: [.camera], origin: origin, profileID: little.profileID)
        #expect(await little.surface(surface, requestsPermission: request) == .grant)
        let otherProfile = try await environment.store.createSettingsFixtureProfileWithSpace(name: "Synthetic separate permissions")
        let otherSpace = try #require(await environment.store.catalogSnapshot().spaces.first { $0.profileID == otherProfile }?.id)
        let other = try await environment.makeQuickWindow(spaceID: otherSpace, url: url)
        #expect(await other.surface(try #require(other.surface), requestsPermission: request) == .dismiss)
        #expect(await little.surface(surface, requestsPermission: .init(kind: .camera, origin: "https://foreign.test", isMainFrame: true)) == .deny)
        try await permissions.set(.ask, for: [.camera], origin: origin, profileID: little.profileID)
        let entered = AsyncStream<Void>.makeStream(), gate = AsyncStream<Void>.makeStream()
        little.siteControls.permissionPrompt = { _, _ in
            entered.continuation.yield(())
            for await _ in gate.stream { break }
            return .alwaysAllow
        }
        let answer = Task { await little.surface(surface, requestsPermission: request) }
        for await _ in entered.stream { break }
        surface.navigate(to: URL(string: "https://little-r2.test/replaced")!)
        gate.continuation.finish()
        #expect(await answer.value == .deny)
        #expect(await permissions.snapshot(origin: origin, profileID: little.profileID)[.camera] == .ask)
    }

    @Test("Unavailable SITE settings deny access instead of using the engine default")
    func unavailablePermissions() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine(), permissions: BrowserSitePermissionStore.unavailable())
        defer { environment.retireQuickWindows() }
        let little = try await environment.makeQuickWindow(url: URL(string: "https://little-r2.test/page")!)
        let surface = try #require(little.surface)
        #expect(await little.surface(surface, requestsPermission: .init(kind: .camera, origin: "https://little-r2.test", isMainFrame: true)) == .deny)
    }

    @Test("Quit checkpoints an open persistent Little Circa in the archive without losing its history or duplicating retries")
    func quitPreservesURL() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try quickWindowR2Root()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = PeekSyntheticEngine()
        let session = root.appendingPathComponent("session.json")
        let environment = try await BrowserEnvironment.open(engine: engine, sessionFile: session)
        let recorder = environment.historyRecorder
        let main = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let profile = try #require(main.session.activeProfileID)
        engine.persistentProfiles.insert(profile)
        let url = URL(string: "https://little-r2.test/quit")!
        let little = try await environment.makeQuickWindow(url: url)
        try await environment.prepareToSaveForTermination()
        #expect(!little.acceptsCommands)
        environment.terminationDidCancel()
        main.cancelTerminationPreparation()
        #expect(little.acceptsCommands)
        try await environment.prepareToSaveForTermination()
        try await environment.finalize()
        let document = try BrowserSessionFileStore().load(from: session)
        #expect(document.organization.archive.filter { $0.id == little.archiveID && $0.tab.url == url }.count == 1)
        #expect(try await recorder.visits(for: profile).filter { $0.url == url }.count == 1)
        #expect((try BrowserSessionDocument.decode(document.encoded())).organization.archive.contains { $0.tab.url == url })
        try await recorder.close()
    }

    @Test("Normal close makes a persistent Little Circa available to Reopen Closed Tab")
    func closeArchives() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = PeekSyntheticEngine()
        let environment = BrowserEnvironment(engine: engine)
        let main = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let profile = try #require(main.session.activeProfileID)
        engine.persistentProfiles.insert(profile)
        let url = URL(string: "https://little-r2.test/closed")!
        let little = try await environment.makeQuickWindow(url: url)
        little.window?.performClose(nil)
        try await environment.flushQuickWindowArchives()
        main.session.refreshCatalog()
        await main.session.waitForPendingCommands()
        main.session.restoreMostRecentArchivedTab()
        await main.session.waitForPendingCommands()
        #expect(main.session.selectedSurface?.currentURL == url)
    }

    @Test("Pending Little Circa snapshots respect profile quarantine and a completed user deletion")
    func archiveProfileDeletion() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = PeekSyntheticEngine()
        let environment = BrowserEnvironment(engine: engine)
        let main = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let profile = try await environment.store.createSettingsFixtureProfileWithSpace(name: "Synthetic removed archive profile")
        let space = try #require(await environment.store.catalogSnapshot().spaces.first { $0.profileID == profile }?.id)
        engine.persistentProfiles.insert(profile)
        let little = try await environment.makeQuickWindow(spaceID: space, url: URL(string: "https://little-r2.test/pending-close")!)
        let surface = try #require(little.surface)
        environment.captureQuickWindowForReopening(little, surface: surface)
        little.retire()
        little.window?.close()
        try await environment.store.removeSettingsSpace(space)
        _ = try await environment.store.reserveSettingsProfileRemoval(profile)
        try await environment.flushQuickWindowArchives()
        #expect(environment.pendingQuickWindowArchives[little.archiveID] != nil)
        await environment.store.cancelSettingsProfileReservation(profile)
        try await environment.flushQuickWindowArchives()
        let saved = try #require(await environment.store.sessionDocument().organization.archive.first { $0.id == little.archiveID })
        environment.pendingQuickWindowArchives[saved.id] = saved
        try await environment.store.removeSettingsProfile(profile)
        try await environment.flushQuickWindowArchives()
        #expect(environment.pendingQuickWindowArchives.isEmpty)
        #expect(await environment.store.sessionDocument().organization.archive.allSatisfy { $0.profileID != profile })
    }

    @Test("A deleted remembered Space is revalidated and external delivery still opens its URL")
    func staleSpaceNeverDropsURL() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        environment.lastUsedSpaceID = SpaceID()
        let server = try LocalFixtureServer(), port = try await server.start()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/first")!
        app.openQuickWindow(url: url, spaceID: SpaceID())
        await app.waitForQuickWindowCommands()
        #expect(environment.quickWindows.values.first?.surface?.currentURL == url)
        #expect(app.unroutedQuickWindowURLs.isEmpty)
    }

    @Test("A captured context that closes before delivery falls back to a main tab instead of dropping the URL")
    func closedContextFallback() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        let main = try #require(app.activeBrowserWindow)
        let originalProfile = try #require(main.session.activeProfileID)
        let foreignProfile = try await environment.store.createSettingsFixtureProfileWithSpace(name: "Synthetic current foreign profile")
        let foreignSpace = try #require(await environment.store.catalogSnapshot().spaces.first { $0.profileID == foreignProfile }?.id)
        let foreignID = UUID()
        app.quickWindowDestinationSpaces[foreignID] = foreignSpace
        app.windows.newWindow(id: foreignID)
        await app.windows.waitForPendingCommands()
        let foreignWindow = try #require(app.windows.windows[foreignID])
        let entered = AsyncStream<Void>.makeStream(), gate = AsyncStream<Void>.makeStream()
        main.session.enqueue { _ in
            entered.continuation.yield(())
            for await _ in gate.stream { break }
        }
        for await _ in entered.stream { break }
        let server = try LocalFixtureServer(), port = try await server.start()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/first")!
        app.openQuickWindow(url: url, source: main)
        main.window?.close()
        gate.continuation.finish()
        await app.waitForQuickWindowCommands()
        #expect(environment.quickWindows.isEmpty)
        #expect(app.activeBrowserWindow?.session.snapshot?.tabs.contains { $0.url == url } == true)
        #expect(app.unroutedQuickWindowURLs.isEmpty)
        #expect(app.activeBrowserWindow?.session.activeProfileID == originalProfile)
        #expect(foreignWindow.session.snapshot?.tabs.contains { $0.url == url } == false)
    }

    @Test("A captured profile removed by Settings is refused instead of falling back to another account")
    func deletedSpace() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let main = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let profile = try #require(main.session.activeProfileID)
        let removedProfile = try await environment.store.createSettingsFixtureProfileWithSpace(name: "Synthetic removed profile")
        let removed = try #require(await environment.store.catalogSnapshot().spaces.first { $0.profileID == removedProfile }?.id)
        environment.lastUsedSpaceID = removed
        try await environment.store.removeSettingsSpace(removed)
        try await environment.store.removeSettingsProfile(removedProfile)
        await #expect(throws: BrowserStoreError.profileMissing) {
            _ = try await environment.makeQuickWindow(spaceID: removed, url: URL(string: "https://little-r2.test/not-lost")!, preferredProfileID: removedProfile)
        }
        #expect(environment.quickWindows.isEmpty && main.session.activeProfileID == profile)
    }

    @Test("A Space reassigned by Settings cannot move a captured Little Circa request to another profile")
    func reassignedSpaceKeepsCapturedProfile() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let main = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let profile = try #require(main.session.activeProfileID)
        let originalSpace = try await environment.store.createSpace(name: "Synthetic reassigned Space", profileID: profile)
        environment.lastUsedSpaceID = originalSpace
        let foreign = try await environment.store.createSettingsFixtureProfileWithSpace(name: "Synthetic other account")
        try await environment.store.assignSettingsSpace(originalSpace, to: foreign)
        let little = try await environment.makeQuickWindow(spaceID: originalSpace,
            url: URL(string: "https://little-r2.test/original-account")!, preferredProfileID: profile)
        #expect(little.profileID == profile && little.sourceSpaceID != originalSpace)
        #expect(little.sourceSpaceID == main.session.snapshot?.activeSpaceID)
    }

    @Test("Failed Little Circa creation falls back to a main tab for both a URL and an empty request")
    func creationFallback() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        let server = try LocalFixtureServer(), port = try await server.start()
        defer { server.stop() }
        environment.settingsRemovalIsRunning = true
        let url = URL(string: "http://127.0.0.1:\(port)/second")!
        app.openQuickWindow(url: url)
        await app.waitForQuickWindowCommands()
        #expect(app.activeBrowserWindow?.session.snapshot?.tabs.contains { $0.url == url } == true)
        let count = app.activeBrowserWindow?.session.snapshot?.tabs.count ?? 0
        app.openQuickWindow()
        await app.waitForQuickWindowCommands()
        #expect(app.activeBrowserWindow?.session.snapshot?.tabs.count == count + 1)
        #expect(environment.quickWindows.isEmpty && app.unroutedQuickWindowURLs.isEmpty)
    }

    @Test("Closing during promotion window creation is vetoed, and a refusing receiver leaves no empty model window")
    func promotionPreparationAndCleanup() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        app.openQuickWindow()
        await app.waitForQuickWindowCommands()
        let little = try #require(environment.quickWindows.values.first)
        var visited = false
        app.quickWindowPromotionWindowPrepared = { target in
            visited = true
            little.window?.performClose(nil)
            #expect(!little.isClosed && little.isPromotionInProgress)
            target.freezeCommandsForTermination()
        }
        app.promoteQuickWindow(little)
        #expect(little.isPromotionInProgress)
        await app.waitForQuickWindowCommands()
        #expect(visited && !little.isClosed && !little.isPromotionInProgress)
        #expect(app.windows.windows.isEmpty)
        #expect(await environment.store.sessionDocument().windows.isEmpty)
        #expect(little.surface.map { little.container.owns($0) } == true)
    }

    @Test("A forced close before adoption also discards the hidden provisional main window")
    func forcedCloseDuringCreation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        app.openQuickWindow()
        await app.waitForQuickWindowCommands()
        let little = try #require(environment.quickWindows.values.first)
        app.quickWindowPromotionWindowPrepared = { _ in little.window?.close() }
        app.promoteQuickWindow(little)
        await app.waitForQuickWindowCommands()
        #expect(little.isClosed && app.windows.windows.isEmpty)
        #expect(await environment.store.sessionDocument().windows.isEmpty)
    }

    @Test("The real monitor and menu route Little Circa page commands while the browser router has no target")
    func pageCommandRoutes() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SyntheticEngine()
        let environment = BrowserEnvironment(engine: engine)
        defer { environment.retireQuickWindows() }
        let little = try await environment.makeQuickWindow(url: URL(string: "https://little-r2.test/first")!)
        let surface = try #require(little.surface)
        surface.navigate(to: URL(string: "https://little-r2.test/second")!)
        let router = BrowserWindowRouter<BrowserWindowController<SyntheticEngine>>(create: { _ in try await environment.makeWindow() },
            present: { _, _ in }, dispose: { _ in })
        let registry = try BrowserCommandRegistry(router: router, state: { _ in .init() }, currentWindowID: { nil })
        var active = true
        BrowserQuickWindowCommands.install(in: registry, active: { active ? little : nil }, promote: { _ in }, chooseSpace: { _ in })
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true }, firstResponder: { little.window?.firstResponder })
        let menus = BrowserCommandMenus(registry: registry, keyWindow: { little.window })
        let bar = menus.makeMenuBar()
        func event(_ key: String, flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: little.window?.windowNumber ?? 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
        }
        #expect(keyboard.handle(try event("t")))
        #expect(little.isEditingAddress)
        let input = try #require(little.compactInput)
        #expect(input.input.stringValue == surface.currentURL?.absoluteString)
        #expect(little.ownsCommandWindow(input.window))
        #expect(router.windows.isEmpty)
        little.window?.makeFirstResponder(nil)
        #expect(!keyboard.handle(try event("[")))
        #expect(bar.performKeyEquivalent(with: try event("[")))
        #expect(surface.currentURL?.path == "/first")
        #expect(bar.performKeyEquivalent(with: try event("]")))
        #expect(surface.currentURL?.path == "/second")
        #expect(bar.performKeyEquivalent(with: try event("f")))
        #expect(little.findSession.state?.isVisible == true)
        little.findSession.submit("synthetic")
        #expect(little.findSession.state?.query == "synthetic")
        little.findSession.close()
        #expect(bar.performKeyEquivalent(with: try event("+")))
        #expect(surface.pageZoom > 1)
        #expect(bar.performKeyEquivalent(with: try event("-")))
        var copied: URL?
        little.copyURLWriter = { copied = $0 }
        #expect(bar.performKeyEquivalent(with: try event("C", flags: [.command, .shift])))
        #expect(copied == surface.currentURL)
        #expect(bar.performKeyEquivalent(with: try event("p")))
        #expect(engine.printedSurfaces == [ObjectIdentifier(surface)])
        #expect(little.openButton.toolTip?.contains("⌘O") == true)
        #expect(little.openButton.accessibilityLabel()?.contains(little.sourceSpaceName) == true)
        active = false
        #expect(!registry.isEnabled(.find) && !registry.isEnabled(.print))
        #expect(!NSApp.isActive && little.window?.isVisible == false)
    }

    @Test("WebKit local HTML has an explicit read scope and survives transfer; remote file downloads are refused")
    func localHTMLAndPolicy() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try quickWindowR2Root()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("local.html")
        try "<!doctype html><title>Scoped local fixture</title><input id='draft'>".write(to: file, atomically: true, encoding: .utf8)
        let environment = PreviewEnvironment()
        let main = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let little = try await environment.makeQuickWindow(url: file)
        let surface = try #require(little.surface)
        try await quickWindowR2Wait { surface.webView.title == "Scoped local fixture" && !surface.webView.isLoading }
        _ = try await surface.webView.evaluateJavaScript("document.getElementById('draft').value='retained';void 0")
        let promotion = try #require(little.promote(to: main))
        #expect(await promotion.value != nil)
        #expect(try await surface.webView.evaluateJavaScript("document.getElementById('draft').value") as? String == "retained")
        let download = BrowserNavigationAction(url: file, shouldPerformDownload: true, isMainFrame: true, kind: .typed)
        #expect(main.navigationActionPolicy(for: download, in: surface) == .cancel)
        let other = try await environment.makeQuickWindow()
        let otherSurface = try #require(other.surface)
        let ungranted = BrowserNavigationAction(url: file, isMainFrame: true, kind: .linkActivation)
        #expect(BrowserNavigationPolicy.action(ungranted, surface: otherSurface, held: true, routesEnabled: true, hooks: other.engineEventHooks) == .cancel)
        var routed = 0
        other.engineEventHooks.routeNavigations { _, _ in routed += 1; return .handled(.cancel) }
        let http = BrowserNavigationAction(url: URL(string: "https://little-r2.test/routed")!)
        #expect(BrowserNavigationPolicy.action(http, surface: otherSurface, held: true, routesEnabled: true, hooks: other.engineEventHooks) == .cancel)
        #expect(routed == 1)
        main.openTab(url: file)
        await main.session.waitForPendingCommands()
        let mainLocal = try #require(main.session.selectedSurface)
        try await quickWindowR2Wait { mainLocal.webView.title == "Scoped local fixture" }
    }

    @Test("Last active window metadata restores activation order rather than UUID sort order")
    func lastActiveWindowRestoration() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try quickWindowR2Root()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("session.json")
        let environment = try await BrowserEnvironment.open(engine: PeekSyntheticEngine(), sessionFile: session)
        let first = try await environment.makeWindow(), second = try await environment.makeWindow()
        defer { first.window?.close(); second.window?.close() }
        let active = [first, second].sorted { $0.session.snapshot!.id.rawValue.uuidString < $1.session.snapshot!.id.rawValue.uuidString }.first!
        let profile = try #require(active.session.activeProfileID)
        let lastSpace = try await environment.store.createSpace(name: "Synthetic last active Space", profileID: profile)
        active.session.activateSpace(lastSpace)
        await active.session.waitForPendingCommands()
        active.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: active.window))
        let activeID = try #require(active.session.snapshot?.id)
        try await environment.finalize()
        first.retireForTermination(); second.retireForTermination()
        let reopened = try await BrowserEnvironment.open(engine: PeekSyntheticEngine(), sessionFile: session)
        #expect(reopened.restoredWindowIDs.last == activeID)
        #expect(reopened.lastUsedSpaceID == lastSpace)
        let little = try await reopened.makeQuickWindow()
        #expect(little.sourceSpaceID == lastSpace)
        reopened.retireQuickWindows()
        try await reopened.finalize()
    }

    @Test("The copy fallback never creates an about:blank tab for an empty Little Circa")
    func emptyCopyFallback() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: QuickWindowR2LimitedEngine())
        let main = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let little = try await environment.makeQuickWindow()
        let before = main.session.snapshot?.tabs.count
        #expect(little.promote(to: main) == nil)
        await main.session.waitForPendingCommands()
        #expect(main.session.snapshot?.tabs.count == before)
        little.surface?.navigate(to: URL(string: "about:blank")!)
        #expect(little.promote(to: main) == nil)
        await main.session.waitForPendingCommands()
        #expect(main.session.snapshot?.tabs.count == before && !little.canPrint)
    }

    @Test("A failed fallback retains its external URL and retries after a valid Space becomes available")
    func retainAndRetryUndeliveredURL() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let context = try await environment.initialContext.value
        // A synthetic recovery fixture with no usable Space, never a user's profile graph.
        await environment.store.recoverSettingsProfileRemoval(context.1)
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        var failures = 0
        app.quickWindowRoutingFailure = { failures += 1 }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        let server = try LocalFixtureServer(), port = try await server.start()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(port)/first")!
        app.openQuickWindow(url: url)
        await app.waitForQuickWindowCommands()
        #expect(app.unroutedQuickWindowURLs == [url] && failures == 1)
        _ = try await environment.store.createSettingsFixtureProfileWithSpace(name: "Synthetic recovered profile")
        app.retryUnroutedQuickWindowURLs()
        await app.waitForQuickWindowCommands()
        #expect(app.unroutedQuickWindowURLs.isEmpty)
        #expect(environment.quickWindows.values.first?.surface?.currentURL == url)
    }

    @Test("Unavailable Open Links settings refresh the published value after a failed write")
    func settingsFailureRefresh() async throws {
        let runtime = BrowserSettingsRuntime(store: BrowserSettingsStore.unavailable())
        await runtime.refresh()
        var refreshes = 0
        runtime.onChange = { refreshes += 1 }
        await #expect(throws: BrowserSettingsError.unavailable) { try await runtime.setOpensExternalLinksInQuickWindow(false) }
        #expect(runtime.document.opensExternalLinksInQuickWindow && refreshes == 1)
    }
}
}

extension NativeWebKitTests.NativeQuickWindowR2Tests {
    @Test("Deleting the final Space of a profile archives persistent Little Circa documents and excludes ephemeral ones", arguments: [false, true])
    func deletingSpaceArchivesQuickWindow(isPersistent: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = PeekSyntheticEngine()
        let environment = BrowserEnvironment(engine: engine)
        let main = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let profile = try await environment.store.createSettingsFixtureProfileWithSpace(name: "Little Circa deletion")
        let space = try #require(await environment.store.catalogSnapshot().spaces.first { $0.profileID == profile }?.id)
        if isPersistent { engine.persistentProfiles.insert(profile) }
        let little = try await environment.makeQuickWindow(spaceID: space, url: URL(string: "https://little-r2.test/deleted-space")!)
        let surface = try #require(little.surface)
        try await environment.removeSpaceFromSettings(space, expectedProfileID: profile)
        #expect(little.isClosed && surface.isDisposed && little.surface == nil)
        let doc = await environment.store.sessionDocument()
        try doc.validate()
        #expect(!doc.spaces.contains { $0.profileID == profile })
        #expect(doc.organization.archive.contains { $0.id == little.archiveID && $0.profileID == profile } == isPersistent)
        #expect(environment.pendingQuickWindowArchives.isEmpty)
        #expect(main.window?.isVisible == false && little.window?.isVisible == false)
    }
}
