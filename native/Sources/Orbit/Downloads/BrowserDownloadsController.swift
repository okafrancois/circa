import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation

/// Application-wide download list and destination UI. Engine-independent: transfers come from
/// `BrowserEngineDownload` adapters and outlive their source tabs and windows.
@MainActor
final class BrowserDownloadsController {
    typealias DestinationProvider = @MainActor (BrowserDownloadOwner, String) async -> URL?
    let coordinator = BrowserDownloadCoordinator()
    var destinationProvider: DestinationProvider?
    var preferencesProvider: @MainActor () -> BrowserDownloadPreferences = { .init() }
    struct SaveRequest {
        let filename: String
        let directory: URL
        let explanation: String?
    }
    var saveSheetProvider: (@MainActor (SaveRequest) async -> URL?)?
    var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var revealFile: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    private var deltaObservers: [UUID: (BrowserDownloadCoordinator.Delta) -> Void] = [:]
    private var observers: [UUID: () -> Void] = [:]
    private var transfers: [UUID: any BrowserEngineDownloadTransfer] = [:]
    private var pickers: [UUID: DownloadDestinationPicker] = [:]

    private var history: BrowserDownloadHistoryStore?
    var onHistoryError: ((any Error) -> Void)?

    init(history: BrowserDownloadHistoryStore? = nil) {
        self.history = history
        if let history {
            profiles = Set(history.records.map(\.profileID))
            try? coordinator.restore(history.records)
        }
        coordinator.onDelta = { [weak self] in self?.publish($0) }
    }

    func observe(_ id: UUID, _ callback: @escaping () -> Void) { observers[id] = callback }
    func observeChanges(_ id: UUID, _ callback: @escaping (BrowserDownloadCoordinator.Delta) -> Void) { deltaObservers[id] = callback }
    func stopObserving(_ id: UUID) { observers.removeValue(forKey: id); deltaObservers.removeValue(forKey: id) }

    private func publish(_ delta: BrowserDownloadCoordinator.Delta) {
        for key in delta.removed { fileChecks[key] = nil }
        for item in delta.changed where fileChecks[item.key]?.url != item.destinationURL || item.state != .complete {
            fileChecks[item.key] = nil
        }
        if let history, delta.historyChanged {
            let records = coordinator.allSnapshots.filter { $0.state.isTerminal }.map(BrowserDownloadHistoryRecord.init)
            do { try history.save(records) } catch { onHistoryError?(error) }
        }
        for callback in Array(deltaObservers.values) { callback(delta) }
        for callback in Array(observers.values) { callback() }
        if delta.historyChanged { refreshFiles(delta.changed) }
    }

    @discardableResult
    func adopt(_ download: any BrowserEngineDownload, owner: BrowserDownloadOwner,
               sourceWindow: NSWindow?) -> BrowserDownloadKey? {
        profiles.insert(owner.profileID)
        let id = UUID()
        let transfer = download.makeTransfer { [weak self, weak sourceWindow] filename in
            guard let self, !coordinator.isClosed else { return nil }
            if let destinationProvider { return await destinationProvider(owner, filename) }
            return await chooseDestination(filename: filename, sourceWindow: sourceWindow, id: id)
        }
        do {
            let registration = try coordinator.register(owner: owner, transfer: transfer,
                suggestedFilename: BrowserDownloadPaths.suggestedFilename(download.suggestedFilename),
                sourceURL: download.sourceURL, id: id)
            transfers[id] = transfer
            transfer.onInvalidate = { [weak self] in
                self?.pickers[id]?.cancel()
                self?.transfers.removeValue(forKey: id)
            }
            transfer.attach(registration)
            return registration.key
        } catch {
            download.cancel()
            transfer.invalidate()
            return nil
        }
    }

    func chooseDestination(filename: String, sourceWindow: NSWindow?, id: UUID = UUID()) async -> URL? {
        let preferences = preferencesProvider()
        let folder = preferences.folderURL
        let destination = await Task.detached(priority: .utility) {
            BrowserDownloadPaths.uniqueDestination(filename: filename, in: folder)
        }.value
        guard !Task.isCancelled, !coordinator.isClosed else { return nil }
        if !preferences.asksWhereToSave, let destination { return destination }
        let request = SaveRequest(filename: BrowserDownloadPaths.suggestedFilename(filename), directory: folder,
            explanation: destination != nil ? nil :
                uiText("Orbit can’t save to the download folder. It may be missing or not writable. Choose another location."))
        if let saveSheetProvider { return await saveSheetProvider(request) }
        guard let sourceWindow, sourceWindow.isVisible, !coordinator.isClosed else { return nil }
        let picker = DownloadDestinationPicker()
        pickers[id] = picker
        defer { pickers.removeValue(forKey: id) }
        return await picker.choose(request: request, window: sourceWindow)
    }

    /// Completes the provisional owner of a download started while its source tab was being
    /// recorded (see `BrowserDownloadCoordinator.attributeSource`).
    func attributeSource(_ key: BrowserDownloadKey, windowID: WindowID, occurrenceID: TabOccurrenceID) {
        coordinator.attributeSource(key, windowID: windowID, occurrenceID: occurrenceID)
    }

    func clearProvisionalSourceWindow(_ key: BrowserDownloadKey) {
        coordinator.clearProvisionalSourceWindow(key)
    }

    func sourceWindowClosed(_ id: WindowID?) {
        guard let id else { return }
        // Only a pending destination sheet belongs to the source window. Active transfers survive.
        for (key, picker) in Array(pickers) {
            if let transfer = transfers[key], let snapshot = snapshot(for: transfer), snapshot.owner.sourceWindowID == id {
                picker.cancel()
            }
        }
    }

    private func snapshot(for transfer: any BrowserEngineDownloadTransfer) -> BrowserDownloadSnapshot? {
        guard let pair = transfers.first(where: { $0.value === transfer }) else { return nil }
        return knownSnapshots.first { $0.key.id == pair.key }
    }

    private var profiles: Set<ProfileID> = []
    private var knownSnapshots: [BrowserDownloadSnapshot] { profiles.flatMap { coordinator.snapshots(profileID: $0) } }

    private struct FileCheck {
        let url: URL?
        let token: UUID
        var checkedAt: TimeInterval?
    }
    private var fileChecks: [BrowserDownloadKey: FileCheck] = [:]
    private var fileCheckTask: Task<Void, Never>?
    private var fileWatchers: [URL: DownloadDirectoryWatcher] = [:]
    var fileCheck: @Sendable (URL) -> Bool = { BrowserDownloadPaths.regularFileSize($0) != nil }
    var fileCheckNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    func snapshots(profileID: ProfileID) -> [BrowserDownloadSnapshot] {
        profiles.insert(profileID)
        let items = coordinator.snapshots(profileID: profileID)
        refreshFiles(items)
        return items
    }

    /// Explicit invalidation is also used when a completed destination is moved or deleted.
    func invalidateFileChecks(in directory: URL) {
        for (key, value) in Array(fileChecks) where value.url?.deletingLastPathComponent() == directory {
            fileChecks[key] = nil
        }
        refreshFiles(coordinator.allSnapshots)
    }

    private func refreshFiles(_ items: [BrowserDownloadSnapshot]) {
        guard !coordinator.isClosed, fileCheckTask == nil else { return }
        let now = fileCheckNow()
        let pending = items.filter { item in
            guard item.state == .complete else { return false }
            guard let check = fileChecks[item.key], check.url == item.destinationURL,
                  let checkedAt = check.checkedAt else { return true }
            return now - checkedAt >= 2
        }
        guard !pending.isEmpty else { return }
        var tokens: [BrowserDownloadKey: UUID] = [:]
        for item in pending {
            let token = UUID()
            tokens[item.key] = token
            fileChecks[item.key] = FileCheck(url: item.destinationURL, token: token)
        }
        let check = fileCheck
        let directories = Set(pending.compactMap { $0.destinationURL?.deletingLastPathComponent() }).subtracting(fileWatchers.keys)
        fileCheckTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                let watchers = directories.compactMap { DownloadDirectoryWatcher(directory: $0) }
                let results = pending.map { ($0, $0.destinationURL.map(check) == true) }
                return (results, watchers)
            }
            let (results, watchers) = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, !coordinator.isClosed else { return }
            fileCheckTask = nil
            for watcher in watchers {
                fileWatchers[watcher.directory] = watcher
                watcher.start { [weak self] directory in
                    Task { @MainActor in self?.invalidateFileChecks(in: directory) }
                }
            }
            var changes: [(BrowserDownloadContext, BrowserDownloadFileAvailability)] = []
            for (original, available) in results {
                guard fileChecks[original.key]?.token == tokens[original.key],
                      let current = coordinator.snapshot(for: original.key), current.state == .complete,
                      current.destinationURL == original.destinationURL else { continue }
                fileChecks[original.key]?.checkedAt = fileCheckNow()
                let value: BrowserDownloadFileAvailability = available ? .available : .missing
                if current.fileAvailability != value { changes.append((current.context, value)) }
            }
            coordinator.setFileAvailabilities(changes)
            // A directory event or a completion may have invalidated an item while IO was pending.
            refreshFiles(coordinator.allSnapshots)
        }
    }

    var hasActiveTransfers: Bool {
        !transfers.isEmpty
    }

    func perform(_ action: DownloadRowPresentation.Action, in context: BrowserDownloadContext) {
        guard let context = coordinator.currentActionContext(context),
              let snapshot = coordinator.snapshot(for: context.key), snapshot.context == context else { return }
        switch action {
        case .cancel, .pause, .resume:
            let command: BrowserDownloadAction = action == .cancel ? .cancel : action == .pause ? .pause : .resume
            try? coordinator.perform(command, in: context)
        case .remove:
            try? coordinator.remove(in: context)
        case .open, .reveal:
            guard snapshot.state == .complete, let url = snapshot.destinationURL else { return }
            Task { [weak self] in
                let available = await Task.detached { BrowserDownloadPaths.regularFileSize(url) != nil }.value
                // A background availability batch may finish during this action's own file
                // validation. Terminal identity/owner/path must stay exact; metadata alone can
                // advance the revision, so publish against the freshly validated context.
                guard let self, !coordinator.isClosed, let current = coordinator.snapshot(for: context.key),
                      current.state == .complete, current.owner == snapshot.owner,
                      current.destinationURL == url else { return }
                fileChecks[context.key] = nil
                let availability: BrowserDownloadFileAvailability = available ? .available : .missing
                guard current.revision < .max else { return }
                let expectedRevision = current.revision + 1
                do { try coordinator.setFileAvailability(availability, in: current.context) }
                catch { return }
                guard available, !coordinator.isClosed, let refreshed = coordinator.snapshot(for: context.key),
                      refreshed.revision == expectedRevision, refreshed.state == .complete,
                      refreshed.fileAvailability == .available, refreshed.destinationURL == url else { return }
                if action == .open { openFile(url) }
                else { revealFile(url) }
            }
        }
    }

    /// A drag exports only a completed, still-current local file. No URL replay or transfer data
    /// is written to the pasteboard. The caller additionally validates the active profile.
    func dragFileURL(in context: BrowserDownloadContext) -> URL? {
        guard !coordinator.isClosed, let snapshot = coordinator.snapshot(for: context.key),
              snapshot.context == context, snapshot.state == .complete,
              let url = snapshot.destinationURL, url.isFileURL,
              BrowserDownloadPaths.regularFileSize(url) != nil,
              coordinator.snapshot(for: context.key)?.context == context else { return nil }
        return url
    }

    func shutdown() {
        fileCheckTask?.cancel()
        fileCheckTask = nil
        fileChecks.removeAll()
        fileWatchers.removeAll()
        coordinator.shutdown()
        for picker in Array(pickers.values) { picker.cancel() }
        pickers.removeAll()
        transfers.removeAll()
        observers.removeAll()
        deltaObservers.removeAll()
    }
}

@MainActor
private final class DownloadDestinationPicker: NSObject, NSOpenSavePanelDelegate {
    private var panel: NSSavePanel?

    func choose(request: BrowserDownloadsController.SaveRequest, window: NSWindow) async -> URL? {
        let panel = NSSavePanel()
        panel.title = uiText("Save Download")
        panel.nameFieldStringValue = request.filename
        panel.directoryURL = request.directory
        if let explanation = request.explanation { panel.message = explanation }
        panel.canCreateDirectories = true
        panel.delegate = self
        self.panel = panel
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { [weak self] result in
                self?.panel = nil
                continuation.resume(returning: result == .OK ? panel.url : nil)
            }
        }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard BrowserDownloadPaths.isValidDestination(url) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                          userInfo: [NSLocalizedDescriptionKey: uiText("Choose an available name in a folder you can access.")])
        }
    }

    func cancel() { panel?.cancel(nil) }
}

/// The descriptor is opened on the utility worker; directory changes revoke cached existence.
private final class DownloadDirectoryWatcher: @unchecked Sendable {
    let directory: URL
    private let source: DispatchSourceFileSystemObject
    init?(directory: URL) {
        let fd = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        self.directory = directory
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .revoke], queue: .global(qos: .utility))
        source.setCancelHandler { close(fd) }
        source.activate()
    }
    func start(_ callback: @escaping @Sendable (URL) -> Void) {
        let directory = directory
        source.setEventHandler { callback(directory) }
    }
    deinit { source.cancel() }
}
