import AppKit
import BrowserCore
import Testing
@testable import BrowserShell
@testable import Orbit

@MainActor
private final class BookmarkRecheckPanels: BrowserBookmarkPanelPresenting {
    var cancellations = 0
    var failures = 0
    func chooseImport(on window: NSWindow) async -> URL? { URL(fileURLWithPath: "/private/tmp/synthetic-r2-import.html") }
    func chooseExport(preview: BrowserBookmarkTransferPreview, on window: NSWindow) async -> URL? {
        URL(fileURLWithPath: "/private/tmp/synthetic-r2-export.html")
    }
    func confirmImport(preview: BrowserBookmarkTransferPreview, on window: NSWindow) async -> Bool { true }
    func failed(on window: NSWindow) async { failures += 1 }
    func cancel() { cancellations += 1 }
}

@MainActor
private final class BookmarkRecheckWriteGate {
    private(set) var entered = false
    private(set) var wasCancelled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        wasCancelled = Task.isCancelled
    }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
}

extension NativeWebKitTests {
@Suite("Independent native bookmark R2 lifetime recheck", .serialized)
@MainActor
struct NativeBookmarkR2IndependentRecheckTests {
    private func controller(in environment: BrowserEnvironment<SiteSyntheticEngine>) async throws -> BrowserWindowController<SiteSyntheticEngine> {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let result = try await environment.makeWindow(opensInitialTab: false)
        #expect(result.window?.isVisible == false && result.window?.attachedSheet == nil)
        #expect(environment.engine.surfaces.isEmpty && !NSApplication.shared.isActive)
        return result
    }

    private func cleanup(_ controller: BrowserWindowController<SiteSyntheticEngine>) async {
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        await controller.session.waitForPendingCommands()
        #expect(controller.window?.isVisible == false && controller.window?.attachedSheet == nil)
        controller.window?.delegate = nil
        controller.window = nil
    }

    @Test("Dropping weak owners before the task starts removes pre-presentation enrollment")
    func ownerDisappearsBeforeTaskBegins() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let panels = BookmarkRecheckPanels()
        weak var weakOwner: BrowserWindowController<SiteSyntheticEngine>?
        weak var weakTransfer: BrowserBookmarkTransferController<SiteSyntheticEngine>?
        // End AppKit's autoreleased construction temporaries synchronously, before
        // yielding to either the queued context capture or the transfer task.
        let (session, operation) = try autoreleasepool {
            let owner = BrowserWindowController(id: UUID(), store: store, spaceID: space,
                engine: SiteSyntheticEngine(), opensInitialTab: false, onClose: {}, onActivate: {})
            let session = try #require(owner.session)
            let transfer = BrowserBookmarkTransferController(owner: owner, panels: panels)
            owner.bookmarkTransfer = transfer
            weakOwner = owner
            weakTransfer = transfer
            let operation = try #require(transfer.startImport())
            #expect(session.bookmarkTransferCancellations.count == 1)
            owner.bookmarkTransfer = nil
            owner.window?.delegate = nil
            owner.window = nil
            return (session, operation)
        }
        #expect(weakOwner == nil && weakTransfer == nil)
        await operation.value
        #expect(session.bookmarkTransferCancellations.isEmpty)
        #expect(panels.cancellations == 0)
        session.close()
        await session.waitForPendingCommands()
    }

    @Test("Accepted write survives outer cancellation/retirement, drains once and removes its lifetime on success or failure",
          arguments: [false, true])
    func acceptedWriteLifetime(failing: Bool) async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await controller(in: environment)
        let session = try #require(owner.session)
        let gate = BookmarkRecheckWriteGate()
        let panels = BookmarkRecheckPanels()
        var files = BrowserBookmarkFileOperations()
        files.write = { _, _ in
            await gate.hold()
            if failing { throw CocoaError(.fileWriteNoPermission) }
        }
        let transfer = BrowserBookmarkTransferController(owner: owner, panels: panels, files: files)
        owner.bookmarkTransfer = transfer
        let operation = try #require(transfer.startExport())
        defer { gate.release() }
        try await withNativeTestDeadline("Independent accepted Save starts", timeout: 3) {
            while !gate.entered { await Task.yield() }
        }
        #expect(session.acceptedBookmarkExports.count == 1 && !session.hasPendingCommands)
        let boundary = session.captureContextInCommandOrder()
        #expect(await boundary.value != nil)
        var drainFinished = false
        let drain = Task { @MainActor in await session.waitForPendingCommands(); drainFinished = true }
        // Cancelling an observer must not cancel the independently accepted write.
        drain.cancel()
        session.retireForApplicationTermination()
        operation.cancel()
        try await Task.sleep(for: .milliseconds(15))
        #expect(!drainFinished && session.acceptedBookmarkExports.count == 1)
        gate.release()
        await operation.value
        await drain.value
        #expect(drainFinished && !gate.wasCancelled)
        #expect(transfer.lastOutcome == (failing ? .failed : .exported(0)))
        #expect(!transfer.isBusy && session.acceptedBookmarkExports.isEmpty)
        #expect(session.bookmarkTransferCancellations.isEmpty && panels.failures == 0)
        await cleanup(owner)
    }

    @Test("Normal final-save and retirement paths wait for accepted disk work without retaining completed tasks",
          arguments: [false, true])
    func environmentDrainsAcceptedWrite(retiring: Bool) async throws {
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        var owner: BrowserWindowController<SiteSyntheticEngine>? = try await controller(in: environment)
        var session: BrowserWindowSession<SiteSyntheticSurface>? = owner?.session
        weak var weakSession = session
        let gate = BookmarkRecheckWriteGate()
        let panels = BookmarkRecheckPanels()
        var files = BrowserBookmarkFileOperations()
        files.write = { _, _ in await gate.hold() }
        var transfer: BrowserBookmarkTransferController<SiteSyntheticEngine>? = BrowserBookmarkTransferController(owner: owner!, panels: panels, files: files)
        owner?.bookmarkTransfer = transfer
        var operation: Task<Void, Never>? = try #require(transfer?.startExport())
        defer { gate.release() }
        try await withNativeTestDeadline("Independent final-save write starts", timeout: 3) {
            while !gate.entered { await Task.yield() }
        }
        if retiring {
            owner?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        } else {
            try await environment.prepareToSaveForTermination()
        }
        var finalized = false
        let finalization = Task { @MainActor in try await environment.finalize(); finalized = true }
        try await Task.sleep(for: .milliseconds(15))
        #expect(!finalized)
        gate.release()
        try await finalization.value
        await operation?.value
        #expect(finalized && transfer?.lastOutcome == .exported(0))
        #expect(session?.acceptedBookmarkExports.isEmpty == true)
        if let owner { await cleanup(owner) }
        operation = nil
        transfer = nil
        session = nil
        owner = nil
        try await withNativeTestDeadline("Independent retired session releases", timeout: 3) {
            while weakSession != nil { await Task.yield() }
        }
    }

    @Test("Default native file operations use explicit selection authority for ordinary chosen HTML")
    func nativeDefaultSelectedIO() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/orbit-native-r2-selected-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.html")
        let document = BrowserBookmarkDocument(entries: [])
        try BrowserBookmarkHTML.encode(document).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) { try BrowserBookmarkFile.read(at: file) }
        let files = BrowserBookmarkFileOperations()
        #expect(try await files.read(file) == document)
        try await files.write(document, file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try await files.read(file) == document)
    }

    @Test("An unrelated palette command must not wait for an accepted standalone export write")
    func paletteCommandDuringAcceptedWrite() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let router = BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>(
            create: { id in try await environment.makeWindow(id: id, opensInitialTab: false) },
            present: { _, _ in }, dispose: { _ in })
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        _ = router.newWindow()
        await router.waitForPendingCommands()
        let owner = try #require(router.selectedWindow)
        owner.palette.registry = registry
        let gate = BookmarkRecheckWriteGate()
        var files = BrowserBookmarkFileOperations()
        files.write = { _, _ in await gate.hold() }
        let transfer = BrowserBookmarkTransferController(owner: owner, panels: BookmarkRecheckPanels(), files: files)
        owner.bookmarkTransfer = transfer
        let operation = try #require(transfer.startExport())
        defer { gate.release(); router.shutdown() }
        try await withNativeTestDeadline("Palette recheck export starts", timeout: 3) {
            while !gate.entered { await Task.yield() }
        }
        owner.palette.present(.newTab)
        owner.palette.query("Sidebar")
        await owner.palette.waitForResults()
        let index = try #require(owner.palette.results.firstIndex { $0.action == .command(.showHideSidebar) })
        owner.palette.move(index - owner.palette.selection.index)
        let wasVisible = owner.isSidebarShown
        owner.palette.accept()
        #expect(owner.palette.isAccepting && !owner.session.hasPendingCommands)
        try await withNativeTestDeadline("Palette command completes while export I/O is held", timeout: 2) {
            while owner.isSidebarShown == wasVisible {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        #expect(owner.isSidebarShown != wasVisible)
        gate.release()
        await operation.value
        await owner.palette.waitForAcceptance()
        await router.waitForPendingCommands()
        await owner.session.waitForPendingCommands()
        #expect(owner.isSidebarShown != wasVisible)
        #expect(transfer.lastOutcome == .exported(0))
        #expect(owner.window?.isVisible == false && owner.window?.attachedSheet == nil)
        await cleanup(owner)
    }
}
}
