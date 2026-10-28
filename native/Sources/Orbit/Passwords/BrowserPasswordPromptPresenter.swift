import AppKit
import BrowserEngine

@MainActor
final class BrowserPasswordPromptPresenter<Engine: BrowserEngine> {
    private weak var owner: BrowserWindowController<Engine>?
    private weak var surface: Engine.Surface?
    let session = BrowserPasswordPromptSession()
    private var overlay: BrowserPasswordPromptView?
    private var retiringOverlay: BrowserPasswordPromptView?

    init(owner: BrowserWindowController<Engine>) {
        self.owner = owner
        session.isCurrent = { [weak self] in
            guard let self, let owner = self.owner, let surface = self.surface else { return false }
            return !surface.isDisposed && owner.acceptsCommands && owner.owns(surface)
                && owner.session.selectedSurface === surface && owner.session.activeProfileID == surface.profileID
                && owner.window?.isKeyWindow == true && !owner.isPrivateWindow
        }
        session.onShow = { [weak self] prompt, decide in self?.show(prompt, decide: decide) }
        session.onHide = { [weak self] animated in self?.hide(animated: animated) }
    }

    func render() {
        guard let owner else { return }
        let next = owner.acceptsCommands && !owner.isPrivateWindow && owner.window?.isKeyWindow == true
            ? owner.session.selectedSurface : nil
        surface = next
        session.select(next?.isReady == true ? next?.passwordPrompts : nil, profileID: next?.profileID)
    }

    func surfaceDidLeave(_ surface: Engine.Surface) {
        if self.surface === surface { close() }
    }

    func close() {
        surface = nil
        session.select(nil, profileID: nil)
        hide(animated: false)
    }

    private func show(_ prompt: BrowserPasswordPrompt, decide: @escaping (BrowserPasswordDecision) -> Void) {
        guard let root = owner?.window?.contentView else { return }
        hide(animated: false)
        retiringOverlay?.removeFromSuperview()
        retiringOverlay = nil
        let overlay = BrowserPasswordPromptView(prompt: prompt, decide: decide)
        overlay.frame = root.bounds
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(overlay)
        self.overlay = overlay
        root.window?.makeFirstResponder(overlay)
        overlay.present()
    }

    private func hide(animated: Bool) {
        if !animated { retiringOverlay?.removeFromSuperview(); retiringOverlay = nil }
        guard let overlay else { return }
        self.overlay = nil
        retiringOverlay = overlay
        overlay.dismiss(animated: animated) { [weak self, weak overlay] in
            guard let self else { return }
            if self.retiringOverlay === overlay { self.retiringOverlay = nil }
            guard self.overlay == nil, let owner = self.owner else { return }
            if owner.window?.firstResponder === overlay { owner.focusSelectedDocument() }
        }
    }
}
