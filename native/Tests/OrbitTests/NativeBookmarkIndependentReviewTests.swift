import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class IndependentBookmarkPanels: BrowserBookmarkPanelPresenting {
    var holdOpen = false
    var opened = false
    var cancellationCount = 0
    var failureCount = 0
    private var completion: BrowserBookmarkPanelCompletion<URL?>?

    func chooseImport(on window: NSWindow) async -> URL? {
        opened = true
        guard holdOpen else { return URL(fileURLWithPath: "/private/tmp/orbit-independent-synthetic-input.html") }
        return await withCheckedContinuation { completion = BrowserBookmarkPanelCompletion($0) }
    }
    func chooseExport(preview: BrowserBookmarkTransferPreview, on window: NSWindow) async -> URL? { nil }
    func confirmImport(preview: BrowserBookmarkTransferPreview, on window: NSWindow) async -> Bool { true }
    func failed(on window: NSWindow) async { failureCount += 1 }
    func cancel() { cancellationCount += 1; completion?.finish(nil) }
}

@MainActor
private struct IndependentBookmarkNativeFixture {
    let store: BrowserStore
    let controller: BrowserWindowController<SiteSyntheticEngine>
    let panels: IndependentBookmarkPanels
    let transfer: BrowserBookmarkTransferController<SiteSyntheticEngine>

    static func make(document: BrowserBookmarkDocument) async throws -> Self {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic independent review")
        let space = try await store.createSpace(name: "Synthetic source", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: space,
            engine: SiteSyntheticEngine(), restoringWindowID: window, onClose: {}, onActivate: {})
        await controller.session.waitForPendingCommands()
        controller.session.onError = { _ in }
        let panels = IndependentBookmarkPanels()
        var files = BrowserBookmarkFileOperations()
        // No file is opened. The only input is the synthetic supported document supplied here.
        files.read = { _ in document }
        let transfer = BrowserBookmarkTransferController(owner: controller, panels: panels, files: files)
        controller.bookmarkTransfer = transfer
        return .init(store: store, controller: controller, panels: panels, transfer: transfer)
    }

    func cleanup() async {
        transfer.cancel()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        await controller.session.waitForPendingCommands()
        #expect(controller.engine.surfaces.isEmpty)
        #expect(controller.window?.isVisible == false)
        #expect(controller.window?.attachedSheet == nil)
        #expect(NSApplication.shared.activationPolicy() == .prohibited)
        #expect(!NSApplication.shared.isActive)
        controller.window?.delegate = nil
        controller.window = nil
    }
}

extension NativeWebKitTests {
@Suite("Independent hidden native bookmark review R1", .serialized)
@MainActor
struct NativeBookmarkIndependentReviewTests {
    @Test("R1-P2-LIFETIME: direct session retirement during a held file choice must finish the transfer",
          .disabled("Historical R1 bug characterization; desired fixed invariants run in NativeBookmarkReviewInvariantTests"), arguments: [false, true])
    func retirementDuringFileChoiceCounterexample(termination: Bool) async throws {
        let f = try await IndependentBookmarkNativeFixture.make(document: .init(entries: []))
        f.panels.holdOpen = true
        let operation = try #require(f.transfer.startImport())
        try await withNativeTestDeadline("Independent synthetic open checkpoint", timeout: 5) {
            while !f.panels.opened { try await Task.sleep(for: .milliseconds(5)) }
        }
        if termination { f.controller.session.retireForApplicationTermination() }
        else { f.controller.session.close() }
        await f.controller.session.waitForPendingCommands()
        #expect(f.controller.session.isClosed)
        #expect(f.transfer.isBusy && f.panels.cancellationCount == 0)
        withKnownIssue("R1-P2-LIFETIME: session retirement has no notification to a pre-admission transfer/panel") {
            #expect(f.panels.cancellationCount > 0)
        }
        // The review owns this continuation and releases it directly. Never hang on a failed expectation.
        f.transfer.cancel()
        await operation.value
        #expect(f.transfer.lastOutcome == .cancelled)
        #expect((await f.store.sessionDocument()).organization.tabs.isEmpty)
        await f.cleanup()
    }

    @Test("R1-P2-RESULT: an admitted failed transaction retains failure after its error callback closes the source", .disabled("Historical R1 failure trigger is fixed; independent admitted-failure regression remains active"))
    func admittedFailureAfterClosureCounterexample() async throws {
        let title = String(repeating: "A", count: 1_023) + " B"
        // A real decoder accepts this portable document; the existing normalization later refuses it.
        let html = "<DL><H3>\(title)</H3><DL></DL></DL>"
        let document = try BrowserBookmarkHTML.decode(Data(html.utf8))
        let f = try await IndependentBookmarkNativeFixture.make(document: document)
        let before = await f.store.sessionDocument()
        var sawError = false
        f.controller.session.onError = { _ in
            sawError = true
            f.controller.session.close()
        }
        let operation = try #require(f.transfer.startImport())
        await operation.value
        #expect(sawError && f.controller.session.isClosed)
        #expect(f.transfer.lastOutcome == .cancelled)
        #expect((await f.store.sessionDocument()).organization == before.organization)
        #expect(f.panels.failureCount == 0)
        withKnownIssue("R1-P2-RESULT: the controller drops an admitted failure when current(owner, context) becomes false") {
            #expect(f.transfer.lastOutcome == .failed)
        }
        await f.cleanup()
    }
}
}
