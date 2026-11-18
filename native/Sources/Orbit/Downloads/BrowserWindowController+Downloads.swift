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

    func renderDownloads(delta: BrowserDownloadCoordinator.Delta? = nil) {
        guard let profile = downloadsProfileID else { return }
        guard session.activeProfileID == profile else { downloadsPane.list.render([]); return }
        downloadsPane.setProfileName(session.catalog?.profiles.first { $0.id == profile }?.name ?? "")
        let query = downloadsPane.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let delta, downloadsPane.list.canUpdate(delta, profileID: profile) {
            downloadsPane.list.update(delta.changed.filter { $0.owner.profileID == profile }.map(DownloadRowPresentation.init))
            return
        }
        // Rows are built only for the entries that receive a view.
        let items = downloads.snapshots(profileID: profile)
        downloadsPane.list.render(items.map { DownloadListEntry(id: $0.key.id, lifetime: $0.key.lifetime,
                                                                title: DownloadRowPresentation.title($0), startedAt: $0.startedAt) },
                                  query: query, presentation: { DownloadRowPresentation(items[$0]) })
    }
}

extension DownloadRowPresentation {
    static func title(_ item: BrowserDownloadSnapshot) -> String {
        item.destinationURL?.lastPathComponent ?? item.suggestedFilename
    }

    init(_ item: BrowserDownloadSnapshot) {
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
            let summary = uiFormat("%@ · %@", uiText("Complete"), size)
            detail = item.fileAvailability == .missing ? uiFormat("%@ · %@", summary, uiText("File Unavailable")) : summary
        case .cancelled: detail = uiText("Canceled")
        case .failed: detail = item.failure == .destinationUnavailable ? uiText("Destination Unavailable") : uiText("Download Failed")
        }
        var actions: [Action] = []
        if item.canPerform(.pause) { actions.append(.pause) }
        if item.canPerform(.resume) { actions.append(.resume) }
        if item.canPerform(.cancel) { actions.append(.cancel) }
        if item.state == .complete { actions.append(contentsOf: [.open, .reveal]) }
        if item.state.isTerminal { actions.append(.remove) }
        self.init(id: item.key.id, lifetime: item.key.lifetime, revision: item.revision,
                  title: Self.title(item), detail: detail,
                  receivedBytes: item.receivedBytes, totalBytes: item.totalBytes,
                  isRunning: item.state == .running, actions: actions,
                  fileURL: item.state == .complete && item.fileAvailability == .available ? item.destinationURL : nil,
                  startedAt: item.startedAt)
    }
}


extension BrowserWindowController {
    func installDownloadFeedback() {
        sidebar.downloadHoverTarget.onEnter = { [weak self] in self?.downloadHoverChanged(true) }
        downloadHoverPopover.onDismiss = { [weak self] _ in self?.downloadHoverChanged(false) }
        sidebar.recentDownloads.onAction = { [weak self] context in
            guard let self, acceptsCommands, context.key.profileID == session.activeProfileID,
                  let item = downloads.coordinator.snapshot(for: context.key) else { return }
            if item.state == .complete { downloads.perform(.open, in: context) }
            else { showDownloads() }
        }
    }

    func renderDownloadFeedback() {
        let wasPresented = sidebar.recentDownloads.isPresented
        let profile = downloads.coordinator.isClosed ? nil : session.activeProfileID
        downloadFeedback.update(profile.map { downloads.snapshots(profileID: $0) } ?? [], profileID: profile)
        if library.isPresented || sidebar.isPresentationHidden {
            downloadFeedback.hover(false)
        }
        sidebar.footer.downloadBadge.render(active: downloadFeedback.hasActiveDownloads, completion: downloadFeedback.completionItem)
        sidebar.recentDownloads.render(downloadFeedback.recentItems, presented: downloadFeedback.isPresented)
        sidebar.layoutDownloadHoverTarget()
        sidebar.needsLayout = true
        if wasPresented && !downloadFeedback.isPresented {
            downloadHoverPopover.stop()
            windowShell.hoverHoldDidChange()
        }
    }

    func downloadHoverChanged(_ inside: Bool) {
        if inside {
            guard acceptsCommands, !isPrivateWindow, !library.isPresented, !sidebar.isPresentationHidden,
                  !downloadFeedback.isHovering, !downloadFeedback.items.isEmpty else { return }
            // Showing the list acknowledges the completion badge. Retain its footprint for the
            // current handoff so the pointer can move off the badge even after it disappears.
            let badgeBounds = sidebar.footer.downloadBadge.hoverBounds
            downloadFeedback.hover(true)
            renderDownloadFeedback()
            sidebar.layoutSubtreeIfNeeded()
            downloadHoverPopover.start(trigger: sidebar.downloadHoverTarget, popover: sidebar.recentDownloads) { [weak self] in
                guard let self, let window, let rect = SidebarHoverPopover.visibleRect(of: sidebar.downloadHoverTarget, in: window) else { return nil }
                guard let badgeBounds else { return rect }
                let badge = sidebar.footer.downloadBadge.convert(badgeBounds, to: nil)
                return rect.union(badge).intersection(sidebar.convert(sidebar.visibleRect, to: nil))
            }
            windowShell.hoverHoldDidChange()
        } else if downloadFeedback.isHovering {
            downloadFeedback.hover(false)
            renderDownloadFeedback()
        }
    }

    func stopDownloadFeedback() {
        downloadHoverPopover.stop()
        downloadFeedback.reset()
        sidebar.recentDownloads.render([], presented: false)
    }
}
