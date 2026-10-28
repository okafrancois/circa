import AppKit

/// Native text editors own Escape before ordinary browser commands; feature-owned modal
/// gestures are handled earlier by the monitor. Do not use NSTextInputClient alone: remote
/// document views also conform, and page focus must still allow closing a Peek.
@MainActor
enum BrowserCommandTextInput {
    static func isEditing(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is NSTextField
    }

    static func ownsEscape(_ event: NSEvent, responder: NSResponder?) -> Bool {
        (event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}")
            && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            && isEditing(responder)
    }
}
