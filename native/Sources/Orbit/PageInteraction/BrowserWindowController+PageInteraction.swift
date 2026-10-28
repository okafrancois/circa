import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Page-initiated surfaces of a browser window's documents (tabs and Split panes; the Peek forwards
/// its own): tab-modal JavaScript dialogs and sign-in, file choosers, external application links,
/// the page context menu, element fullscreen, unresponsive and crashed pages, page commands and the
/// beforeunload-aware tab close. Every handler re-verifies that this window holds the surface.
/// See docs/native-port/ch-essentials-2026-10-25.md.
extension BrowserWindowController {
    /// The window shows `surface` as one of its documents (tab, Split pane or Peek).
    func showsPageSurface(_ surface: Surface) -> Bool {
        guard !isPreparingForTermination else { return false }
        return session.holds(surface) || peek.owns(surface)
    }

    // MARK: Delegate: dialogs, sign-in, choosers

    func surface(_ surface: Surface, runJavaScriptDialog dialog: BrowserJavaScriptDialog) async -> BrowserJavaScriptDialogResponse {
        guard showsPageSurface(surface) else { return .suppressed }
        return await BrowserPageDialogCenter.shared.runJavaScriptDialog(
            dialog, on: surface.hostView, surface: ObjectIdentifier(surface), generation: surface.documentGeneration)
    }

    func surfaceDidResetJavaScriptDialogs(_ surface: Surface) {
        BrowserPageDialogCenter.shared.resetJavaScriptDialogs(for: ObjectIdentifier(surface),
                                                             keepingGeneration: surface.documentGeneration)
    }

    func surface(_ surface: Surface, requestsCredentialsFor challenge: BrowserAuthenticationChallenge) async -> BrowserCredential? {
        guard showsPageSurface(surface) else { return nil }
        return await BrowserPageDialogCenter.shared.requestCredentials(challenge, on: surface.hostView,
                                                                       surface: ObjectIdentifier(surface))
    }

    func surface(_ surface: Surface, runFileChooser request: BrowserFileChooserRequest) async -> [URL]? {
        guard showsPageSurface(surface) else { return nil }
        return await BrowserFileChooserPresenter.shared.run(request, on: surface.hostView, surface: ObjectIdentifier(surface))
    }

    // MARK: External application links

    /// `mailto:`, `tel:` and other application links never navigate: a confirmation over the page,
    /// then the system opens them (`BrowserExternalProtocolGate`). Called by every navigation policy
    /// of this window (tabs, Split panes, Peek).
    func handleExternalApplicationLink(_ action: BrowserNavigationAction, from surface: Surface) -> Bool {
        guard showsPageSurface(surface) else { return BrowserExternalProtocolGate.isExternal(action.url) }
        return BrowserExternalProtocolGate.shared.handle(action, hostView: surface.hostView, surface: ObjectIdentifier(surface),
                                                         pageURL: surface.navigationState.committedURL)
    }

    // MARK: Delegate: renderer

    func surface(_ surface: Surface, rendererDidTerminate termination: BrowserRendererTermination) {
        let key = ObjectIdentifier(surface)
        pageInteraction.unresponsive.remove(key)
        if pageInteraction.fullscreen?.surfaceKey == key { leaveElementFullscreenLayout() }
        guard showsPageSurface(surface) else { return }
        BrowserPageDialogCenter.shared.showCrashedPage(on: surface.hostView, surface: key, termination: termination) {
            [weak self, weak surface] in
            guard let self, let surface, self.showsPageSurface(surface) else { return }
            surface.reload()
        }
    }

    func surface(_ surface: Surface, rendererDidBecomeUnresponsive isUnresponsive: Bool) {
        let key = ObjectIdentifier(surface)
        guard isUnresponsive else {
            pageInteraction.unresponsive.remove(key)
            BrowserPageDialogCenter.shared.dismissUnresponsive(for: key)
            return
        }
        guard showsPageSurface(surface), pageInteraction.unresponsive.insert(key).inserted else { return }
        Task { [weak self, weak surface] in
            guard let surface else { return }
            let wait = await BrowserPageDialogCenter.shared.askToWaitForUnresponsivePage(on: surface.hostView, surface: key)
            guard let self, self.pageInteraction.unresponsive.remove(key) != nil, !surface.isDisposed else { return }
            try? surface.perform(wait ? .waitForUnresponsiveRenderer : .terminateUnresponsiveRenderer)
        }
    }

    /// A new document of `surface` replaces the crashed page and any dialog of the previous one
    /// (sign-in and application-link questions included, as Chromium closes them on navigation).
    func pageSurfaceDidCommit(_ surface: Surface) {
        capture.documentDidCommit(surface)
        let key = ObjectIdentifier(surface)
        BrowserPageDialogCenter.shared.hideCrashedPage(for: key)
        BrowserPageDialogCenter.shared.resetJavaScriptDialogs(for: key, keepingGeneration: surface.documentGeneration)
        BrowserPageDialogCenter.shared.dismissAll(for: key, kinds: [.authentication, .externalProtocol])
    }

    /// The window no longer shows `surface` (closed, moved): its page UI goes with it.
    func pageSurfaceDidLeave(_ surface: Surface) {
        let key = ObjectIdentifier(surface)
        if pageInteraction.fullscreen?.surfaceKey == key { leaveElementFullscreenLayout() }
        if pageInteraction.menu?.surfaceKey == key { pageInteraction.menu = nil }
        pageInteraction.unresponsive.remove(key)
        if surface.isDisposed { BrowserPageDialogCenter.shared.forget(key) }
    }

    // MARK: Delegate: element fullscreen

    /// The page's element takes the whole screen: the window enters native fullscreen (as Chromium
    /// and Orbit do), the sidebar hides, the content card goes edge to edge. A Split pane shows alone.
    func surface(_ surface: Surface, didChangeElementFullscreen isFullscreen: Bool) {
        let key = ObjectIdentifier(surface)
        if isFullscreen {
            guard showsPageSurface(surface), pageInteraction.fullscreen == nil, let window else { return }
            let native = window.styleMask.contains(.fullScreen)
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.willExitFullScreenNotification,
                                                                  object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowWillLeaveNativeFullScreen() }
            }
            pageInteraction.fullscreen = .init(surfaceKey: key, enteredNativeFullScreen: !native,
                                               sidebarWasVisible: isSidebarVisible, windowObserver: observer)
            if isSidebarVisible { setSidebarVisible(false, animated: false) }
            // A Split pane (or a document not shown as the selection) takes the card alone.
            if !peek.owns(surface), session.holds(surface),
               session.activeSplit != nil || session.selectedSurface !== surface {
                contentCard.present(surface.hostView)
            }
            if !native { toggleNativeFullScreen(window) }
        } else if pageInteraction.fullscreen?.surfaceKey == key {
            leaveElementFullscreenLayout()
        }
    }

    var elementFullscreenSurfaceKey: ObjectIdentifier? { pageInteraction.fullscreen?.surfaceKey }

    /// The user left native fullscreen while a page element was fullscreen: the page leaves too.
    private func windowWillLeaveNativeFullScreen() {
        guard let key = pageInteraction.fullscreen?.surfaceKey else { return }
        if let surface = pageSurface(for: key) { surface.exitElementFullscreen() }
        leaveElementFullscreenLayout(restoringNativeFullScreen: false)
    }

    private func pageSurface(for key: ObjectIdentifier) -> Surface? {
        session.ownedSurfaces.first(where: { ObjectIdentifier($0) == key })
            ?? peek.presentedSurface.flatMap({ ObjectIdentifier($0) == key ? $0 : nil })
    }

    func leaveElementFullscreenLayout(restoringNativeFullScreen: Bool = true) {
        guard let state = pageInteraction.fullscreen else { return }
        pageInteraction.fullscreen = nil
        if let observer = state.windowObserver { NotificationCenter.default.removeObserver(observer) }
        guard restoringNativeFullScreen else {
            if state.sidebarWasVisible { setSidebarVisible(true, animated: false) }
            renderSession()
            return
        }
        if state.sidebarWasVisible { setSidebarVisible(true, animated: false) }
        if state.enteredNativeFullScreen, let window, window.styleMask.contains(.fullScreen) { toggleNativeFullScreen(window) }
        renderSession()
    }

    /// Escape (page-first route) and the window leaving native fullscreen end element fullscreen.
    func exitElementFullscreenIfNeeded() -> Bool {
        guard let key = pageInteraction.fullscreen?.surfaceKey else { return false }
        if let surface = pageSurface(for: key) { surface.exitElementFullscreen() }
        leaveElementFullscreenLayout()
        return true
    }

    // MARK: Delegate: context menu

    func surface(_ surface: Surface, showContextMenu request: BrowserContextMenuRequest) {
        guard showsPageSurface(surface), engine.capabilities.contains(.pageContextMenus) else {
            surface.contextMenuDidClose(request)
            return
        }
        let groups = BrowserPageContextMenuModel.groups(for: request, context: pageContextMenuContext(for: surface))
        pageInteraction.menu = .init(surface: surface, surfaceKey: ObjectIdentifier(surface), request: request)
        if let observer = pageInteraction.menuObserver {
            observer(request, groups)
            return
        }
        // After the engine callback returns: AppKit's menu tracking must not run inside it.
        Task { [weak self, weak surface] in
            guard let self, let surface else { return }
            self.presentPageContextMenu(groups, request: request, surface: surface)
        }
    }

    func pageContextMenuContext(for surface: Surface) -> BrowserPageContextMenuModel.Context {
        BrowserPageContextMenuModel.Context(
            canGoBack: surface.navigationState.canGoBack, canGoForward: surface.navigationState.canGoForward,
            canPrint: engine.capabilities.contains(.printing), canInspect: engine.capabilities.contains(.devTools),
            searchEngineName: addressResolver.searchEngine.displayName)
    }

    private func presentPageContextMenu(_ groups: [[BrowserPageContextMenuModel.Item]], request: BrowserContextMenuRequest,
                                        surface: Surface) {
        guard pageInteraction.menu?.request == request, showsPageSurface(surface),
              let built = SidebarCommandHub.contextMenu(for: self, commands: groups.map { $0.map(\.command) }) else {
            closePageContextMenu(request, on: surface)
            return
        }
        let items = groups.flatMap { $0 }
        for menuItem in built.menu.items where !menuItem.isSeparatorItem {
            guard let raw = menuItem.identifier?.rawValue, let item = items.first(where: { $0.command.rawValue == raw }) else { continue }
            if let title = item.title { menuItem.title = title }
            menuItem.state = item.isChecked ? .on : .off
            menuItem.keyEquivalent = ""
            if !item.isEnabled { menuItem.isEnabled = false }
        }
        built.menu.autoenablesItems = true
        pageInteraction.menu?.owner = built.owner
        let location = NSPoint(x: request.location.x,
                               y: surface.hostView.isFlipped ? request.location.y : surface.hostView.bounds.height - request.location.y)
        let extensions = BrowserExtensionContextMenu { [weak self, weak surface] id in
            self?.performExtensionContextCommand(id, request: request, surface: surface)
        }
        extensions.append(request.extensionItems, to: built.menu)
        withExtendedLifetime(extensions) {
            built.menu.popUp(positioning: nil, at: location, in: surface.hostView)
        }
        // Commands dispatched by the menu already ran or are queued; release the native menu after.
        Task { [weak self, weak surface] in
            guard let self, let surface else { return }
            self.closePageContextMenu(request, on: surface)
        }
    }

    private func closePageContextMenu(_ request: BrowserContextMenuRequest, on surface: Surface) {
        if let menu = pageInteraction.menu, menu.request == request {
            if !menu.deliveredEngineCommand { surface.contextMenuDidClose(request) }
            pageInteraction.menu = nil
        }
    }

    func performExtensionContextCommand(_ id: Int32, request: BrowserContextMenuRequest, surface: Surface?) {
        guard let surface, showsPageSurface(surface), pageInteraction.menu?.request == request,
              pageInteraction.menu?.surfaceKey == ObjectIdentifier(surface),
              surface.documentGeneration == request.documentGeneration,
              request.extensionItems.contains(where: { $0.permits(id) }) else { return }
        do {
            try surface.performContextMenuCommand(.extensionAction(id), for: request)
            pageInteraction.menu?.deliveredEngineCommand = true
        } catch { NSSound.beep() }
    }

    /// Handler of the page context menu's registry commands, for the captured document only.
    func performPageContextCommand(_ id: BrowserCommandID) {
        guard let menu = pageInteraction.menu, let surface = menu.surface as? Surface, showsPageSurface(surface),
              surface.documentGeneration == menu.request.documentGeneration else { return }
        let request = menu.request
        if let command = BrowserPageContextCommands.engineCommand(for: id, request: request) {
            pageInteraction.menu?.deliveredEngineCommand = true
            do { try surface.performContextMenuCommand(command, for: request) } catch { NSSound.beep() }
            return
        }
        func copy(_ string: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
        switch id {
        case .pageOpenLinkInNewTab:
            if let url = request.linkURL { openPageURLInNewTab(url) }
        case .pageOpenLinkInSplitView:
            if let url = request.linkURL, canAddSplitPane { session.addSplitPane(url: url) } else { NSSound.beep() }
        case .pageCopyLinkAddress:
            if let url = request.linkURL { copy(url.absoluteString) }
        case .pageCopyEmailAddress:
            if let url = request.linkURL {
                let address = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? url.absoluteString
                copy(address.removingPercentEncoding ?? address)
            }
        case .pageOpenImageInNewTab, .pageOpenMediaInNewTab:
            if let url = request.sourceURL { openPageURLInNewTab(url) }
        case .pageCopyImageAddress, .pageCopyMediaAddress:
            if let url = request.sourceURL { copy(url.absoluteString) }
        case .pageSearchSelection:
            let text = request.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { openPageURLInNewTab(addressResolver.searchEngine.searchURL(for: text), activate: true) }
        case .pageEmojiAndSymbols:
            surface.focusDocument()
            NSApp.orderFrontCharacterPalette(nil)
        case .pageBack:
            if let url = surface.goBack() { session.updateDestination(for: surface, to: url) }
        case .pageForward:
            if let url = surface.goForward() { session.updateDestination(for: surface, to: url) }
        case .pageReload:
            surface.reload()
        case .pagePrint:
            try? surface.perform(.print)
        case .pageShare:
            if let url = request.pageURL { sharing.share(url, title: surface.navigationState.title) }
        case .pageViewSource:
            if let page = request.pageURL, let url = BrowserPageContextCommands.viewSourceURL(for: page) {
                openPageURLInNewTab(url, activate: true)
            }
        default:
            break
        }
    }

    /// New tab next to the window's tabs, in the background unless asked (Chromium: Open Link in New
    /// Tab is a background tab).
    func openPageURLInNewTab(_ url: URL, activate: Bool = false) {
        guard acceptsCommands else { return }
        session.openTab(url: url, activate: activate)
    }

    // MARK: Page commands of the menu bar

    func canPerformPageCommand(_ command: BrowserPageCommand) -> Bool {
        guard pageCommandSurface() != nil else { return false }
        switch command {
        case .print: return engine.capabilities.contains(.printing) && engine is any BrowserPagePrinting<Surface>
        case .showDevTools, .inspectElements, .closeDevTools: return engine.capabilities.contains(.devTools)
        case .terminateUnresponsiveRenderer, .waitForUnresponsiveRenderer: return false
        }
    }

    func performPageCommand(_ command: BrowserPageCommand) {
        guard acceptsCommands, let surface = pageCommandSurface() else { return }
        let generation = surface.documentGeneration
        session.performWindowAction { [weak self, weak surface] in
            guard let self, let surface, self.showsPageSurface(surface), surface.documentGeneration == generation else { return }
            do {
                if command == .print, let service = self.engine as? any BrowserPagePrinting<Surface> {
                    try service.printPage(surface)
                } else {
                    try surface.perform(command)
                }
            } catch { NSSound.beep() }
        }
    }

    var canViewPageSource: Bool {
        guard engine.capabilities.contains(.devTools), let url = pageCommandSurface()?.navigationState.committedURL else { return false }
        return BrowserPageContextCommands.canViewSource(url)
    }

    func viewPageSource() {
        guard canViewPageSource, let page = pageCommandSurface()?.navigationState.committedURL,
              let url = BrowserPageContextCommands.viewSourceURL(for: page) else { return }
        openPageURLInNewTab(url, activate: true)
    }

    // MARK: beforeunload on close

    /// ⌘W on a live document of an engine that runs beforeunload (`beforeUnloadOnClose`): the page
    /// may ask to stay ("Leave site?"). Only when the selection is settled (no queued command); the
    /// exact document then closes, never a newer selection. Otherwise the tab closes in command order.
    func closeSelectedTabConfirmingWithPage() -> Bool {
        guard engine.capabilities.contains(.beforeUnloadOnClose), !session.hasPendingCommands,
              let surface = session.selectedSurface, surface.isReady, owns(surface) else { return false }
        Task { [weak self, weak surface] in
            guard let surface else { return }
            let mayClose = await surface.confirmClose()
            guard mayClose, let self, self.acceptsCommands, !surface.isDisposed || self.session.holds(surface) else { return }
            _ = self.session.closeOwnedSurface(surface)
        }
        return true
    }
}

extension BrowserWindowController {
    /// Navigation scheme policy shared by tabs, Split panes and Peek: web documents load, other
    /// application links go to the external protocol gate, everything else is refused.
    static var webDocumentSchemes: Set<String> { ["http", "https", "about", "blob", "data", "view-source"] }
}
