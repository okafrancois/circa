import BrowserCore
import BrowserShell
import Foundation
import Testing

@Suite("Owned download renaming") @MainActor
struct BrowserDownloadRenameTests {
    final class Transfer: BrowserDownloadTransfer {
        func perform(_ action: BrowserDownloadAction, completion: @escaping @MainActor (Result<Void, BrowserDownloadError>) -> Void) {}
        func invalidate() {}
    }
    @Test func collisionUndoAndStaleIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-tidy-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.pdf")
        try Data("synthetic".utf8).write(to: original)
        let coordinator = BrowserDownloadCoordinator()
        let registration = try coordinator.register(owner: .init(profileID: ProfileID()), transfer: Transfer(), suggestedFilename: "original.pdf")
        _ = registration.report(.init(key: registration.key, sequence: 1, state: .running, receivedBytes: 9, destinationURL: original))
        _ = registration.report(.init(key: registration.key, sequence: 2, state: .complete, receivedBytes: 9, destinationURL: original))
        let snapshot = try #require(coordinator.snapshot(for: registration.key))
        let lease = try #require(coordinator.renameLease(in: snapshot.context))
        let collision = root.appendingPathComponent("collision.pdf")
        try Data("keep".utf8).write(to: collision)
        #expect(coordinator.rename(lease, to: "collision.pdf") == nil)
        #expect(try String(contentsOf: collision, encoding: .utf8) == "keep")
        #expect(coordinator.rename(lease, to: "../escape.pdf") == nil)
        let renamed = try #require(coordinator.rename(lease, to: "Invoice.pdf"))
        #expect(coordinator.snapshot(for: registration.key)?.destinationURL == renamed.url)
        #expect(coordinator.rename(lease, to: "stale.pdf") == nil)
        try Data("keep original collision".utf8).write(to: original)
        #expect(coordinator.rename(renamed, to: "original.pdf") == nil)
        try FileManager.default.removeItem(at: original)
        let undone = try #require(coordinator.rename(renamed, to: "original.pdf"))
        let moved = root.appendingPathComponent("user-moved.pdf")
        try FileManager.default.moveItem(at: undone.url, to: moved)
        try FileManager.default.moveItem(at: moved, to: undone.url)
        #expect(coordinator.rename(undone, to: "late-after-user-move.pdf") == nil)
        try FileManager.default.removeItem(at: undone.url)
        #expect(coordinator.rename(undone, to: "missing.pdf") == nil)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: collision)
        #expect(coordinator.renameLease(in: undone.context) == nil)
        coordinator.shutdown()
    }
}
