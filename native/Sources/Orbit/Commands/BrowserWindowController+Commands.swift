import AppKit
import BrowserCore
import BrowserEngine

extension BrowserWindowController {
    var isTextFieldEditing: Bool { BrowserCommandTextInput.isEditing(window?.firstResponder) }

    var commandState: BrowserCommandState {
        let surface = session.selectedSurface
        let navigation = surface?.navigationState
        var state = BrowserCommandState()
        state.isAvailable = acceptsCommands && !session.isClosed
        state.isModal = window?.attachedSheet != nil
        state.hasWindow = window != nil
        state.hasSurface = surface != nil
        state.hasURL = navigation?.url != nil
        state.canGoBack = navigation?.canGoBack == true
        state.canGoForward = navigation?.canGoForward == true
        state.isLoading = navigation?.isLoading == true
        state.canReopen = session.canReopenClosedTab
        state.hasPendingCommands = session.hasPendingCommands
        state.context = BrowserCommandContext(revision: session.snapshot?.revision ?? 0,
            surface: surface.map(ObjectIdentifier.init), documentGeneration: surface?.findDocumentGeneration ?? 0,
            inputToken: explicitInputToken)
        return state
    }

    func recordAddressFieldInput(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === addressField else { return }
        recordExplicitInput()
    }

    /// Stop at this window: text actions for an unfocused captured window cannot escape to
    /// another window's responder chain. Native validation gets the actual selector.
    func commandResponder(for action: Selector, keyWindow: NSWindow? = NSApp.keyWindow) -> NSResponder? {
        guard window === keyWindow else { return nil }
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        var responder = window?.firstResponder
        while let current = responder {
            if current.responds(to: action) {
                if let validator = current as? NSUserInterfaceValidations,
                   !validator.validateUserInterfaceItem(item) { return nil }
                return current
            }
            if current === window { break }
            responder = current.nextResponder
        }
        return nil
    }
}
