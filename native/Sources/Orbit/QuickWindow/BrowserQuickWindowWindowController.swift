import AppKit
import QuartzCore
import BrowserCore
import BrowserEngine
import BrowserShell

/// A transient document owner. It never creates a tab until promotion has committed.
@MainActor
final class BrowserQuickWindowWindowController<Engine: BrowserEngine>: NSWindowController, NSWindowDelegate, BrowserEngineSurfaceDelegate {
    typealias Surface = Engine.Surface
    let id = WindowID()
    let engine: Engine
    let engineEventHooks = BrowserSurfaceEventHooks<Surface>()
    let historyObserver: BrowserHistoryEngineObserver<Surface>
    lazy var siteControls = BrowserSiteControls<Engine>(owner: self)
    private(set) var isPreparingForTermination = false
    private(set) var isPromotionPreparing = false
    var isPromotionInProgress: Bool { isPromotionPreparing || promotion != nil }
    var onArchive: ((Surface) -> Void)?
    let archiveID = TabID()
    let openedAt = ContinuousClock.now
    let findBar = BrowserFindBarView(frame: .zero)
    let findSession = BrowserFindSession<Surface>()
    var copyURLWriter: (URL) -> Void = { url in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    let copiedToast = BrowserCopiedToast()
    var sharingPicker: NSSharingServicePicker?
    var promotionShortcut: (() -> String?)?

    let sourceSpaceID: SpaceID
    let profileID: ProfileID
    private(set) var sourceSpaceName: String
    let container = BrowserSurfaceContainer<Surface>()
    private(set) var surface: Surface?
    private(set) var isClosed = false
    private(set) var promotion: Task<TabOccurrenceID?, Never>?
    var onClose: (() -> Void)?
    var onPromote: (() -> Void)?
    var onChooseSpace: (() -> Void)?
    var onNewTarget: ((Surface, BrowserNewSurfaceRequest, () -> Surface) -> Surface?)?
    var onDownload: ((Surface, any BrowserEngineDownload) -> Void)?
    let addressField = BrowserQuickWindowAddressField()
    let openButton = BrowserQuickWindowOpenButton()
    let copyAddressButton = NSButton()
    private var trafficLights: OrbitTrafficLights?
    let spaceButton = NSButton()
    let toolbar = BrowserQuickWindowToolbarView(frame: .zero)
    let openGroup = BrowserQuickWindowOpenGroup()
    private let page = NSView()
    private var destinationName: String
    private var resolver = AddressResolver()
    private var bindingRevision: UInt64 = 0
    private var unresponsivePageRequests: [ObjectIdentifier: UUID] = [:]
    private var opensWithDocument = false
    private let inputToken = UUID()

    init(engine: Engine, spaceID: SpaceID, profileID: ProfileID, spaceName: String,
         rescue: BrowserSurfaceContainer<Surface>, searchEngine: SearchEngine, history: BrowserHistoryRecorder) {
        self.engine = engine
        historyObserver = BrowserHistoryEngineObserver(recorder: history, resolveProfile: engine.profile(for:))
        sourceSpaceID = spaceID
        self.profileID = profileID
        sourceSpaceName = spaceName
        destinationName = spaceName
        resolver.searchEngine = searchEngine
        let window = BrowserQuickWindowPanel(contentRect: NSRect(origin: .zero, size: OrbitTokens.Metrics.QuickWindow.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = uiText("Little Orbit")
        window.identifier = NSUserInterfaceItemIdentifier("orbit-little-orbit")
        window.minSize = OrbitTokens.Metrics.QuickWindow.minimumSize
        window.level = .normal
        window.hidesOnDeactivate = false
        super.init(window: window)
        container.rescueContainer = rescue
        window.delegate = self
        configureContent()
        if let root = window.contentView { installPageTools(in: root) }
        historyObserver.install(in: engineEventHooks)
        siteControls.install()
        engine.shellWindowDidOpen(id, window: window)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func load(_ url: URL?) {
        guard !isClosed, surface == nil else { return }
        let created = engine.makeSurface(profileID: profileID, delegate: self)
        guard container.claim(created) else { created.dispose(); return }
        surface = created
        opensWithDocument = url != nil
        bind(created)
        if let url {
            BrowserNavigationPolicy.authorizeLocalDocument(url, for: created)
            created.navigate(to: url)
        }
    }

    /// Used for native new targets: the original request, body and opener stay in the engine.
    func adoptNewTarget(_ created: Surface) -> Bool {
        guard !isClosed, surface == nil, created.profileID == profileID, container.claim(created) else { return false }
        surface = created
        opensWithDocument = true
        bind(created)
        return true
    }

    func bind(_ document: Surface) {
        guard container.owns(document), !isClosed else { return }
        bindingRevision &+= 1
        document.delegate = self
        document.placement = .init(container: .quickWindow, windowID: id)
        document.onChange = { [weak self, weak document] in
            guard let self, let document, container.owns(document) else { return }
            render()
            engineEventHooks.emit(.stateChanged, for: document)
        }
        document.onDispose = { [weak self, weak document] in
            if let document {
                let key = ObjectIdentifier(document)
                self?.unresponsivePageRequests.removeValue(forKey: key)
                BrowserPageDialogCenter.shared.forget(key)
            }
            self?.render()
        }
        attach(document)
        findSession.select(document)
        render()
        siteControls.render()
    }

    private func attach(_ document: Surface) {
        page.subviews.forEach { $0.removeFromSuperview() }
        let host = document.hostView
        host.removeFromSuperview()
        host.frame = page.bounds
        host.autoresizingMask = [.width, .height]
        page.addSubview(host)
    }

    /// Close only after adoption commits. Both synchronous refusal and asynchronous recording
    /// failure restore this same document, binding and host. No fallback is used on failure.
    @discardableResult
    func promote(to destination: BrowserWindowController<Engine>) -> Task<TabOccurrenceID?, Never>? {
        guard !isClosed, promotion == nil, !isPreparingForTermination, destination.acceptsCommands,
              destination.engine === engine, destination.session.activeProfileID == profileID,
              let surface, !surface.isDisposed, container.owns(surface) else { return nil }
        guard engine.capabilities.contains(.liveSurfaceTransfer) else {
            // Explicit degraded mode, only when the engine cannot transfer live documents.
            // Keep Little Orbit intact: reloading must never silently discard form or POST state.
            guard let url = surface.currentURL, url.absoluteString != "about:blank" else { return nil }
            destination.openTab(url: url)
            return nil
        }
        siteControls.cancelPermission()
        findSession.close()
        guard let transfer = container.release(surface, profileID: profileID,
                                               rebind: { [weak self] in self?.bind($0) }) else { return nil }
        let adoption = destination.acceptSurface(transfer, activate: true)
        guard transfer.state != .pending else { transfer.cancel(); return nil }
        siteControls.render()
        openButton.isEnabled = false
        let completion = Task<TabOccurrenceID?, Never> { [self] in
            let result = await adoption.value
            promotion = nil
            if result != nil, transfer.state == .completed {
                self.surface = nil
                // Orbit's model handoff retires the panel immediately. Order it out before
                // close so AppKit does not add a separate panel-dismissal fade.
                window?.orderOut(nil)
                window?.close()
            } else if container.owns(surface), !isClosed {
                bind(surface)
            }
            return result
        }
        promotion = completion
        return completion
    }

    func focusInitialContent() {
        if opensWithDocument, let surface, container.owns(surface) { surface.focusDocument() }
        else { focusAddress() }
    }

    func focusAddress() { window?.makeFirstResponder(addressField); addressField.selectText(nil) }

    @discardableResult
    func beginPromotionPreparation() -> Bool {
        guard acceptsCommands else { return false }
        isPromotionPreparing = true
        siteControls.cancelPermission()
        render()
        return true
    }
    func endPromotionPreparation() { isPromotionPreparing = false; render() }
    func freezeForTermination() {
        isPreparingForTermination = true
        siteControls.cancelPermission()
        surface?.stopLoading()
        render()
    }
    func cancelTerminationPreparation() {
        isPreparingForTermination = false
        surface?.cancelStoppedNavigationTracking()
        render()
    }
    private func reapplyTrafficLightsAfterWindowLayout() {
        trafficLights?.reapply(isFullScreen: window?.styleMask.contains(.fullScreen) == true)
        // AppKit lays out its title-bar container again after delegate notifications. Apply the
        // same geometry once that pass ends so the transparent container cannot cover the bar.
        DispatchQueue.main.async { [weak self] in
            guard let self, !isClosed else { return }
            trafficLights?.reapply(isFullScreen: window?.styleMask.contains(.fullScreen) == true)
        }
    }
    func windowDidResize(_ notification: Notification) { reapplyTrafficLightsAfterWindowLayout() }
    func windowDidBecomeKey(_ notification: Notification) { reapplyTrafficLightsAfterWindowLayout() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isPromotionInProgress && !isPreparingForTermination }
    func windowWillClose(_ notification: Notification) {
        if let surface, container.owns(surface) { onArchive?(surface) }
        retire()
    }

    /// Only called after a successful application save, or when this synthetic owner is disposed.
    func retire() {
        guard !isClosed else { return }
        isClosed = true
        siteControls.cancelPermission()
        findSession.shutdown()
        container.close()
        surface = nil
        engine.shellWindowWillClose(id)
        onClose?()
        onClose = nil
    }

    private func configureContent() {
        guard let littleWindow = window else { return }
        let root = OrbitWindowRootView(frame: littleWindow.contentView?.bounds ?? .zero)
        root.onLayout = { [weak self] in
            guard let self else { return }
            trafficLights?.reapply(isFullScreen: self.window?.styleMask.contains(.fullScreen) == true)
        }
        littleWindow.contentView = root
        let bar = toolbar
        for view in [bar, page] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: root.topAnchor), bar.heightAnchor.constraint(equalToConstant: OrbitTokens.Metrics.QuickWindow.toolbarHeight),
            page.topAnchor.constraint(equalTo: bar.bottomAnchor), page.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: root.trailingAnchor), page.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        addressField.placeholderString = uiText("Search or Enter URL")
        addressField.font = OrbitTokens.Typography.quickWindowDomain
        addressField.alignment = .center
        OrbitAddressFieldStyle.applySingleLine(to: addressField)
        addressField.focusRingType = .none
        addressField.isBezeled = false
        addressField.drawsBackground = false
        addressField.wantsLayer = true
        addressField.setAccessibilityLabel(uiText("Address"))
        addressField.identifier = NSUserInterfaceItemIdentifier("little-orbit-address")
        addressField.target = self
        addressField.action = #selector(submitAddress(_:))
        openButton.isBordered = false
        openButton.font = OrbitTokens.Typography.quickWindowDomain
        openButton.lineBreakMode = .byTruncatingTail
        openGroup.wantsLayer = true
        openButton.target = self
        openButton.action = #selector(openInOrbit(_:))
        openButton.toolTip = uiText("Open in Orbit")
        openButton.setAccessibilityLabel(uiText("Open in Orbit"))
        spaceButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: uiText("Choose Space"))
        spaceButton.isBordered = false
        spaceButton.target = self
        spaceButton.action = #selector(chooseDestination(_:))
        spaceButton.setAccessibilityLabel(uiText("Choose Space"))
        copyAddressButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: uiText("Copy URL"))
        copyAddressButton.isBordered = false
        copyAddressButton.target = self
        copyAddressButton.action = #selector(copyAddress(_:))
        copyAddressButton.setAccessibilityLabel(uiText("Copy URL"))
        for control in [addressField, openGroup, copyAddressButton] { control.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(control) }
        for control in [openButton, spaceButton] { control.translatesAutoresizingMaskIntoConstraints = false; openGroup.addSubview(control) }
        NSLayoutConstraint.activate([
            addressField.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: OrbitTokens.Metrics.QuickWindow.addressLeadingInset),
            addressField.centerYAnchor.constraint(equalTo: bar.topAnchor, constant: OrbitTokens.Metrics.QuickWindow.addressPillCenterY),
            addressField.heightAnchor.constraint(equalToConstant: OrbitTokens.Metrics.QuickWindow.addressPillHeight),
            addressField.trailingAnchor.constraint(equalTo: openGroup.leadingAnchor, constant: -OrbitTokens.Metrics.QuickWindow.controlGap),
            copyAddressButton.widthAnchor.constraint(equalToConstant: 26),
            copyAddressButton.heightAnchor.constraint(equalToConstant: 26),
            copyAddressButton.trailingAnchor.constraint(equalTo: addressField.trailingAnchor, constant: -3),
            copyAddressButton.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
            openGroup.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
            openGroup.heightAnchor.constraint(equalToConstant: OrbitTokens.Metrics.QuickWindow.openInButtonSize.height),
            openGroup.widthAnchor.constraint(equalToConstant: OrbitTokens.Metrics.QuickWindow.openInButtonSize.width),
            openGroup.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -OrbitTokens.Metrics.QuickWindow.trailingInset),
            openButton.leadingAnchor.constraint(equalTo: openGroup.leadingAnchor), openButton.topAnchor.constraint(equalTo: openGroup.topAnchor),
            openButton.bottomAnchor.constraint(equalTo: openGroup.bottomAnchor), openButton.trailingAnchor.constraint(equalTo: spaceButton.leadingAnchor),
            spaceButton.widthAnchor.constraint(equalToConstant: OrbitTokens.Metrics.QuickWindow.disclosureWidth),
            spaceButton.topAnchor.constraint(equalTo: openGroup.topAnchor), spaceButton.bottomAnchor.constraint(equalTo: openGroup.bottomAnchor),
            spaceButton.trailingAnchor.constraint(equalTo: openGroup.trailingAnchor)
        ])
        if let window {
            let lights = OrbitTrafficLights(window: window)
            trafficLights = lights
            let centers = (0..<3).map { index in
                CGPoint(x: OrbitTokens.Metrics.Window.quickWindowTrafficLightFirstCenterX + CGFloat(index) * lights.pitch,
                        y: OrbitTokens.Metrics.Window.quickWindowTrafficLightCenterY)
            }
            lights.apply(centers: centers, visible: true, isFullScreen: false)
        }
        render()
    }

    func applyPreferences(searchEngine: SearchEngine, theme: OrbitTokens.SpaceTheme) {
        resolver.searchEngine = searchEngine
        window?.appearance = OrbitAppearance.windowAppearance(for: theme.mode)
        toolbar.fill.apply(theme)
        let accent = OrbitSpaceThemes.accent(for: theme)
        openGroup.accent = accent
        openButton.contentTintColor = accent.sidebarText
        spaceButton.contentTintColor = accent.sidebarText
        addressField.textColor = accent.sidebarText
        copyAddressButton.contentTintColor = accent.sidebarText.withAlphaComponent(0.55)
    }

    func updateDestinationName(_ name: String, sourceName: String) {
        sourceSpaceName = sourceName
        destinationName = name
        render()
    }

    func render() {
        if addressField.currentEditor() == nil {
            addressField.stringValue = surface?.navigationState.url?.absoluteString ?? ""
        }
        window?.title = surface?.navigationState.title ?? uiText("Little Orbit")
        let shortcut = promotionShortcut?() ?? ""
        openButton.shortcut = shortcut
        openButton.title = engine.capabilities.contains(.liveSurfaceTransfer)
            ? uiFormat("Open in %@", destinationName) : uiText("Open a Copy in Orbit")
        openButton.isEnabled = acceptsCommands && surface?.isDisposed == false
        openButton.setAccessibilityLabel(engine.capabilities.contains(.liveSurfaceTransfer)
            ? uiFormat("Open in %@", destinationName) : uiText("Open a Copy in Orbit"))
        openButton.toolTip = shortcut.isEmpty ? uiFormat("Open in %@", destinationName) : uiFormat("Open in %@ (%@)", destinationName, shortcut)
    }

    @objc private func submitAddress(_ sender: NSTextField) {
        guard acceptsCommands, !isClosed, promotion == nil, let surface, container.owns(surface),
              let url = try? resolver.resolve(sender.stringValue).url else { return }
        historyObserver.markTypedNavigation(surface, url: url)
        surface.navigate(to: url)
        surface.focusDocument()
    }
    @objc private func copyAddress(_ sender: Any?) {
        if let url = surface?.currentURL { copyURLWriter(url) }
    }
    @objc private func openInOrbit(_ sender: Any?) { onPromote?() }
    @objc private func chooseDestination(_ sender: Any?) { onChooseSpace?() }

    private var pageKeyContext: BrowserCommandContext? {
        guard let surface, container.owns(surface), !isClosed else { return nil }
        return .init(revision: bindingRevision, surface: ObjectIdentifier(surface),
                     documentGeneration: surface.documentGeneration, inputToken: inputToken)
    }

    func surface(_ surface: Surface, willSendKeyToPage event: NSEvent) -> BrowserKeyRouting {
        guard container.owns(surface), let context = pageKeyContext else { return .page(receipt: nil) }
        return .page(receipt: BrowserKeyReceipt(context: BrowserPageKeyContext(windowID: id.rawValue, context: context)))
    }

    func surface(_ surface: Surface, pageDidNotHandleKey event: NSEvent, receipt: BrowserKeyReceipt) -> Bool {
        let responder = window?.firstResponder as? NSView
        guard BrowserPageKeyContext.accepts(receipt, windowID: id.rawValue, current: pageKeyContext,
            isKeyWindow: window?.isKeyWindow == true, isSelected: container.owns(surface),
            focusInsideDocument: responder?.isDescendant(of: surface.hostView) == true) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    private func emit(_ event: BrowserSurfaceEvent, surface: Surface) {
        guard !isClosed, container.owns(surface) else { return }
        render()
        engineEventHooks.emit(event, for: surface)
    }
    func surfaceDidStartNavigation(_ surface: Surface) { emit(.navigationStarted, surface: surface) }
    func surfaceDidCommitNavigation(_ surface: Surface) {
        if owns(surface) {
            findSession.documentDidChange(on: surface)
            let key = ObjectIdentifier(surface)
            BrowserPageDialogCenter.shared.hideCrashedPage(for: key)
            BrowserPageDialogCenter.shared.resetJavaScriptDialogs(for: key, keepingGeneration: surface.documentGeneration)
            unresponsivePageRequests.removeValue(forKey: key)
            BrowserPageDialogCenter.shared.dismissAll(for: key, kinds: [.authentication, .externalProtocol, .unresponsive])
        }
        emit(.navigationCommitted, surface: surface)
    }
    func surfaceDidFinishNavigation(_ surface: Surface) { emit(.navigationFinished, surface: surface) }
    func surfaceDidFailNavigation(_ surface: Surface) { emit(.navigationFailed, surface: surface) }
    func surface(_ surface: Surface, didNavigateWithinDocument navigation: BrowserSameDocumentNavigation) {
        emit(.navigatedWithinDocument(navigation.kind), surface: surface)
    }
    func surface(_ surface: Surface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        let held = !isClosed && !isPreparingForTermination && container.owns(surface)
        if held, BrowserExternalProtocolGate.shared.handle(action, hostView: surface.hostView,
            surface: ObjectIdentifier(surface), pageURL: surface.navigationState.committedURL) {
            decision.decide(.cancel)
            return
        }
        decision.decide(BrowserNavigationPolicy.action(action, surface: surface,
            held: !isClosed && !isPreparingForTermination && container.owns(surface),
            routesEnabled: acceptsCommands, hooks: engineEventHooks,
            extensionDocuments: engine.capabilities.contains(.extensionDocuments)))
    }
    func surface(_ surface: Surface, decidePolicyFor response: BrowserNavigationResponse,
                 decision: BrowserPolicyDecision<BrowserNavigationResponsePolicy>) {
        decision.decide(BrowserNavigationPolicy.response(response, surface: surface,
            held: !isClosed && !isPreparingForTermination && container.owns(surface),
            extensionDocuments: engine.capabilities.contains(.extensionDocuments)))
    }

    // MARK: Page surfaces (CH-ESSENTIALS): shown over the Little Orbit document.

    private func showsPage(_ surface: Surface) -> Bool { !isClosed && container.owns(surface) }

    func surface(_ surface: Surface, runJavaScriptDialog dialog: BrowserJavaScriptDialog) async -> BrowserJavaScriptDialogResponse {
        guard showsPage(surface) else { return .suppressed }
        return await BrowserPageDialogCenter.shared.runJavaScriptDialog(
            dialog, on: surface.hostView, surface: ObjectIdentifier(surface), generation: surface.documentGeneration)
    }

    func surfaceDidResetJavaScriptDialogs(_ surface: Surface) {
        BrowserPageDialogCenter.shared.resetJavaScriptDialogs(for: ObjectIdentifier(surface),
                                                             keepingGeneration: surface.documentGeneration)
    }

    func surface(_ surface: Surface, requestsCredentialsFor challenge: BrowserAuthenticationChallenge) async -> BrowserCredential? {
        guard showsPage(surface) else { return nil }
        return await BrowserPageDialogCenter.shared.requestCredentials(challenge, on: surface.hostView, surface: ObjectIdentifier(surface))
    }

    func surface(_ surface: Surface, runFileChooser request: BrowserFileChooserRequest) async -> [URL]? {
        guard showsPage(surface) else { return nil }
        return await BrowserFileChooserPresenter.shared.run(request, on: surface.hostView, surface: ObjectIdentifier(surface))
    }

    func surface(_ surface: Surface, rendererDidTerminate termination: BrowserRendererTermination) {
        guard showsPage(surface) else { return }
        BrowserPageDialogCenter.shared.showCrashedPage(on: surface.hostView, surface: ObjectIdentifier(surface),
                                                       termination: termination) { [weak surface] in
            guard let surface, !surface.isDisposed else { return }
            surface.reload()
        }
    }

    func surface(_ surface: Surface, rendererDidBecomeUnresponsive isUnresponsive: Bool) {
        let key = ObjectIdentifier(surface)
        guard isUnresponsive else {
            unresponsivePageRequests.removeValue(forKey: key)
            BrowserPageDialogCenter.shared.dismissUnresponsive(for: key)
            return
        }
        guard showsPage(surface), unresponsivePageRequests[key] == nil else { return }
        let request = UUID()
        unresponsivePageRequests[key] = request
        Task { [weak self, weak surface] in
            guard let self, let surface, self.unresponsivePageRequests[key] == request,
                  self.showsPage(surface), !surface.isDisposed else { return }
            let wait = await BrowserPageDialogCenter.shared.askToWaitForUnresponsivePage(on: surface.hostView, surface: key)
            guard self.unresponsivePageRequests[key] == request, !surface.isDisposed, surface.isReady else { return }
            self.unresponsivePageRequests.removeValue(forKey: key)
            try? surface.perform(wait ? .waitForUnresponsiveRenderer : .terminateUnresponsiveRenderer)
        }
    }

    /// A reduced page menu: page commands of the document and Copy Link/Image Address. Commands that
    /// need a browser window (new tab, Split View, search, view source) are not offered here.
    func surface(_ surface: Surface, showContextMenu request: BrowserContextMenuRequest) {
        guard showsPage(surface), engine.capabilities.contains(.pageContextMenus) else {
            surface.contextMenuDidClose(request)
            return
        }
        let context = BrowserPageContextMenuModel.Context(
            canGoBack: surface.navigationState.canGoBack, canGoForward: surface.navigationState.canGoForward,
            canPrint: false, canInspect: engine.capabilities.contains(.devTools))
        let windowOnly: Set<BrowserCommandID> = [.pageOpenLinkInNewTab, .pageOpenLinkInSplitView, .pageOpenImageInNewTab,
                                                 .pageOpenMediaInNewTab, .pageSearchSelection, .pageViewSource]
        let groups = BrowserPageContextMenuModel.groups(for: request, context: context)
            .map { $0.filter { !windowOnly.contains($0.command) } }.filter { !$0.isEmpty }
        Task { [weak self, weak surface] in
            guard let self, let surface, self.showsPage(surface) else { surface?.contextMenuDidClose(request); return }
            let menu = BrowserQuickWindowPageMenu(groups: groups) { [weak self, weak surface] id in
                guard let self, let surface, self.showsPage(surface) else { return false }
                return self.performPageMenuCommand(id, request: request, on: surface)
            }
            menu.extensionItems = request.extensionItems
            menu.performExtension = { [weak self, weak surface] id in
                guard let self, let surface, showsPage(surface),
                      surface.documentGeneration == request.documentGeneration,
                      request.extensionItems.contains(where: { $0.permits(id) }) else { return false }
                do { try surface.performContextMenuCommand(.extensionAction(id), for: request); return true }
                catch { return false }
            }
            let delivered = menu.popUp(at: request.location, in: surface.hostView)
            if !delivered { surface.contextMenuDidClose(request) }
        }
    }

    /// True when a page command went to the engine (it then releases its native menu itself).
    private func performPageMenuCommand(_ id: BrowserCommandID, request: BrowserContextMenuRequest, on surface: Surface) -> Bool {
        if let command = BrowserPageContextCommands.engineCommand(for: id, request: request) {
            do { try surface.performContextMenuCommand(command, for: request) } catch { NSSound.beep() }
            return true
        }
        let copied: String? = switch id {
        case .pageCopyLinkAddress, .pageCopyEmailAddress: request.linkURL?.absoluteString
        case .pageCopyImageAddress, .pageCopyMediaAddress: request.sourceURL?.absoluteString
        default: nil
        }
        if let copied {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copied, forType: .string)
        }
        switch id {
        case .pageBack: _ = surface.goBack()
        case .pageForward: _ = surface.goForward()
        case .pageReload: surface.reload()
        case .pageShare:
            if let url = request.pageURL { shareURL(url) }
        case .pageEmojiAndSymbols: surface.focusDocument(); NSApp.orderFrontCharacterPalette(nil)
        default: break
        }
        return false
    }
    func surface(_ surface: Surface, createSurfaceFor request: BrowserNewSurfaceRequest, make: () -> Surface) -> Surface? {
        guard !isClosed, container.owns(surface) else { return nil }
        return onNewTarget?(surface, request, make)
    }
    func surfaceDidRequestClose(_ surface: Surface) { if container.owns(surface) { window?.performClose(nil) } }
    func surfaceDidRequestActivation(_ surface: Surface) {
        guard acceptsCommands, container.owns(surface), window?.isVisible == true || window?.isMiniaturized == true,
              window?.isKeyWindow != true else { return }
        window?.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func surface(_ surface: Surface, didStartDownload download: any BrowserEngineDownload) {
        guard !isClosed, container.owns(surface), let onDownload else { download.cancel(); return }
        onDownload(surface, download)
    }
}
