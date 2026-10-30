import AppKit
import SwiftUI

/// A real first responder owns the entire chord, including normally reserved ⌘Q/⌘W.
@MainActor
final class BrowserShortcutRecorderView: NSButton {
    var onRecord: ((BrowserShortcut?) -> Void)?
    var shortcutTitle = "—" { didSet { if !isRecording { title = shortcutTitle } } }
    private(set) var isRecording = false
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { beginRecording() }
    override func accessibilityPerformPress() -> Bool { beginRecording(); return true }
    private func beginRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        title = uiText("Type shortcut…")
        setAccessibilityValue(title)
    }
    override func resignFirstResponder() -> Bool {
        isRecording = false; title = shortcutTitle
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) { _ = record(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { isRecording && record(event) }
    @discardableResult
    func record(_ event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return false }
        guard !event.isARepeat else { return true }
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return true }
        if event.keyCode == 51 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            onRecord?(nil); window?.makeFirstResponder(nil); return true
        }
        guard let shortcut = BrowserShortcut.recordedInput(event) else { return true }
        onRecord?(shortcut)
        window?.makeFirstResponder(nil)
        return true
    }
}

struct BrowserShortcutRecorder: NSViewRepresentable {
    let title: String
    let identifier: String
    let onRecord: (BrowserShortcut?) -> Void
    func makeNSView(context: Context) -> BrowserShortcutRecorderView {
        let view = BrowserShortcutRecorderView(title: title, target: nil, action: nil)
        view.bezelStyle = .rounded
        view.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        return view
    }
    func updateNSView(_ view: BrowserShortcutRecorderView, context: Context) {
        view.shortcutTitle = title
        view.onRecord = onRecord
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(uiText("Record shortcut"))
    }
}

@MainActor
struct BrowserShortcutSettingsPane: View {
    @ObservedObject var preferences: BrowserShortcutPreferences
    let definitions: [BrowserCommandDefinition]
    let conflictDefinitions: [BrowserCommandDefinition]
    @State private var query = ""
    private var filtered: [BrowserCommandDefinition] {
        definitions.filter {
            query.isEmpty || $0.localizedTitle.localizedStandardContains(query)
                || preferences.bindings(for: $0).contains { shortcutLabel($0).localizedStandardContains(query) }
        }.sorted {
            let left = preferences.isCustomized($0.id), right = preferences.isCustomized($1.id)
            if left != right { return left }
            return $0.localizedTitle.localizedStandardCompare($1.localizedTitle) == .orderedAscending
        }
    }
    private func change(_ action: () throws -> Void) {
        do { try action() } catch { preferences.errorMessage = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(uiText("Search shortcuts"), text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings-search-shortcuts")
            HStack {
                Text(uiText("Keyboard Shortcuts")).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(uiText("Reset All")) { change { try preferences.resetAll() } }
                    .accessibilityIdentifier("settings-reset-shortcuts")
            }
            Text(uiText("Click a shortcut and press new keys. Escape cancels; Delete removes it."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Toggle(uiText("Include Favorites in Ordering"), isOn: Binding(
                get: { preferences.document.includeFavorites },
                set: { value in change { try preferences.setOrdering(includeFavorites: value) } }))
            Toggle(uiText("⌘9 selects the last tab"), isOn: Binding(
                get: { preferences.document.nineSelectsLast },
                set: { value in change { try preferences.setOrdering(nineSelectsLast: value) } }))
            Toggle(uiText("Open Little Orbit from other apps"), isOn: Binding(
                get: { preferences.document.globalQuickWindowEnabled },
                set: { value in change { try preferences.setGlobalQuickWindowEnabled(value) } }))
                .help(uiText("Uses the New Little Orbit Window shortcut, even when Orbit is in the background."))
            if let error = preferences.errorMessage {
                Text(error).foregroundStyle(.red).font(.system(size: 12))
                    .accessibilityIdentifier("settings-shortcut-error")
            }
            LazyVStack(spacing: 0) {
                ForEach(filtered, id: \.id) { command in
                    HStack(spacing: 8) {
                        Text(command.localizedTitle).frame(maxWidth: .infinity, alignment: .leading)
                        BrowserShortcutRecorder(title: preferences.bindings(for: command).isEmpty ? "—" : preferences.bindings(for: command).map(shortcutLabel).joined(separator: " / "),
                            identifier: "settings-shortcut-" + command.id.rawValue) { shortcut in
                                change { try preferences.setShortcut(shortcut, for: command.id, definitions: conflictDefinitions) }
                            }.frame(width: 122, height: 26)
                        Menu {
                            ForEach(BrowserShortcutWebsitePriority.allCases, id: \.rawValue) { priority in
                                Button(priority.title) { change { try preferences.setPriority(priority, for: command.id) } }
                            }
                            Divider()
                            Button(uiText("Remove Shortcut")) { change { try preferences.setShortcut(nil, for: command.id, definitions: conflictDefinitions) } }
                            Button(uiText("Reset to Default")) { change { try preferences.reset(command.id) } }
                        } label: { OrbitIcon.view(sfName: "ellipsis.circle", pointSize: 13) }
                        .menuStyle(.borderlessButton).frame(width: 22)
                        .accessibilityLabel(command.localizedTitle + " " + uiText("Shortcut options"))
                    }.padding(.horizontal, 10).padding(.vertical, 7)
                    Divider()
                }
            }
            .background(OrbitSettingsStyle.panel, in: RoundedRectangle(cornerRadius: 6))
            if filtered.isEmpty { Text(uiText("No matching shortcuts.")).foregroundStyle(.secondary) }
        }
        .disabled(preferences.isUnavailable)
    }
}
