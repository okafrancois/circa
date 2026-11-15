import AppKit
import BrowserCore
import BrowserEngine

/// View > Show/Hide Toolbar. The toolbar appears and disappears at once, without motion; while it
/// is shown the sidebar drops its history buttons and address row.
extension BrowserWindowController {
    func toggleToolbar() {
        guard acceptsCommands else { return }
        session.performWindowAction { [weak self] in
            guard let self, !isPreparingForTermination else { return }
            let visible = !isToolbarVisible
            guard let runtime = settingsPreferences?.runtime else {
                setToolbarVisible(visible)
                return
            }
            // Publish before anything renders: every window, this one included, re-applies the
            // settings document. Persistence follows; a failed write reverts to the saved choice.
            runtime.publishShowsToolbar(visible)
            setToolbarVisible(visible)
            Task { [weak self] in
                do { try await runtime.setShowsToolbar(visible) }
                catch { self?.session.onError?(error) }
            }
        }
    }

    func setToolbarVisible(_ visible: Bool) {
        guard visible != isToolbarVisible else { return }
        isToolbarVisible = visible
        refreshToolbarPresentation()
    }

    func refreshToolbarPresentation() {
        configureOptionalToolbarIfNeeded()
        sidebar.showsNavigationChrome = !isToolbarVisible
        renderPageHeader()
    }

    func renderOptionalToolbar(for surface: Surface) {
        configureOptionalToolbarIfNeeded()
        let state = surface.navigationState
        optionalToolbar.apply(theme: windowShell.theme)
        // Keep the validated white canvas. Page-colour treatment is a separate visual change;
        // updateTint is the seam for it once its light and dark states have been measured.
        optionalToolbar.updateTint(BrowserPageTint(red: 255, green: 255, blue: 255))
        optionalToolbar.update(url: state.committedURL ?? state.url, canGoBack: state.canGoBack,
                               canGoForward: state.canGoForward)
        contentCard.setHeader(optionalToolbar, height: BrowserOptionalToolbar.height)
    }

    private func configureOptionalToolbarIfNeeded() {
        guard optionalToolbar.onAddress == nil else { return }
        optionalToolbar.onBack = { [weak self] in self?.submitInput { $0.navigateBack() } }
        optionalToolbar.onForward = { [weak self] in self?.submitInput { $0.navigateForward() } }
        optionalToolbar.onReload = { [weak self] in self?.submitInput { $0.reload() } }
        optionalToolbar.onAddress = { [weak self] in self?.submitInput { $0.palette.present(.currentTab) } }
        optionalToolbar.onSiteControls = { [weak self] anchor in
            self?.siteControls.toggle(presentationAnchor: anchor)
        }
        optionalToolbar.onSplit = { [weak self] in self?.submitInput { $0.addSplitFromSelection() } }
    }

    /// The site controls follow the toolbar while it replaces the sidebar address row.
    var optionalToolbarSiteAnchor: NSView? {
        guard isToolbarVisible, contentCard.header === optionalToolbar, optionalToolbar.window != nil else { return nil }
        return optionalToolbar.site
    }
}
