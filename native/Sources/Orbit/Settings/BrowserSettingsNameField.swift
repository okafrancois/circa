import AppKit
import SwiftUI
import BrowserShell

/// A native field editor reports composition separately from its SwiftUI text binding. Marked
/// text must never be replaced by a catalog refresh, including before the binding has changed.
@MainActor
struct BrowserSettingsNameField: NSViewRepresentable {
    @ObservedObject var draft: BrowserSettingsNameDraft
    let onSubmit: () -> Void
    var savesOnEndEditing = false

    func makeNSView(context: Context) -> BrowserSettingsNameTextField {
        let field = BrowserSettingsNameTextField()
        field.draft = draft
        field.onSubmit = onSubmit
        field.savesOnEndEditing = savesOnEndEditing
        field.setAccessibilityLabel(settingsText("name", "Name"))
        return field
    }

    func updateNSView(_ field: BrowserSettingsNameTextField, context: Context) {
        field.draft = draft
        field.onSubmit = onSubmit
        field.savesOnEndEditing = savesOnEndEditing
        field.isEnabled = context.environment.isEnabled
        field.applyDraft()
    }
}

@MainActor
final class BrowserSettingsNameTextField: NSTextField, NSTextFieldDelegate {
    var draft: BrowserSettingsNameDraft?
    var onSubmit: (() -> Void)?
    var savesOnEndEditing = false
    private var isApplyingDraft = false

    init() {
        super.init(frame: .zero)
        cell = BrowserSettingsNameCell(textCell: "")
        isEditable = true
        isSelectable = true
        isBordered = false
        drawsBackground = false
        font = BrandFonts.ui(13)
        delegate = self
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }

    func applyDraft() {
        guard let draft, (currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let value = (currentEditor() as? NSTextView)?.string ?? stringValue
        guard value != draft.text else { return }
        isApplyingDraft = true
        stringValue = draft.text
        isApplyingDraft = false
    }

    func editorDidChange(_ editor: NSTextView) {
        guard !isApplyingDraft else { return }
        if editor.hasMarkedText() { draft?.beginComposition() }
        else { draft?.finishComposition(text: editor.string) }
    }

    func controlTextDidChange(_ notification: Notification) {
        if let editor = currentEditor() as? NSTextView { editorDidChange(editor) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !isApplyingDraft else { return }
        draft?.finishComposition(text: stringValue)
        if savesOnEndEditing { onSubmit?() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
        editorDidChange(textView)
        onSubmit?()
        return true
    }
}

@MainActor
private final class BrowserSettingsNameCell: NSTextFieldCell {
    private lazy var editor = BrowserSettingsNameFieldEditor()
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor.owner = controlView as? BrowserSettingsNameTextField
        editor.isFieldEditor = true
        return editor
    }
}

@MainActor
private final class BrowserSettingsNameFieldEditor: NSTextView {
    weak var owner: BrowserSettingsNameTextField?
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        owner?.editorDidChange(self)
    }
    override func unmarkText() {
        super.unmarkText()
        owner?.editorDidChange(self)
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        owner?.editorDidChange(self)
    }
}


@MainActor
struct BrowserSettingsRenameForm: View {
    @StateObject private var draft: BrowserSettingsNameDraft
    let error: String?
    let save: (String) -> Void
    let cancel: () -> Void

    init(name: String, error: String?, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        _draft = StateObject(wrappedValue: BrowserSettingsNameDraft(name: name))
        self.error = error; self.save = save; self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(uiText("Rename")).font(Font(BrandTextStyle.title.font(size: 22)))
            BrowserSettingsNameField(draft: draft) { draft.submit(save) }
                .padding(.horizontal, 9).frame(height: 26)
                .background(OrbitSettingsStyle.panel, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(OrbitSettingsStyle.border))
            if let error { Text(error).foregroundStyle(.red).font(Font(BrandFonts.ui(12))) }
            HStack {
                Spacer()
                Button(uiText("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(uiText("Rename")) { draft.submit(save) }
                    .keyboardShortcut(.defaultAction).disabled(!draft.canSubmit)
            }
        }.padding(22).frame(width: 396).font(Font(BrandFonts.ui(13))).settingsFrost()
    }
}
