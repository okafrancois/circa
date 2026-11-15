import AppKit
import BrowserCore
import BrowserEngine

extension BrowserWindowController {
    /// The content card's page-coloured header: the developer toolbar for sites in Developer Mode,
    /// otherwise the optional toolbar when it is shown outside Split View, where panes carry their own.
    func renderPageHeader() {
        guard let surface = session.selectedSurface else { return clearPageHeader() }
        if siteControls.preferences.preferences(url: surface.navigationState.committedURL,
                                                profileID: surface.profileID).developerMode {
            observePageTint(of: surface)
            renderDeveloperToolbar(for: surface)
        } else if isToolbarVisible, session.activeSplit == nil {
            observePageTint(of: surface)
            renderOptionalToolbar(for: surface)
        } else {
            clearPageHeader()
        }
    }

    private func clearPageHeader() {
        pageTintSurface?.setPageTintObservationEnabled(false)
        pageTintSurface = nil
        contentCard.setHeader(nil)
    }

    private func observePageTint(of surface: Surface) {
        guard pageTintSurface !== surface else { return }
        pageTintSurface?.setPageTintObservationEnabled(false)
        pageTintSurface = surface
        surface.setPageTintObservationEnabled(true)
    }

    private func renderDeveloperToolbar(for surface: Surface) {
        developerToolbar.apply(theme: windowShell.theme)
        developerToolbar.updateTint(surface.navigationState.pageTint)
        developerToolbar.update(url: surface.navigationState.committedURL, canCapture: engine.capabilities.contains(.snapshots))
        developerToolbar.onNavigate = { [weak self, weak surface] value in
            guard let self, let surface, session.selectedSurface === surface, acceptsCommands else { return }
            submitAddress(value)
        }
        developerToolbar.onPanel = { [weak self, weak surface] panel in
            guard let self, let surface, session.selectedSurface === surface, acceptsCommands else { return }
            do { try surface.showDeveloperPanel(panel) } catch { session.onError?(error) }
        }
        developerToolbar.onSiteControls = { [weak self] in self?.siteControls.show() }
        developerToolbar.onCapture = { [weak self, weak surface] in
            guard let self, let surface, session.selectedSurface === surface, acceptsCommands else { return }
            capture.begin()
        }
        developerToolbar.onExtensions = { [weak self] in self?.extensionControls.show() }
        developerToolbar.onSplit = { [weak self] in self?.submitInput { $0.addSplitFromSelection() } }
        developerToolbar.onExtension = { [weak self, weak surface] id, anchor in
            guard let self, let surface, session.selectedSurface === surface, acceptsCommands else { return }
            do { try engine.extensions?.performAction(extensionID: id, on: surface, anchor: anchor) }
            catch { session.onError?(error) }
        }
        if developerToolbarProfile != surface.profileID {
            developerToolbar.updateExtensions([])
            developerToolbarProfile = surface.profileID
        }
        contentCard.setHeader(developerToolbar)
    }
}
