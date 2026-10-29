import Darwin
import Foundation
import SQLite3
import Testing
@testable import BrowserCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_SYNC_IDLE_BENCHMARK"] == "1"))
struct BrowserSyncIdleBenchmarks {
    func cpu() -> Double {
        var time = timespec(); clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }
    func mainCPU() -> Double {
        #expect(Thread.isMainThread)
        var time = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
    }
    func fixture(_ count: Int) -> BrowserSessionDocument {
        let profile = BrowserProfile(id: ProfileID(), name: "Synthetic"), date = Date(timeIntervalSince1970: 1_800_000_000)
        let spaces = (0..<5).map { BrowserSpace(id: SpaceID(), profileID: profile.id, name: "Space \($0)") }
        let tabs = (0..<count).map { index in
            let url = URL(string: "https://example.invalid/\(index)")!
            return BrowserOrganizedTab(id: TabID(), url: url, customTitle: "Synthetic \(index)", pinnedURL: url, createdAt: date, lastActiveAt: date)
        }
        let sections = spaces.enumerated().map { index, space in
            BrowserOrganizationDocument.SpaceSections(spaceID: space.id,
                pinned: tabs.enumerated().filter { $0.offset != 0 && $0.offset % 5 == index }.map { .tab($0.element.id) }, today: [])
        }
        return .init(profiles: [profile], spaces: spaces, windows: [], tabs: [],
            organization: .init(tabs: tabs, folders: [], favorites: [.init(profileID: profile.id, items: [.tab(tabs[0].id)])], spaces: sections, archive: [], archivePolicy: .init()))
    }

    @Test @MainActor
    func organization() async throws {
        for count in [62, 1000] {
            let root = URL(fileURLWithPath: "/private/tmp/sync-benchmark-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let session = fixture(count), settings = BrowserSettingsDocument(), now = Date(timeIntervalSince1970: 1_800_000_000)
            if let path = ProcessInfo.processInfo.environment["ORBIT_SYNC_IDLE_FIXTURE_ROOT"] {
                try session.encoded().write(to: URL(fileURLWithPath: path).appendingPathComponent("fixture-\(count).json"))
            }
            let boosts = session.profiles.map { BrowserBoostDocument(profileID: $0.id) }
            let snapshot = BrowserSyncWorker.Snapshot(session: session, settings: settings, boosts: boosts)
            var original = BrowserSyncState(); try original.account.admit("synthetic")
            try original.replica.capture(LegacySyncMapping.project(session: session, settings: settings, boosts: boosts), now: now)
            let worker = BrowserSyncWorker(state: original, destination: root.appendingPathComponent("new.json"))
            let oldTransport = BrowserSyncMemoryTransport(cloud: BrowserSyncMemoryCloud(), account: "synthetic")
            let newTransport = BrowserSyncMemoryTransport(cloud: BrowserSyncMemoryCloud(), account: "synthetic")
            let iterations = 8
            var oldPersistence = BrowserSyncPersistence()
            let oldDestination = root.appendingPathComponent("old.json")
            try oldPersistence.save(BrowserSyncReplica.encodeValue(original), to: oldDestination, maximumBytes: 64 * 1024 * 1024)
            let oldBefore = oldPersistence
            var oldMain = 0.0, oldWall = 0.0, oldCPU = 0.0, oldMainCPU = 0.0
            for i in 0..<iterations {
                let time = now.addingTimeInterval(Double(i + 1)), start = Date(), c = cpu(), threadStart = mainCPU()
                var segment = Date()
                try original.account.admit("synthetic"); try oldPersistence.save(BrowserSyncReplica.encodeValue(original), to: oldDestination, maximumBytes: 64 * 1024 * 1024)
                try original.replica.capture(LegacySyncMapping.project(session: session, settings: settings, boosts: boosts), now: time)
                try oldPersistence.save(BrowserSyncReplica.encodeValue(original), to: oldDestination, maximumBytes: 64 * 1024 * 1024)
                oldMain += Date().timeIntervalSince(segment)
                let incoming = try await oldTransport.exchange(Array(original.replica.records.values))
                segment = Date()
                try original.replica.merge(incoming); try oldPersistence.save(BrowserSyncReplica.encodeValue(original), to: oldDestination, maximumBytes: 64 * 1024 * 1024)
                try original.replica.capture(LegacySyncMapping.project(session: session, settings: settings, boosts: boosts), now: time)
                let value = try LegacySyncMapping.materialize(original.replica.visible, local: session, settings: settings, boosts: boosts)
                let shared = BrowserSessionDocument(profiles: value.profiles, spaces: value.spaces, windows: [], tabs: [], organization: value.organization)
                let projected = try LegacySyncMapping.project(session: shared, settings: value.settings, boosts: value.boosts)
                #expect(projected == (try LegacySyncMapping.project(session: session, settings: settings, boosts: boosts)))
                try original.replica.acknowledge(projected); try oldPersistence.save(BrowserSyncReplica.encodeValue(original), to: oldDestination, maximumBytes: 64 * 1024 * 1024)
                oldMain += Date().timeIntervalSince(segment); oldWall += Date().timeIntervalSince(start); oldCPU += cpu() - c; oldMainCPU += mainCPU() - threadStart
            }
            // Prime caches outside the measured idle interval.
            try await worker.admit("synthetic")
            let warm = try await worker.capture(snapshot, now: now)
            try await worker.merge(await newTransport.exchange(warm), identity: "synthetic")
            let prepared = try await worker.prepare(snapshot, now: now); try await worker.acknowledge(prepared.projection)
            let before = await worker.persistenceCounts()
            var newWall = 0.0, newCPU = 0.0, newMainCPU = 0.0
            for i in 0..<iterations {
                let time = now.addingTimeInterval(Double(i + 1)), start = Date(), c = cpu(), threadStart = mainCPU()
                try await worker.admit("synthetic")
                let outgoing = try await worker.capture(snapshot, now: time)
                try await worker.merge(await newTransport.exchange(outgoing), identity: "synthetic")
                let result = try await worker.prepare(snapshot, now: time)
                try await worker.acknowledge(result.projection)
                newWall += Date().timeIntervalSince(start); newCPU += cpu() - c; newMainCPU += mainCPU() - threadStart
            }
            let after = await worker.persistenceCounts()
            #expect(after.replicaWrites == before.replicaWrites)
            #expect(after.writes - before.writes == iterations * 2)
            #expect(after.bytes - before.bytes == iterations * 2 * 72)
            let scale = 1000 / Double(iterations)
            print("SYNC_BENCH tabs=\(count) cycles=\(iterations) old_wall_ms=\(oldWall * scale) new_wall_ms=\(newWall * scale) old_main_ms=\(oldMain * scale) old_main_cpu_ms=\(oldMainCPU * scale) new_main_cpu_ms=\(newMainCPU * scale) old_cpu_ms=\(oldCPU * scale) new_cpu_ms=\(newCPU * scale) old_writes_hour=\((oldPersistence.writes - oldBefore.writes) * 720 / iterations) new_replica_writes_hour=\((after.replicaWrites - before.replicaWrites) * 720 / iterations) new_writes_hour=\((after.writes - before.writes) * 720 / iterations) old_bytes_hour=\((oldPersistence.bytesWritten - oldBefore.bytesWritten) * 720 / iterations) new_bytes_hour=\((after.bytes - before.bytes) * 720 / iterations)")
        }
    }

    @Test
    func history() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/history-benchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let visits = (0..<100_000).map { index in
            BrowserHistoryVisit(url: URL(string: "https://example.invalid/\(index % 1000)")!, title: "Synthetic \(index)", visitedAt: now.addingTimeInterval(-Double(index % 89) * 86400))
        }
        try await store.importDocument(.init(profileID: profile, visits: visits))
        for _ in 0..<21 { _ = try await store.legacyHistorySyncBatches(now: now) }
        let cycles = 8
        var start = Date(), c = cpu()
        for _ in 0..<cycles { _ = try await store.legacyHistorySyncBatches(now: now) }
        let oldWall = Date().timeIntervalSince(start), oldCPU = cpu() - c
        let batches = try await store.historySyncBatches(now: now)
        let before = await store.syncDatabaseChanges()
        start = Date(); c = cpu()
        for _ in 0..<cycles { #expect(try await store.historySyncBatches(now: now) == batches) }
        let newWall = Date().timeIntervalSince(start), newCPU = cpu() - c
        #expect(await store.syncDatabaseChanges() == before)
        let scale = 1000 / Double(cycles)
        print("HISTORY_BENCH visits=100000 batches=\(batches.count) old_wall_ms=\(oldWall * scale) new_wall_ms=\(newWall * scale) old_cpu_ms=\(oldCPU * scale) new_cpu_ms=\(newCPU * scale) idle_sqlite_changes=0")
        try await store.close()
    }
}

extension BrowserHistoryStore {
    func syncDatabaseChanges() -> Int64 { database?.withHandle { sqlite3_total_changes64($0) } ?? 0 }
}
