import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class LibraryDownloadTransfer: BrowserDownloadTransfer {
    var actions: [BrowserDownloadAction] = []
    func perform(_ action: BrowserDownloadAction, completion: @escaping @MainActor (Result<Void, BrowserDownloadError>) -> Void) {
        actions.append(action); completion(.success(()))
    }
    func invalidate() { }
}

extension NativeWebKitTests {
@Suite("Library model and hidden integration", .serialized)
@MainActor
struct NativeLibraryTests {
    private func fixture() async throws -> (BrowserWindowController<SiteSyntheticEngine>, ProfileID, ProfileID, SpaceID) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let a = await store.createProfile(name: "Synthetic A")
        let b = await store.createProfile(name: "Synthetic B")
        let space = try await store.createSpace(name: "A", profileID: a)
        let other = try await store.createSpace(name: "B", profileID: b)
        let window = try await store.createWindow(activeSpaceID: space)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: space,
            engine: SiteSyntheticEngine(), restoringWindowID: window, onClose: {}, onActivate: {})
        await controller.session.waitForPendingCommands()
        return (controller, a, b, other)
    }

    @Test("Footer and category routes share a single Library, leave the window hidden and return to the page")
    func categoryRouting() async throws {
        let (controller, a, _, _) = try await fixture()
        defer { controller.session.close(); controller.window?.close() }
        controller.sidebar.onShowLibrary?()
        await controller.session.waitForPendingCommands()
        #expect(controller.library.isPresented)
        #expect(controller.library.category == .downloads)
        #expect(controller.downloadsProfileID == a)
        #expect(!controller.contentCard.isHidden)
        controller.showArchive()
        await controller.session.waitForPendingCommands()
        await controller.archive.task?.value
        #expect(controller.library.category == .archive)
        #expect(controller.archive.isPresented)
        #expect(controller.downloadsProfileID == nil)
        #expect(controller.archive.view.superview === controller.library.view.body)
        controller.library.view.onCategory?(.history)
        await controller.session.waitForPendingCommands()
        await controller.library.history.task?.value
        #expect(controller.library.category == .history)
        #expect(!controller.archive.isPresented)
        #expect(controller.library.history.profileID == a)
        controller.library.view.onBack?()
        await controller.session.waitForPendingCommands()
        #expect(!controller.library.isPresented)
        #expect(!controller.contentCard.isHidden)
        #expect(controller.library.history.visits.isEmpty)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Downloads and history follow the active Space profile and discard old search and selection")
    func profileSwitching() async throws {
        let (controller, a, b, other) = try await fixture()
        defer { controller.session.close(); controller.window?.close() }
        controller.showDownloads()
        await controller.session.waitForPendingCommands()
        controller.downloadsPane.searchField.stringValue = "Synthetic A filter"
        controller.session.activateSpace(other)
        await controller.session.waitForPendingCommands()
        #expect(controller.downloadsProfileID == b)
        #expect(controller.library.displayedProfileID == b)
        #expect(controller.downloadsPane.query.isEmpty)
        controller.showLibrary(.history)
        await controller.session.waitForPendingCommands()
        await controller.library.history.task?.value
        #expect(controller.library.history.profileID == b)
        #expect(!(await controller.library.history.delete(.all, in: a)))
        #expect(controller.library.historyView.selectedVisit == nil)
        #expect(!controller.library.historyView.isHidden)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Production commands route Library, History, Downloads and Archive without duplicate handlers")
    func registryRouting() async throws {
        let (controller, _, _, _) = try await fixture()
        let router = BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>(
            create: { _ in controller }, present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        _ = router.newWindow()
        await router.waitForPendingCommands()
        for (command, category) in [(BrowserCommandID.viewHistory, BrowserLibraryCategory.history), (.viewDownloads, .downloads), (.viewArchive, .archive), (.viewLibrary, .archive)] {
            #expect(registry.dispatch(command, origin: .keyboard))
            await controller.session.waitForPendingCommands()
            #expect(controller.library.category == category)
        }
        #expect(OrbitCommandCatalog.declarations.first { $0.command == .viewHistory }?.key == "y")
        #expect(BrowserLibraryCategory.allCases.count == 6)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Downloads UI dispatches capability-based controls and refuses stale or cross-profile file drags")
    func downloadsControlsAndDrag() async throws {
        let (controller, a, _, otherSpace) = try await fixture()
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-library-drag-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { controller.downloads.shutdown(); controller.session.close(); controller.window?.close(); try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.txt")
        try Data("Synthetic".utf8).write(to: file)
        let transfer = LibraryDownloadTransfer()
        let registration = try controller.downloads.coordinator.register(owner: .init(profileID: a), transfer: transfer, suggestedFilename: "synthetic.txt")
        registration.report(.init(key: registration.key, sequence: 1, state: .running, receivedBytes: 4, totalBytes: 9, capabilities: [.pause, .cancel]))
        controller.showDownloads(); await controller.session.waitForPendingCommands()
        #expect(controller.downloadsPane.list.displayedTitles == ["synthetic.txt"])
        let running = try #require(controller.downloads.coordinator.snapshot(for: registration.key))
        #expect(controller.downloads.dragFileURL(in: running.context) == nil)
        controller.downloadsPane.list.onAction?(running.key.id, running.key.lifetime, running.revision, .pause)
        #expect(transfer.actions == [.pause])
        registration.report(.init(key: registration.key, sequence: 2, state: .paused, receivedBytes: 4, totalBytes: 9, capabilities: [.resume, .cancel]))
        let paused = try #require(controller.downloads.coordinator.snapshot(for: registration.key))
        controller.downloadsPane.list.onAction?(paused.key.id, paused.key.lifetime, paused.revision, .resume)
        #expect(transfer.actions == [.pause, .resume])
        registration.report(.init(key: registration.key, sequence: 3, state: .complete, receivedBytes: 9, totalBytes: 9, destinationURL: file))
        let complete = try #require(controller.downloads.coordinator.snapshot(for: registration.key))
        #expect(controller.downloads.dragFileURL(in: running.context) == nil)
        #expect(controller.downloadsPane.list.onDragFile?(complete.key.id, complete.key.lifetime, complete.revision) == file)
        controller.session.activateSpace(otherSpace); await controller.session.waitForPendingCommands()
        #expect(controller.downloadsPane.list.displayedTitles.isEmpty)
        #expect(controller.downloadsPane.list.onDragFile?(complete.key.id, complete.key.lifetime, complete.revision) == nil)
        try FileManager.default.removeItem(at: file)
        #expect(controller.downloads.dragFileURL(in: complete.context) == nil)
        #expect(controller.window?.isVisible == false)
    }

    @Test("History keyboard search moves to visits and Return, Delete and Escape dispatch accessible actions")
    func keyboardActions() async throws {
        let (model, recorder, a, _, root) = try historyFixture()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let visit = BrowserHistoryVisit(url: URL(string: "https://library.test/keyboard")!, title: "Synthetic")
        _ = try await recorder.importDocument(.init(profileID: a, visits: [visit]))
        model.selectProfile(a); await model.task?.value
        let view = BrowserLibraryHistoryView(); view.render(model, profileName: "Synthetic")
        #expect(view.control(view.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(view.selectedVisit?.id == visit.id)
        var opened = 0; var deleted = 0; var closed = 0
        view.onOpen = { _ in opened += 1 }; view.onDelete = { _ in deleted += 1 }; view.onBack = { closed += 1 }
        for code: UInt16 in [36, 51, 53] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            view.table.keyDown(with: event)
        }
        #expect(opened == 1); #expect(deleted == 1); #expect(closed == 1)
        #expect(view.searchField.accessibilityIdentifier() == "library-history-search")
        try await recorder.close()
    }

    @Test("Date range confirmations reject reversed and empty ranges before enabling deletion")
    func rangeValidation() {
        let view = BrowserLibraryDateRangeView(now: Date(timeIntervalSince1970: 1_800_000_000))
        let confirm = NSButton(); view.confirmButton = confirm
        view.validateInterval()
        #expect(view.interval != nil); #expect(confirm.isEnabled)
        view.start.dateValue = view.end.dateValue
        view.validateInterval()
        #expect(view.interval == nil); #expect(!confirm.isEnabled)
        view.start.dateValue = view.end.dateValue.addingTimeInterval(60)
        view.validateInterval()
        #expect(view.interval == nil); #expect(!confirm.isEnabled)
        view.start.dateValue = view.end.dateValue.addingTimeInterval(-60)
        view.validateInterval()
        #expect(view.interval?.duration == 60); #expect(confirm.isEnabled)
    }

    private func historyFixture() throws -> (BrowserLibraryHistoryModel, BrowserHistoryRecorder, ProfileID, ProfileID, URL) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-library-\(UUID())", isDirectory: true)
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: { BrowserEngineProfile(profileID: $0, persistence: .persistent) })
        let model = BrowserLibraryHistoryModel(); model.recorder = recorder
        return (model, recorder, ProfileID(), ProfileID(), root)
    }

    @Test("History UI model deletes a visit, exact site and half-open date range only in the selected profile")
    func historyDeletion() async throws {
        let (model, recorder, a, b, root) = try historyFixture()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let visits = [
            BrowserHistoryVisit(url: URL(string: "https://library.test/one")!, title: "One", visitedAt: now),
            BrowserHistoryVisit(url: URL(string: "https://library.test/two")!, title: "Two", visitedAt: now.addingTimeInterval(-10)),
            BrowserHistoryVisit(url: URL(string: "https://sub.library.test/three")!, title: "Three", visitedAt: now.addingTimeInterval(-20)),
            BrowserHistoryVisit(url: URL(string: "https://other.test/four")!, title: "Four", visitedAt: now.addingTimeInterval(-30))
        ]
        _ = try await recorder.importDocument(.init(profileID: a, visits: visits))
        _ = try await recorder.importDocument(.init(profileID: b, visits: visits))
        model.selectProfile(a); await model.task?.value
        #expect(model.visits.count == 4)
        #expect(await model.delete(.visit(visits[0].id), in: a))
        #expect(model.visits.count == 3)
        #expect(await model.delete(.site("library.test"), in: a))
        #expect(Set(model.visits.map(\.id)) == [visits[2].id, visits[3].id])
        #expect(await model.delete(.interval(.init(start: now.addingTimeInterval(-30), end: now.addingTimeInterval(-20))), in: a))
        #expect(model.visits.map(\.id) == [visits[2].id])
        #expect(try await recorder.visits(for: b).count == 4)
        model.selectProfile(b)
        #expect(model.visits.isEmpty)
        #expect(!model.hasMore)
        #expect(!(await model.delete(.all, in: a)))
        await model.task?.value
        #expect(model.visits.count == 4)
        try await recorder.close()
    }

    @Test("History pages merge day headings and Unicode search, while a superseded query cannot repopulate old rows")
    func historyPaginationAndSearch() async throws {
        let (model, recorder, a, b, root) = try historyFixture()
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let visits = (0..<205).map { index in
            BrowserHistoryVisit(url: URL(string: "https://library.test/\(index)")!, title: index == 0 ? "Café" : "Synthetic", visitedAt: now.addingTimeInterval(-Double(index)))
        }
        _ = try await recorder.importDocument(.init(profileID: a, visits: visits))
        model.selectProfile(a); await model.task?.value
        #expect(model.visits.count == 200); #expect(model.hasMore)
        model.loadMore(); await model.task?.value
        #expect(model.visits.count == 205); #expect(!model.hasMore)
        let view = BrowserLibraryHistoryView(); view.render(model, profileName: "Synthetic")
        let expectedDays = Set(visits.map { Calendar.current.startOfDay(for: $0.visitedAt) }).count
        #expect(view.rows.count == 205 + expectedDays)
        model.search("cafe"); await model.task?.value
        #expect(model.visits.map(\.id) == [visits[0].id])
        model.search("Synthetic")
        model.selectProfile(b)
        #expect(model.visits.isEmpty)
        await model.task?.value
        #expect(model.visits.isEmpty); #expect(model.query.isEmpty)
        #expect(!model.hasError)
        model.stop()
        #expect(model.profileID == nil)
        try await recorder.close()
    }
}
}
