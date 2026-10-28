import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Library media inventory", .serialized)
@MainActor
struct LibraryMediaTests {
    private func snapshot(_ url: URL, profile: ProfileID, state: BrowserDownloadState = .complete) -> BrowserDownloadSnapshot {
        .init(key: .init(id: UUID(), profileID: profile, lifetime: UUID()), owner: .init(profileID: profile),
              revision: 1, sequence: 1, suggestedFilename: url.lastPathComponent, state: state,
              receivedBytes: 1, totalBytes: 1, capabilities: [], currentURL: nil, destinationURL: url,
              fileAvailability: .available, failure: nil, pendingAction: nil, isCancellationRequested: false, controlError: nil)
    }
    @Test("Only completed image and video downloads from the selected profile enter the grid")
    func scopedInventory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = ProfileID(), b = ProfileID()
        let urls = ["Café.png", "Clip.mp4", "Other.jpg", "Running.png", "Notes.txt", "Untracked.png"].map { root.appendingPathComponent($0) }
        for url in urls { try Data([0]).write(to: url) }
        let records = [snapshot(urls[0], profile: a), snapshot(urls[1], profile: a), snapshot(urls[2], profile: b),
                       snapshot(urls[3], profile: a, state: .running), snapshot(urls[4], profile: a), snapshot(root.appendingPathComponent("Missing.png"), profile: a)]
        let view = BrowserLibraryMediaView(frame: NSRect(x: 0, y: 0, width: 305, height: 780))
        view.render(records, profile: a)
        #expect(view.rows.map(\.url) == Array(urls.prefix(2)))
        #expect(view.rows.map(\.isVideo) == [false, true])
        view.searchField.stringValue = "cafe"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(view.rows.map(\.url) == [urls[0]])
        view.render(records, profile: b)
        #expect(view.rows.map(\.url) == [urls[2]])
        #expect(view.searchField.stringValue.isEmpty)
        try FileManager.default.removeItem(at: urls[2])
        view.render(records, profile: b)
        #expect(view.rows.isEmpty)
    }
    @Test("Restored media uses existing open and reveal actions, and stale profile actions are rejected")
    func restoredActions() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserStore()
        let a = await store.createProfile(name: "Synthetic A"), b = await store.createProfile(name: "Synthetic B")
        let first = try await store.createSpace(name: "First", profileID: a)
        let other = try await store.createSpace(name: "Other", profileID: b)
        let file = root.appendingPathComponent("Synthetic.png")
        try Data([0]).write(to: file)
        let history = try BrowserDownloadHistoryStore(destination: root.appendingPathComponent("downloads.json"))
        try history.save([BrowserDownloadHistoryRecord(snapshot(file, profile: a))])
        let downloads = BrowserDownloadsController(history: history)
        var opened: [URL] = [], revealed: [URL] = []
        downloads.openFile = { opened.append($0) }; downloads.revealFile = { revealed.append($0) }
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: first, engine: SiteSyntheticEngine(), downloads: downloads, onClose: {}, onActivate: {})
        defer { controller.session.close(); controller.window?.close(); downloads.shutdown() }
        await controller.session.waitForPendingCommands()
        controller.showLibrary(.media); await controller.session.waitForPendingCommands()
        let view = controller.library.mediaView
        #expect(view.rows.count == 1)
        let context = try #require(view.rows.first?.snapshot.context)
        view.onAction?(context, .open)
        for _ in 0..<100 where opened.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(opened == [file])
        let refreshed = try #require(view.rows.first?.snapshot.context)
        view.onAction?(refreshed, .reveal)
        for _ in 0..<100 where revealed.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(revealed == [file])
        controller.session.activateSpace(other); await controller.session.waitForPendingCommands()
        #expect(view.rows.isEmpty)
        view.onAction?(refreshed, .open)
        #expect(opened == [file])
    }
}
}
