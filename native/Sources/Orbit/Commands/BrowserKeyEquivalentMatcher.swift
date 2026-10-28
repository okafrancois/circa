import AppKit

/// A private AppKit menu is the authority for localization and RTL mirroring. Disabled
/// items record matching without executing browser/text actions or showing a menu.
@MainActor
final class BrowserKeyEquivalentMatcher: NSObject {
    /// A disabled probe records AppKit's enablement query after key matching. It never
    /// runs an action, so lookup has no menu flash, accessibility action or dispatch delay.
    private final class ProbeItem: NSMenuItem {
        var onMatchingQuery: (() -> Void)?
        override var isEnabled: Bool {
            get { onMatchingQuery?(); return false }
            set { }
        }
    }

    private static let mirroredKeys: Set<String> = ["[", "]", "{", "}", "(", ")", "<", ">", "\u{F702}", "\u{F703}"]
    private static let letters = CharacterSet.letters
    private static let validationBinding = BrowserShortcut(key: "q", modifiers: .command)
    private let lookupValidation: (() -> Bool)?
    private let validationLayoutEvent: () -> NSEvent?
    private(set) var nativeLookupSupported: Bool?
    private let menu = NSMenu()
    private var isMatching = false
    private(set) var unexpectedActionCount = 0
    private var bindingsByItem: [ObjectIdentifier: BrowserShortcut] = [:]
    private var matchedItem: NSMenuItem?

    init(bindings: [BrowserShortcut], lookupValidation: (() -> Bool)? = nil,
         validationLayoutEvent: @escaping () -> NSEvent? = { BrowserKeyEquivalentMatcher.layoutEvent(producing: "q", flags: .maskCommand) }) {
        self.lookupValidation = lookupValidation
        self.validationLayoutEvent = validationLayoutEvent
        super.init()
        menu.autoenablesItems = false
        for binding in Set(bindings + [Self.validationBinding]).sorted(by: { ($0.key, $0.modifiers.rawValue) < ($1.key, $1.modifiers.rawValue) }) {
            // AppKit represents an ASCII letter's Shift using its uppercase equivalent,
            // as Orbit's NIB does ("T" + Command, rather than "t" + Command+Shift).
            let shiftedLetter = binding.modifiers.contains(.shift) && binding.key.count == 1
                && binding.key.utf8.first.map { (97...122).contains($0) } == true
            let item = ProbeItem(title: "", action: #selector(unexpectedAction(_:)),
                                  keyEquivalent: shiftedLetter ? binding.key.uppercased() : binding.key)
            item.keyEquivalentModifierMask = shiftedLetter ? binding.modifiers.subtracting(.shift) : binding.modifiers
            item.allowsAutomaticKeyEquivalentLocalization = OrbitMenuTree.allowsKeyEquivalentLocalization
            item.allowsAutomaticKeyEquivalentMirroring = OrbitMenuTree.allowsKeyEquivalentMirroring
            item.target = self
            item.onMatchingQuery = { [weak self, weak item] in
                guard let self, self.isMatching else { return }
                self.matchedItem = item
            }
            bindingsByItem[ObjectIdentifier(item)] = binding
            menu.addItem(item)
        }
        _ = validateNativeLookup()
    }

    /// The disabled-item query order is an observed macOS behavior. Verify it once rather
    /// than turning a platform change into dead browser shortcuts in a shipped build. Both event
    /// origins are checked: a synthesized NSEvent, and a window-server (CGEvent-backed) event as
    /// produced by a physical keyboard or an injected key, whose disabled match AppKit reports
    /// differently (DBG-KEYS-R2).
    private func validateNativeLookup() -> Bool {
        if let supported = nativeLookupSupported { return supported }
        if let lookupValidation {
            let supported = lookupValidation()
            nativeLookupSupported = supported
            return supported
        }
        guard NSApp != nil else { return false } // Retry lazily once the application exists.
        var events: [NSEvent] = []
        if let synthetic = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "q", charactersIgnoringModifiers: "q",
            isARepeat: false, keyCode: 12) { events.append(synthetic) }
        if let hardware = validationLayoutEvent() { events.append(hardware) }
        let supported = events.count == 2
            && events.allSatisfy { nativeBindings(for: $0).contains(Self.validationBinding) }
            && unexpectedActionCount == 0
        nativeLookupSupported = supported
        return supported
    }

    /// A CGEvent-backed key event for the key producing `character` on the current layout.
    static func layoutEvent(producing character: String, flags: CGEventFlags,
                            plainEvent: (UInt16) -> NSEvent? = { code in
                                CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true).flatMap { NSEvent(cgEvent: $0) }
                            }) -> NSEvent? {
        for code in UInt16(0)...UInt16(127) {
            // Modifier virtual keys produce flagsChanged even when CGEvent requests keyDown.
            // Reading characters on those events raises an Objective-C exception.
            guard !(54...63).contains(code), let plain = plainEvent(code), plain.type == .keyDown,
                  plain.charactersIgnoringModifiers == character,
                  let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { continue }
            event.flags = flags
            return NSEvent(cgEvent: event)
        }
        return nil
    }

    @objc private func unexpectedAction(_ sender: NSMenuItem) { unexpectedActionCount += 1 }

    private func nativeBindings(for event: NSEvent) -> Set<BrowserShortcut> {
        var result: Set<BrowserShortcut> = []
        var removed: [(Int, NSMenuItem)] = []
        defer {
            for (index, item) in removed.reversed() { menu.insertItem(item, at: index) }
            matchedItem = nil
        }
        // Collect every matching declaration, not just the first menu item. Resolution of
        // scopes/conflicts remains in the registry and never depends on this menu's order.
        for _ in 0..<bindingsByItem.count {
            matchedItem = nil
            isMatching = true
            // AppKit queries `isEnabled` only on the item matching the event. For a disabled match
            // it returns true for a synthesized NSEvent but false for a window-server event (a real
            // or injected key): the query, not the return value, identifies the match. Relying on
            // the return value made every hardware lookup empty (reserved keys fell to the page,
            // Escape never closed a Peek: VIS-3, DBG-KEYS-R2).
            _ = menu.performKeyEquivalent(with: event)
            isMatching = false
            guard let item = matchedItem,
                  let binding = bindingsByItem[ObjectIdentifier(item)] else { break }
            result.insert(binding)
            let index = menu.index(of: item)
            removed.append((index, item))
            menu.removeItem(item)
        }
        return result
    }

    func matches(_ binding: BrowserShortcut, input: BrowserShortcutEvent, strictShift: Bool = true) -> Bool {
        let functionKey = binding.key.unicodeScalars.first.map { (0xF700...0xF8FF).contains($0.value) } == true
        let letterKey = !binding.key.isEmpty && binding.key.unicodeScalars.allSatisfy { Self.letters.contains($0) }
        // AppKit tolerates extra Shift for some equivalents. Preserve explicit Shift for
        // browser letters/functions (and Caps Lock), without losing glyph Shift for symbols.
        if strictShift && (functionKey || letterKey),
           binding.modifiers.contains(.shift) != input.shortcut.modifiers.contains(.shift) { return false }
        if binding.key.isASCIINumber && input.shortcut.key.isASCIINumber { return binding == input.shortcut }
        // On AZERTY the physical 6 key produces "-". Once the number row has been
        // normalized, AppKit's implicit glyph Shift must not also claim Ctrl+6 as
        // Ctrl+Shift+- (Close Split Pane), shadowing the Space shortcut.
        if input.shortcut.key.isASCIINumber { return false }
        // Tab/Backtab are layout-independent control keys. AppKit's menu probing may reserve
        // Control-Tab for key-view traversal without querying a disabled probe item.
        if binding.key == "\t" { return binding == input.shortcut }
        // Preserve explicit base-key punctuation bindings even when AppKit compares the
        // produced glyph (Ctrl+Shift+equals produces '+', Shift+Command+minus produces '_').
        // Mirrored characters must always use AppKit's result instead.
        let punctuation = !binding.key.isEmpty && binding.key.unicodeScalars.allSatisfy {
            BrowserShortcut.punctuation.contains($0)
        }
        if punctuation && !Self.mirroredKeys.contains(binding.key) && input.matches(binding) { return true }
        guard let event = input.nativeEvent, validateNativeLookup() else {
            if !strictShift && functionKey,
               binding.key == input.shortcut.key,
               binding.modifiers == input.shortcut.modifiers.subtracting(.shift) { return true }
            return input.matches(binding)
        }
        if input.nativeMatches.bindings == nil { input.nativeMatches.bindings = nativeBindings(for: event) }
        return input.nativeMatches.bindings?.contains(binding) == true
    }
}

private extension String {
    var isASCIINumber: Bool { utf8.count == 1 && utf8.first.map { (48...57).contains($0) } == true }
}
