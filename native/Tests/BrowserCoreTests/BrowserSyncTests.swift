import Darwin
import Foundation
import Testing
@testable import BrowserCore

struct BrowserSyncTests {
    let profile = ProfileID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let space = SpaceID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let first = TabID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let second = TabID(UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    let folder = FolderID(UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
    let otherFolder = FolderID(UUID(uuidString: "00000000-0000-0000-0000-000000000006")!)
    let date = Date(timeIntervalSince1970: 100)

    func document(order: [TabID]? = nil, name: String = "Synthetic Space", title: String = "Synthetic Tab",
                  nested: Bool = false, moved: Bool = false, restored: Bool = true) -> BrowserSessionDocument {
        let order = order ?? [first, second]
        let ids = restored ? order : order.filter { $0 != first }
        let tabs = ids.map { BrowserOrganizedTab(id: $0, url: URL(string: "https://example.invalid/\($0.rawValue)")!,
            customTitle: $0 == first ? title : "Second", pinnedURL: URL(string: "https://example.invalid/\($0.rawValue)")!,
            createdAt: date, lastActiveAt: date) }
        let folders: [BrowserOrganizedFolder] = nested ? [
            .init(id: folder, title: "Folder", children: moved ? [] : ids.map(BrowserOrganizationNode.tab), createdAt: date),
            .init(id: otherFolder, title: "Other", children: moved ? ids.map(BrowserOrganizationNode.tab) : [], createdAt: date)
        ] : []
        return BrowserSessionDocument(profiles: [.init(id: profile, name: "Synthetic Profile")],
            spaces: [.init(id: space, profileID: profile, name: name)], windows: [], tabs: [],
            organization: .init(tabs: tabs, folders: folders, favorites: [],
                spaces: [.init(spaceID: space, pinned: nested ? [.folder(folder), .folder(otherFolder)] : ids.map(BrowserOrganizationNode.tab), today: [])],
                archive: [], archivePolicy: .init()))
    }

    func project(_ document: BrowserSessionDocument) throws -> BrowserSyncProjection {
        try BrowserSyncMapping.project(session: document, settings: .init())
    }
    func materialize(_ replica: BrowserSyncReplica, local: BrowserSessionDocument) throws -> BrowserSessionDocument {
        let result = try BrowserSyncMapping.materialize(replica.visible, local: local, settings: .init())
        let session = BrowserSessionDocument(profiles: result.profiles, spaces: result.spaces, windows: [], tabs: [], organization: result.organization)
        try session.validate()
        return session
    }
    func exchange(_ replica: inout BrowserSyncReplica, _ transport: BrowserSyncMemoryTransport) async throws {
        try replica.merge(await transport.exchange(Array(replica.records.values)))
    }

    @Test("Two Macs create, reorder and move the same identities between folders without duplication")
    func twoMacOrganization() async throws {
        let cloud = BrowserSyncMemoryCloud()
        let a = BrowserSyncMemoryTransport(cloud: cloud, account: "synthetic-a")
        let b = BrowserSyncMemoryTransport(cloud: cloud, account: "synthetic-a")
        var macA = BrowserSyncReplica(device: "a"), macB = BrowserSyncReplica(device: "b")
        let initial = document(nested: true)
        try macA.capture(project(initial), now: date)
        try await exchange(&macA, a); try await exchange(&macB, b)
        let onB = try materialize(macB, local: initial)
        try macB.acknowledge(project(onB))
        try macA.capture(project(document(order: [second, first], nested: true, moved: true)), now: date.addingTimeInterval(1))
        try await exchange(&macA, a); try await exchange(&macB, b)
        let result = try materialize(macB, local: onB)
        #expect(result.organization.folders.first { $0.id == otherFolder }?.children == [.tab(second), .tab(first)])
        #expect(result.organization.tabs.count == 2)
        #expect(result.spaces.count == 1)
        #expect(Set(result.organization.tabs.map(\.id)).count == 2)
        // Round-trip materialization is stable and does not generate new edits.
        try macB.acknowledge(project(result))
        let records = macB.records
        try macB.capture(project(result), now: date.addingTimeInterval(10))
        #expect(macB.records == records)
    }

    @Test("Concurrent field edits survive, same-field ties converge, and order has stable keys")
    func conflicts() async throws {
        var a = BrowserSyncReplica(device: "a"), b = BrowserSyncReplica(device: "b")
        let initial = document()
        try a.capture(project(initial), now: date); try b.merge(Array(a.records.values)); try b.acknowledge(project(initial))
        try a.capture(project(document(order: [second, first], name: "Renamed on A")), now: date.addingTimeInterval(2))
        try b.capture(project(document(title: "Renamed on B")), now: date.addingTimeInterval(2))
        let left = Array(a.records.values), right = Array(b.records.values)
        try a.merge(right); try b.merge(left)
        #expect(a.records == b.records)
        // Recapturing an unchanged local UI after a fetch must not undo the remote reorder.
        let merged = b.records
        try b.capture(project(document(title: "Renamed on B")), now: date.addingTimeInterval(10))
        #expect(b.records == merged)
        let result = try materialize(a, local: initial)
        #expect(result.spaces.first?.name == "Renamed on A")
        #expect(result.organization.tabs.first { $0.id == first }?.customTitle == "Renamed on B")
        #expect(result.organization.spaces.first?.pinned == [.tab(second), .tab(first)])
        try a.acknowledge(project(result)); try b.acknowledge(project(result))
        try a.capture(project(document(title: "A")), now: date.addingTimeInterval(20))
        try b.capture(project(document(title: "B")), now: date.addingTimeInterval(20))
        let aa = Array(a.records.values), bb = Array(b.records.values)
        try a.merge(bb); try b.merge(aa)
        #expect(a.records == b.records)
        #expect(try materialize(a, local: initial).organization.tabs.first { $0.id == first }?.customTitle == "B")
    }

    @Test("Deletion beats concurrent ordinary edits; explicit restore keeps its logical identity")
    func deleteRestore() throws {
        var a = BrowserSyncReplica(device: "a"), b = BrowserSyncReplica(device: "b")
        let initial = document()
        try a.capture(project(initial), now: date); try b.merge(Array(a.records.values)); try b.acknowledge(project(initial))
        try a.capture(project(document(restored: false)), now: date.addingTimeInterval(1))
        try b.capture(project(document(title: "Offline edit")), now: date.addingTimeInterval(2))
        try a.merge(Array(b.records.values)); try b.merge(Array(a.records.values))
        #expect(try materialize(a, local: initial).organization.tabs.map(\.id) == [second])
        let deleted = try materialize(a, local: initial)
        try a.acknowledge(project(deleted))
        try a.capture(project(initial), now: date.addingTimeInterval(3))
        try b.merge(Array(a.records.values))
        #expect(try materialize(b, local: initial).organization.tabs.count == 2)
        #expect(b.records[BrowserSyncMapping.id("tab", first.rawValue)]?.deleted == false)
    }

    @Test("Sign-out retains the local replica and marker; switching Apple IDs cannot exchange data")
    func accounts() async throws {
        let cloud = BrowserSyncMemoryCloud()
        let transport = BrowserSyncMemoryTransport(cloud: cloud, account: "synthetic-a")
        var marker = BrowserSyncAccountMarker(), replica = BrowserSyncReplica()
        try marker.admit(await transport.account()); try replica.capture(project(document()))
        try await exchange(&replica, transport)
        let original = replica.records
        await transport.setAccount(nil)
        #expect(throws: BrowserSyncError.signedOut) { try marker.admit(nil) }
        #expect(marker.signedOut)
        await #expect(throws: BrowserSyncError.signedOut) { try await transport.exchange(Array(original.values)) }
        #expect(replica.records == original)
        await transport.setAccount("synthetic-b")
        #expect(throws: BrowserSyncError.accountChanged) { try marker.admit("synthetic-b") }
        #expect(try await transport.exchange([]).isEmpty)
        #expect(replica.records == original)
        await transport.setAccount("synthetic-a"); try marker.admit(await transport.account())
        #expect(!marker.signedOut)
        #expect(try await transport.exchange([]).count == original.count)
    }

    @Test("Mapping retains safe settings, themes, Favorites and Boost fields while excluding device state and consent")
    func mappingRoundTrip() async throws {
        let initial = document()
        let store = try BrowserStore(restoring: initial)
        // Exercise actual model authorities, including live window state.
        let window = try await store.createWindow(activeSpaceID: space)
        let context = try await store.captureContext(in: window)
        _ = try await store.addToFavorites([first], from: context)
        try await store.setSpaceTheme(BrowserSpaceThemePresets.default, for: space)
        var settings = BrowserSettingsDocument()
        settings.memorySaver = .never
        settings.lastActiveSpaceID = space; settings.lastActiveWindowID = window
        settings.profiles[profile] = .init(); settings.profiles[profile]?.searchEngine = .bing
        let boosts = try BrowserBoostStore(profileID: profile)
        var content = BrowserBoostContent(); content.customJavaScript = "document.title = 'Synthetic';"
        let boost = BrowserBoost(title: "Synthetic Boost", hostPattern: try .init(host: "example.invalid"), content: content, javaScriptOptIn: true)
        try await boosts.save(boost)
        let session = await store.sessionDocument()
        var replica = BrowserSyncReplica()
        let projection = try BrowserSyncMapping.project(session: session, settings: settings, boosts: [await boosts.snapshot()])
        try replica.capture(projection)
        let wire = try BrowserSyncReplica.encodeValue(replica)
        let text = String(decoding: wire, as: UTF8.self)
        #expect(!text.contains("javaScriptOptIn")); #expect(!text.contains("lastActiveWindowID")); #expect(!text.contains("memorySaver"))
        let decoded = try JSONDecoder().decode(BrowserSyncReplica.self, from: wire)
        let value = try BrowserSyncMapping.materialize(decoded.visible, local: session, settings: .init())
        #expect(value.spaces.first?.theme == BrowserSpaceThemePresets.default)
        #expect(value.settings.profile(profile).searchEngine == .bing)
        #expect(value.settings.memorySaver == .oneHour)
        #expect(value.settings.lastActiveWindowID == nil)
        #expect(value.boosts.first?.boosts.first?.javaScriptOptIn == false)
        #expect(value.boosts.first?.boosts.first?.content == content)
        #expect(value.organization.favorites.first?.items == [.tab(first)])
        try await store.applySync(value, expected: session)
        try await store.sessionDocument().validate()
    }

    @Test("Future schemas and stale local snapshots are refused; state survives relaunch")
    func persistenceAndAdmission() async throws {
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        let directory = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("sync.json")
        var state = BrowserSyncState(); state.enabled = true
        try state.account.admit("synthetic-a"); try state.replica.capture(project(document()))
        try state.save(destination)
        let restored = try BrowserSyncState.load(destination)
        #expect(restored.enabled); #expect(restored.replica.records == state.replica.records)
        #expect(restored.account == state.account)
        var record = try #require(state.replica.records.values.first); record.version = 999
        #expect(throws: BrowserSyncError.unsupportedVersion) { try state.replica.merge([record]) }
        let store = try BrowserStore(restoring: document())
        let value = try BrowserSyncMapping.materialize(state.replica.visible, local: document(), settings: .init())
        try await store.renameSpace(space, name: "Local edit")
        await #expect(throws: BrowserSyncError.localChange) { try await store.applySync(value, expected: document()) }
        #expect(await store.catalogSnapshot().spaces.first?.name == "Local edit")
    }

    @Test("Concurrent insertions and cyclic folder moves converge to a valid graph")
    func concurrentStructure() throws {
        let initial = document(nested: true)
        var a = BrowserSyncReplica(device: "a"), b = BrowserSyncReplica(device: "b")
        try a.capture(project(initial), now: date)
        try b.merge(Array(a.records.values)); try b.acknowledge(project(initial))
        var left = try project(initial), right = left
        let root = BrowserSyncMapping.id("pinned", space.rawValue)
        let firstFolder = BrowserSyncMapping.id("folder", folder.rawValue)
        let nextFolder = BrowserSyncMapping.id("folder", otherFolder.rawValue)
        left.lists[root] = [nextFolder]; left.lists[nextFolder] = [firstFolder]
        right.lists[root] = [firstFolder]; right.lists[firstFolder] = [nextFolder, BrowserSyncMapping.id("tab", first.rawValue), BrowserSyncMapping.id("tab", second.rawValue)]
        try a.capture(left, now: date.addingTimeInterval(1)); try b.capture(right, now: date.addingTimeInterval(1))
        let aa = Array(a.records.values), bb = Array(b.records.values)
        try a.merge(bb); try b.merge(aa)
        #expect(a.records == b.records)
        let result = try materialize(a, local: initial)
        #expect(result.organization.folders.count == 2)
        #expect(result.organization.tabs.count == 2)
        // New independent tabs at identical ordering keys use their logical IDs as a tie-break.
        var c = BrowserSyncReplica(device: "c"), d = BrowserSyncReplica(device: "d")
        try c.capture(project(document()), now: date); try d.merge(Array(c.records.values)); try d.acknowledge(project(document()))
        var cp = try project(document()), dp = cp
        let keyC = "tab/00000000-0000-0000-0000-000000000007"
        let keyD = "tab/00000000-0000-0000-0000-000000000008"
        let template = try #require(cp.entries[BrowserSyncMapping.id("tab", first.rawValue)])
        cp.entries[keyC] = template; dp.entries[keyD] = template
        cp.lists[root, default: []].append(keyC); dp.lists[root, default: []].append(keyD)
        // Assign matching model identities as a production local command would.
        cp.entries[keyC]?["id"] = try BrowserSyncReplica.encodeValue(TabID(UUID(uuidString: String(keyC.split(separator: "/")[1]))!))
        dp.entries[keyD]?["id"] = try BrowserSyncReplica.encodeValue(TabID(UUID(uuidString: String(keyD.split(separator: "/")[1]))!))
        try c.capture(cp, now: date.addingTimeInterval(1)); try d.capture(dp, now: date.addingTimeInterval(1))
        let cc = Array(c.records.values), dd = Array(d.records.values)
        try c.merge(dd); try d.merge(cc)
        #expect(c.records == d.records)
        #expect(try materialize(c, local: document()).organization.tabs.count == 4)
    }

    @Test("Clearing a theme and remote Space deletion retain valid local windows")
    func localStatePreservation() async throws {
        let store = try BrowserStore(restoring: document())
        let otherSpace = try await store.createSpace(name: "Other", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: otherSpace)
        try await store.setSpaceTheme(BrowserSpaceThemePresets.default, for: space)
        let initial = await store.sessionDocument()
        var replica = BrowserSyncReplica()
        try replica.capture(project(initial), now: date)
        try await store.setSpaceTheme(nil, for: space)
        let cleared = await store.sessionDocument()
        try replica.capture(project(cleared), now: date.addingTimeInterval(1))
        let result = try BrowserSyncMapping.materialize(replica.visible, local: cleared, settings: .init())
        #expect(result.spaces.first { $0.id == space }?.theme == nil)
        // Delete a Space on the other Mac while this Mac still has an occurrence there.
        let context = try await store.captureContext(in: window)
        _ = try await store.openTab(url: URL(string: "https://example.invalid/local")!, from: context, activate: true)
        let before = await store.sessionDocument()
        try replica.capture(project(document()), now: date.addingTimeInterval(2))
        let deletion = try BrowserSyncMapping.materialize(replica.visible, local: before, settings: .init())
        try await store.applySync(deletion, expected: before)
        let after = await store.sessionDocument()
        try after.validate()
        #expect(after.windows.first?.activeSpaceID == space)
        #expect(after.tabs.isEmpty)
    }

    @Test("Sync preserves local Today split groups and archive entries from deleted Spaces")
    func preservesLocalArchiveAndSplit() throws {
        let shared = document()
        let oldSpace = SpaceID()
        let todayA = TabID(), todayB = TabID(), archivedID = TabID()
        func tab(_ id: TabID) -> BrowserOrganizedTab {
            .init(id: id, url: URL(string: "https://example.invalid/local")!, createdAt: date, lastActiveAt: date)
        }
        let split = BrowserSplitGroup(tabIDs: [todayA, todayB])
        let organization = BrowserOrganizationDocument(tabs: shared.organization.tabs + [tab(todayA), tab(todayB)], folders: [], favorites: [],
            spaces: [.init(spaceID: space, pinned: [.tab(first), .tab(second)], today: [.split(split.id)])],
            archive: [.init(tab: tab(archivedID), profileID: profile, spaceID: oldSpace, origin: .today, reason: .closed, archivedAt: date)],
            archivePolicy: .init(), splits: [split])
        let local = BrowserSessionDocument(profiles: shared.profiles, spaces: shared.spaces, windows: [], tabs: [], organization: organization)
        try local.validate()
        var replica = BrowserSyncReplica(); try replica.capture(project(shared))
        let result = try materialize(replica, local: local)
        #expect(result.organization.archive.map(\.id) == [archivedID])
        #expect(result.organization.splits == [split])
        #expect(result.organization.spaces.first?.today == [.split(split.id)])
        #expect(result.organization.tabs.count == 4)
    }

    @Test("An unsigned process cannot create a CloudKit transport")
    func entitlementGate() throws {
        #expect(!BrowserSyncEntitlement.matches([:]))
        #expect(!BrowserSyncEntitlement.isAvailable())
        #expect(throws: BrowserSyncError.unavailable) {
            _ = try BrowserCloudKitTransport(destination: URL(fileURLWithPath: "/tmp/unused-sync-test"), identity: "synthetic-a")
        }
    }
}
