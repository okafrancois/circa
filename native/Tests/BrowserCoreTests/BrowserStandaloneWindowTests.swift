import Foundation
import Testing
@testable import BrowserCore

@Suite("Standalone window ownership")
struct BrowserStandaloneWindowTests {
    @Test("A standalone owns its ordered tabs, leaves no source placeholder and stays local through persistence and sync")
    func ownershipPersistenceAndSync() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Source", profileID: profile)
        let source = try await store.createWindow(activeSpaceID: space)
        let occurrence = try await store.openTab(url: URL(string: "https://synthetic.test/first")!, from: store.captureContext(in: source), activate: true)
        let id = try #require(await store.snapshot(of: source).tabs.first?.id)
        _ = try await store.pinTabs([id], from: store.captureContext(in: source))
        let before = try BrowserSyncMapping.project(session: await store.sessionDocument(), settings: .init())
        #expect(before.entries.keys.contains { $0.contains(id.rawValue.uuidString) })
        let receiver = try await store.createStandaloneWindow(profileID: profile, homeSpaceID: space)
        let target = try await store.openTransferredOccurrence(of: id, url: URL(string: "https://synthetic.test/edited")!, from: store.captureContext(in: receiver), activate: true, movingTo: .init(.standalone(receiver)))
        #expect(target != occurrence)
        #expect(try await store.snapshot(of: source).tabs.isEmpty)
        #expect(try await store.organizationSnapshot(from: store.captureContext(in: source)).tab(id) == nil)
        let local = try await store.organizationSnapshot(from: store.captureContext(in: receiver))
        #expect(local.selectedTab?.id == id && local.allTabs.count == 1)
        await store.updateWindowPlacements([receiver: .init(x: 592, y: 157, width: 900, height: 750, sidebarWidth: 500, isFullScreen: true)])
        let saved = await store.sessionDocument()
        #expect(saved.windows.first { $0.id == receiver }?.placement?.isFullScreen == true)
        #expect(saved.spaces.count == 1)
        #expect(saved.organization.tabs.isEmpty)
        #expect(saved.windows.first { $0.id == receiver }?.standalone?.tabs.map(\.id) == [id])
        let projection = try BrowserSyncMapping.project(session: saved, settings: .init())
        #expect(projection.entries.keys.allSatisfy { !$0.contains(id.rawValue.uuidString) })
        // Replacing the shared graph cannot erase data absent from its sync projection.
        try await store.applySync(.init(profiles: saved.profiles, spaces: saved.spaces, organization: saved.organization, settings: .init(), boosts: []), expected: saved)
        #expect(try await store.organizationSnapshot(from: store.captureContext(in: receiver)).selectedTab?.id == id)
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(saved.encoded()))
        #expect(try await restored.snapshot(of: receiver).isStandalone)
        #expect(try await restored.organizationSnapshot(from: restored.captureContext(in: receiver)).selectedTab?.id == id)
        // Moving back uses the same live-transfer model path and empties the standalone in place.
        _ = try await restored.openTransferredOccurrence(of: id, url: URL(string: "https://synthetic.test/edited")!, from: restored.captureContext(in: source), activate: true, movingTo: .init(.today(space)))
        #expect(try await restored.snapshot(of: receiver).tabs.isEmpty)
        #expect(try await restored.snapshot(of: source).tabs.first?.id == id)
        try await restored.sessionDocument().validate()
    }
    @Test("Older session windows decode without standalone or fullscreen fields")
    func legacySession() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let home = try await store.createSpace(name: "Source", profileID: profile)
        _ = try await store.createWindow(activeSpaceID: home)
        let saved = await store.sessionDocument()
        let decoded = try BrowserSessionDocument.decode(saved.encoded())
        #expect(decoded == saved && decoded.windows.allSatisfy { $0.standalone == nil })
        let restored = try BrowserStore(restoring: decoded)
        #expect(await restored.sessionDocument() == saved)
    }

    @Test("Standalone tab order and selection persist without exposing Space siblings")
    func orderedLocalList() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let home = try await store.createSpace(name: "Source", profileID: profile)
        let source = try await store.createWindow(activeSpaceID: home)
        _ = try await store.openTab(url: URL(string: "https://synthetic.test/sibling")!, from: store.captureContext(in: source), activate: true)
        let receiver = try await store.createStandaloneWindow(profileID: profile, homeSpaceID: home)
        _ = try await store.openTab(url: URL(string: "https://synthetic.test/local-one")!, from: store.captureContext(in: receiver), activate: true)
        _ = try await store.openTab(url: URL(string: "https://synthetic.test/local-two")!, from: store.captureContext(in: receiver), activate: true)
        let before = try await store.organizationSnapshot(from: store.captureContext(in: receiver))
        #expect(before.allTabs.count == 2 && before.allTabs.allSatisfy { $0.url.path != "/sibling" })
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(await store.sessionDocument().encoded()))
        let after = try await restored.organizationSnapshot(from: restored.captureContext(in: receiver))
        #expect(after.allTabs.map(\.id) == before.allTabs.map(\.id) && after.selectedTab?.id == before.selectedTab?.id)
        #expect(try await restored.organizationSnapshot(from: restored.captureContext(in: source)).allTabs.count == 1)
        // Local archive commands must never clear or restore into the source's shared list.
        _ = try await restored.clearTodayTabs(from: restored.captureContext(in: receiver))
        #expect(try await restored.organizationSnapshot(from: restored.captureContext(in: receiver)).allTabs.isEmpty)
        #expect(try await restored.organizationSnapshot(from: restored.captureContext(in: source)).allTabs.count == 1)
        let archived = try #require(before.allTabs.first?.id)
        _ = try await restored.restoreArchivedTab(archived, activate: true, from: restored.captureContext(in: receiver))
        #expect(try await restored.organizationSnapshot(from: restored.captureContext(in: receiver)).selectedTab?.id == archived)
        #expect(try await restored.organizationSnapshot(from: restored.captureContext(in: source)).allTabs.count == 1)
        #expect(await restored.sessionDocument().organization.tabs.count == 1)
    }

    @Test("Standalone transfers use the existing reversible organization journal")
    func undoRedo() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let home = try await store.createSpace(name: "Source", profileID: profile)
        let source = try await store.createWindow(activeSpaceID: home)
        let url = URL(string: "https://synthetic.test/undo")!
        _ = try await store.openTab(url: url, from: store.captureContext(in: source), activate: true)
        let id = try #require(await store.snapshot(of: source).tabs.first?.id)
        let receiver = try await store.createStandaloneWindow(profileID: profile, homeSpaceID: home)
        _ = try await store.openTransferredOccurrence(of: id, url: url, from: store.captureContext(in: receiver), activate: true)
        _ = try await store.undoOrganization(from: store.captureContext(in: receiver))
        #expect(try await store.organizationSnapshot(from: store.captureContext(in: source)).tab(id) != nil)
        #expect(try await store.organizationSnapshot(from: store.captureContext(in: receiver)).allTabs.isEmpty)
        _ = try await store.redoOrganization(from: store.captureContext(in: receiver))
        #expect(try await store.organizationSnapshot(from: store.captureContext(in: source)).tab(id) == nil)
        #expect(try await store.organizationSnapshot(from: store.captureContext(in: receiver)).tab(id) != nil)
        try await store.sessionDocument().validate()
    }

}
