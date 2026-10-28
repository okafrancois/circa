import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class BookmarkInvariantPanels: BrowserBookmarkPanelPresenting {
    var holdOpen = false
    var opened = false
    var cancellations = 0
    var failures = 0
    var exportURL: URL?
    private var completion: BrowserBookmarkPanelCompletion<URL?>?
    func chooseImport(on window: NSWindow) async -> URL? {
        opened = true
        if holdOpen { return await withCheckedContinuation { completion = BrowserBookmarkPanelCompletion($0) } }
        return URL(fileURLWithPath: "/private/tmp/orbit-invariant-input.html")
    }
    func chooseExport(preview: BrowserBookmarkTransferPreview, on window: NSWindow) async -> URL? { exportURL }
    func confirmImport(preview: BrowserBookmarkTransferPreview, on window: NSWindow) async -> Bool { true }
    func failed(on window: NSWindow) async { failures += 1 }
    func cancel() { cancellations += 1; completion?.finish(nil) }
}

extension NativeWebKitTests {
@Suite("Native bookmark review fixed invariants", .serialized)
@MainActor
struct NativeBookmarkReviewInvariantTests {
    private func fixture(document: BrowserBookmarkDocument,
                         write: (@Sendable (BrowserBookmarkDocument, URL) async throws -> Void)? = nil) async throws ->
        (BrowserStore, BrowserWindowController<SiteSyntheticEngine>, BookmarkInvariantPanels, BrowserBookmarkTransferController<SiteSyntheticEngine>) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: space,
            engine: SiteSyntheticEngine(), restoringWindowID: window, onClose: {}, onActivate: {})
        await controller.session.waitForPendingCommands()
        let panels = BookmarkInvariantPanels()
        var files = BrowserBookmarkFileOperations()
        files.read = { _ in document }
        if let write { files.write = write }
        let transfer = BrowserBookmarkTransferController(owner: controller, panels: panels, files: files)
        controller.bookmarkTransfer = transfer
        return (store, controller, panels, transfer)
    }
    private func cleanup(_ controller: BrowserWindowController<SiteSyntheticEngine>) async {
        controller.bookmarkTransfer?.cancel()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        await controller.session.waitForPendingCommands()
        #expect(controller.window?.isVisible == false && controller.window?.attachedSheet == nil)
        controller.window?.delegate = nil; controller.window = nil
    }

    @Test("Direct close and terminal retirement finish a pre-admission file choice", arguments: [false, true])
    func retirementCancelsChoice(termination: Bool) async throws {
        let (store, controller, panels, transfer) = try await fixture(document: .init(entries: []))
        panels.holdOpen = true
        let operation = try #require(transfer.startImport())
        try await withNativeTestDeadline("Synthetic open choice", timeout: 3) {
            while !panels.opened { await Task.yield() }
        }
        if termination { controller.session.retireForApplicationTermination() } else { controller.session.close() }
        #expect(panels.cancellations > 0)
        // Baseline sensitivity must never leave a held fixture continuation behind.
        if panels.cancellations == 0 { transfer.cancel() }
        await operation.value
        #expect(!transfer.isBusy && transfer.lastOutcome == .cancelled)
        #expect(await store.sessionDocument().organization.tabs.isEmpty)
        await cleanup(controller)
    }

    @Test("An admitted model failure remains failed after its error callback closes the source")
    func admittedFailureRetainsOutcome() async throws {
        // Inject a post-admission service failure independently of the repaired title sanitizer.
        let invalid = BrowserBookmarkDocument(entries: [.link(title: "Invalid", url: URL(fileURLWithPath: "/synthetic-only") )])
        let (store, controller, panels, transfer) = try await fixture(document: invalid)
        let before = await store.sessionDocument().organization
        var sawError = false
        controller.session.onError = { _ in sawError = true; controller.session.close() }
        let operation = try #require(transfer.startImport())
        await operation.value
        #expect(sawError && controller.session.isClosed)
        #expect(transfer.lastOutcome == .failed)
        #expect(await store.sessionDocument().organization == before)
        #expect(panels.failures == 0)
        await cleanup(controller)
    }

    @Test("Quit draining waits for an accepted Save while ordinary command boundaries still proceed")
    func acceptedSaveIsDrained() async throws {
        let gate = BookmarkInvariantExportGate()
        let (_, controller, panels, transfer) = try await fixture(document: .init(entries: []), write: { _, _ in await gate.hold() })
        panels.exportURL = URL(fileURLWithPath: "/private/tmp/orbit-invariant-export.html")
        let operation = try #require(transfer.startExport())
        defer { gate.resume() }
        try await withNativeTestDeadline("Accepted synthetic export", timeout: 3) {
            while !gate.entered { await Task.yield() }
        }
        let boundary = controller.session.captureContextInCommandOrder()
        try await withNativeTestDeadline("Navigation does not wait for export I/O", timeout: 3) {
            #expect(await boundary.value != nil)
        }
        var started = false, finished = false
        let drain = Task { @MainActor in
            started = true
            await controller.session.waitForPendingCommands()
            finished = true
        }
        try await withNativeTestDeadline("Drain begins", timeout: 3) {
            while !started { await Task.yield() }
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(!finished)
        controller.freezeCommandsForTermination()
        gate.resume()
        await drain.value; await operation.value
        #expect(finished && transfer.lastOutcome == .exported(0))
        await cleanup(controller)
    }
}
}

@MainActor
private final class BookmarkInvariantExportGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { let pending = continuation; continuation = nil; pending?.resume() }
}
