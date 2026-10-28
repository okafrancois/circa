import AppKit
import BrowserCore
import BrowserEngine

extension BrowserWindowController {
    func renderDeveloperToolbar() {
        guard let surface = session.selectedSurface,
              siteControls.preferences.preferences(url: surface.navigationState.committedURL,
                                                   profileID: surface.profileID).developerMode else {
            contentCard.setHeader(nil)
            return
        }
        developerToolbar.apply(theme: windowShell.theme)
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
