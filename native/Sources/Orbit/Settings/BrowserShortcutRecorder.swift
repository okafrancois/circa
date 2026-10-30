import AppKit
import SwiftUI
import BrowserShell

/// A real first responder owns the entire chord, including normally reserved ⌘Q/⌘W.
@MainActor
final class BrowserShortcutRecorderView: NSButton {
    var onRecord: ((BrowserShortcut?) -> Void)?
    var shortcutTitle = "—" { didSet { if !isRecording { applyTitle() } } }
    private func applyTitle() {
        let value = NSAttributedString(string: shortcutTitle, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
        attributedTitle = value
    }
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
        isRecording = false; applyTitle()
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
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
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
    var openExtensionSettings: (() -> Void)? = nil
    var extensionSettingsAvailable = true
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
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    OrbitIcon.view(sfName: "magnifyingglass", pointSize: 14).font(.system(size: 14)).foregroundStyle(.secondary)
                    TextField(uiText("Search shortcuts"), text: $query).textFieldStyle(.plain)
                        .accessibilityIdentifier("settings-search-shortcuts")
                }.padding(.horizontal, 9).frame(height: 26)
                    .background(OrbitSettingsStyle.panel, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(OrbitSettingsStyle.border))
                if let openExtensionSettings {
                    Button(action: openExtensionSettings) {
                        Label { Text(uiText("Extension Shortcuts…")) } icon: { OrbitIcon.view(sfName: "puzzlepiece.extension", pointSize: 14).font(.system(size: 14)) }
                    }
                        .disabled(!extensionSettingsAvailable).accessibilityIdentifier("settings-extension-shortcuts")
                }
            }
            SettingsCard {
                Toggle(uiText("Include Favorites in Ordering"), isOn: Binding(
                    get: { preferences.document.includeFavorites },
                    set: { value in change { try preferences.setOrdering(includeFavorites: value) } }))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
                Toggle(uiText("⌘9 selects the last tab"), isOn: Binding(
                    get: { preferences.document.nineSelectsLast },
                    set: { value in change { try preferences.setOrdering(nineSelectsLast: value) } }))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
                Toggle(isOn: Binding(
                    get: { preferences.document.globalQuickWindowEnabled },
                    set: { value in change { try preferences.setGlobalQuickWindowEnabled(value) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(uiText("Open Little Circa from other apps"))
                            Text(uiText("Uses the New Little Circa Window shortcut, even when Circa is in the background."))
                                .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 8)
            }
            HStack {
                Text(uiText("Keyboard Shortcuts")).font(Font(BrandFonts.ui(14, weight: .semibold)))
                Spacer()
                Button(uiText("Reset All")) { change { try preferences.resetAll() } }
                    .accessibilityIdentifier("settings-reset-shortcuts")
            }.padding(.top, 8)
            if let error = preferences.errorMessage {
                Text(error).foregroundStyle(.red).font(Font(BrandFonts.ui(12)))
                    .accessibilityIdentifier("settings-shortcut-error")
            }
            ScrollView {
              LazyVStack(spacing: 0) {
                ForEach(Array(Set(filtered.map(\.menu))).sorted(), id: \.self) { menu in
                  Text(uiText(menu)).font(Font(BrandFonts.ui(11, weight: .semibold))).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
                  ForEach(filtered.filter { $0.menu == menu }, id: \.id) { command in
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
                        } label: { OrbitIcon.view(sfName: "ellipsis.circle", pointSize: 13).font(.system(size: 13)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26)
                        .accessibilityLabel(command.localizedTitle + " " + uiText("Shortcut options"))
                    }.padding(.horizontal, 10).padding(.vertical, 5)
                    SettingsRule()
                  }
                }
            }
              }
            .frame(height: 236)
            .background(OrbitSettingsStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OrbitSettingsStyle.border, lineWidth: 1))
            if filtered.isEmpty { Text(uiText("No matching shortcuts.")).foregroundStyle(.secondary) }
            Text(uiText("Click a shortcut and press new keys. Escape cancels; Delete removes it."))
                .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
        }
        .toggleStyle(SettingsSwitchStyle())
        .disabled(preferences.isUnavailable)
    }
}
