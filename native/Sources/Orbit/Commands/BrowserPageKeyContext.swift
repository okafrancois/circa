import AppKit
import BrowserEngine

/// Shell state carried by a page-first key receipt. Commands run only while the
/// window, selection revision, document and focus still match.
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
