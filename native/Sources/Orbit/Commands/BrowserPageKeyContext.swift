import AppKit
import BrowserEngine

/// The shell state a page-first key would target, carried by its `BrowserKeyReceipt`
/// (BL-CONTRACT-KEY-RECEIPT, proposal of `docs/native-port/shortcuts.md`, "Routage clavier
/// CMD-R2"). It is compared, not trusted: the command runs only for the same window, selection
/// revision, document and focus.
struct BrowserPageKeyContext {
    let windowID: UUID
    let context: BrowserCommandContext

    /// Consumes `receipt` and tells whether its key may still run its command now. A receipt is
    /// accepted once; a foreign, replaced or revoked context refuses.
    @MainActor
    static func accepts(_ receipt: BrowserKeyReceipt, windowID: UUID, current: BrowserCommandContext?,
                        isKeyWindow: Bool, isSelected: Bool, focusInsideDocument: Bool) -> Bool {
        guard receipt.consume(), let captured = receipt.context as? BrowserPageKeyContext,
              captured.windowID == windowID, isKeyWindow, isSelected, focusInsideDocument else { return false }
        return BrowserCommandTarget(windowID: windowID, context: captured.context, policy: .document).matches(current)
    }
}
