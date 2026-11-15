import AppKit

/// NSApplication reaches the menu after the key window's performKeyEquivalent path. This
/// hook therefore resolves post-page shortcuts (including supplemental commands without a
/// visible NIB item), using precisely the same event matcher as the reserved-key monitor.
@MainActor
final class BrowserKeyEquivalentMenu: NSMenu {
    /// nil preserves AppKit's native responder/system menu handling; false rejects a known
    /// disabled or shadowed binding without accidentally picking another menu item.
    var routeKeyEquivalent: ((NSEvent) -> Bool?)?
    /// Diagnostics: browser, rejected (known binding refused), native or unhandled.
    var onKeyEquivalentResult: ((NSEvent, String) -> Void)?

    /// The key event AppKit is matching against this menu's key equivalents, for the duration
    /// of that match only. Every other activation of an item (a click, Return in an open menu,
    /// an Accessibility press) runs with no matching event, whatever `NSApp.currentEvent` holds.
    private(set) static var matchingEvent: NSEvent?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let outer = Self.matchingEvent
        Self.matchingEvent = event
        defer { Self.matchingEvent = outer }
        if let handled = routeKeyEquivalent?(event) {
            onKeyEquivalentResult?(event, handled ? "browser" : "rejected")
            return handled
        }
        let handled = super.performKeyEquivalent(with: event)
        onKeyEquivalentResult?(event, handled ? "native" : "unhandled")
        return handled
    }
}
