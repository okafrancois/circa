import Darwin
import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class BookmarkFakePanels: BrowserBookmarkPanelPresenting {
    enum Stage { case open, confirm, save, failure }
    var held: Stage?
    var entered: Stage?
    var importURL: URL?
    var exportURL: URL?
    var confirms = true
    var previews: [BrowserBookmarkTransferPreview] = []
    var opens = 0
    var saves = 0
    var failures = 0
    var cancellations = 0
    var onConfirm: (() async -> Void)?
    private var finishWait: ((Bool) -> Void)?

    private func pass(_ stage: Stage) async -> Bool {
        entered = stage
        guard held == stage else { return true }
        return await withCheckedContinuation { continuation in
            let completion = BrowserBookmarkPanelCompletion(continuation)
            finishWait = { [weak self] value in
                if completion.finish(value) { self?.finishWait = nil }
            }
        }
    }
    func release() { finishWait?(true) }
    func chooseImport(on window: NSWindow) async -> URL? {
        opens += 1
        return await pass(.open) ? importURL : nil
    }
    func chooseExport(preview: BrowserBookmarkTransferPreview, on window: NSWindow) async -> URL? {
        saves += 1; previews.append(preview)
        return await pass(.save) ? exportURL : nil
    }
    func confirmImport(preview: BrowserBookmarkTransferPreview, on window: NSWindow) async -> Bool {
        previews.append(preview)
        await onConfirm?()
        return await pass(.confirm) && confirms
    }
    func failed(on window: NSWindow) async { failures += 1; _ = await pass(.failure) }
    func cancel() { cancellations += 1; finishWait?(false) }
}

private final class BookmarkModelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    let release = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { started } }
    func hold() { lock.withLock { started = true }; _ = release.wait(timeout: .now() + 10) }
}

private extension BrowserStore {
    func holdForBookmarkTest(_ gate: BookmarkModelGate) { gate.hold() }
    /// A real settings reassignment is possible only after the source Space is inactive and empty.
    /// Keep the entire ABA sequence in one model turn so a stale shell cache cannot hide the test.
    func holdAndChangeBookmarkTarget(_ gate: BookmarkModelGate, window: WindowID, original: SpaceID,
                                     alternate: SpaceID, foreign: ProfileID, originalProfile: ProfileID,
                                     reassign: Bool, returnToOriginal: Bool) throws {
        gate.hold()
        _ = try activateSpace(alternate, from: captureContext(in: window))
        if reassign { try assignSettingsSpace(original, to: foreign) }
        if returnToOriginal {
            if reassign { try assignSettingsSpace(original, to: originalProfile) }
            _ = try activateSpace(original, from: captureContext(in: window))
        }
    }
}

private actor BookmarkIOGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private struct BookmarkTransferFixture {
    let store: BrowserStore
    let controller: BrowserWindowController<SiteSyntheticEngine>
    let panels: BookmarkFakePanels
    let transfer: BrowserBookmarkTransferController<SiteSyntheticEngine>
    let profile: ProfileID
    let foreign: ProfileID
    let space: SpaceID
    let alternate: SpaceID
    let foreignSpace: SpaceID
    let windowID: WindowID
    let root: URL

    static func make(files: BrowserBookmarkFileOperations = .init()) async throws -> Self {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("orbit-bookmark-controller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic source profile")
        let foreign = await store.createProfile(name: "Synthetic foreign profile")
        let space = try await store.createSpace(name: "Source Space", profileID: profile)
        let alternate = try await store.createSpace(name: "Other Space", profileID: profile)
        let foreignSpace = try await store.createSpace(name: "Foreign Space", profileID: foreign)
        let windowID = try await store.createWindow(activeSpaceID: space)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: space,
            engine: SiteSyntheticEngine(), restoringWindowID: windowID, onClose: {}, onActivate: {})
        await controller.session.waitForPendingCommands()
        controller.session.onError = { _ in }
        let panels = BookmarkFakePanels()
        panels.importURL = root.appendingPathComponent("input.html")
        panels.exportURL = root.appendingPathComponent("output.html")
        let transfer = BrowserBookmarkTransferController(owner: controller, panels: panels, files: files)
        controller.bookmarkTransfer = transfer
        return Self(store: store, controller: controller, panels: panels, transfer: transfer,
                    profile: profile, foreign: foreign, space: space, alternate: alternate,
                    foreignSpace: foreignSpace, windowID: windowID, root: root)
    }
    func seedInput() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1><DL>
        <H3>Research &amp; Équipe</H3><DL><A HREF="https://bookmarks.test/a?q=1&amp;x=2">Saved title</A><H3>Empty</H3><DL></DL></DL>
        <A HREF="https://bookmarks.test/b">Second</A>
        <A HREF="javascript:alert(1)">Unsupported</A><A HREF="chrome://settings">Internal</A>
        <A HREF="https://synthetic:credential@bookmarks.test/">Credential</A></DL>
        """
        try Data(html.utf8).write(to: panels.importURL!)
    }
    func cleanup() {
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.window?.delegate = nil
        controller.window = nil
        try? FileManager.default.removeItem(at: root)
    }
    func expectHidden() {
        #expect(controller.window?.isVisible == false)
        #expect(controller.window?.attachedSheet == nil)
        #expect(NSApplication.shared.activationPolicy() == .prohibited)
        #expect(!NSApplication.shared.isActive)
        #expect(controller.engine.surfaces.isEmpty)
    }
    func waitForPanel(_ stage: BookmarkFakePanels.Stage) async throws {
        try await withNativeTestDeadline("Synthetic bookmark panel checkpoint", timeout: 5) {
            while panels.entered != stage { try await Task.sleep(for: .milliseconds(5)) }
        }
    }
}

extension NativeWebKitTests {
@Suite("Actual native bookmark file flow without ordered windows", .serialized)
@MainActor
struct NativeBookmarkTransferTests {
    @Test("Registry reaches the real controller; busy state prevents duplicate pending commands")
    func registryAndBusyMenu() async throws {
        let f = try await BookmarkTransferFixture.make()
        defer { f.cleanup() }
        try f.seedInput()
        f.panels.held = .open
        let router = BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>(
            create: { _ in f.controller }, present: { _, _ in }, dispose: { _ in })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        #expect(!registry.isEnabled(.importBookmarks))
        _ = router.newWindow()
        await router.waitForPendingCommands()
        let menus = BrowserCommandMenus(registry: registry)
        let menu = try #require(menus.makeMenuBar().items.first { $0.title == "File" }?.submenu)
        for id in [BrowserCommandID.importBookmarks, .exportBookmarks] {
            // Reached from the Command Bar; File keeps a single browser import entry.
            #expect(!menu.items.contains { $0.identifier?.rawValue == id.rawValue })
            #expect(registry.isImplemented(id) && registry.isEnabled(id))
        }
        #expect(registry.dispatch(.importBookmarks, origin: .menu))
        await router.waitForPendingCommands()
        try await f.waitForPanel(.open)
        #expect(!registry.isEnabled(.importBookmarks) && !registry.isEnabled(.exportBookmarks))
        #expect(!registry.dispatch(.exportBookmarks, origin: .menu))
        #expect(f.transfer.startImport() == nil && f.transfer.startExport() == nil)
        f.panels.release()
        try await withNativeTestDeadline("Bookmark command completed", timeout: 5) {
            while f.transfer.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(f.transfer.lastOutcome == .imported(2))
        #expect(f.panels.opens == 1)
        #expect((await f.store.sessionDocument()).organization.tabs.count == 2)
        #expect(registry.isEnabled(.exportBookmarks))
        f.expectHidden()
    }

    @Test("Choose, parse, exact preview, confirm, dormant sidebar batch, undo and export/readback retain structure")
    func actualFileRoundtripAndUndo() async throws {
        let f = try await BookmarkTransferFixture.make()
        defer { f.cleanup() }
        try f.seedInput()
        let before = await f.store.sessionDocument()
        let operation = try #require(f.transfer.startImport())
        await operation.value
        #expect(f.transfer.lastOutcome == .imported(2))
        #expect(f.panels.previews == [.init(links: 2, folders: 2, skipped: 3,
                                           profile: "Synthetic source profile", space: "Source Space")])
        #expect(f.controller.session.organization?.pinned.count == 1)
        #expect(f.controller.session.organization?.undoAction == .importBookmarks)
        let imported = await f.store.sessionDocument()
        #expect(imported.tabs == before.tabs && imported.windows == before.windows)
        let export = try #require(f.transfer.startExport())
        await export.value
        #expect(f.transfer.lastOutcome == .exported(2))
        let readback = try BrowserBookmarkFile.read(at: f.panels.exportURL!)
        #expect(readback.linkCount == 2 && readback.folderCount == 4)
        let expected = try await f.store.exportBookmarks(from: f.store.captureContext(in: f.windowID))
        #expect(readback == expected)
        // Reimport the exported structure using the same actual organization path in a fresh store.
        let copy = BrowserStore()
        let profile = await copy.createProfile(name: "Synthetic copy")
        let space = try await copy.createSpace(name: "Copy", profileID: profile)
        let window = try await copy.createWindow(activeSpaceID: space)
        _ = try await copy.importBookmarks(readback, folderTitle: "Roundtrip", from: copy.captureContext(in: window))
        let copyExport = try await copy.exportBookmarks(from: copy.captureContext(in: window))
        #expect(copyExport.entries == [.folder(title: "Copy", children: [.folder(title: "Roundtrip", children: readback.entries)])])
        f.controller.session.undoOrganization()
        await f.controller.session.waitForPendingCommands()
        #expect((await f.store.sessionDocument()).organization == before.organization)
        f.controller.session.redoOrganization()
        await f.controller.session.waitForPendingCommands()
        #expect((await f.store.sessionDocument()).organization == imported.organization)
        f.expectHidden()
    }

    @Test("Refusing confirmation or cancelling the file choice makes no mutation", arguments: [true, false])
    func userCancellation(atConfirmation: Bool) async throws {
        let f = try await BookmarkTransferFixture.make()
        defer { f.cleanup() }
        try f.seedInput()
        if atConfirmation { f.panels.confirms = false } else { f.panels.importURL = nil }
        let before = await f.store.sessionDocument()
        await f.transfer.startImport()?.value
        #expect(f.transfer.lastOutcome == .cancelled)
        #expect(await f.store.sessionDocument() == before)
        #expect(f.panels.failures == 0)
        f.expectHidden()
    }

    @Test("Malformed files report failure with no success and no browser mutation")
    func malformedFailure() async throws {
        let f = try await BookmarkTransferFixture.make()
        defer { f.cleanup() }
        try Data("<DL><A>unfinished".utf8).write(to: f.panels.importURL!)
        let before = await f.store.sessionDocument()
        await f.transfer.startImport()?.value
        #expect(f.transfer.lastOutcome == .failed && f.panels.failures == 1)
        #expect(f.panels.previews.isEmpty)
        #expect(await f.store.sessionDocument() == before)
        f.expectHidden()
    }

    @Test("Source Space or profile changes and ABA while file reading is suspended cancel the original target",
          arguments: ["space", "profile", "aba"])
    func sourceChangesDuringRead(action: String) async throws {
        let io = BookmarkIOGate()
        var files = BrowserBookmarkFileOperations()
        let read = files.read
        files.read = { url in await io.hold(); return try await read(url) }
        let f = try await BookmarkTransferFixture.make(files: files)
        defer { f.cleanup() }
        try f.seedInput()
        let operation = try #require(f.transfer.startImport())
        try await withNativeTestDeadline("Bookmark read entered", timeout: 5) {
            while !(await io.entered) { try await Task.sleep(for: .milliseconds(5)) }
        }
        f.controller.session.activateSpace(action == "profile" ? f.foreignSpace : f.alternate)
        await f.controller.session.waitForPendingCommands()
        if action == "aba" {
            f.controller.session.activateSpace(f.space)
            await f.controller.session.waitForPendingCommands()
        }
        await io.release()
        await operation.value
        #expect(f.transfer.lastOutcome == .cancelled)
        #expect(f.panels.previews.isEmpty)
        #expect((await f.store.sessionDocument()).organization.tabs.isEmpty)
        f.expectHidden()
    }

    @Test("Exact actor context refuses stale Space, profile reassignment and ABA even before shell refresh",
          arguments: ["space", "profile", "aba", "profile-aba"])
    func actorTargetChanges(action: String) async throws {
        let f = try await BookmarkTransferFixture.make()
        defer { f.cleanup() }
        try f.seedInput()
        let gate = BookmarkModelGate()
        defer { gate.release.signal() }
        var holder: Task<Void, any Error>?
        f.panels.onConfirm = {
            holder = Task.detached {
                try await f.store.holdAndChangeBookmarkTarget(gate, window: f.windowID, original: f.space,
                    alternate: f.alternate, foreign: f.foreign, originalProfile: f.profile,
                    reassign: action.hasPrefix("profile"), returnToOriginal: action.contains("aba"))
            }
            try? await withNativeTestDeadline("Bookmark model gate entered", timeout: 5) {
                while !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
            }
        }
        let operation = try #require(f.transfer.startImport())
        try await withNativeTestDeadline("Import queued while model held", timeout: 5) {
            while !gate.entered || !f.controller.session.hasPendingCommands { try await Task.sleep(for: .milliseconds(5)) }
        }
        gate.release.signal()
        try await holder?.value
        await operation.value
        #expect(f.transfer.lastOutcome != .imported(2))
        #expect((await f.store.sessionDocument()).organization.tabs.isEmpty)
        f.expectHidden()
    }

    @Test("Cancel, close or termination before actor admission revoke the one queued transaction",
          arguments: ["cancel", "close", "termination", "session-close"])
    func cancelBeforeAdmission(action: String) async throws {
        let f = try await BookmarkTransferFixture.make()
        defer { f.cleanup() }
        try f.seedInput()
        let gate = BookmarkModelGate()
        defer { gate.release.signal() }
        var holder: Task<Void, Never>?
        f.panels.onConfirm = {
            holder = Task.detached { await f.store.holdForBookmarkTest(gate) }
            try? await withNativeTestDeadline("Import actor held", timeout: 5) {
                while !gate.entered { try await Task.sleep(for: .milliseconds(5)) }
            }
        }
        let operation = try #require(f.transfer.startImport())
        try await withNativeTestDeadline("Import command pending", timeout: 5) {
            while !gate.entered || !f.controller.session.hasPendingCommands { try await Task.sleep(for: .milliseconds(5)) }
        }
        switch action {
        case "cancel": f.transfer.cancel()
        case "close": f.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        case "termination": f.controller.freezeCommandsForTermination()
        default: f.controller.session.close()
        }
        gate.release.signal()
        await holder?.value
        await operation.value
        await f.controller.session.waitForPendingCommands()
        #expect(f.transfer.lastOutcome == .cancelled)
        #expect((await f.store.sessionDocument()).organization.tabs.isEmpty)
        #expect(!f.controller.session.hasPendingCommands)
        if action != "close" && action != "session-close" { f.expectHidden() }
    }

    @Test("Source closure or termination finishes a held fake panel continuation without AppKit",
          arguments: ["open-close", "confirm-termination", "save-close"])
    func panelLifetime(action: String) async throws {
        let f = try await BookmarkTransferFixture.make()
        defer { f.cleanup() }
        try f.seedInput()
        let stage: BookmarkFakePanels.Stage = action.hasPrefix("open") ? .open : (action.hasPrefix("save") ? .save : .confirm)
        f.panels.held = stage
        let operation = try #require(stage == .save ? f.transfer.startExport() : f.transfer.startImport())
        try await f.waitForPanel(stage)
        if action.contains("termination") { f.controller.freezeCommandsForTermination() }
        else { f.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        await operation.value
        #expect(!f.transfer.isBusy && f.transfer.lastOutcome == .cancelled)
        #expect(f.panels.cancellations > 0)
        #expect(!FileManager.default.fileExists(atPath: f.panels.exportURL!.path))
        #expect((await f.store.sessionDocument()).organization.tabs.isEmpty)
    }

    @Test("An explicit Save grant finishes atomic export after source closure or termination",
          arguments: [false, true])
    func acceptedExportSurvivesClosure(termination: Bool) async throws {
        let io = BookmarkIOGate()
        var files = BrowserBookmarkFileOperations()
        let write = files.write
        files.write = { document, url in await io.hold(); try await write(document, url) }
        let f = try await BookmarkTransferFixture.make(files: files)
        defer { f.cleanup() }
        try f.seedInput()
        await f.transfer.startImport()?.value
        let operation = try #require(f.transfer.startExport())
        try await withNativeTestDeadline("Accepted export held before write", timeout: 5) {
            while !(await io.entered) { try await Task.sleep(for: .milliseconds(5)) }
        }
        if termination { f.controller.freezeCommandsForTermination() }
        else { f.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        await io.release()
        await operation.value
        #expect(f.transfer.lastOutcome == .exported(2))
        #expect(try BrowserBookmarkFile.read(at: f.panels.exportURL!).linkCount == 2)
        #expect(f.panels.saves == 1)
    }

    @Test("Committed import remains successful if session installation immediately retires its source",
          arguments: [false, true])
    func acceptedImportSurvivesClosure(termination: Bool) async throws {
        let f = try await BookmarkTransferFixture.make()
        defer { f.cleanup() }
        try f.seedInput()
        let original = f.controller.session.onChange
        f.controller.session.onChange = {
            original?()
            if f.controller.session.organization?.undoAction == .importBookmarks {
                if termination { f.controller.freezeCommandsForTermination() }
                else { f.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
            }
        }
        await f.transfer.startImport()?.value
        #expect(f.transfer.lastOutcome == .imported(2))
        #expect((await f.store.sessionDocument()).organization.tabs.count == 2)
        #expect(f.panels.previews.count == 1)
    }

    @Test("Actual controller preserves other Spaces, profiles, Today and archive and exports only saved profile links")
    func controllerScopeIsolation() async throws {
        let f = try await BookmarkTransferFixture.make()
        defer { f.cleanup() }
        try f.seedInput()
        let otherWindow = try await f.store.createWindow(activeSpaceID: f.alternate)
        func context() async throws -> BrowserContext { try await f.store.captureContext(in: otherWindow) }
        func open(_ path: String) async throws -> TabID {
            let occurrence = try await f.store.openTab(url: URL(string: "https://scope.test/\(path)")!, from: context(), activate: true)
            return try #require((await f.store.sessionDocument()).tabs.first { $0.occurrenceID == occurrence }?.id)
        }
        let saved = try await open("saved-home")
        _ = try await f.store.addToFavorites([saved], from: context())
        _ = try await f.store.renameTab(saved, to: "Custom favorite", from: context())
        let occurrence = try #require((await f.store.sessionDocument()).tabs.first { $0.id == saved }?.occurrenceID)
        try await f.store.updateDestination(for: occurrence, to: URL(string: "https://scope.test/live-away")!, from: context())
        let archived = try await open("archived")
        _ = try await f.store.archiveTabs([archived], from: context())
        _ = try await open("today")
        _ = try await f.store.createFolder(title: "Unchanged alternate folder", at: .init(.pinned(f.alternate)), from: context())
        let foreignWindow = try await f.store.createWindow(activeSpaceID: f.foreignSpace)
        let foreignDocument = BrowserBookmarkDocument(entries: [.link(title: "Foreign saved", url: URL(string: "https://foreign.test/")!)])
        _ = try await f.store.importBookmarks(foreignDocument, folderTitle: "Foreign folder", from: f.store.captureContext(in: foreignWindow))
        await f.controller.session.waitForPendingCommands()
        let before = await f.store.sessionDocument()
        await f.transfer.startImport()?.value
        #expect(f.transfer.lastOutcome == .imported(2))
        let after = await f.store.sessionDocument()
        #expect(after.tabs == before.tabs && after.windows == before.windows)
        #expect(after.organization.favorites == before.organization.favorites)
        #expect(after.organization.archive == before.organization.archive)
        for space in [f.alternate, f.foreignSpace] {
            #expect(after.organization.spaces.first { $0.spaceID == space } == before.organization.spaces.first { $0.spaceID == space })
        }
        await f.transfer.startExport()?.value
        #expect(f.transfer.lastOutcome == .exported(3))
        let exported = try BrowserBookmarkFile.read(at: f.panels.exportURL!)
        #expect(exported.entries.first == .folder(title: "Favorites", children: [
            .link(title: "Custom favorite", url: URL(string: "https://scope.test/saved-home")!)
        ]))
        let text = try String(contentsOf: f.panels.exportURL!, encoding: .utf8)
        for excluded in ["live-away", "foreign.test", "scope.test/archived", "scope.test/today"] { #expect(!text.contains(excluded)) }
        #expect(f.panels.previews.last?.profile == "Synthetic source profile")
        f.expectHidden()
    }

    @Test("An accepted export I/O failure never becomes success or a misleading cancellation after closure",
          arguments: [false, true])
    func acceptedExportFailure(closes: Bool) async throws {
        let io = BookmarkIOGate()
        var files = BrowserBookmarkFileOperations()
        files.write = { _, _ in await io.hold(); throw CocoaError(.fileWriteNoPermission) }
        let f = try await BookmarkTransferFixture.make(files: files)
        defer { f.cleanup() }
        let operation = try #require(f.transfer.startExport())
        try await withNativeTestDeadline("Export failure checkpoint", timeout: 5) {
            while !(await io.entered) { try await Task.sleep(for: .milliseconds(5)) }
        }
        if closes { f.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification)) }
        await io.release()
        await operation.value
        #expect(f.transfer.lastOutcome == .failed)
        #expect(f.panels.failures == (closes ? 0 : 1))
        #expect(!FileManager.default.fileExists(atPath: f.panels.exportURL!.path))
    }

    @Test("Native panel continuations are one-shot under cancellation and late completion")
    func completionExactlyOnce() async {
        var completions = 0
        let result: Bool = await withCheckedContinuation { continuation in
            let request = BrowserBookmarkPanelCompletion(continuation)
            if request.finish(false) { completions += 1 }
            if request.finish(true) { completions += 1 }
        }
        #expect(!result && completions == 1)
    }

    @Test("Native presenters reject a hidden source without allocating or invoking a system panel")
    func nativeHiddenGuard() async throws {
        let f = try await BookmarkTransferFixture.make()
        defer { f.cleanup() }
        let panels = BrowserBookmarkPanels()
        let window = try #require(f.controller.window)
        let preview = BrowserBookmarkTransferPreview(links: 1, folders: 1, skipped: 2, profile: "Synthetic", space: "Synthetic")
        #expect(await panels.chooseImport(on: window) == nil)
        #expect(await panels.chooseExport(preview: preview, on: window) == nil)
        #expect(await panels.confirmImport(preview: preview, on: window) == false)
        await panels.failed(on: window)
        panels.cancel()
        f.expectHidden()
    }
}
}
