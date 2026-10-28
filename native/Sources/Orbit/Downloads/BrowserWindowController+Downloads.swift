import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Downloads embedded in the Library; transfers remain application-owned.
extension BrowserWindowController {
    func installDownloadsPane(in root: NSView) {
        downloadsPane.setLibraryEmbedded()
        downloadsPane.translatesAutoresizingMaskIntoConstraints = false
        downloadsPane.isHidden = true
        root.addSubview(downloadsPane)
        NSLayoutConstraint.activate([
            downloadsPane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            downloadsPane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            downloadsPane.topAnchor.constraint(equalTo: root.topAnchor),
            downloadsPane.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        downloadsPane.onBack = { [weak self] in
            self?.submitInput { controller in controller.session.performWindowAction { [weak controller] in controller?.hideLibrary() } }
        }
        downloadsPane.list.onDragFile = { [weak self] id, lifetime, revision in
            guard let self, library.isPresented, library.category == .downloads,
                  let profile = downloadsProfileID, session.activeProfileID == profile else { return nil }
            return downloads.dragFileURL(in: BrowserDownloadContext(
                key: BrowserDownloadKey(id: id, profileID: profile, lifetime: lifetime), revision: revision))
        }
        downloadsPane.onSearch = { [weak self] in self?.renderDownloads() }
        downloadsPane.list.onAction = { [weak self] id, lifetime, revision, action in
            guard let self, acceptsCommands, library.isPresented, library.category == .downloads,
                  let profile = downloadsProfileID, session.activeProfileID == profile else { return }
            downloads.perform(action, in: BrowserDownloadContext(
                key: BrowserDownloadKey(id: id, profileID: profile, lifetime: lifetime), revision: revision))
        }
    }

    func showDownloads() { showLibrary(.downloads) }

    func hideDownloads() {
        guard downloadsProfileID != nil || !downloadsPane.isHidden else { return }
        downloadsProfileID = nil
        downloadsPane.isHidden = true
        downloadsPane.list.render([])
    }

    func renderDownloads() {
        guard let profile = downloadsProfileID else { return }
        guard session.activeProfileID == profile else { downloadsPane.list.render([]); return }
        downloadsPane.setProfileName(session.catalog?.profiles.first { $0.id == profile }?.name ?? "")
        let query = downloadsPane.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = downloads.snapshots(profileID: profile).filter {
            query.isEmpty || ($0.destinationURL?.lastPathComponent ?? $0.suggestedFilename).localizedCaseInsensitiveContains(query)
        }.map { item -> DownloadRowPresentation in
            let detail: String
            switch item.state {
            case .awaitingDestination: detail = uiText("Choose a Destination…")
            case .running:
                let received = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
                detail = item.totalBytes.map { uiFormat("%@ of %@", received, ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) } ?? received
            case .paused: detail = uiText("Paused")
            case .interrupted: detail = uiText("Interrupted")
            case .complete:
                let size = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
                let status = item.fileAvailability == .missing ? uiText("Complete · File Unavailable") : uiText("Complete")
                detail = uiFormat("%@ · %@", status, size)
            case .cancelled: detail = uiText("Canceled")
            case .failed: detail = item.failure == .destinationUnavailable ? uiText("Destination Unavailable") : uiText("Download Failed")
            }
            var actions: [DownloadRowPresentation.Action] = []
            if item.canPerform(.pause) { actions.append(.pause) }
            if item.canPerform(.resume) { actions.append(.resume) }
            if item.canPerform(.cancel) { actions.append(.cancel) }
            if item.state == .complete { actions.append(contentsOf: [.open, .reveal]) }
            if item.state.isTerminal { actions.append(.remove) }
            return DownloadRowPresentation(id: item.key.id, lifetime: item.key.lifetime, revision: item.revision,
                title: item.destinationURL?.lastPathComponent ?? item.suggestedFilename, detail: detail,
                receivedBytes: item.receivedBytes, totalBytes: item.totalBytes,
                isRunning: item.state == .running, actions: actions)
        }
        downloadsPane.list.render(rows)
    }
}
