import AppKit
import BrowserEngine
import BrowserShell

extension BrowserQuickWindowWindowController {
    func installPageTools(in root: NSView) {
        copiedToast.onShare = { [weak self] in
            guard let self, let url = surface?.currentURL else { return }
            shareURL(url)
        }
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        root.addSubview(findBar)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            findBar.widthAnchor.constraint(equalToConstant: 400), findBar.heightAnchor.constraint(equalToConstant: 42),
            findBar.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -16)
        ])
        findSession.onChange = { [weak self] in self?.renderFind() }
        findSession.onFocusReturn = { [weak self] surface in if self?.owns(surface) == true { surface.focusDocument() } }
        findBar.onQueryChange = { [weak self] query, matchCase in
            guard let self, acceptsCommands else { return }
            findSession.submit(query, matchCase: matchCase)
            findBar.acknowledgeOptions(findBar.pendingOptionsRevision)
        }
        findBar.onNext = { [weak self] in self?.findSession.next() }
        findBar.onPrevious = { [weak self] in self?.findSession.previous() }
        findBar.onClose = { [weak self] in self?.findSession.close() }
    }

    func showFind() {
        guard acceptsCommands, let surface, container.owns(surface) else { return }
        findSession.show(on: surface)
        findBar.focusQuery()
    }

    func renderFind() {
        guard let state = findSession.state else { findBar.isHidden = true; return }
        findBar.isHidden = !state.isVisible
        let status: String
        if state.isPending { status = uiText("Searching…") }
        else if state.error != nil { status = uiText("Find Unavailable") }
        else if let count = state.count { status = uiFormat("%ld results", count) }
        else if let found = state.matchFound { status = found ? uiText("Found") : uiText("No Results") }
        else { status = "" }
        findBar.render(query: state.query, matchCase: state.matchCase, status: status,
                       searching: state.isPending, canNavigate: !state.query.isEmpty && state.error == nil)
    }

    var canPrint: Bool { engine.capabilities.contains(.printing) && engine is any BrowserPagePrinting<Surface> }
    func printPage() {
        guard acceptsCommands, let surface, owns(surface), let service = engine as? any BrowserPagePrinting<Surface> else { return }
        do { try service.printPage(surface) } catch { NSSound.beep() }
    }

    func copyURL() {
        guard copyCurrentURL() else { return }
        if let view = window?.contentView { copiedToast.show(in: view) }
    }

    @discardableResult
    func copyCurrentURL() -> Bool {
        guard acceptsCommands, let surface, !surface.isDisposed, owns(surface),
              let url = surface.currentURL else { return false }
        copyURLWriter(url)
        return true
    }

    func shareURL(_ url: URL) {
        guard acceptsCommands, let view = window?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        sharingPicker = picker
        picker.show(relativeTo: NSRect(x: view.bounds.maxX - 44, y: view.bounds.maxY - 40, width: 24, height: 24),
                    of: view, preferredEdge: .minY)
    }
}
