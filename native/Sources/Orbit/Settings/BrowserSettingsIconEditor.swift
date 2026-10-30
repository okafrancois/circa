import BrowserCore
import Combine
import SwiftUI
import BrowserShell

/// Composition and intermediate invalid input belong to the draft, never to the persisted file.
@MainActor
final class BrowserSettingsIconDraft: ObservableObject {
    @Published var text: String
    @Published private var persisted: BrowserSpaceIcon
    var canSubmit: Bool { BrowserSpaceIcon(legacyIcon: text) != persisted && BrowserSpaceSettings.isValidIcon(text) }
    var hasEdits: Bool { text != Self.text(persisted) }
    var isValid: Bool { BrowserSpaceSettings.isValidIcon(text) }
    convenience init(icon: String) { self.init(choice: BrowserSpaceIcon(legacyIcon: icon)) }
    init(choice: BrowserSpaceIcon) { text = Self.text(choice); persisted = choice }
    private static func text(_ choice: BrowserSpaceIcon) -> String {
        if case .grapheme(let value) = choice { value } else { "" }
    }
    func receivePersisted(_ icon: String) { receivePersisted(BrowserSpaceIcon(legacyIcon: icon)) }
    func receivePersisted(_ choice: BrowserSpaceIcon) {
        if text == Self.text(persisted) { text = Self.text(choice) }
        persisted = choice
    }
    func submit(_ save: (String) -> Void) {
        guard canSubmit else { return }
        save(text)
    }
}

@MainActor
struct BrowserSettingsIconEditor: View {
    let choice: BrowserSpaceIcon
    let save: (String) -> Void
    let compact: Bool
    @FocusState private var isFocused: Bool
    @StateObject private var draft: BrowserSettingsIconDraft
    init(choice: BrowserSpaceIcon, compact: Bool = false, save: @escaping (String) -> Void) {
        self.choice = choice
        self.compact = compact
        self.save = save
        _draft = StateObject(wrappedValue: BrowserSettingsIconDraft(choice: choice))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
          if compact {
            HStack(spacing: 6) {
              if choice != .none, draft.text.isEmpty {
                Menu {
                    Button(uiText("Clear Icon")) { save("") }
                } label: { BrowserSettingsIconPreview(choice: choice).frame(width: 20, height: 20) }
                    .menuStyle(.borderlessButton).frame(width: 30)
              }
              TextField(settingsText("spaceIcon", "Icon (one character or emoji)"), text: $draft.text)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.center).frame(width: 52, height: 26)
                .focused($isFocused).onSubmit { if draft.hasEdits { draft.submit(save) } }
                .onChange(of: isFocused) { _, focused in if !focused && draft.hasEdits { draft.submit(save) } }
                .accessibilityIdentifier("settings-space-icon")
                .help(SpaceIconImages.label(choice))
            }
          } else {
            HStack {
                BrowserSettingsIconPreview(choice: choice).frame(width: 28, height: 28)
                Text(SpaceIconImages.label(choice))
                Spacer()
                Button(uiText("Clear Icon")) { save("") }.disabled(choice == .none)
            }
            HStack {
                TextField(settingsText("spaceIcon", "Icon (one character or emoji)"), text: $draft.text)
                    .onSubmit { draft.submit(save) }
                    .accessibilityIdentifier("settings-space-icon")
                Button(settingsText("applyIcon", "Apply")) { draft.submit(save) }.disabled(!draft.canSubmit)
            }
          }
            if !draft.isValid {
                Text(settingsText("invalidIcon", "Choose a single character or emoji for the Space icon."))
                    .font(Font(BrandFonts.ui(12))).foregroundStyle(.secondary)
            }
        }.onChange(of: choice) { _, choice in draft.receivePersisted(choice) }
    }
}

/// Actual Settings projection, shared with Library's native icon view.
@MainActor
struct BrowserSettingsIconPreview: NSViewRepresentable {
    let choice: BrowserSpaceIcon
    static func projection(_ choice: BrowserSpaceIcon) -> NSView { SpaceIconImages.view(choice) }
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.setAccessibilityIdentifier("settings-space-icon-preview")
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        host.subviews.forEach { $0.removeFromSuperview() }
        let icon = Self.projection(choice)
        icon.frame = host.bounds
        icon.autoresizingMask = [.width, .height]
        host.addSubview(icon)
    }
}

/// Catalog acknowledgements and IME state are independent from the last bound text value.
@MainActor
final class BrowserSettingsNameDraft: ObservableObject {
    @Published var text: String {
        didSet { if text != oldValue { editRevision &+= 1 } }
    }
    @Published private var persisted: String
    @Published private(set) var isComposing = false
    private var deferredPersisted: String?
    private var editRevision: UInt64 = 0
    private var submission: (text: String, normalized: String, revision: UInt64)?

    var canSubmit: Bool {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isComposing && name != persisted && !name.isEmpty && name.rangeOfCharacter(from: .controlCharacters) == nil
    }
    init(name: String) { text = name; persisted = name }

    func beginComposition() {
        if !isComposing {
            // Composition is an edit even while the bound string has not changed yet.
            editRevision &+= 1
            isComposing = true
        }
    }

    func finishComposition(text committedText: String) {
        // Read the actual field editor before applying any deferred catalog value. The binding
        // can still contain the pre-composition value when the marked text is confirmed.
        if text != committedText { text = committedText }
        if isComposing { isComposing = false }
        if let value = deferredPersisted {
            deferredPersisted = nil
            receivePersisted(value)
        }
    }

    func receivePersisted(_ name: String) {
        guard !isComposing else { deferredPersisted = name; return }
        let acknowledgement = submission.map {
            $0.revision == editRevision && $0.text == text && $0.normalized == name
        } ?? false
        if text == persisted || acknowledgement { text = name }
        persisted = name
        if submission?.normalized == name { submission = nil }
    }

    func submit(_ save: (String) -> Void) {
        guard canSubmit else { return }
        submission = (text, text.trimmingCharacters(in: .whitespacesAndNewlines), editRevision)
        save(text)
    }
}
