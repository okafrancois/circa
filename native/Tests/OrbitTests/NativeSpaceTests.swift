import AppKit
import BrowserCore
import BrowserShell
import Foundation
import Testing
import WebKit
@testable import Orbit
import BrowserEngine
import WebKitEngine

private enum NativeSpaceTestError: Error { case timedOut }

@MainActor
private func waitForSpaceState(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(12)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw NativeSpaceTestError.timedOut }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private func spaceTestDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "/private/tmp/OrbitSpaces-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    return directory
}

@MainActor
private func buttons(in view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeSpaceTests {
    @Test("A short sidebar tab list starts at the top of its scroll viewport, on Orbit's row rhythm")
    func sidebarRowsStartAtTop() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let root = try #require(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let page = controller.sidebar.page
        let row = try #require(page.tabRows.first)
        #expect(row.item.title == "New Tab")
        let clip = try #require(row.enclosingScrollView?.contentView)
        let document = page.scrollDocument
        let documentRect = document.convert(document.bounds, to: root)
        let clipRect = clip.convert(clip.bounds, to: root)
        #expect(abs(clipRect.maxY - documentRect.maxY) <= 0.5)
        let geometry = controller.sidebar.geometry
        let rowRect = row.convert(row.bounds, to: controller.sidebar)
        #expect(abs(rowRect.midY - (geometry.pageFrame.minY + geometry.todayRowCenters[0])) <= 0.5)
        #expect(rowRect.minX == 8 && rowRect.height == 36)
    }

    @Test("Inactive navigation preserves an address draft in an empty Space and explicit switching clears it")
    func inactiveNavigationKeepsEmptySpaceAddressDraft() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        let profile = try #require(controller.session.catalog?.profiles.first?.id)
        controller.submitAddress("http://127.0.0.1:\(port)/first")
        await controller.session.waitForPendingCommands()
        let occurrence = try #require(controller.session.snapshot?.selectedOccurrenceID)
        let inactive = try #require(controller.session.selectedSurface?.webView)
        try await waitForSpaceState { inactive.title == "First" }
        controller.createSpace(name: "Synthetic empty editor", profileID: profile)
        controller.focusAddress()
        await controller.session.waitForPendingCommands()
        let emptySpace = try #require(controller.session.snapshot?.activeSpaceID)
        let editor = try #require(controller.window?.firstResponder as? NSTextView)
        editor.string = "Unsubmitted synthetic address draft"
        _ = try await inactive.evaluateJavaScript("history.pushState({}, '', '/inactive-editing');")
        try await waitForSpaceState {
            let document = await environment.store.sessionDocument()
            return document.tabs.first { $0.occurrenceID == occurrence }?.url.path == "/inactive-editing"
        }
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.activeSpaceID == emptySpace)
        #expect(controller.displayedAddress == "Unsubmitted synthetic address draft")
        controller.createSpace(name: "Synthetic other empty editor", profileID: profile)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.activeSpaceID != emptySpace)
        #expect(controller.session.snapshot?.tabs.isEmpty == true)
        #expect(controller.displayedAddress.isEmpty)
    }

    @Test("New windows inherit queued Space switches through ready and pending source windows")
    func queuedWindowInheritanceUsesDestinationProfile() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let profileB = await environment.store.createProfile(name: "Synthetic inherited profile")
        let spaceB = try await environment.store.createSpace(name: "Synthetic inherited Space", profileID: profileB)
        var contexts: [UUID: Task<BrowserContext?, Never>] = [:]
        let router = BrowserWindowRouter<PreviewWindowController>(create: { id in
            let space: SpaceID?
            if let task = contexts.removeValue(forKey: id) {
                guard let context = await task.value else { throw CancellationError() }
                space = context.spaceID
            } else { space = nil }
            return try await environment.makeWindow(id: id, spaceID: space)
        }, present: { _, _ in }, dispose: { $0.window?.close() })
        defer { router.shutdown() }
        let firstID = try #require(router.newWindow())
        await router.waitForPendingCommands()
        let first = try #require(router.windows[firstID])
        first.activateSpace(spaceB)
        let secondID = UUID()
        router.newWindow(id: secondID, prepare: { source in
            if let source { contexts[secondID] = source.session.captureContextInCommandOrder() }
        })
        router.perform { $0.activateSpace(spaceB) }
        let thirdID = UUID()
        router.newWindow(id: thirdID, prepare: { source in
            if let source { contexts[thirdID] = source.session.captureContextInCommandOrder() }
        })
        router.perform { $0.openTab() }
        await router.waitForPendingCommands()
        let second = try #require(router.windows[secondID])
        let third = try #require(router.windows[thirdID])
        await first.session.waitForPendingCommands()
        await second.session.waitForPendingCommands()
        await third.session.waitForPendingCommands()
        #expect(second.session.snapshot?.activeSpaceID == spaceB)
        #expect(third.session.snapshot?.activeSpaceID == spaceB)
        #expect(second.session.selectedSurface?.profileID == profileB)
        #expect(third.session.selectedSurface?.profileID == profileB)
        #expect(third.session.snapshot?.tabs.count == 2)
        #expect(second.session.selectedSurface?.webView.configuration.websiteDataStore ===
            third.session.selectedSurface?.webView.configuration.websiteDataStore)
        #expect(!first.window!.isVisible && !second.window!.isVisible && !third.window!.isVisible)
    }

    @Test("Real WebKit documents, drafts, selection and profile partitions survive Space switching")
    func livingDocumentsAndProfilePartitions() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        let spaceA = try #require(controller.session.snapshot?.activeSpaceID)
        let profileA = try #require(controller.session.catalog?.spaces.first { $0.id == spaceA }?.profileID)
        let profileB = await environment.store.createProfile(name: "Synthetic second profile")
        let spaceB = try await environment.store.createSpace(name: "Synthetic second Space", profileID: profileB)
        let sharedSpace = try await environment.store.createSpace(name: "Synthetic shared profile", profileID: profileA)
        controller.session.refreshCatalog()
        controller.submitAddress("http://127.0.0.1:\(port)/first")
        await controller.session.waitForPendingCommands()
        let firstView = try #require(controller.session.selectedSurface?.webView)
        try await waitForSpaceState { firstView.title == "First" }
        _ = try await firstView.evaluateJavaScript("document.cookie='spaces=profile-a; path=/'; localStorage.setItem('spaces', 'profile-a');")
        controller.openTab(url: URL(string: "http://127.0.0.1:\(port)/second")!)
        await controller.session.waitForPendingCommands()
        let selectedA = try #require(controller.session.snapshot?.selectedOccurrenceID)
        let viewA = try #require(controller.session.selectedSurface?.webView)
        try await waitForSpaceState { viewA.title == "Second" }
        _ = try await viewA.evaluateJavaScript("window.syntheticDocument='document-a'; document.getElementById('draft').value='Synthetic draft A';")

        controller.activateSpace(spaceB)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.selectedSurface == nil)
        #expect(controller.session.snapshot?.tabs.isEmpty == true)
        controller.submitAddress("http://127.0.0.1:\(port)/first")
        await controller.session.waitForPendingCommands()
        let viewB = try #require(controller.session.selectedSurface?.webView)
        #expect(controller.session.selectedSurface?.profileID == profileB)
        try await waitForSpaceState { viewB.title == "First" }
        #expect(try await viewB.evaluateJavaScript("document.cookie") as? String == "")
        #expect(try await viewB.evaluateJavaScript("localStorage.getItem('spaces')") is NSNull)
        _ = try await viewB.evaluateJavaScript("window.syntheticDocument='document-b'; document.cookie='spaces=profile-b; path=/';")

        controller.activateSpace(sharedSpace)
        await controller.session.waitForPendingCommands()
        controller.submitAddress("http://127.0.0.1:\(port)/first")
        await controller.session.waitForPendingCommands()
        let sharedView = try #require(controller.session.selectedSurface?.webView)
        try await waitForSpaceState { sharedView.title == "First" }
        #expect(try await sharedView.evaluateJavaScript("document.cookie") as? String == "spaces=profile-a")
        #expect(try await sharedView.evaluateJavaScript("localStorage.getItem('spaces')") as? String == "profile-a")

        controller.activateSpace(spaceA)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.selectedOccurrenceID == selectedA)
        #expect(controller.session.selectedSurface?.webView === viewA)
        #expect(try await viewA.evaluateJavaScript("window.syntheticDocument") as? String == "document-a")
        #expect(try await viewA.evaluateJavaScript("document.getElementById('draft').value") as? String == "Synthetic draft A")
        controller.activateSpace(spaceB)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.selectedSurface?.webView === viewB)
        #expect(try await viewB.evaluateJavaScript("window.syntheticDocument") as? String == "document-b")
        #expect(!controller.window!.isVisible)
    }

    @Test("Inactive Space page navigation is saved without selecting or reconstructing its document")
    func inactiveMetadataAndRestoration() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try spaceTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.json")
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = try await PreviewEnvironment.open(sessionFile: file)
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        let spaceA = try #require(controller.session.snapshot?.activeSpaceID)
        let profile = try #require(controller.session.catalog?.spaces.first?.profileID)
        controller.submitAddress("http://127.0.0.1:\(port)/first")
        await controller.session.waitForPendingCommands()
        let occurrence = try #require(controller.session.snapshot?.selectedOccurrenceID)
        let view = try #require(controller.session.selectedSurface?.webView)
        try await waitForSpaceState { view.title == "First" }
        controller.createSpace(name: "Synthetic empty Space", profileID: profile)
        await controller.session.waitForPendingCommands()
        let emptySpace = try #require(controller.session.snapshot?.activeSpaceID)
        #expect(emptySpace != spaceA && controller.session.selectedSurface == nil)
        _ = try await view.evaluateJavaScript("history.pushState({}, '', '/inactive-updated'); document.title='Inactive updated';")
        let changedURL = URL(string: "http://127.0.0.1:\(port)/inactive-updated")!
        try await waitForSpaceState {
            let document = await environment.store.sessionDocument()
            return document.tabs.first { $0.occurrenceID == occurrence }?.url == changedURL
        }
        #expect(controller.session.snapshot?.activeSpaceID == emptySpace)
        #expect(controller.displayedAddress.isEmpty)
        controller.prepareForTermination()
        await controller.session.waitForPendingCommands()
        try await environment.finalize()
        let saved = try BrowserSessionFileStore().load(from: file)
        #expect(saved.windows.first?.activeSpaceID == emptySpace)
        #expect(saved.tabs.first { $0.occurrenceID == occurrence }?.url == changedURL)

        let restoredEnvironment = try await PreviewEnvironment.open(sessionFile: file)
        let restoredID = try #require(controller.session.snapshot?.id)
        let restored = try await restoredEnvironment.makeWindow(id: restoredID.rawValue)
        defer { restored.window?.close() }
        #expect(restored.session.ownedSurfaces.isEmpty)
        #expect(restored.session.snapshot?.tabs.isEmpty == true)
        #expect(restored.displayedEmptyTitle == "Synthetic empty Space")
        restored.session.renameSpace(emptySpace, name: "Synthetic renamed empty Space")
        await restored.session.waitForPendingCommands()
        #expect(restored.displayedEmptyTitle == "Synthetic renamed empty Space")
        try await captureSyntheticWindow(restored)
        restored.focusAddress()
        await restored.session.waitForPendingCommands()
        #expect(restored.session.snapshot?.tabs.isEmpty == true && restored.isSidebarShown)
        restored.activateSpace(spaceA)
        await restored.session.waitForPendingCommands()
        #expect(restored.session.snapshot?.selectedOccurrenceID == occurrence)
        let restoredView = try #require(restored.session.selectedSurface?.webView)
        try await waitForSpaceState { restoredView.url == changedURL }
        #expect(restoredView !== view)
    }

    @Test("Catalog changes reach other windows while each window keeps its own Space and document")
    func catalogSynchronizationAndWindowIndependence() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let first = try await environment.makeWindow()
        let second = try await environment.makeWindow()
        defer { first.window?.close(); second.window?.close() }
        let initialSpace = try #require(second.session.snapshot?.activeSpaceID)
        let secondView = try #require(second.session.selectedSurface?.webView)
        let profile = try #require(first.session.catalog?.profiles.first?.id)
        first.createSpace(name: "Synthetic new Space", profileID: profile)
        await first.session.waitForPendingCommands()
        await second.session.waitForPendingCommands()
        let created = try #require(first.session.snapshot?.activeSpaceID)
        #expect(second.session.snapshot?.activeSpaceID == initialSpace)
        #expect(second.session.selectedSurface?.webView === secondView)
        #expect(second.displayedSpaceTitles == ["Personal", "Synthetic new Space"])
        first.session.renameSpace(created, name: "Synthetic renamed Space")
        first.session.moveSpace(created, before: initialSpace)
        await first.session.waitForPendingCommands()
        await second.session.waitForPendingCommands()
        #expect(first.displayedSpaceTitles == ["Synthetic renamed Space", "Personal"])
        #expect(second.displayedSpaceTitles == first.displayedSpaceTitles)
        #expect(second.session.snapshot?.activeSpaceID == initialSpace)
        #expect(second.session.selectedSurface?.webView === secondView)
    }

    @Test("A real sidebar background-close button targets its row and preserves the selected document")
    func sidebarCloseTargetsExactBackgroundRow() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        controller.submitAddress("http://127.0.0.1:\(port)/first")
        await controller.session.waitForPendingCommands()
        let firstID = try #require(controller.session.snapshot?.selectedOccurrenceID)
        let first = try #require(controller.session.selectedSurface?.webView)
        try await waitForSpaceState { first.title == "First" }
        controller.openTab(url: URL(string: "http://127.0.0.1:\(port)/second")!)
        await controller.session.waitForPendingCommands()
        let selected = try #require(controller.session.snapshot?.selectedOccurrenceID)
        let second = try #require(controller.session.selectedSurface?.webView)
        try await waitForSpaceState { second.title == "Second" }
        let content = try #require(controller.window?.contentView)
        let close = try #require(buttons(in: content).first { $0.accessibilityLabel() == "Close First" })
        close.performClick(nil)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.selectedOccurrenceID == selected)
        #expect(controller.session.selectedSurface?.webView === second)
        #expect(controller.session.surface(for: firstID) == nil)
        #expect(first.navigationDelegate == nil)
        #expect(controller.displayedTabTitles == ["Second"])
    }

    @Test("Hiding the sidebar and focusing the address reveal it without reloading the selected page")
    func sidebarVisibilityPreservesDocument() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        controller.submitAddress("http://127.0.0.1:\(port)/first")
        await controller.session.waitForPendingCommands()
        let view = try #require(controller.session.selectedSurface?.webView)
        try await waitForSpaceState { view.title == "First" }
        _ = try await view.evaluateJavaScript("window.syntheticDocument='sidebar-document'; document.getElementById('draft').value='Synthetic retained draft';")
        controller.toggleSidebar()
        await controller.session.waitForPendingCommands()
        #expect(!controller.isSidebarShown)
        controller.focusAddress()
        await controller.session.waitForPendingCommands()
        #expect(controller.isSidebarShown)
        #expect(controller.session.selectedSurface?.webView === view)
        #expect(try await view.evaluateJavaScript("window.syntheticDocument") as? String == "sidebar-document")
        #expect(try await view.evaluateJavaScript("document.getElementById('draft').value") as? String == "Synthetic retained draft")
        #expect(!controller.window!.isVisible)
    }
}

}
