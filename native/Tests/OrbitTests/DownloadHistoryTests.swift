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
    func restore() throws {
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
        #expect(throws: (any Error).self) { try conflict.finish() }
        conflict.discard()
        #expect(try Data(contentsOf: target) == Data([7]))
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
