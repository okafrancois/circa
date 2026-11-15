import AppKit
import BrowserCore
import BrowserShell
import SwiftUI

struct BrowserSettingsSearchEntry: Identifiable, Equatable {
    let id: String
    let section: BrowserSettingsSection
    let title: String
    var help = ""
    var keywords = ""
    var group = ""
    var unavailableReason: String?
    var identity: String { section.rawValue + "/" + id }
    static func rowID(_ title: String) -> String { "settings-row/" + title }
}

/// Token matching is local, deterministic and independent of mutable setting values.
enum BrowserSettingsSearchIndex {
    struct Matches {
        var entries: [BrowserSettingsSearchEntry]
        var approximate: Bool
    }
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    static func oneEdit(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= 1 else { return false }
        if a.count == b.count {
            let different = a.indices.filter { a[$0] != b[$0] }
            if different.count == 2, different[1] == different[0] + 1,
               a[different[0]] == b[different[1]], a[different[1]] == b[different[0]] { return true }
        }
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var next = [i + 1]
            for (j, right) in b.enumerated() {
                next.append(min(next[j] + 1, previous[j + 1] + 1, previous[j] + (left == right ? 0 : 1)))
            }
            previous = next
        }
        return previous[b.count] <= 1
    }
    static func search(_ query: String, entries: [BrowserSettingsSearchEntry]) -> Matches {
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return .init(entries: [], approximate: false) }
        func ranked(approximate: Bool) -> [BrowserSettingsSearchEntry] {
            entries.compactMap { entry -> (BrowserSettingsSearchEntry, Int)? in
                let label = tokens(entry.title), keywords = tokens(entry.keywords + " " + entry.section.title + " " + entry.group), help = tokens(entry.help)
                var score = 0
                for token in queryTokens {
                    if label.contains(token) { continue }
                    if label.contains(where: { $0.hasPrefix(token) }) { score += 1; continue }
                    if keywords.contains(where: { $0.hasPrefix(token) }) { score += 3; continue }
                    if help.contains(where: { $0.hasPrefix(token) }) { score += 5; continue }
                    if approximate, token.count >= 4, (label + keywords + help).contains(where: { oneEdit(token, $0) }) {
                        score += 10; continue
                    }
                    return nil
                }
                if tokens(entry.title) == queryTokens { score -= 1 }
                return (entry, score)
            }.sorted { left, right in
                if left.1 != right.1 { return left.1 < right.1 }
                return left.0.identity < right.0.identity
            }.map(\.0)
        }
        let exact = ranked(approximate: false)
        if !exact.isEmpty { return .init(entries: exact, approximate: false) }
        let closest = ranked(approximate: true)
        return .init(entries: closest, approximate: !closest.isEmpty)
    }
}

enum BrowserSettingsLocator {
    static let hold = 1.2
    static let fade = 0.65
    static let controlPoints = [0.0, 0.0, 0.2, 1.0]
    static func opacity(elapsed: TimeInterval, reducedMotion: Bool) -> Double {
        if reducedMotion || elapsed <= hold { return 1 }
        if elapsed >= hold + fade { return 0 }
        // Solve the timing curve's x coordinate before evaluating y.
        let x = (elapsed - hold) / fade
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 {
            let t = (lo + hi) / 2
            let curveX = 0.6 * (1 - t) * t * t + t * t * t
            if curveX < x { lo = t } else { hi = t }
        }
        let t = (lo + hi) / 2
        return 1 - (3 * (1 - t) * t * t + t * t * t)
    }
}

@MainActor
final class BrowserSettingsSearch: ObservableObject {
    @Published var query = ""
    @Published var fieldFocused = false
    @Published var matches = BrowserSettingsSearchIndex.Matches(entries: [], approximate: false)
    @Published var selectedID: String?
    @Published var jumped = false
    @Published var targetID: String?
    @Published var jumpGeneration = UUID()
    var entries: () -> [BrowserSettingsSearchEntry] = { BrowserSettingsSearchCatalog.entries }
    var navigate: ((BrowserSettingsSearchEntry) -> Bool)?
    weak var field: NSTextField?
    var pending: Task<Void, Never>?
    var showsResults: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !jumped }
    var summary: String {
        if matches.entries.isEmpty { return uiText("No settings found") }
        if matches.approximate { return uiFormat("Closest matches for “%@”", query) }
        return uiFormat("%ld results across Settings", matches.entries.count)
    }
    func update(_ value: String) {
        query = value; jumped = false; targetID = nil
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            refresh()
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let field else { return }
            NSAccessibility.post(element: field, notification: .announcementRequested,
                                 userInfo: [.announcement: summary, .priority: NSAccessibilityPriorityLevel.low.rawValue])
        }
    }
    func refresh() {
        matches = BrowserSettingsSearchIndex.search(query, entries: entries())
        if !matches.entries.contains(where: { $0.identity == selectedID }) { selectedID = matches.entries.first?.identity }
    }
    func clear() {
        pending?.cancel(); query = ""; jumped = false; targetID = nil
        matches = .init(entries: [], approximate: false); selectedID = nil
    }
    func focus() {
        targetID = nil
        field?.window?.makeFirstResponder(field)
        field?.selectText(nil)
    }
    func move(_ offset: Int) {
        guard showsResults, !matches.entries.isEmpty else { return }
        let index = matches.entries.firstIndex { $0.identity == selectedID } ?? 0
        selectedID = matches.entries[(index + offset + matches.entries.count) % matches.entries.count].identity
    }
    func jump(_ entry: BrowserSettingsSearchEntry) {
        guard entry.unavailableReason == nil else { return }
        pending?.cancel()
        if navigate?(entry) == true {
            jumped = true; targetID = entry.id; jumpGeneration = UUID()
        }
    }
    func accept() {
        if let entry = matches.entries.first(where: { $0.identity == selectedID }) { jump(entry) }
    }
    func back() { jumped = false; targetID = nil; focus() }
}

/// AppKit owns composition and selection; commands never consume marked text.
struct BrowserSettingsSearchField: NSViewRepresentable {
    @ObservedObject var search: BrowserSettingsSearch
    func makeCoordinator() -> Coordinator { Coordinator(search) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = uiText("Search Settings")
        field.font = .systemFont(ofSize: 13)
        field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.delegate = context.coordinator
        field.setAccessibilityLabel(uiText("Search Settings"))
        field.setAccessibilityIdentifier("settings-search")
        search.field = field
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != search.query { field.stringValue = search.query }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let search: BrowserSettingsSearch
        init(_ search: BrowserSettingsSearch) { self.search = search }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            search.update(field.stringValue)
        }
        func controlTextDidEndEditing(_ notification: Notification) { search.fieldFocused = false }
        func controlTextDidBeginEditing(_ notification: Notification) {
            search.fieldFocused = true
            guard let editor = search.field?.currentEditor() as? NSTextView else { return }
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText(), control.window?.attachedSheet == nil else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): search.move(1); return search.showsResults
            case #selector(NSResponder.moveUp(_:)): search.move(-1); return search.showsResults
            case #selector(NSResponder.insertNewline(_:)):
                guard search.showsResults else { return false }; search.accept(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                if !search.query.isEmpty { search.clear() } else { control.window?.makeFirstResponder(nil) }
                return true
            default: return false
            }
        }
    }
}

struct BrowserSettingsSearchBar: View {
    @ObservedObject var search: BrowserSettingsSearch
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            BrowserSettingsSearchField(search: search)
            if !search.query.isEmpty {
                Button { search.clear(); search.focus() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(uiText("Clear search"))
            } else { Text("⌘F").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true) }
        }.font(.system(size: 13)).padding(.horizontal, 9).frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(search.fieldFocused ? Color(nsColor: .controlAccentColor).opacity(0.55) : .clear, lineWidth: 2).padding(-3))
    }
}

struct BrowserSettingsSearchResults: View {
    @ObservedObject var search: BrowserSettingsSearch
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if search.matches.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundStyle(.secondary)
                    Text(uiText("No settings found")).font(.system(size: 15, weight: .semibold))
                    Text(uiFormat("No matches for “%@”.", search.query))
                    Text(uiText("Try a shorter word, like “downloads” or “memory”."))
                    Button(uiText("Clear search")) { search.clear(); search.focus() }
                }.font(.system(size: 13)).foregroundStyle(Color(nsColor: .labelColor))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).multilineTextAlignment(.center)
            } else {
                HStack {
                    Text(search.summary)
                    Spacer()
                    Text("↑ ↓  ↩").accessibilityHidden(true)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(search.matches.entries, id: \.identity) { entry in
                                Button { search.jump(entry) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: entry.section.symbol).frame(width: 20).foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entry.title).font(.system(size: 13, weight: .medium))
                                            Text(entry.unavailableReason ?? (entry.section.title + (entry.group.isEmpty ? "" : " › " + entry.group))).font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                    }.padding(.horizontal, 13).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                        .background(search.selectedID == entry.identity ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.12) : .clear)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(entry.unavailableReason != nil)
                                    .accessibilityIdentifier("settings-result/" + entry.identity)
                                    .accessibilityAddTraits(search.selectedID == entry.identity ? .isSelected : [])
                                    .id(entry.identity)
                                if entry.identity != search.matches.entries.last?.identity { Divider() }
                            }
                        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
                    }.onChange(of: search.selectedID) { _, id in if let id { reader.scrollTo(id) } }
                }
            }
        }.padding(.horizontal, 28).padding(.vertical, 18)
            .foregroundStyle(Color(nsColor: .labelColor))
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityIdentifier("settings-search-results")
    }
}

private struct SettingsSearchEnvironmentKey: EnvironmentKey {
    static let defaultValue: BrowserSettingsSearch? = nil
}
extension EnvironmentValues {
    var settingsSearch: BrowserSettingsSearch? {
        get { self[SettingsSearchEnvironmentKey.self] }
        set { self[SettingsSearchEnvironmentKey.self] = newValue }
    }
}
private struct BrowserSettingsSearchTarget: ViewModifier {
    @Environment(\.settingsSearch) private var search
    let id: String
    func body(content: Content) -> some View {
        if let search { content.modifier(BrowserSettingsActiveSearchTarget(search: search, id: id)) }
        else { content }
    }
}
private struct BrowserSettingsActiveSearchTarget: ViewModifier {
    @ObservedObject var search: BrowserSettingsSearch
    let id: String
    @State private var opacity = 0.0
    @AccessibilityFocusState private var accessibleFocus: Bool
    @FocusState private var keyboardFocus: Bool
    func body(content: Content) -> some View {
        content
            .background(alignment: .leading) {
                Rectangle().fill(Color(nsColor: .controlAccentColor).opacity(0.12))
                    .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .controlAccentColor)).frame(width: 3) }
                    .opacity(opacity).allowsHitTesting(false).accessibilityHidden(true)
            }
            .focusable(search.targetID == id).focused($keyboardFocus)
            .accessibilityFocused($accessibleFocus)
            .id(id)
            .task(id: search.jumpGeneration) {
                guard search.targetID == id else { opacity = 0; return }
                // Wait for the destination layout and pane entry before starting the locator clock.
                if !OrbitMotionPreferences.prefersReducedMotion { try? await Task.sleep(for: .milliseconds(420)) }
                guard !Task.isCancelled, search.targetID == id else { return }
                accessibleFocus = true; keyboardFocus = true; opacity = 1
                if OrbitMotionPreferences.prefersReducedMotion { return }
                try? await Task.sleep(for: .seconds(BrowserSettingsLocator.hold))
                guard !Task.isCancelled, search.targetID == id else { return }
                withAnimation(.timingCurve(0, 0, 0.2, 1, duration: BrowserSettingsLocator.fade)) { opacity = 0 }
            }
            .onChange(of: search.targetID) { _, target in if target != id { opacity = 0; accessibleFocus = false } }
    }
}

extension View {
    func settingsSearchTarget(_ id: String) -> some View { modifier(BrowserSettingsSearchTarget(id: id)) }
    // Search metadata is derived from these declarations by scripts/settings-search-index.py.
    func settingsSearchItem(_ title: String, section: BrowserSettingsSection, id: String) -> some View {
        settingsSearchTarget(id)
    }
}

struct BrowserSettingsSearchScroll<Content: View>: View {
    @Environment(\.settingsSearch) private var search
    @ViewBuilder var content: Content
    var body: some View {
        if let search { BrowserSettingsActiveSearchScroll(search: search) { content } }
        else { ScrollView { content } }
    }
}
private struct BrowserSettingsActiveSearchScroll<Content: View>: View {
    @ObservedObject var search: BrowserSettingsSearch
    @ViewBuilder var content: Content
    var body: some View {
        ScrollViewReader { reader in
            ScrollView { content }
                .task(id: search.jumpGeneration) {
                    guard let target = search.targetID else { return }
                    await Task.yield()
                    reader.scrollTo(target, anchor: .center)
                }
        }
    }
}

extension BrowserSettingsModel {
    var searchEntries: [BrowserSettingsSearchEntry] {
        var entries = BrowserSettingsSearchCatalog.entries
        // Only static command definitions are indexed; customized bindings and site data stay out.
        entries += settingsShortcuts.map {
            .init(id: "settings-shortcut-" + $0.id.rawValue, section: .shortcuts,
                  title: $0.localizedTitle, keywords: uiText($0.menu))
        }
        entries += OrbitAIService.order.map { provider in
            var entry = BrowserSettingsSearchEntry(id: "settings-ai-program-" + provider.rawValue, section: .ai,
                                                  title: BrowserSettingsAIText.name(provider))
            if provider != .onDevice, environment.ai.statuses[provider]?.state == .notInstalled {
                entry.unavailableReason = uiText("Not on this Mac")
            }
            return entry
        }
        return entries.filter { entry in
            if entry.id == "settings-create-profile" { return false } // Confirmation sheet, not the pane row.
            if entry.id == "settings-sync" { return environment.sync.showsSettings }
            return true
        }.map { original in
            var entry = original
            if entry.section == .ai, entry.id != "settings-ai-enabled", !runtime.document.ai.isEnabled {
                entry.unavailableReason = uiText("Turn on AI to use this setting.")
            }
            if entry.id == "settings-safe-browsing-key", !runtime.document.safeBrowsingEnabled {
                entry.unavailableReason = uiText("Turn on Safe Browsing to use this setting.")
            }
            if entry.id == BrowserSettingsSearchEntry.rowID(uiText("Block ads and trackers")), environment.contentBlocking == nil {
                entry.unavailableReason = uiText("Unavailable")
            }
            if selectedProfileID == nil, [.profiles, .spaces, .privacy].contains(entry.section) {
                entry.unavailableReason = uiText("Choose an available profile.")
            }
            return entry
        }
    }
}
