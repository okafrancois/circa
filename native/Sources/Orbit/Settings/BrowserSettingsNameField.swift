import AppKit
import SwiftUI
import BrowserShell

/// A native field editor reports composition separately from its SwiftUI text binding. Marked
/// text must never be replaced by a catalog refresh, including before the binding has changed.
@MainActor
struct BrowserSettingsNameField: NSViewRepresentable {
    @ObservedObject var draft: BrowserSettingsNameDraft
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> BrowserSettingsNameTextField {
        let field = BrowserSettingsNameTextField()
        field.draft = draft
        field.onSubmit = onSubmit
        field.setAccessibilityLabel(settingsText("name", "Name"))
        return field
    }

    func updateNSView(_ field: BrowserSettingsNameTextField, context: Context) {
        field.draft = draft
        field.onSubmit = onSubmit
        field.isEnabled = context.environment.isEnabled
        field.applyDraft()
    }
}

@MainActor
final class BrowserSettingsNameTextField: NSTextField, NSTextFieldDelegate {
    var draft: BrowserSettingsNameDraft?
    var onSubmit: (() -> Void)?
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
