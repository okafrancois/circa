import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Injectable I/O retains the same off-main production implementation in tests.
struct BrowserBookmarkFileOperations: Sendable {
    var read: @Sendable (URL) async throws -> BrowserBookmarkDocument = { url in
        try await Task.detached { try BrowserBookmarkFile.read(selection: .init(explicitPanelURL: url, forExport: false)) }.value
    }
    var write: @Sendable (BrowserBookmarkDocument, URL) async throws -> Void = { document, url in
        try await Task.detached { try BrowserBookmarkFile.write(document, selection: .init(explicitPanelURL: url, forExport: true)) }.value
    }
}

@MainActor
final class BrowserBookmarkTransferController<Engine: BrowserEngine> {
    enum Outcome: Equatable { case imported(Int), exported(Int), cancelled, failed }
    private weak var owner: BrowserWindowController<Engine>?
    private let panels: any BrowserBookmarkPanelPresenting
    private let files: BrowserBookmarkFileOperations
    private var task: Task<Void, Never>?
    private var captured: BrowserContext?
    private var admission: BrowserBookmarkImportAdmission?
    private(set) var lastOutcome: Outcome?
    var isBusy: Bool { task != nil }

    init(owner: BrowserWindowController<Engine>, panels: any BrowserBookmarkPanelPresenting = BrowserBookmarkPanels(),
         files: BrowserBookmarkFileOperations = .init()) {
        self.owner = owner
        self.panels = panels
        self.files = files
    }

    private var labels: BrowserBookmarkLabels {
        .init(favorites: uiText("Favorites"), split: uiText("Split View"), untitled: uiText("Untitled"))
    }

    private func current(_ owner: BrowserWindowController<Engine>, _ context: BrowserContext) -> Bool {
        !owner.session.isClosed && owner.acceptsCommands && !owner.isPreparingForTermination
            && owner.session.paletteContext == context
    }

    private func preview(_ document: BrowserBookmarkDocument, owner: BrowserWindowController<Engine>,
                         context: BrowserContext) -> BrowserBookmarkTransferPreview? {
        guard let catalog = owner.session.catalog,
              let profile = catalog.profiles.first(where: { $0.id == context.profileID }),
              let space = catalog.spaces.first(where: { $0.id == context.spaceID && $0.profileID == context.profileID }) else { return nil }
        return .init(links: document.linkCount, folders: document.folderCount, skipped: document.skippedLinkCount,
                     profile: profile.name, space: space.name)
    }

    func contextDidChange() {
        guard let owner, let captured, admission?.state != .admitted else { return }
        if !current(owner, captured) { cancel() }
    }

    func cancel() {
        admission?.revoke()
        task?.cancel()
        panels.cancel()
    }

    @discardableResult
    func startImport() -> Task<Void, Never>? { start(importing: true) }

    @discardableResult
    func startExport() -> Task<Void, Never>? { start(importing: false) }

    private func start(importing: Bool) -> Task<Void, Never>? {
        guard task == nil, let owner, owner.acceptsCommands, !owner.isPreparingForTermination,
              !owner.session.isClosed, owner.window != nil else { return nil }
        lastOutcome = nil
        let contextTask = owner.session.captureContextInCommandOrder()
        let gate = BrowserBookmarkImportAdmission()
        admission = gate
        guard let cancellation = owner.session.registerBookmarkTransferCancellation({ [weak self] in self?.cancel() }) else {
            gate.revoke(); admission = nil
            return nil
        }
        let sourceSession = owner.session
        let operation = Task { @MainActor [weak self, weak owner] in
            defer { sourceSession?.removeBookmarkTransferCancellation(cancellation); gate.revoke() }
            guard let self else { return }
            defer {
                if lastOutcome == nil { lastOutcome = .cancelled }
                captured = nil; admission = nil; task = nil
            }
            guard let owner, let context = await contextTask.value, let window = owner.window,
                  !Task.isCancelled, current(owner, context) else { return }
            captured = context
            var exportAccepted = false
            do {
                if importing {
                    guard let url = await panels.chooseImport(on: window), !Task.isCancelled, current(owner, context) else { return }
                    let document = try await files.read(url)
                    guard !Task.isCancelled, current(owner, context),
                          let preview = preview(document, owner: owner, context: context),
                          await panels.confirmImport(preview: preview, on: window),
                          !Task.isCancelled, current(owner, context) else { return }
                    let committed = await owner.session.importBookmarks(document, title: uiText("Imported Bookmarks"), from: context,
                                                                        labels: labels, admission: gate).value
                    if committed != nil { lastOutcome = .imported(document.linkCount) }
                    else if gate.state == .admitted || (!Task.isCancelled && current(owner, context)) {
                        lastOutcome = .failed
                        if !Task.isCancelled, current(owner, context) { await panels.failed(on: window) }
                    }
                } else {
                    guard let document = await owner.session.exportBookmarks(from: context, labels: labels).value else {
                        if !Task.isCancelled, current(owner, context) {
                            lastOutcome = .failed
                            await panels.failed(on: window)
                        }
                        return
                    }
                    guard !Task.isCancelled, current(owner, context),
                          let preview = preview(document, owner: owner, context: context),
                          let url = await panels.chooseExport(preview: preview, on: window),
                          !Task.isCancelled, current(owner, context) else { return }
                    // The deliberate Save grant is the export acceptance boundary.
                    // Atomic file replacement finishes independently of later UI closure.
                    exportAccepted = true
                    let write = files.write
                    try await owner.session.finishAcceptedBookmarkExport { try await write(document, url) }
                    lastOutcome = .exported(document.linkCount)
                }
            } catch {
                if exportAccepted { lastOutcome = .failed }
                guard !Task.isCancelled, current(owner, context) else { return }
                lastOutcome = .failed
                await panels.failed(on: window)
            }
        }
        task = operation
        return operation
    }
}
