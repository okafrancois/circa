import AppKit
import Testing
@testable import BrowserCore
@testable import Orbit

extension NativeWebKitTests {
@Suite @MainActor
struct SidebarMetadataTests {
    @Test("Dirty row updates match full content while preserving row identity and geometry", arguments: [true, false])
    func metadataMatchesFullProjection(live: Bool) throws {
        let fixture = SyntheticOrganization()
        let ids = (0..<200).map { _ in TabID() }
        let occurrences = Dictionary(uniqueKeysWithValues: ids.map { ($0, TabOccurrenceID()) })
        var titles = ids.map { _ in "Initial" }
        var activities: [TabID: SidebarTabActivity] = [:]
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        func snapshot() -> BrowserOrganizationSnapshot {
            fixture.snapshot(today: zip(ids, titles).map { fixture.tab($0, title: $1, occurrence: live ? occurrences[$0] : nil) })
        }
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 700))
        sidebar.liveActivity = { activities[$0.id] ?? .init() }
        sidebar.render(catalog: fixture.catalog, activeSpaceID: fixture.spaceID, organization: snapshot())
        sidebar.layoutSubtreeIfNeeded()
        let initialRows = ids.compactMap { id in sidebar.page.list.row(for: .tab(id)).map { (BrowserOrganizationNode.tab(id), $0) } }
        var seed: UInt64 = 9
        for step in 0..<100 {
            seed = seed &* 6364136223846793005 &+ 1
            let index = Int(seed % 200)
            titles[index] = "Changed \(step)"
            activities[ids[index]] = SidebarTabActivity(favicon: step.isMultiple(of: 2) ? icon : nil,
                isLoading: step.isMultiple(of: 3), isAudible: step.isMultiple(of: 5), isAudioMuted: step.isMultiple(of: 7))
            let current = snapshot()
            let centers = ids.map { sidebar.page.list.displayedCenterY(of: .node(.tab($0))) }
            sidebar.applyMetadata([ids[index]], organization: current)
            #expect(sidebar.page.list.content == SidebarListContent(snapshot: current, liveActivity: { live ? activities[$0.id] ?? .init() : .init() }))
            #expect(ids.map { sidebar.page.list.displayedCenterY(of: .node(.tab($0))) } == centers)
            for (node, row) in initialRows { #expect(sidebar.page.list.row(for: node) === row) }
        }
    }
    @Test("Termination persists a background title before its display-cycle batch fires")
    func terminationDrainsTitle() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: space,
            engine: SiteSyntheticEngine(), onClose: {}, onActivate: {})
        defer { controller.session.close(); controller.window?.close() }
        await controller.session.waitForPendingCommands()
        controller.session.openTab(url: URL(string: "https://first.test/")!)
        await controller.session.waitForPendingCommands()
        let first = try #require(controller.session.snapshot?.selectedOccurrenceID)
        controller.session.openTab(url: URL(string: "https://second.test/")!)
        await controller.session.waitForPendingCommands()
        let background = try #require(controller.session.selectedSurface)
        let id = try #require(controller.session.organization?.selectedTab?.id)
        controller.session.selectOccurrence(first)
        await controller.session.waitForPendingCommands()
        background.navigate(to: URL(string: "https://final-title.test/")!)
        controller.prepareForTermination()
        await controller.session.waitForPendingCommands()
        let document = await store.sessionDocument()
        #expect(document.organization.tabs.first { $0.id == id }?.pageTitle == "final-title.test")
    }

}
}
