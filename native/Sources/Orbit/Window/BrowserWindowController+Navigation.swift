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
        let address = BrowserAddressPresentation(surface: session.selectedSurface)
        addressField.refreshAddress(address.value, in: session.snapshot?.activeSpaceID, presentation: address)
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
            self?.authorizeEnteredFile(destination.url, for: surface)
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
        let address = BrowserAddressPresentation(surface: session.selectedSurface)
        addressField.refreshAddress(address.value, in: session.snapshot?.activeSpaceID, presentation: address)
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
        guard session.selectedSurface === surface else { return }
        refreshPageZoom()
        renderLoadingIndicator()
        renderDeveloperToolbar()
        addressSecurityObservation.observe(surface.nativePageServices) { [weak self, weak surface] in
            guard let self, let surface, !self.isPreparingForTermination else { return }
            self.refreshNavigation(for: surface)
        }
        let state = surface.navigationState
        if window?.firstResponder !== addressField.currentEditor() {
            let address = BrowserAddressPresentation(surface: surface)
            addressField.refreshAddress(address.value, in: session.snapshot?.activeSpaceID, presentation: address)
        }
        if backButton.isEnabled != state.canGoBack { backButton.isEnabled = state.canGoBack }
        if forwardButton.isEnabled != state.canGoForward { forwardButton.isEnabled = state.canGoForward }
        if reloadButton.isEnabled != (state.url != nil) { reloadButton.isEnabled = state.url != nil }
    }
}

extension BrowserWindowController {
    func configureHistoryInteraction(_ interaction: BrowserNavigationButtonInteraction,
                                     direction: BrowserNavigationHistoryMenu.Direction, tabID: TabID? = nil) {
        interaction.makeMenu = { [weak self] in
            guard let self, acceptsCommands,
                  let surface = historySurface(tabID: tabID),
                  let history = surface.nativePageServices?.navigationHistory() else { return nil }
            let generation = surface.documentGeneration
            return BrowserNavigationHistoryMenu(history: history, direction: direction, favicon: { [weak self] url in
                self?.sidebarIcons.memoryCache.image(profile: surface.profileID, home: url)
            }, select: { [weak self, weak surface] entry, adjacent in
                self?.submitInput { controller in
                    guard let surface, controller.owns(surface), !surface.isDisposed,
                          surface.documentGeneration == generation else { return }
                    controller.routeHistoryEntry(entry, on: surface, adjacent: adjacent)
                }
            })
        }
        interaction.openAdjacent = { [weak self] in
            self?.submitInput { controller in
                guard let surface = controller.historySurface(tabID: tabID),
                      let history = surface.nativePageServices?.navigationHistory(),
                      let entry = history.entries.filter({ direction == .back
                          ? $0.index < history.currentIndex : $0.index > history.currentIndex })
                        .min(by: { abs($0.index - history.currentIndex) < abs($1.index - history.currentIndex) }) else { return }
                controller.routeHistoryEntry(entry, on: surface, adjacent: true)
            }
        }
    }

    private func historySurface(tabID: TabID?) -> Surface? {
        guard acceptsCommands else { return nil }
        let surface: Surface?
        if let tabID, let occurrence = session.organization?.tab(tabID)?.occurrenceID {
            surface = session.surface(for: occurrence)
        } else if tabID == nil { surface = session.selectedSurface }
        else { surface = nil }
        guard let surface, owns(surface), !surface.isDisposed else { return nil }
        return surface
    }

    func routeHistoryEntry(_ entry: BrowserNavigationEntry, on surface: Surface, adjacent: Bool) {
        guard acceptsCommands, owns(surface), !surface.isDisposed,
              let api = surface.nativePageServices,
              api.navigationHistory()?.entries.contains(entry) == true else { return }
        if adjacent {
            guard let occurrence = session.occurrenceID(for: surface) else { return }
            session.openNavigationTab(url: entry.url, nextTo: occurrence)
        } else if api.goToEntry(index: entry.index) {
            session.updateDestination(for: surface, to: entry.url)
        }
    }
}
