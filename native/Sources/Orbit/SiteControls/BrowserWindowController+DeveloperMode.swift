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
        developerToolbar.update(url: surface.navigationState.committedURL)
        developerToolbar.onNavigate = { [weak self, weak surface] value in
            guard let self, let surface, session.selectedSurface === surface, acceptsCommands else { return }
            submitAddress(value)
        }
        developerToolbar.onPanel = { [weak self, weak surface] panel in
            guard let self, let surface, session.selectedSurface === surface, acceptsCommands else { return }
            do { try surface.showDeveloperPanel(panel) } catch { session.onError?(error) }
        }
        developerToolbar.onExtensions = { [weak self] in self?.siteControls.show() }
        developerToolbar.onSplit = { [weak self] in self?.submitInput { $0.addSplitFromSelection() } }
        developerToolbar.onExtension = { [weak self, weak surface] id, anchor in
            guard let self, let surface, session.selectedSurface === surface, acceptsCommands else { return }
            do { try engine.extensions?.performAction(extensionID: id, on: surface, anchor: anchor) }
            catch { session.onError?(error) }
        }
        if let host = engine.extensions, let installed = try? host.installedExtensions(in: surface.profileID) {
            developerToolbar.updateExtensions(installed.filter { $0.isEnabled && $0.hasAction && $0.isPinned == true })
        }
        contentCard.setHeader(developerToolbar)
    }
}
