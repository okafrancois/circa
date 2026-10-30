import AppKit
import BrowserCore
import BrowserEngine

/// A sheet-local draft. Marked text never becomes a committed Space icon.
@MainActor
final class BrowserSpaceIconEditor: NSObject, NSTextFieldDelegate {
    let field = NSTextField()
    let alert = OrbitFloatingMaterial.alert()
    private let initialChoice: BrowserSpaceIcon
    private let draft: BrowserSettingsIconDraft
    private let save: (String) async -> Void
    private(set) var pending: Task<Void, Never>?
    private var finished = false

    convenience init(icon: String, save: @escaping (String) async -> Void) {
        self.init(choice: BrowserSpaceIcon(legacyIcon: icon), save: save)
    }
    init(choice: BrowserSpaceIcon, save: @escaping (String) async -> Void) {
        initialChoice = choice
        draft = BrowserSettingsIconDraft(choice: choice)
        self.save = save
        super.init()
        alert.messageText = uiText("Change Space Icon or Emoji")
        alert.informativeText = uiText("Choose one character or emoji, or clear the icon to show a dot.")
        alert.addButton(withTitle: uiText("Apply"))
        alert.addButton(withTitle: uiText("Cancel"))
        alert.addButton(withTitle: uiText("Clear Icon"))
        field.stringValue = draft.text
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityLabel(uiText("Icon (one character or emoji)"))
        field.setAccessibilityIdentifier("space-icon-draft")
        field.delegate = self
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        refreshValidation()
    }

    func refreshValidation() {
        draft.text = field.stringValue
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        alert.buttons[0].isEnabled = draft.canSubmit && !composing
        alert.buttons[2].isEnabled = !composing && initialChoice != .none
    }
    func controlTextDidChange(_ notification: Notification) { refreshValidation() }

    /// Shared by the real sheet callback and hidden tests; cancellation has no write side effect.
    func complete(_ response: NSApplication.ModalResponse) {
        guard !finished else { return }
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        refreshValidation()
        let value: String
        switch response {
        case .alertFirstButtonReturn:
            guard draft.canSubmit else { return }
            value = draft.text
        case .alertThirdButtonReturn: value = ""
        default: finished = true; return
        }
        finished = true
        pending = Task { await save(value) }
    }
    func waitForSave() async { await pending?.value }
    func show(on window: NSWindow) {
        alert.beginSheetModal(for: window) { [self] response in complete(response) }
    }
}

extension BrowserWindowController {
    /// The Space and its profile are captured before presentation; focus never substitutes a target.
    func makeSpaceIconEditor(for id: SpaceID) -> BrowserSpaceIconEditor? {
        guard let commit = makeSpaceIconCommit(for: id) else { return nil }
        return BrowserSpaceIconEditor(choice: commit.choice) { await commit.save(BrowserSpaceIcon(legacyIcon: $0)) }
    }

    /// The footer picker shares the editor's captured-identity commit; it is the default surface.
    func makeSpaceIconPicker(for id: SpaceID) -> SpaceIconPicker? {
        guard let commit = makeSpaceIconCommit(for: id) else { return nil }
        let picker = SpaceIconPicker(currentChoice: commit.choice, accent: sidebar.footer.accent)
        picker.onChooseIcon = { value in
            guard value.isValid else { return }
            Task { @MainActor in await commit.save(value) }
        }
        return picker
    }

    private func makeSpaceIconCommit(for id: SpaceID) -> (choice: BrowserSpaceIcon, save: (BrowserSpaceIcon) async -> Void)? {
        guard acceptsCommands, !session.isClosed, !session.hasPendingCommands,
              let runtime = settingsPreferences?.runtime, !runtime.isUnavailable,
              let space = session.catalog?.spaces.first(where: { $0.id == id }),
              let sourceProfile = session.activeProfileID,
              let authority = session.captureSpaceSettingsAuthority(for: id, profileID: space.profileID) else { return nil }
        let profile = space.profileID
        return (runtime.document.space(id).iconSelection, { [weak self, weak runtime] value in
            guard let self, let runtime else { return }
            await session.waitForQueuedCommands()
            guard acceptsCommands, !session.isClosed, !session.hasPendingCommands,
                  session.activeProfileID == sourceProfile, !runtime.isUnavailable,
                  value.isValid else { return }
            let catalog = await session.paletteDocument()
            guard acceptsCommands, !session.isClosed, !session.hasPendingCommands,
                  session.activeProfileID == sourceProfile,
                  catalog.spaces.contains(where: { $0.id == id && $0.profileID == profile }) else { return }
            do {
                try await session.updateSpaceIcon(value, authority: authority, settings: runtime.store, sourceProfile: sourceProfile)
                await runtime.refresh()
                settingsPreferences?.renderIcons(in: self)
            } catch { await runtime.refresh(); session.onError?(error) }
        })
    }

    /// Prefers the picker anchored on the footer Space; the sheet remains for a hidden footer.
    func presentSpaceIconEditor(for id: SpaceID) {
        guard acceptsCommands, window?.isVisible == true else { return }
        if window?.isVisible == true, !sidebar.isPresentationHidden,
           sidebar.footer.spaceButtons.contains(where: { $0.space.id == id }), let picker = makeSpaceIconPicker(for: id) {
            session.performWindowAction { [weak self] in
                guard let self, acceptsCommands, window?.isVisible == true, !session.isClosed else { return }
                sidebar.footer.presentIconPicker(picker, for: id)
            }
            return
        }
        guard let editor = makeSpaceIconEditor(for: id) else { return }
        session.performWindowAction { [weak self] in
            guard let self, let window, window.isVisible, acceptsCommands, !session.isClosed else { return }
            editor.show(on: window)
        }
    }
}
