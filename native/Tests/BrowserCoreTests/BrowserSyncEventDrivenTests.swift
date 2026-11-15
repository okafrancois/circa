import CloudKit
import Foundation
import Testing
@testable import BrowserCore

@Suite(.serialized)
struct BrowserSyncEventDrivenTests {
    let fixture = BrowserSyncTests()
    func root() -> URL { URL(fileURLWithPath: "/private/tmp/sync-event-\(UUID())") }
    func snapshot(_ session: BrowserSessionDocument, settings: BrowserSettingsDocument = .init()) -> BrowserSyncWorker.Snapshot {
        .init(session: session, settings: settings)
    }
    func modified(_ url: URL) throws -> Date? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// One runtime cycle, exactly as BrowserSyncRuntime.synchronize drives the worker.
    @discardableResult
    func cycle(_ worker: BrowserSyncWorker, _ transport: any BrowserSyncTransport, _ local: inout BrowserSessionDocument,
               settings: inout BrowserSettingsDocument, now: Date) async throws -> Bool {
        try await worker.admit("synthetic")
        let outgoing = try await worker.capture(snapshot(local, settings: settings), now: now)
        try await worker.merge(transport.exchange(outgoing), identity: "synthetic")
        let prepared = try await worker.prepare(snapshot(local, settings: settings), now: now)
        if prepared.changed {
            let value = prepared.value
            local = BrowserSessionDocument(profiles: value.profiles, spaces: value.spaces, windows: [], tabs: [], organization: value.organization)
            settings = value.settings
        }
        try await worker.acknowledge(prepared.projection)
        return prepared.changed
    }

    @Test("An unchanged projection neither stamps nor advances the replica clock")
    func unchangedCaptureKeepsTick() throws {
        var replica = BrowserSyncReplica(device: "synthetic")
        let projection = try fixture.project(fixture.document())
        try replica.capture(projection, now: fixture.date)
        let tick = replica.tick, records = replica.records
        for offset in 1...5 { try replica.capture(projection, now: fixture.date.addingTimeInterval(Double(offset))) }
        #expect(replica.tick == tick)
        #expect(replica.records == records)
        // A real edit still stamps after the clock, never behind an earlier stamp.
        try replica.capture(try fixture.project(fixture.document(title: "Edited")), now: fixture.date)
        #expect(replica.tick == tick + 1)
    }

    @Test("Idle cycles leave the replica and clock files untouched; an edit writes once")
    func idleCyclesDoNotRewriteFiles() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sync.json"), clock = BrowserSyncClockPersistence.clockURL(url)
        let transport = BrowserSyncMemoryTransport(cloud: BrowserSyncMemoryCloud(), account: "synthetic")
        let worker = BrowserSyncWorker(state: .init(), destination: url)
        var local = fixture.document(), settings = BrowserSettingsDocument()
        try await cycle(worker, transport, &local, settings: &settings, now: Date())
        try await cycle(worker, transport, &local, settings: &settings, now: Date())
        let counts = await worker.persistenceCounts()
        let replicaBytes = try Data(contentsOf: url), replicaDate = try modified(url), clockDate = try modified(clock)
        for _ in 0..<5 { try await cycle(worker, transport, &local, settings: &settings, now: Date()) }
        let idle = await worker.persistenceCounts()
        #expect(idle.writes == counts.writes)
        #expect(try Data(contentsOf: url) == replicaBytes)
        #expect(try modified(url) == replicaDate)
        #expect(try modified(clock) == clockDate)
        local = fixture.document(title: "Edited")
        try await cycle(worker, transport, &local, settings: &settings, now: Date())
        let edited = await worker.persistenceCounts()
        #expect(edited.replicaWrites == idle.replicaWrites + 1)
        // Restart from the same bytes: one launch barrier, then idle again.
        let restarted = try BrowserSyncWorker(loading: url)
        try await cycle(restarted, transport, &local, settings: &settings, now: Date())
        let afterRestart = await restarted.persistenceCounts()
        #expect(afterRestart.replicaWrites == 0 && afterRestart.writes <= 1)
        for _ in 0..<3 { try await cycle(restarted, transport, &local, settings: &settings, now: Date()) }
        #expect(await restarted.persistenceCounts().writes == afterRestart.writes)
    }

    @Test("Loading once seeds the clock writer exactly like a full reload")
    func singleReadLaunch() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sync.json")
        let transport = BrowserSyncMemoryTransport(cloud: BrowserSyncMemoryCloud(), account: "synthetic")
        let worker = BrowserSyncWorker(state: .init(), destination: url)
        var local = fixture.document(), settings = BrowserSettingsDocument()
        try await worker.setEnabled(true)
        try await cycle(worker, transport, &local, settings: &settings, now: fixture.date)
        let (state, bytes) = try BrowserSyncState.loadWithBytes(url)
        #expect(try BrowserSyncReplica.encodeValue(state) == BrowserSyncReplica.encodeValue(BrowserSyncState.load(url)))
        #expect(bytes == (try Data(contentsOf: url)))
        let loaded = try BrowserSyncWorker(loading: url)
        #expect(await loaded.enabled)
        // Missing file: an empty disabled state and no seed.
        let empty = try BrowserSyncWorker(loading: root.appendingPathComponent("missing.json"))
        #expect(await !empty.enabled)
    }

    @Test("Unchanged exchanges skip the network and persistence until an edit, refresh, remote change or forced interval")
    func exchangeShortCircuit() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try BrowserCloudKitTransport(testDestination: root.appendingPathComponent("sync.cloudkit"))
        var replica = BrowserSyncReplica(device: "synthetic")
        try replica.capture(try fixture.project(fixture.document()), now: fixture.date)
        let now = Date()
        _ = try await transport.exchange(Array(replica.records.values), now: now)
        let first = await transport.explicitExchanges
        #expect(first == 1)
        let writes = await transport.persistenceWrites()
        for offset in 1...5 { _ = try await transport.exchange(Array(replica.records.values), now: now.addingTimeInterval(Double(offset))) }
        let idle = await transport.explicitExchanges
        #expect(idle == 1)
        #expect(await transport.persistenceWrites() == writes)
        try replica.capture(try fixture.project(fixture.document(title: "Edited")), now: fixture.date)
        let returned = try await transport.exchange(Array(replica.records.values), now: now.addingTimeInterval(10))
        let exchanges2 = await transport.explicitExchanges
        #expect(exchanges2 == 2)
        #expect(Dictionary(uniqueKeysWithValues: returned.map { ($0.id, $0) }) == replica.records)
        // Through the existential, exactly as the runtime calls it.
        let erased: any BrowserSyncTransport = transport
        await erased.requestRefresh()
        _ = try await transport.exchange(Array(replica.records.values), now: now.addingTimeInterval(11))
        let exchanges3 = await transport.explicitExchanges
        #expect(exchanges3 == 3)
        _ = try await transport.exchange(Array(replica.records.values), now: now.addingTimeInterval(11 + BrowserSyncExchangeGate.forcedInterval))
        let exchanges4 = await transport.explicitExchanges
        #expect(exchanges4 == 4)
    }

    @Test("Admission is cached for a minute and voided by an account-change notification")
    func admissionCache() async throws {
        var admission = BrowserSyncAdmission()
        let start = ContinuousClock.now, epoch = BrowserSyncAccountEpoch.current
        admission.record("synthetic", epoch: epoch, now: start)
        #expect(admission.identity(now: start + .seconds(59), epoch: epoch) == "synthetic")
        #expect(admission.identity(now: start + .seconds(60), epoch: epoch) == nil)
        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        #expect(BrowserSyncAccountEpoch.current != epoch)
        #expect(admission.identity(now: start + .seconds(1)) == nil)
        admission.record(nil, epoch: BrowserSyncAccountEpoch.current)
        #expect(admission.identity() == nil)

        // The transport asks the account daemon once per lifetime, and again after a change.
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try BrowserCloudKitTransport(testDestination: root.appendingPathComponent("sync.cloudkit"))
        var replica = BrowserSyncReplica(device: "synthetic")
        try replica.capture(try fixture.project(fixture.document()), now: fixture.date)
        for _ in 0..<3 { _ = try await transport.exchange(Array(replica.records.values)) }
        _ = try await transport.account()
        #expect(await transport.accountQueries == 1)
        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        _ = try await transport.exchange(Array(replica.records.values))
        #expect(await transport.accountQueries == 2)
    }

    @Test("Throttling and connectivity errors are transient; schema errors are not")
    func transientClassification() {
        #expect(BrowserSyncRetry.isTransient(CKError(.requestRateLimited)))
        #expect(BrowserSyncRetry.isTransient(CKError(.zoneBusy)))
        #expect(BrowserSyncRetry.isTransient(CKError(.networkUnavailable)))
        #expect(!BrowserSyncRetry.isTransient(CKError(.invalidArguments)))
        #expect(!BrowserSyncRetry.isTransient(BrowserSyncError.invalidRecord))
        let throttled = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 12.0])
        #expect(BrowserSyncRetry.retryAfter(throttled) == .seconds(12))
    }

    @Test("Two replicas converge on Space, tab and settings edits and deletions, with idle cycles in between")
    func twoReplicasConverge() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let cloud = BrowserSyncMemoryCloud()
        let transports = [BrowserSyncMemoryTransport(cloud: cloud, account: "synthetic"), BrowserSyncMemoryTransport(cloud: cloud, account: "synthetic")]
        let workers = (0..<2).map { index -> BrowserSyncWorker in
            var state = BrowserSyncState(); state.replica = .init(device: "device-\(index)")
            return BrowserSyncWorker(state: state, destination: root.appendingPathComponent("\(index).json"))
        }
        var locals = [fixture.document(), fixture.document()], settings = [BrowserSettingsDocument(), BrowserSettingsDocument()]
        var clock = Date()
        func run(_ index: Int) async throws {
            clock += 1
            try await cycle(workers[index], transports[index], &locals[index], settings: &settings[index], now: clock)
        }
        func idle() async throws {
            let before = [await workers[0].persistenceCounts().writes, await workers[1].persistenceCounts().writes]
            try await run(0); try await run(1)
            #expect(await workers[0].persistenceCounts().writes == before[0])
            #expect(await workers[1].persistenceCounts().writes == before[1])
        }
        try await run(0); try await run(1); try await run(0); try await run(1)
        try await idle()
        // A renames the Space and changes a synced setting; B removes a tab.
        locals[0] = fixture.document(name: "Renamed Space")
        settings[0].profiles[fixture.profile] = .init(); settings[0].profiles[fixture.profile]?.searchEngine = .bing
        locals[1] = fixture.document(restored: false)
        try await run(0); try await run(1); try await run(0); try await run(1)
        for index in 0..<2 {
            #expect(locals[index].spaces.first?.name == "Renamed Space")
            #expect(locals[index].organization.tabs.map(\.id) == [fixture.second])
            #expect(settings[index].profile(fixture.profile).searchEngine == .bing)
        }
        try await idle()
        // B deletes the remaining tab; A edits its title concurrently: deletion wins on both.
        func session(_ tabs: [BrowserOrganizedTab], from local: BrowserSessionDocument) -> BrowserSessionDocument {
            BrowserSessionDocument(profiles: local.profiles, spaces: local.spaces, windows: [], tabs: [],
                organization: .init(tabs: tabs, folders: [], favorites: [],
                    spaces: [.init(spaceID: fixture.space, pinned: tabs.map { .tab($0.id) }, today: [])],
                    archive: [], archivePolicy: .init()))
        }
        locals[1] = session([], from: locals[1])
        locals[0] = session(locals[0].organization.tabs.map {
            BrowserOrganizedTab(id: $0.id, url: $0.url, customTitle: "Concurrent", pinnedURL: $0.pinnedURL,
                                createdAt: fixture.date, lastActiveAt: fixture.date)
        }, from: locals[0])
        try await run(1); try await run(0); try await run(1); try await run(0)
        #expect(locals[0].organization.tabs.isEmpty && locals[1].organization.tabs.isEmpty)
        try await idle()
        let states = try (0..<2).map { try BrowserSyncState.load(root.appendingPathComponent("\($0).json")) }
        #expect(states[0].replica.records == states[1].replica.records)
    }
}
