import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Tabs, address entry and history navigation of the selected surface.
extension BrowserWindowController {
    func openTab(url: URL? = nil) {
        guard acceptsCommands else { return }
        hideLibrary()
        session.openTab(url: url ?? URL(string: "about:blank")!)
        if url == nil { focusAddress() }
    }

    func closeSelectedTab() {
        guard acceptsCommands else { return }
        if library.isPresented { hideLibrary(); return }
        // CH-ESSENTIALS: a page with a beforeunload handler may ask to stay.
        if closeSelectedTabConfirmingWithPage() { return }
        session.closeSelectedTab()
    }

    func focusAddress() {
        guard acceptsCommands else { return }
        recordExplicitInput()
        session.performWindowAction { [weak self] in
            guard let self, !isPreparingForTermination else { return }
            hideLibrary()
            setSidebarVisible(true)
            window?.makeFirstResponder(addressField)
            addressField.currentEditor()?.selectAll(nil)
        }
    }

    func submitEnteredAddress() {
        let input = addressField.stringValue
        submitInput { $0.submitAddress(input) }
    }

    func submitAddress(_ input: String) {
        guard acceptsCommands else { return }
        let destination: AddressDestination
        do { destination = try addressResolver.resolve(input) }
        catch {
            NSSound.beep()
            focusAddress()
            return
        }
        hideLibrary()
        session.performOnSelectedSurface(createIfMissing: true) { [weak self] surface in
            surface.navigate(to: destination.url)
            self?.session.updateDestination(for: surface, to: destination.url)
            surface.focusDocument()
        }
    }

    /// Focuses the selected document through the engine, or the window when the Space is empty.
    /// The host view itself is never made first responder: it can be a plain parent view.
    func focusSelectedDocument() {
        if let surface = session.selectedSurface { surface.focusDocument() }
        else { window?.makeFirstResponder(nil) }
    }

    func addressEditingDidEnd(_ notification: Notification) {
        guard !session.isClosed else { return }
        // AppKit dispatches the Return action after ending editing. Preserve its input.
        let movement = (notification.userInfo?["NSTextMovement"] as? NSNumber)?.intValue
        guard movement != NSTextMovement.return.rawValue else { return }
        addressField.stringValue = session.selectedSurface?.navigationState.url?.absoluteString ?? ""
    }

    func navigateBack() {
        guard acceptsCommands else { return }
        hideLibrary()
        session.performOnSelectedSurface { [weak self] surface in
            if let url = surface.goBack() {
                self?.session.updateDestination(for: surface, to: url)
            }
        }
    }

    func navigateForward() {
        guard acceptsCommands else { return }
        hideLibrary()
        session.performOnSelectedSurface { [weak self] surface in
            if let url = surface.goForward() {
                self?.session.updateDestination(for: surface, to: url)
            }
        }
    }

    func reload() {
        guard acceptsCommands else { return }
        hideLibrary()
        session.performOnSelectedSurface { $0.reload() }
    }

    func refreshNavigation(for surface: Surface) {
        guard owns(surface) else { return }
        rebuildTabStrip()
        guard session.selectedSurface === surface else { return }
        refreshPageZoom()
        renderLoadingIndicator()
        renderDeveloperToolbar()
        let state = surface.navigationState
        if window?.firstResponder !== addressField.currentEditor() {
            let url = state.url ?? session.organization?.selectedTab?.url
            addressField.refreshAddress(url?.absoluteString ?? "", in: session.snapshot?.activeSpaceID)
        }
        if backButton.isEnabled != state.canGoBack { backButton.isEnabled = state.canGoBack }
        if forwardButton.isEnabled != state.canGoForward { forwardButton.isEnabled = state.canGoForward }
        if reloadButton.isEnabled != (state.url != nil) { reloadButton.isEnabled = state.url != nil }
    }
}
