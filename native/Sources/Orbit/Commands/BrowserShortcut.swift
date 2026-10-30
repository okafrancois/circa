import AppKit

struct BrowserShortcut: Hashable, Sendable {
    static let commandModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
    static let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
    private static let numberKeys: [UInt16: String] = [29: "0", 82: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9"]
    private static let specialKeys: [UInt16: String] = [48: "\t", 51: "\u{7f}", 53: "\u{1b}"]

    /// Plain text never needs catalog or AppKit menu lookup. Keep Escape, Tab and function
    /// keys available for overlay bindings and system menu equivalents.
    static func canRoute(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if !event.modifierFlags.intersection(commandModifiers).isEmpty { return true }
        if event.keyCode == 53 || event.keyCode == 48 { return true }
        return event.charactersIgnoringModifiers?.unicodeScalars.first.map { (0xF700...0xF8FF).contains($0.value) } == true
    }

    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        let isUppercaseASCII = key.count == 1 && key.utf8.first.map { (65...90).contains($0) } == true
        self.key = key == "\u{19}" ? "\t" : (isUppercaseASCII ? key.lowercased() : key)
        self.modifiers = modifiers.intersection([.command, .control, .option, .shift])
            .union(isUppercaseASCII ? [.shift] : [])
    }

    var displayLabel: String {
        let flags = (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
        return flags + key.uppercased()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }

    /// `unmodifiedCharacters` comes from this event's keyboard layout, not a US letter
    /// keycode table. Number shortcuts intentionally address physical number keys (including
    /// the keypad), matching the archived Orbit requirement on AZERTY as well as QWERTY.
    static func input(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                      isComposing: Bool, isRepeat: Bool, unmodifiedCharacters: String? = nil) -> BrowserShortcut? {
        guard !isComposing, let characters, !characters.isEmpty else { return nil }
        let relevant = modifiers.intersection([.command, .control, .option, .shift])
        if relevant.contains(.command) || relevant.contains(.control), let number = numberKeys[keyCode] {
            return .init(key: number, modifiers: relevant)
        }
        if let key = specialKeys[keyCode] { return .init(key: key, modifiers: relevant) }
        let base = unmodifiedCharacters.flatMap { $0.isEmpty ? nil : $0 } ?? characters
        // Arrow/function keys retain their semantic characters even if Fn is stripped.
        let isFunctionKey = characters.unicodeScalars.first.map { (0xF700...0xF8FF).contains($0.value) } == true
        let key = isFunctionKey ? characters : base.lowercased()
        // Shift is carried by flags. Caps Lock must not manufacture a Shift modifier.
        return .init(key: key, modifiers: relevant)
    }

    static func recordedInput(_ event: NSEvent) -> BrowserShortcut? {
        guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
        let key = specialKeys[event.keyCode] ?? characters.lowercased()
        return .init(key: key, modifiers: event.modifierFlags)
    }

    static func input(_ event: NSEvent, isComposing: Bool = false) -> BrowserShortcut? {
        let characters = event.charactersIgnoringModifiers
        // Letter identity is already encoded in this event's layout translation. Only
        // punctuation needs a keycode-based unshifted translation to remove glyph Shift.
        let isLetter = characters?.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) } == true
        return input(characters: characters, keyCode: event.keyCode,
                     modifiers: event.modifierFlags, isComposing: isComposing, isRepeat: event.isARepeat,
                     unmodifiedCharacters: isLetter ? characters?.lowercased() : event.characters(byApplyingModifiers: []))
    }

    @MainActor
    func matches(_ event: NSEvent) -> Bool { BrowserShortcutEvent(event)?.matches(self) == true }
}

/// Normalize once per routing phase, rather than translating the keyboard layout for every
/// candidate in the catalog. Native event references are weak; the shared cache expires
/// at the end of the event turn and never logs event text.
@MainActor
final class BrowserShortcutMatchCache {
    var bindings: Set<BrowserShortcut>?
}

private final class BrowserShortcutNativeEvent {
    weak var value: NSEvent?
    init(_ value: NSEvent) { self.value = value }
}

struct BrowserShortcutEvent {
    let shortcut: BrowserShortcut
    let glyph: String
    private let eventReference: BrowserShortcutNativeEvent
    var nativeEvent: NSEvent? { eventReference.value }
    let nativeMatches: BrowserShortcutMatchCache

    @MainActor
    init?(_ event: NSEvent, isComposing: Bool = false) {
        guard let shortcut = BrowserShortcut.input(event, isComposing: isComposing) else { return nil }
        self.shortcut = shortcut
        glyph = event.charactersIgnoringModifiers ?? ""
        eventReference = BrowserShortcutNativeEvent(event)
        nativeMatches = BrowserShortcutMatchCache()
    }

    func matches(_ binding: BrowserShortcut) -> Bool {
        if binding == shortcut { return true }
        // Only a distinct punctuation/symbol glyph may imply Shift on the active layout.
        // Shift+letters and Shift+arrows must never fall through to unshifted commands.
        guard !binding.modifiers.contains(.shift), glyph != shortcut.key,
              !glyph.isEmpty, glyph.unicodeScalars.allSatisfy({ BrowserShortcut.punctuation.contains($0) }) else { return false }
        return binding.key == glyph && shortcut.modifiers == binding.modifiers.union(.shift)
    }
}

/// Reserved browser commands run before page handlers; other commands use AppKit's page-first path.
enum BrowserShortcutPriority {
    static let reserved: Set<BrowserCommandID> = [
        .newTab, .newWindow, .newIncognitoWindow, .newQuickWindowWindow, .blankWindow,
        .archiveTab, .closeWindow, .restoreLastClosedTab, .quitOrbit, .hideOrbit, .hideOtherWindows,
        .cycleTabForward, .cycleTabBackward, .nextTab, .previousTab,
        .tabSwitcherForward, .tabSwitcherBackward, .nextSpace, .previousSpace,
        .selectSpace1, .selectSpace2, .selectSpace3, .selectSpace4, .selectSpace5,
        .selectSpace6, .selectSpace7, .selectSpace8, .selectSpace9,
        .openCommandBar
    ]

    static func isReserved(_ id: BrowserCommandID, commandScope: BrowserCommandScope) -> Bool {
        reserved.contains(id) || (commandScope != .browser && commandScope != .responder)
    }
}

/// The local monitor handles feature-owned modal input and browser-reserved commands.
/// Outside a modal gesture, NSApplication first offers a non-reserved equivalent to its focused view;
/// WebKit re-dispatches an unhandled event to AppKit's menu path. Do not manually re-send it.
@MainActor
final class BrowserCommandKeyboard {
    private var monitor: Any?
    private let dispatch: (BrowserShortcutEvent) -> Bool
    private let eventInputs: BrowserShortcutEventCache
    private let firstResponder: () -> NSResponder?
    private let rawInput: (NSEvent) -> Bool
    private let trace: BrowserKeyRoutingTrace?

    init(eventInputs: BrowserShortcutEventCache = .init(), trace: BrowserKeyRoutingTrace? = nil,
         firstResponder: @escaping () -> NSResponder? = { NSApp?.keyWindow?.firstResponder },
         rawInput: @escaping (NSEvent) -> Bool = { _ in false },
         dispatch: @escaping (BrowserShortcutEvent) -> Bool) {
        self.eventInputs = eventInputs
        self.trace = trace
        self.firstResponder = firstResponder
        self.rawInput = rawInput
        self.dispatch = dispatch
    }

    convenience init<Window>(registry: BrowserCommandRegistry<Window>, acceptsKeyboard: @escaping () -> Bool,
                             firstResponder: @escaping () -> NSResponder? = { NSApp?.keyWindow?.firstResponder }) {
        self.init(eventInputs: registry.eventInputs, trace: registry.keyTrace, firstResponder: firstResponder,
                  rawInput: { [weak registry] event in
            acceptsKeyboard() && registry?.handleInputEvent(event) == true
        }) { [weak registry] event in
            guard acceptsKeyboard(), let registry, let id = registry.resolveBinding(event),
                  registry.prefersBrowser(id) || registry.isSecondWebsiteShortcut(id, event: event) else { return false }
            // Reservation belongs to the command ID, even when a policy or an empty
            // archive disables its action. A reserved key never leaks to the document.
            let accepted = registry.dispatch(id, origin: .keyboard)
            // Auxiliary windows own their standard shortcuts (Close, New Folder, tab
            // navigation). Disabled browser reservation requires an actual browser target.
            return accepted || registry.hasBrowserCommandTarget
        }
    }

    /// Exposed for hidden event-level tests; returning false leaves the original NSEvent intact.
    func handle(_ event: NSEvent, isComposing: Bool = false) -> Bool {
        let responder = firstResponder()
        if event.type == .keyDown, let recorder = responder as? BrowserShortcutRecorderView {
            return recorder.record(event)
        }
        let composing = isComposing || (responder as? NSTextInputClient)?.hasMarkedText() == true
        // An active modal gesture owns mode keys before ordinary shortcut routing. Its
        // modifier release and outside clicks still arrive during IME composition.
        if (event.type != .keyDown || !composing), rawInput(event) {
            trace?.record("monitor", event, responder: responder, "result=raw-input")
            return true
        }
        guard BrowserShortcut.canRoute(event),
              !BrowserCommandTextInput.ownsEscape(event, responder: responder),
              let input = eventInputs.normalized(event, isComposing: composing) else {
            if event.type == .keyDown { trace?.record("monitor", event, responder: responder, "result=pass") }
            return false
        }
        let consumed = dispatch(input)
        trace?.record("monitor", event, responder: responder, consumed ? "result=reserved" : "result=page-first")
        return consumed
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .otherMouseDown]) { [weak self] event in
            // `handle` derives composition from the routed key window's first responder.
            let consumed = MainActor.assumeIsolated { self?.handle(event) == true }
            return consumed ? nil : event
        }
    }

    static func permitsCurrentMenuEvent() -> Bool {
        guard let event = NSApp?.currentEvent, event.type == .keyDown else { return true }
        let input = NSApp.keyWindow?.firstResponder as? NSTextInputClient
        return BrowserShortcut.input(event, isComposing: input?.hasMarkedText() == true) != nil
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
