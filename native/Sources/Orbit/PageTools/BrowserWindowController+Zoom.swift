import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Page zoom commands and the zoom indicator. The per-site policy belongs to the engine adapter.
/// The zoomed page is `pageCommandSurface()`: the selected tab, or a Peek document with focus.
extension BrowserWindowController {
    func changePageZoom(_ command: BrowserPageZoomCommand) {
        guard acceptsCommands else { return }
        session.performWindowAction { [weak self] in
            guard let self, let surface = pageCommandSurface() else { return }
            surface.performZoom(command)
            refreshPageZoom()
        }
    }

    func refreshPageZoom() {
        zoomOwner = pageCommandSurface()
        zoomDocumentGeneration = zoomOwner?.findDocumentGeneration ?? 0
        let factor = zoomOwner?.pageZoom ?? 1
        zoomButton.title = uiFormat("%ld%%", Int((factor * 100).rounded()))
        zoomButton.isHidden = abs(factor - 1) < 0.000_001
    }

    func resetPageZoomFromControl() {
        guard let owner = zoomOwner else { return }
        let generation = zoomDocumentGeneration
        submitInput { [weak owner] controller in
            controller.session.performWindowAction { [weak controller, weak owner] in
                guard let controller, let owner, controller.pageCommandSurface() === owner,
                      owner.findDocumentGeneration == generation else { return }
                owner.performZoom(.reset)
                controller.refreshPageZoom()
            }
        }
    }
}
