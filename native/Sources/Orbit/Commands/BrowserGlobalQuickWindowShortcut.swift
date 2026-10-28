import AppKit
import Carbon.HIToolbox

/// Carbon registers a single declared chord; it requires no Accessibility/keylogging permission.
@MainActor
final class BrowserGlobalQuickWindowShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var installed: BrowserShortcut?
    var onOpen: (() -> Void)?

    func update(enabled: Bool, shortcut: BrowserShortcut?) throws {
        let requested = enabled ? shortcut : nil
        if requested == installed { return }
        guard let requested else { uninstall(); return }
        guard let code = Self.layoutEvent(for: requested)?.keyCode else { throw BrowserShortcutPreferenceError.invalidShortcut }
        var modifiers: UInt32 = 0
        if requested.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if requested.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if requested.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if requested.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<BrowserGlobalQuickWindowShortcut>.fromOpaque(context).takeUnretainedValue().onOpen?()
                }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { throw BrowserShortcutPreferenceError.unavailable }
        }
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), modifiers,
            EventHotKeyID(signature: 0x4E494153, id: 1), GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else {
            throw BrowserShortcutPreferenceError.conflict(uiText("a macOS or another app shortcut"))
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        installed = requested
    }

    static func layoutEvent(for shortcut: BrowserShortcut) -> NSEvent? {
        var flags: CGEventFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if shortcut.modifiers.contains(.control) { flags.insert(.maskControl) }
        if shortcut.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.maskShift) }
        for code in UInt16(0)...UInt16(127) where !(54...63).contains(code) {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { continue }
            event.flags = flags
            guard let native = NSEvent(cgEvent: event), BrowserShortcut.recordedInput(native) == shortcut else { continue }
            return native
        }
        return nil
    }

    func uninstall() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil; installed = nil
    }
}
