import AppKit
import BrowserCore
import BrowserEngine

extension BrowserWindowController {
    func openLocalFiles(_ urls: [URL], at destination: BrowserOrganizationDestination? = nil) {
        guard acceptsCommands else { return }
        let files = urls.compactMap(LocalFileOpen.validURL)
        hideLibrary()
        let ordered: [URL]
        switch destination?.position {
        case .start, .after: ordered = files.reversed()
        default: ordered = files
        }
        for url in ordered { session.openLocalDocument(url, at: destination) }
    }

    func surface(_ surface: Surface, openDroppedFiles urls: [URL]) -> Bool {
        guard acceptsCommands, owns(surface), let file = urls.compactMap(LocalFileOpen.validURL).first else { return false }
        // The destination is this exact live surface, even if selection changes before delivery.
        submitInput { controller in
            guard controller.owns(surface) else { return }
            controller.session.performWindowAction {
                guard controller.owns(surface) else { return }
                controller.authorizeEnteredFile(file, for: surface)
                surface.navigate(to: file)
                controller.session.updateDestination(for: surface, to: file)
            }
        }
        return true
    }

    func restoreLocalDocumentGrant(for surface: Surface, target: URL) {
        guard owns(surface), let document = session.localDocument(for: surface),
              document.matches(target, profileID: surface.profileID) else { return }
        BrowserNavigationPolicy.authorizeLocalDocument(target, for: surface)
    }

    /// Native text acceptance is an explicit user choice, unlike an engine navigation callback.
    func authorizeEnteredFile(_ url: URL, for surface: Surface) {
        guard let file = LocalFileOpen.validURL(url) else { return }
        session.recordUserOpenedLocalDocument(file, for: surface)
        BrowserNavigationPolicy.authorizeLocalDocument(file, for: surface)
    }
}
