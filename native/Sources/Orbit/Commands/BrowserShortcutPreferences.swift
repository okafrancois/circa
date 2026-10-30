import AppKit
import Combine

/// The on-disk format contains command IDs and characters, never hardware key codes.
enum BrowserShortcutPreferenceError: LocalizedError {
    case invalidShortcut, conflict(String), unavailable
    var errorDescription: String? {
        switch self {
        case .invalidShortcut: uiText("Use a modifier key with a character, or a function key.")
        case .conflict(let title): uiText("Shortcut already used by") + " “\(title)”."
        case .unavailable: uiText("Saved shortcuts are unavailable. The existing file has been kept.")
        }
    }
}

enum BrowserShortcutWebsitePriority: String, Codable, CaseIterable {
    case browser, websites, both
    var title: String {
        switch self {
        case .browser: uiText("Prefer Circa")
        case .websites: uiText("Prefer Websites")
        case .both: uiText("Use Both")
        }
    }
}

@MainActor
final class BrowserShortcutPreferences: ObservableObject {
    struct Binding: Codable, Equatable {
        let key: String
        let modifiers: UInt
        init(_ shortcut: BrowserShortcut) { key = shortcut.key; modifiers = shortcut.modifiers.rawValue }
        var shortcut: BrowserShortcut { .init(key: key, modifiers: .init(rawValue: modifiers)) }
    }
    struct Document: Codable, Equatable {
        var version = 1
        /// An empty array explicitly removes a shortcut; absence uses the catalog defaults.
        var overrides: [String: [Binding]] = [:]
        var priorities: [String: BrowserShortcutWebsitePriority] = [:]
        var includeFavorites = true
        var nineSelectsLast = true
        var globalQuickWindowEnabled = false

        /// Preserve saved bindings when the application's sole Quit command is renamed.
        mutating func normalizeQuitCommandID() {
            let current = BrowserCommandID.quitOrbit.rawValue
            let retired = Set(overrides.keys).union(priorities.keys).filter {
                $0.hasPrefix("quit") && $0 != current && BrowserCommandID(rawValue: $0) == nil
            }
            guard retired.count == 1, let previous = retired.first else { return }
            if overrides[current] == nil { overrides[current] = overrides[previous] }
            if priorities[current] == nil { priorities[current] = priorities[previous] }
            overrides[previous] = nil
            priorities[previous] = nil
        }
    }
    @Published private(set) var document = Document()
    @Published var errorMessage: String?
    private(set) var isUnavailable = false
    var onChange: (() -> Void)?
    private let destination: URL?

    init(destination: URL? = nil) {
        self.destination = destination
        guard let destination, FileManager.default.fileExists(atPath: destination.path) else { return }
        do {
            let decoded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: destination))
            guard decoded.version == 1 else { throw BrowserShortcutPreferenceError.unavailable }
            guard decoded.overrides.values.flatMap({ $0 }).allSatisfy({ Self.isValid($0.shortcut) }) else {
                throw BrowserShortcutPreferenceError.unavailable
            }
            document = decoded
            document.normalizeQuitCommandID()
        } catch { isUnavailable = true; errorMessage = BrowserShortcutPreferenceError.unavailable.localizedDescription }
    }

    func bindings(for definition: BrowserCommandDefinition) -> [BrowserShortcut] {
        if let override = document.overrides[definition.id.rawValue] { return override.map(\.shortcut) }
        // The shipped menu/registry policy reserves ⇧⌘N for New Incognito Window.
        if definition.id == .newFolder { return [] }
        return definition.shortcuts
    }
    func isCustomized(_ id: BrowserCommandID) -> Bool {
        document.overrides[id.rawValue] != nil || document.priorities[id.rawValue] != nil
    }
    func priority(for id: BrowserCommandID) -> BrowserShortcutWebsitePriority? { document.priorities[id.rawValue] }

    func setShortcut(_ shortcut: BrowserShortcut?, for id: BrowserCommandID,
                     definitions: [BrowserCommandDefinition]) throws {
        guard let definition = definitions.first(where: { $0.id == id }) else { return }
        if let shortcut {
            guard Self.isValid(shortcut) else { throw BrowserShortcutPreferenceError.invalidShortcut }
            let nativeInput = BrowserGlobalQuickWindowShortcut.layoutEvent(for: shortcut).flatMap { BrowserShortcutEvent($0) }
            let matcher = BrowserKeyEquivalentMatcher(bindings: definitions.flatMap { bindings(for: $0) })
            if let conflict = definitions.first(where: { other in
                guard other.id != id, Self.scopesOverlap(other.scope, definition.scope) else { return false }
                return bindings(for: other).contains { binding in
                    if binding == shortcut { return true }
                    // Default digit and punctuation equivalents adapt to AZERTY through AppKit.
                    // Customized chords keep their recorded character identity.
                    return document.overrides[other.id.rawValue] == nil
                        && nativeInput.map { matcher.matches(binding, input: $0) } == true
                }
            }) { throw BrowserShortcutPreferenceError.conflict(conflict.localizedTitle) }
        }
        var next = document
        next.overrides[id.rawValue] = shortcut.map { [Binding($0)] } ?? []
        try commit(next)
    }

    static func isValid(_ shortcut: BrowserShortcut) -> Bool {
        guard shortcut.key.count == 1 else { return false }
        let function = shortcut.key.unicodeScalars.first.map { (0xF704...0xF726).contains($0.value) } == true
        return function || !shortcut.modifiers.intersection([.command, .control, .option]).isEmpty
            && shortcut.key != "\u{1b}"
    }
    private static func scopesOverlap(_ lhs: BrowserCommandScope, _ rhs: BrowserCommandScope) -> Bool {
        lhs == rhs || ([.browser, .responder].contains(lhs) && [.browser, .responder].contains(rhs))
    }
    func reset(_ id: BrowserCommandID, definitions: [BrowserCommandDefinition] = OrbitCommandCatalog.definitions) throws {
        if let definition = definitions.first(where: { $0.id == id }) {
            let matcher = BrowserKeyEquivalentMatcher(bindings: definition.shortcuts)
            if let conflict = definitions.first(where: { other in
                guard other.id != id, document.overrides[other.id.rawValue] != nil,
                      Self.scopesOverlap(other.scope, definition.scope) else { return false }
                return bindings(for: other).contains { binding in
                    if definition.shortcuts.contains(binding) { return true }
                    guard let event = BrowserGlobalQuickWindowShortcut.layoutEvent(for: binding),
                          let input = BrowserShortcutEvent(event) else { return false }
                    return definition.shortcuts.contains { matcher.matches($0, input: input) }
                }
            }) { throw BrowserShortcutPreferenceError.conflict(conflict.localizedTitle) }
        }
        var next = document; next.overrides[id.rawValue] = nil; next.priorities[id.rawValue] = nil
        try commit(next)
    }
    func resetAll() throws { try commit(Document()) }
    func setPriority(_ priority: BrowserShortcutWebsitePriority, for id: BrowserCommandID) throws {
        var next = document; next.priorities[id.rawValue] = priority; try commit(next)
    }
    func setOrdering(includeFavorites: Bool? = nil, nineSelectsLast: Bool? = nil) throws {
        var next = document
        if let includeFavorites { next.includeFavorites = includeFavorites }
        if let nineSelectsLast { next.nineSelectsLast = nineSelectsLast }
        try commit(next)
    }
    func setGlobalQuickWindowEnabled(_ enabled: Bool) throws {
        var next = document; next.globalQuickWindowEnabled = enabled; try commit(next)
    }
    private func commit(_ next: Document) throws {
        guard !isUnavailable else { throw BrowserShortcutPreferenceError.unavailable }
        if let destination {
            let data = try JSONEncoder().encode(next)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                let backup = destination.appendingPathExtension("backup")
                let old = try Data(contentsOf: destination)
                try old.write(to: backup, options: .atomic)
            }
            try data.write(to: destination, options: .atomic)
        }
        document = next
        errorMessage = nil
        onChange?()
    }
}
