import AppKit
import BrowserCore
import Testing
@testable import BrowserShell
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
// The first three scenarios reproduce the independent LITTLE-R2 review (disposable replay).
struct NativeQuickWindowR3Tests {
    @Test("A refused promotion reveals a provisional window that acquired another document")
    func refusedPromotionPreservesVisibleDestination() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        var presented: [UUID] = []
        let app = OrbitApplication(environment: environment, windowPresenter: { controller, _ in presented.append(controller.id) })
        app.quickWindowPresenter = { _ in }
        app.quickWindowRoutingFailure = {}
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        app.openQuickWindow()
        await app.waitForQuickWindowCommands()
        let little = try #require(environment.quickWindows.values.first)
        app.quickWindowPromotionWindowPrepared = { target in
            target.openTab(url: URL(string: "data:text/html,synthetic-review-document")!)
            little.window?.close()
        }
        app.promoteQuickWindow(little)
        await app.waitForQuickWindowCommands()
        let destination = try #require(app.windows.windows.values.first)
        #expect(destination.session.snapshot?.tabs.isEmpty == false)
        #expect(little.isClosed)
        #expect(presented.contains(destination.id))
    }

    @Test("A quarantined captured profile cannot fall through to another account")
    func quarantinedProfileKeepsBoundary() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        _ = try await environment.initialContext.value
        let capturedProfile = try await environment.store.createSettingsProfile(name: "Synthetic quarantined account")
        let capturedSpace = try await environment.store.createSpace(name: "Synthetic captured Space", profileID: capturedProfile)
        try await environment.store.removeSettingsSpace(capturedSpace)
        _ = try await environment.store.reserveSettingsProfileRemoval(capturedProfile)
        defer { environment.retireQuickWindows() }
        let url = URL(string: "https://synthetic.invalid/captured-account")!
        await #expect(throws: BrowserSettingsError.profileBeingDeleted) {
            _ = try await environment.makeQuickWindow(spaceID: capturedSpace, url: url, preferredProfileID: capturedProfile)
        }
        #expect(environment.quickWindows.isEmpty)
        await environment.store.cancelSettingsProfileReservation(capturedProfile)
        try await environment.store.restoreSettingsSpace(capturedSpace, expectedProfileID: capturedProfile)
        let recovered = try await environment.makeQuickWindow(spaceID: capturedSpace, url: url, preferredProfileID: capturedProfile)
        #expect(recovered.profileID == capturedProfile && recovered.sourceSpaceID == capturedSpace)
        #expect(recovered.surface?.currentURL == url)
    }

    @Test("An external URL survives a pending main window whose source closes", arguments: [true, false])
    func externalURLDuringFailedWindowCreation(opensInQuickWindow: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        app.quickWindowRoutingFailure = {}
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        let source = try #require(app.activeBrowserWindow)
        let profileID = try #require(source.session.activeProfileID)
        try await environment.settings.setOpensExternalLinksInQuickWindow(opensInQuickWindow)
        let entered = AsyncStream<Void>.makeStream(), gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        source.session.enqueue { _ in
            entered.continuation.yield(())
            for await _ in gate.stream { break }
        }
        for await _ in entered.stream { break }
        #expect(app.commands.registry.dispatch(.newWindow, origin: .menu))
        #expect(app.windows.hasPendingWindow)
        let url = URL(string: "https://synthetic.invalid/review-pending-window")!
        app.application(NSApp, open: [url])
        source.window?.close()
        gate.continuation.finish()
        await app.windows.waitForPendingCommands()
        await app.waitForQuickWindowCommands()
        let delivered = environment.quickWindows.values.contains { $0.surface?.currentURL == url }
            || app.windows.windows.values.contains { $0.session.snapshot?.tabs.contains { $0.url == url } == true }
        #expect(delivered || app.unroutedQuickWindowURLs.contains(url))
        let request = try #require(app.quickWindowOpenRequests.first)
        #expect(!request.isRouting && request.profileID == profileID)
        #expect(request.opensInQuickWindow == opensInQuickWindow)

        // Neither an intervening account switch nor a Settings toggle may retarget a retry.
        let foreign = try await environment.store.createSettingsProfile(name: "Synthetic retry foreign account")
        let foreignSpace = try await environment.store.createSpace(name: "Synthetic foreign Space", profileID: foreign)
        let foreignID = UUID()
        app.quickWindowDestinationSpaces[foreignID] = foreignSpace
        app.windows.newWindow(id: foreignID)
        await app.windows.waitForPendingCommands()
        let foreignWindow = try #require(app.windows.windows[foreignID])
        try await environment.settings.setOpensExternalLinksInQuickWindow(!opensInQuickWindow)
        app.retryUnroutedQuickWindowURLs()
        app.retryUnroutedQuickWindowURLs() // An in-flight retry is not submitted twice.
        await app.waitForQuickWindowCommands()
        #expect(app.unroutedQuickWindowURLs.isEmpty)
        #expect(foreignWindow.session.snapshot?.tabs.contains { $0.url == url } == false)
        if opensInQuickWindow {
            let little = try #require(environment.quickWindows.values.first)
            #expect(little.profileID == profileID && little.surface?.currentURL == url)
        } else {
            #expect(environment.quickWindows.isEmpty)
            let destination = try #require(app.activeBrowserWindow)
            #expect(destination.session.activeProfileID == profileID)
            #expect(destination.session.snapshot?.tabs.filter { $0.url == url }.count == 1)
        }
    }

    @Test("A quarantined captured request is retained through fallback and retries until its account recovers", arguments: [true, false])
    func quarantineRetainsRequestAndProfile(hasURL: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        _ = try await environment.initialContext.value
        let profile = try await environment.store.createSettingsProfile(name: "Synthetic captured account")
        let space = try await environment.store.createSpace(name: "Synthetic captured Space", profileID: profile)
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        var failures = 0
        app.quickWindowRoutingFailure = { failures += 1 }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        let sourceID = UUID()
        app.quickWindowDestinationSpaces[sourceID] = space
        app.windows.newWindow(id: sourceID)
        await app.windows.waitForPendingCommands()
        let source = try #require(app.activeBrowserWindow)
        let entered = AsyncStream<Void>.makeStream(), gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        app.enqueueQuickWindowCommand {
            entered.continuation.yield(())
            for await _ in gate.stream { break }
        }
        for await _ in entered.stream { break }
        let url = hasURL ? URL(string: "https://synthetic.invalid/quarantined-request")! : nil
        if let url { app.application(NSApp, open: [url]) }
        else { app.openQuickWindow() }
        await source.session.waitForPendingCommands() // The account capture succeeds before closure.
        source.window?.close()
        await source.session.waitForPendingCommands()
        // A user can reserve removal only after unassigning all Spaces. Keep the already
        // captured request queued while its source Space is deleted and its account quarantined.
        try await environment.store.removeSettingsSpace(space)
        _ = try await environment.store.reserveSettingsProfileRemoval(profile)
        gate.continuation.finish()
        await app.waitForQuickWindowCommands()
        let request = try #require(app.quickWindowOpenRequests.first)
        #expect(app.unroutedQuickWindowURLs == (url.map { [$0] } ?? []) && failures == 1)
        #expect(request.profileID == profile && !request.isRouting)
        #expect(environment.quickWindows.isEmpty && app.windows.windows.isEmpty)
        app.retryUnroutedQuickWindowURLs()
        await app.waitForQuickWindowCommands()
        #expect(app.quickWindowOpenRequests.first === request && failures == 2)
        #expect(environment.quickWindows.isEmpty && app.windows.windows.isEmpty)
        await environment.store.cancelSettingsProfileReservation(profile)
        try await environment.store.restoreSettingsSpace(space, expectedProfileID: profile)
        app.retryUnroutedQuickWindowURLs()
        app.retryUnroutedQuickWindowURLs() // A recovery in flight must not enqueue the request twice.
        await app.waitForQuickWindowCommands()
        let little = try #require(environment.quickWindows.values.first)
        #expect(little.profileID == profile && little.surface?.currentURL == url)
        #expect(environment.quickWindows.count == 1 && app.quickWindowOpenRequests.isEmpty)
        #expect(app.unroutedQuickWindowURLs.isEmpty && failures == 2)
        app.retryUnroutedQuickWindowURLs()
        await app.waitForQuickWindowCommands()
        #expect(environment.quickWindows.count == 1 && environment.quickWindows.values.first === little)
    }

    @Test("Delivery refuses a foreign profile before loading and confirms before a later Space switch")
    func deliveryHasProfileAndCommandBoundary() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let main = try await environment.makeWindow()
        defer { main.window?.close() }
        let original = try #require(main.session.snapshot?.activeSpaceID)
        let foreign = try await environment.store.createSettingsProfile(name: "Synthetic delivery account")
        let foreignSpace = try await environment.store.createSpace(name: "Synthetic foreign Space", profileID: foreign)
        let url = URL(string: "https://synthetic.invalid/profile-checked-delivery")!
        let rejected = main.session.openTabForDelivery(url: url, expectedProfileID: foreign)
        #expect(await rejected.value == nil)
        #expect(main.session.snapshot?.tabs.contains { $0.url == url } == false)
        main.session.activateSpace(foreignSpace)
        let accepted = main.session.openTabForDelivery(url: url, expectedProfileID: foreign)
        main.session.activateSpace(original)
        await main.session.waitForPendingCommands()
        let tab = try #require(await accepted.value)
        #expect(tab.url == url && tab.spaceID == foreignSpace)
        #expect(main.session.snapshot?.activeSpaceID == original)
    }

    @Test("Delivery adopts an archive reconciliation from another window without duplicating the link")
    func deliveryAdoptsOrganizationReconciliation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let source = try await environment.makeWindow()
        let space = try #require(source.session.snapshot?.activeSpaceID)
        let other = try await environment.makeWindow(spaceID: space)
        defer { source.window?.close(); other.window?.close() }
        let snapshot = try #require(source.session.snapshot)
        let tab = try #require(snapshot.tabs.first)
        let profile = try #require(source.session.activeProfileID)
        let entered = AsyncStream<Void>.makeStream(), gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        source.session.enqueue { _ in
            entered.continuation.yield(())
            for await _ in gate.stream { break }
        }
        for await _ in entered.stream { break }
        let url = URL(string: "https://synthetic.invalid/organization-delivery")!
        let delivery = source.session.openTabForDelivery(url: url, expectedProfileID: profile)
        let otherID = try #require(other.session.snapshot?.id)
        _ = try await environment.store.archiveTabs([tab.id], from: environment.store.captureContext(in: otherID))
        gate.continuation.finish()
        let delivered = try #require(await delivery.value)
        #expect(delivered.url == url && delivered.spaceID == space)
        #expect(await environment.store.sessionDocument().tabs.filter { $0.url == url }.count == 1)
    }

    @Test("A Little Orbit fallback reveals its delivered page instead of leaving Library in front")
    func fallbackHidesLibrary() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        app.quickWindowRoutingFailure = {}
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        let main = try #require(app.activeBrowserWindow)
        main.showLibrary()
        await main.session.waitForPendingCommands()
        #expect(main.library.isPresented)
        environment.settingsRemovalIsRunning = true
        let url = URL(string: "https://synthetic.invalid/library-fallback")!
        app.openQuickWindow(url: url)
        await app.waitForQuickWindowCommands()
        #expect(main.session.snapshot?.tabs.contains { $0.url == url } == true)
        #expect(!main.library.isPresented && app.unroutedQuickWindowURLs.isEmpty)
    }

    @Test("Closing after model creation confirms one logical tab without fallback duplication or window resurrection")
    func closeAfterCreationKeepsDeliveryIdentity() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        var presentations = 0
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in presentations += 1 })
        app.quickWindowPresenter = { _ in }
        app.quickWindowRoutingFailure = {}
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        let source = try #require(app.activeBrowserWindow)
        presentations = 0
        environment.settingsRemovalIsRunning = true // Exercise the tab fallback.
        let url = URL(string: "https://synthetic.invalid/closed-after-created")!
        source.session.onChange = { [weak source] in
            if source?.session.snapshot?.tabs.contains(where: { $0.url == url }) == true { source?.window?.close() }
        }
        app.openQuickWindow(url: url, source: source)
        await app.waitForQuickWindowCommands()
        await source.session.waitForPendingCommands()
        #expect(source.session.isClosed && app.windows.windows.isEmpty)
        let records = await environment.store.sessionDocument().organization.tabs.filter { $0.url == url }
        #expect(records.count == 1)
        #expect(app.unroutedQuickWindowURLs.isEmpty && presentations == 0)
    }

    @Test("The promotion title and help use the provided registry binding, including no binding")
    func promotionShortcutTitle() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        defer { environment.retireQuickWindows() }
        let little = try await environment.makeQuickWindow()
        let shortcut = BrowserShortcut(key: "u", modifiers: [.command, .shift])
        little.promotionShortcut = { shortcut.displayLabel }
        little.render()
        #expect(little.openButton.title == "Open in \(little.sourceSpaceName)")
        #expect(little.openButton.shortcut == "⇧⌘U")
        #expect(little.openButton.toolTip == "Open in \(little.sourceSpaceName) (⇧⌘U)")
        #expect(!little.openButton.title.contains("⌘O"))
        little.promotionShortcut = { nil }
        little.render()
        #expect(little.openButton.title == "Open in \(little.sourceSpaceName)")
        #expect(little.openButton.toolTip == little.openButton.title)
    }
}
}
