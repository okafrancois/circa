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
    var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var revealFile: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    private var observers: [UUID: () -> Void] = [:]
    private var transfers: [UUID: any BrowserEngineDownloadTransfer] = [:]
    private var pickers: [UUID: DownloadDestinationPicker] = [:]

    init() { coordinator.onChange = { [weak self] in self?.publish() } }

    func observe(_ id: UUID, _ callback: @escaping () -> Void) { observers[id] = callback }
    func stopObserving(_ id: UUID) { observers.removeValue(forKey: id) }

    private func publish() {
        for callback in Array(observers.values) { callback() }
    }

    @discardableResult
    func adopt(_ download: any BrowserEngineDownload, owner: BrowserDownloadOwner,
               sourceWindow: NSWindow?) -> BrowserDownloadKey? {
        profiles.insert(owner.profileID)
        let id = UUID()
        let transfer = download.makeTransfer { [weak self, weak sourceWindow] filename in
            guard let self, !coordinator.isClosed else { return nil }
            if let destinationProvider { return await destinationProvider(owner, filename) }
            guard let sourceWindow, sourceWindow.isVisible else { return nil }
            let picker = DownloadDestinationPicker()
            pickers[id] = picker
            defer { pickers.removeValue(forKey: id) }
            return await picker.choose(filename: filename, window: sourceWindow)
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

    func snapshots(profileID: ProfileID) -> [BrowserDownloadSnapshot] {
        profiles.insert(profileID)
        return coordinator.snapshots(profileID: profileID)
    }

    var hasActiveTransfers: Bool {
        !transfers.isEmpty
    }

    func perform(_ action: DownloadRowPresentation.Action, in context: BrowserDownloadContext) {
        guard let snapshot = coordinator.snapshot(for: context.key), snapshot.context == context else { return }
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
                guard let self, let current = coordinator.snapshot(for: context.key), current.context == context else { return }
                let availability: BrowserDownloadFileAvailability = available ? .available : .missing
                guard context.revision < .max else { return }
                let expectedRevision = context.revision + 1
                do { try coordinator.setFileAvailability(availability, in: context) }
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
        coordinator.shutdown()
        for picker in Array(pickers.values) { picker.cancel() }
        pickers.removeAll()
        transfers.removeAll()
        observers.removeAll()
    }
}

@MainActor
private final class DownloadDestinationPicker: NSObject, NSOpenSavePanelDelegate {
    private var panel: NSSavePanel?

    func choose(filename: String, window: NSWindow) async -> URL? {
        let panel = NSSavePanel()
        panel.title = uiText("Save Download")
        panel.nameFieldStringValue = filename
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
