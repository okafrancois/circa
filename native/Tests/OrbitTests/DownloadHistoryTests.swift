import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing
@testable import Orbit

@MainActor
private final class HistoryTransfer: BrowserDownloadTransfer {
    func perform(_ action: BrowserDownloadAction, completion: @escaping @MainActor (Result<Void, BrowserDownloadError>) -> Void) { completion(.success(())) }
    func invalidate() {}
}

@Suite("Durable download history and partial-file ownership")
@MainActor
struct DownloadHistoryTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-download-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test("Terminal history restores in order with fresh lifetimes, profile isolation and working removal")
    func restore() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json")
        let manager = BrowserDownloadsController(history: try BrowserDownloadHistoryStore(destination: url))
        let a = ProfileID(), b = ProfileID()
        let first = try manager.coordinator.register(owner: .init(profileID: a), transfer: HistoryTransfer(), suggestedFilename: "first.bin")
        first.report(.init(key: first.key, sequence: 1, state: .complete, receivedBytes: 12, totalBytes: 12,
                           destinationURL: root.appendingPathComponent("first.bin")))
        let second = try manager.coordinator.register(owner: .init(profileID: b), transfer: HistoryTransfer(), suggestedFilename: "second.bin")
        second.report(.init(key: second.key, sequence: 1, state: .cancelled))
        _ = try manager.coordinator.register(owner: .init(profileID: a), transfer: HistoryTransfer())
        let restored = BrowserDownloadsController(history: try BrowserDownloadHistoryStore(destination: url))
        #expect(restored.coordinator.allSnapshots.map(\.key.id) == [first.key.id, second.key.id])
        _ = restored.snapshots(profileID: a)
        for _ in 0..<100 where restored.coordinator.allSnapshots.first?.fileAvailability == .unknown {
            try await Task.sleep(for: .milliseconds(10))
        }
        let item = try #require(restored.snapshots(profileID: a).first)
        #expect(item.key.lifetime != first.key.lifetime)
        #expect(item.fileAvailability == .missing)
        #expect(item.capabilities.isEmpty)
        #expect(!restored.hasActiveTransfers)
        #expect(restored.snapshots(profileID: b).count == 1)
        #expect(throws: BrowserDownloadError.staleLifetime) { try restored.coordinator.remove(in: .init(key: first.key, revision: item.revision)) }
        try restored.coordinator.remove(in: item.context)
        #expect(try BrowserDownloadHistoryStore(destination: url).records.map(\.id) == [second.key.id])
        manager.shutdown(); restored.shutdown()
    }

    @Test("Start and completion timestamps survive durable history and a fresh transfer lifetime")
    func timestamps() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now
        let coordinator = BrowserDownloadCoordinator(clock: { now })
        let registration = try coordinator.register(owner: .init(profileID: ProfileID()), transfer: HistoryTransfer())
        #expect(coordinator.snapshot(for: registration.key)?.startedAt == start)
        #expect(coordinator.snapshot(for: registration.key)?.completedAt == nil)
        now += 20
        registration.report(.init(key: registration.key, sequence: 1, state: .running, receivedBytes: 5))
        #expect(coordinator.snapshot(for: registration.key)?.startedAt == start)
        #expect(coordinator.snapshot(for: registration.key)?.completedAt == nil)
        now += 10
        registration.report(.init(key: registration.key, sequence: 2, state: .complete, receivedBytes: 10))
        let snapshot = try #require(coordinator.snapshot(for: registration.key))
        #expect(snapshot.completedAt == now)
        let file = root.appendingPathComponent("history.json")
        try BrowserDownloadHistoryStore(destination: file).save([.init(snapshot)])
        let loaded = try BrowserDownloadHistoryStore(destination: file)
        let restored = BrowserDownloadCoordinator()
        try restored.restore(loaded.records)
        let item = try #require(restored.allSnapshots.first)
        #expect(item.startedAt == start && item.completedAt == now)
        #expect(item.key.lifetime != registration.key.lifetime)
    }

    @Test("Version one history without timestamp keys or with null timestamps remains undated after migration")
    func oldHistoryTimestampMigration() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = BrowserDownloadCoordinator()
        let registration = try coordinator.register(owner: .init(profileID: ProfileID()), transfer: HistoryTransfer())
        registration.report(.init(key: registration.key, sequence: 1, state: .complete))
        let encoded = try JSONEncoder().encode(BrowserDownloadHistoryRecord(#require(coordinator.snapshot(for: registration.key))))
        var record = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for nulls in [false, true] {
            record["startedAt"] = nulls ? NSNull() : nil
            record["completedAt"] = nulls ? NSNull() : nil
            let bytes = try JSONSerialization.data(withJSONObject: record)
            let decoded = try JSONDecoder().decode(BrowserDownloadHistoryRecord.self, from: bytes)
            #expect(decoded.startedAt == nil && decoded.completedAt == nil)
            let file = root.appendingPathComponent(nulls ? "nulls.json" : "legacy.json")
            try JSONSerialization.data(withJSONObject: ["version": 1, "records": [record]]).write(to: file)
            let history = try BrowserDownloadHistoryStore(destination: file)
            let restored = BrowserDownloadCoordinator()
            try restored.restore(history.records)
            let snapshot = try #require(restored.allSnapshots.first)
            #expect(snapshot.startedAt == nil && snapshot.completedAt == nil)
            let migrated = root.appendingPathComponent(nulls ? "migrated-nulls.json" : "migrated-legacy.json")
            try BrowserDownloadHistoryStore(destination: migrated).save([.init(snapshot)])
            let reloaded = try #require(BrowserDownloadHistoryStore(destination: migrated).records.first)
            #expect(reloaded.startedAt == nil && reloaded.completedAt == nil)
        }
    }

    @Test("Malformed or future history is left intact")
    func futureHistory() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json")
        let bytes = Data("{\"version\":900,\"records\":[]}".utf8)
        try bytes.write(to: url)
        #expect(throws: BrowserDownloadError.invalidUpdate) { try BrowserDownloadHistoryStore(destination: url) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Staging hides partial bytes, cleans cancellation and refuses a target created during transfer")
    func staging() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("complete.bin")
        let partial = try BrowserDownloadStagingFile(destination: target)
        try Data([1, 2, 3]).write(to: partial.file)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        partial.discard(); partial.discard()
        #expect(!FileManager.default.fileExists(atPath: partial.file.deletingLastPathComponent().path))
        let complete = try BrowserDownloadStagingFile(destination: target)
        try Data([4, 5]).write(to: complete.file)
        try complete.finish()
        #expect(try Data(contentsOf: target) == Data([4, 5]))
        try FileManager.default.removeItem(at: target)
        let conflict = try BrowserDownloadStagingFile(destination: target)
        try Data([6]).write(to: conflict.file)
        try Data([7]).write(to: target)
        let landed = try conflict.finish()
        #expect(landed.lastPathComponent == "complete (1).bin")
        #expect(try Data(contentsOf: landed) == Data([6]))
        #expect(try Data(contentsOf: target) == Data([7]))
        #expect(!FileManager.default.fileExists(atPath: conflict.file.deletingLastPathComponent().path))
    }

    @Test("Moved and deleted files revoke Open and Finder and update availability")
    func missingFileActions() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for action in [DownloadRowPresentation.Action.open, .reveal] {
            let file = root.appendingPathComponent(UUID().uuidString)
            try Data([1]).write(to: file)
            let manager = BrowserDownloadsController()
            let registration = try manager.coordinator.register(owner: .init(profileID: ProfileID()), transfer: HistoryTransfer())
            registration.report(.init(key: registration.key, sequence: 1, state: .complete, destinationURL: file, fileAvailability: .available))
            var invoked = false
            manager.openFile = { _ in invoked = true }
            manager.revealFile = { _ in invoked = true }
            if action == .open { try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("moved")) }
            else { try FileManager.default.removeItem(at: file) }
            manager.perform(action, in: try #require(manager.coordinator.snapshot(for: registration.key)).context)
            for _ in 0..<100 {
                if manager.coordinator.snapshot(for: registration.key)?.fileAvailability == .missing { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(manager.coordinator.snapshot(for: registration.key)?.fileAvailability == .missing)
            #expect(!invoked)
            manager.shutdown()
        }
    }
}
