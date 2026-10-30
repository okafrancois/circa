import AppKit
import QuartzCore
import OSLog
import BrowserCore
import BrowserEngine
import BrowserShell

private enum QuickWindowTransferTrace {
    static let signposter = OSSignposter(subsystem: "local.orbit", category: "surface-transfer")
}

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
    var archiveOpenedAt = Date()
    var externalURLKey: String?
    private(set) var isAutoArchiving = false
    let findBar = BrowserFindBarView(frame: .zero)
    let findSession = BrowserFindSession<Surface>()
    var copyURLWriter: (URL) -> Void = { url in
        BrowserLinkPasteboard.write(url)
    }
    let copiedToast = BrowserQuickWindowCopyFeedback()
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
    let copyAddressButton = BrowserQuickWindowButton()
    private var trafficLights: OrbitTrafficLights?
    let spaceButton = BrowserQuickWindowButton()
    let toolbar = BrowserQuickWindowToolbarView(frame: .zero)
    let openGroup = BrowserQuickWindowOpenGroup()
    private let page = NSView()
    private var destinationName: String
    private var resolver = AddressResolver()
    private var bindingRevision: UInt64 = 0
    private var unresponsivePageRequests: [ObjectIdentifier: UUID] = [:]
    var opensWithDocument = false
    var spaceChooser: BrowserQuickWindowSearchPanel?
    private(set) var isEditingAddress = false
    private(set) var compactInput: BrowserQuickWindowSearchPanel?
    var suggestionProvider: ((String) async -> [BrowserHistorySuggestion])?
    var inputHistory: [BrowserHistorySuggestion] = []
    var inputCandidates: [BrowserPaletteResult] = []
    private var inputQueryTask: Task<Void, Never>?
    private var inputQueryRevision = UUID()
    private var compactQuery = ""
    private let inputFavicons = BrowserPaletteFaviconCache()
    let sourceSpaceBadge = BrowserQuickWindowButton()
    let extensionsButton = BrowserQuickWindowButton()
    private var openGroupWidth: NSLayoutConstraint?
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
        // Little Circa keeps its dark chrome independently of the source Space's appearance.
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = uiText("Little Circa")
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
        guard !isClosed, promotion == nil, !isPreparingForTermination, !isAutoArchiving, destination.acceptsCommands,
              destination.engine === engine, destination.session.activeProfileID == profileID,
              let surface, !surface.isDisposed, container.owns(surface) else { return nil }
        guard engine.capabilities.contains(.liveSurfaceTransfer) else {
            // Explicit degraded mode, only when the engine cannot transfer live documents.
            // Keep Little Circa intact: reloading must never silently discard form or POST state.
            guard let url = surface.currentURL, url.absoluteString != "about:blank" else { return nil }
            destination.openTab(url: url)
            return nil
        }
        siteControls.cancelPermission()
        findSession.close()
        guard let transfer = container.release(surface, profileID: profileID,
                                               rebind: { [weak self] in self?.bind($0) }) else { return nil }
        let signposter = QuickWindowTransferTrace.signposter
        let interval = signposter.beginInterval("QuickWindowPromotion", id: signposter.makeSignpostID())
        let adoption = destination.acceptSurface(transfer, activate: true) { [weak self] in
            // The receiver has installed the live host. Do not leave an empty panel on screen
            // until the asynchronous promotion task resumes in a later display frame.
            self?.window?.animationBehavior = .none
            self?.window?.orderOut(nil)
        }
        guard transfer.state != .pending else {
            signposter.endInterval("QuickWindowPromotion", interval)
            transfer.cancel()
            return nil
        }
        siteControls.render()
        openButton.isEnabled = false
        let completion = Task<TabOccurrenceID?, Never> { [self] in
            defer { signposter.endInterval("QuickWindowPromotion", interval) }
            let result = await adoption.value
            promotion = nil
            if result != nil, transfer.state == .completed {
                self.surface = nil
                window?.close()
            } else if container.owns(surface), !isClosed {
                bind(surface)
            }
            return result
        }
        promotion = completion
        return completion
    }

    override func showWindow(_ sender: Any?) {
        if !opensWithDocument, surface?.currentURL == nil {
            showCompactInput()
        } else { super.showWindow(sender) }
    }

    func ownsCommandWindow(_ candidate: NSWindow?) -> Bool {
        candidate != nil && (candidate === window || candidate === compactInput?.window || candidate === spaceChooser?.window)
    }

    private func showCompactInput() {
        guard let input = prepareCompactInput() else { return }
        input.show(screen: window?.screen)
    }

    func prepareCompactInput() -> BrowserQuickWindowSearchPanel? {
        guard acceptsCommands, !isClosed else { return nil }
        if compactInput == nil {
            let input = BrowserQuickWindowSearchPanel(kind: .address)
            compactInput = input
            input.onCancel = { [weak self] in
                guard let self else { return }
                if isEditingAddress {
                    isEditingAddress = false
                    inputQueryTask?.cancel()
                    let restoreFocus = compactInput?.window.isKeyWindow == true
                    compactInput?.hide()
                    if restoreFocus, NSApp.activationPolicy() != .prohibited {
                        window?.makeKeyAndOrderFront(nil)
                        surface?.focusDocument()
                    }
                } else { window?.performClose(nil) }
            }
            input.onQuery = { [weak self] in self?.queryCompactInput($0) }
            input.onSubmit = { [weak self] text in
                guard let self, let url = try? resolver.resolve(text).url else { return }
                acceptCompactURL(url, typed: true)
            }
            inputFavicons.onChange = { [weak self] in self?.renderCompactInput() }
        }
        queryCompactInput(compactInput?.input.stringValue ?? "")
        return compactInput
    }

    func queryCompactInput(_ query: String) {
        compactQuery = query
        inputQueryTask?.cancel()
        inputQueryRevision = UUID()
        inputHistory = BrowserPaletteRanking.rankedHistory(inputHistory.filter {
            BrowserSuggestionText.matches(query, title: $0.title, url: $0.url)
        } + historyObserver.cachedSuggestions(for: profileID, query: query), query: query)
        renderCompactInput()
        guard let suggestionProvider else { return }
        let revision = inputQueryRevision
        inputQueryTask = Task { [weak self] in
            let history = await suggestionProvider(query)
            guard let self, !Task.isCancelled, inputQueryRevision == revision, !isClosed else { return }
            inputHistory = history
            renderCompactInput()
        }
    }

    private func renderCompactInput() {
        guard let compactInput else { return }
        let query = compactQuery
        var results = BrowserPaletteRanking.results(query: query, mode: .newTab, resolver: resolver,
            candidates: inputCandidates, history: inputHistory, actions: [], limit: 5)
        if isEditingAddress, case .page = try? resolver.resolve(query), !results.isEmpty {
            results.insert(.init(id: "search-address", title: query, detail: "", section: .search,
                                 action: .navigate(resolver.searchEngine.searchURL(for: query))), at: 1)
            results = Array(results.prefix(5))
        }
        compactInput.render(results.compactMap { result in
            guard let url = result.url else { return nil }
            let image = result.faviconReference.flatMap { inputFavicons.image(for: $0) }
                ?? OrbitIcon.image(sfName: result.symbol, pointSize: 20, accessibilityDescription: nil)
            return BrowserQuickWindowSearchRow(id: result.id, title: isEditingAddress && result.section == .address ? query : result.title,
                detail: result.section == .address || result.section == .search ? "" : BrowserSuggestionText.displayURL(url), image: image) { [weak self] in
                    self?.acceptCompactURL(url, typed: result.section == .address)
                }
        })
    }

    func acceptCompactURL(_ url: URL, typed: Bool) {
        guard acceptsCommands, (!opensWithDocument || isEditingAddress), let surface, container.owns(surface), !isClosed else { return }
        let editing = isEditingAddress
        isEditingAddress = false
        inputQueryTask?.cancel()
        let screen = compactInput?.window.screen ?? window?.screen ?? NSScreen.main
        compactInput?.hide()
        opensWithDocument = true
        if typed { historyObserver.markTypedNavigation(surface, url: url) }
        surface.navigate(to: url)
        if !editing, let screen {
            window?.setFrame(BrowserQuickWindowMetrics.frame(size: BrowserQuickWindowMetrics.initialPageSize,
                                                               visibleFrame: screen.visibleFrame), display: false)
        }
        if NSApp.activationPolicy() != .prohibited {
            super.showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            surface.focusDocument()
        }
    }

    func prepareCompactPresentation() async {
        _ = prepareCompactInput()
        await inputQueryTask?.value
        await inputFavicons.waitForPendingImages()
        renderCompactInput()
    }

    func waitForCompactSuggestions() async { await inputQueryTask?.value }

    func focusInitialContent() {
        if opensWithDocument, let surface, container.owns(surface) { surface.focusDocument() }
        else { focusAddress() }
    }

    func focusAddress() {
        if let compactInput, compactInput.window.isVisible {
            compactInput.window.makeFirstResponder(compactInput.input)
            compactInput.input.selectText(nil)
        } else if opensWithDocument, let input = prepareAddressEditing(), let window {
            if NSApp.activationPolicy() != .prohibited { input.showCentered(over: window) }
        } else { showCompactInput() }
    }

    func prepareAddressEditing() -> BrowserQuickWindowSearchPanel? {
        guard opensWithDocument, let input = prepareCompactInput() else { return nil }
        isEditingAddress = true
        input.input.stringValue = surface?.navigationState.url?.absoluteString ?? ""
        input.setEditingDocument(true)
        queryCompactInput("")
        return input
    }

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
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isPromotionInProgress && !isPreparingForTermination && !isAutoArchiving }
    func windowWillClose(_ notification: Notification) {
        if let surface, container.owns(surface) { onArchive?(surface) }
        retire()
    }

    func beginAutoArchive() -> Bool {
        guard !isClosed, !isPromotionInProgress, !isPreparingForTermination, !isAutoArchiving,
              let surface, !surface.isDisposed, container.owns(surface) else { return false }
        isAutoArchiving = true
        return true
    }

    func endAutoArchive() { isAutoArchiving = false }

    /// Only called after a successful application save, or when this synthetic owner is disposed.
    func retire() {
        guard !isClosed else { return }
        isClosed = true
        inputQueryTask?.cancel()
        copiedToast.dismiss(presentation: copiedToast.presentation)
        compactInput?.close()
        spaceChooser?.close()
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
        bar.addressField = addressField
        addressField.cursorControls = [sourceSpaceBadge, extensionsButton, copyAddressButton, openGroup]
        for view in [bar, page] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor), bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: root.topAnchor), bar.heightAnchor.constraint(equalToConstant: OrbitTokens.Metrics.QuickWindow.toolbarHeight),
            page.topAnchor.constraint(equalTo: bar.bottomAnchor), page.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: root.trailingAnchor), page.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        addressField.placeholderString = uiText("Search or Enter URL")
        addressField.font = BrandTextStyle.ui.font(size: 13, weight: .medium)
        addressField.alignment = .center
        OrbitAddressFieldStyle.applySingleLine(to: addressField)
        addressField.focusRingType = .none
        addressField.isBezeled = false
        addressField.drawsBackground = false
        addressField.wantsLayer = true
        addressField.setAccessibilityLabel(uiText("Address"))
        addressField.identifier = NSUserInterfaceItemIdentifier("little-orbit-address")
        addressField.onActivate = { [weak self] in self?.focusAddress() }
        addressField.target = self
        addressField.action = #selector(submitAddress(_:))
        openButton.isBordered = false
        openButton.font = BrandTextStyle.ui.font(size: 13, weight: .medium)
        openButton.lineBreakMode = .byTruncatingTail
        openGroup.wantsLayer = true
        openButton.target = self
        openButton.action = #selector(openInOrbit(_:))
        openButton.toolTip = uiText("Open in Circa")
        openButton.setAccessibilityLabel(uiText("Open in Circa"))
        spaceButton.image = OrbitIcon.image(sfName: "chevron.down", pointSize: 16, accessibilityDescription: uiText("Choose Space"))
        spaceButton.isBordered = false
        spaceButton.target = self
        spaceButton.action = #selector(chooseDestination(_:))
        spaceButton.setAccessibilityLabel(uiText("Choose Space"))
        copyAddressButton.image = OrbitIcon.image(sfName: "link", pointSize: 16, accessibilityDescription: uiText("Copy URL"))
        copyAddressButton.isBordered = false
        copyAddressButton.target = self
        copyAddressButton.action = #selector(copyAddress(_:))
        copyAddressButton.setAccessibilityLabel(uiText("Copy URL"))
        sourceSpaceBadge.isBordered = false
        sourceSpaceBadge.font = BrandTextStyle.ui.font(size: 12, weight: .semibold)
        sourceSpaceBadge.imagePosition = .imageLeading
        sourceSpaceBadge.target = self
        sourceSpaceBadge.action = #selector(showQuickWindowSiteControls(_:))
        sourceSpaceBadge.wantsLayer = true
        sourceSpaceBadge.layer?.cornerRadius = 10
        sourceSpaceBadge.setAccessibilityLabel(uiText("Space"))
        extensionsButton.image = OrbitIcon.image(sfName: "puzzlepiece.extension", pointSize: 16, accessibilityDescription: uiText("Extensions Menu"))
        extensionsButton.isBordered = false
        extensionsButton.target = self
        extensionsButton.action = #selector(showQuickWindowExtensions(_:))
        extensionsButton.setAccessibilityLabel(uiText("Extensions Menu"))
        for control in [addressField, openGroup, copyAddressButton, sourceSpaceBadge, extensionsButton] { control.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(control) }
        for control in [openButton, spaceButton] { control.translatesAutoresizingMaskIntoConstraints = false; openGroup.addSubview(control) }
        let groupWidth = openGroup.widthAnchor.constraint(equalToConstant: OrbitTokens.Metrics.QuickWindow.openInButtonSize.width)
        openGroupWidth = groupWidth
        NSLayoutConstraint.activate([
            sourceSpaceBadge.leadingAnchor.constraint(equalTo: addressField.leadingAnchor, constant: 8),
            sourceSpaceBadge.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
            sourceSpaceBadge.heightAnchor.constraint(equalToConstant: 24),
            sourceSpaceBadge.widthAnchor.constraint(lessThanOrEqualToConstant: 130),
            extensionsButton.trailingAnchor.constraint(equalTo: copyAddressButton.leadingAnchor, constant: -4),
            extensionsButton.centerYAnchor.constraint(equalTo: addressField.centerYAnchor),
            extensionsButton.widthAnchor.constraint(equalToConstant: 26), extensionsButton.heightAnchor.constraint(equalToConstant: 26),
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
            groupWidth,
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
        window?.appearance = NSAppearance(named: .darkAqua)
        toolbar.fill.apply(theme)
        let font = BrandTextStyle.ui.font(size: 13, weight: .medium)
        addressField.font = font
        openButton.font = font
        let accent = OrbitSpaceThemes.accent(for: theme)
        openGroup.accent = accent
        openButton.contentTintColor = OrbitFloatingMaterial.body
        spaceButton.contentTintColor = OrbitFloatingMaterial.body
        addressField.textColor = OrbitFloatingMaterial.body
        copyAddressButton.contentTintColor = OrbitFloatingMaterial.secondary
        extensionsButton.contentTintColor = OrbitFloatingMaterial.secondary
        sourceSpaceBadge.contentTintColor = OrbitFloatingMaterial.body
        sourceSpaceBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
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
        window?.title = surface?.navigationState.title ?? uiText("Little Circa")
        sourceSpaceBadge.title = sourceSpaceName
        sourceSpaceBadge.isHidden = addressField.currentEditor() != nil
        extensionsButton.isEnabled = acceptsCommands && engine.extensions != nil
        let shortcut = promotionShortcut?() ?? ""
        openButton.shortcut = shortcut
        openButton.title = engine.capabilities.contains(.liveSurfaceTransfer)
            ? uiFormat("Open in %@", destinationName) : uiText("Open a Copy in Circa")
        let labelWidth = (openButton.title as NSString).size(withAttributes: [.font: openButton.font!]).width
        openGroupWidth?.constant = ceil(labelWidth) + 76
        openButton.isEnabled = acceptsCommands && surface?.isDisposed == false
        openButton.setAccessibilityLabel(engine.capabilities.contains(.liveSurfaceTransfer)
            ? uiFormat("Open in %@", destinationName) : uiText("Open a Copy in Circa"))
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
        copyURL()
    }
    func showSpaceChooser(_ rows: [BrowserQuickWindowSearchRow]) {
        guard acceptsCommands, let window else { return }
        let chooser = spaceChooser ?? BrowserQuickWindowSearchPanel(kind: .spaces)
        spaceChooser = chooser
        chooser.onCancel = { [weak chooser] in chooser?.hide() }
        chooser.onQuery = { [weak chooser] query in
            chooser?.render(rows.filter { query.isEmpty || BrowserSuggestionText.matches(query, title: $0.title, url: nil) }, preserveSelection: false)
        }
        chooser.input.stringValue = ""
        chooser.render(rows)
        let rect = window.convertToScreen(spaceButton.convert(spaceButton.bounds, to: nil))
        if NSApp.activationPolicy() != .prohibited { chooser.show(anchor: rect, screen: window.screen) }
    }

    @objc private func showQuickWindowSiteControls(_ sender: Any?) { siteControls.show() }
    @objc private func showQuickWindowExtensions(_ sender: NSButton) {
        guard acceptsCommands, surface != nil, let host = engine.extensions else { return }
        let menu = NSMenu()
        for item in (try? host.installedExtensions(in: profileID)) ?? [] where item.isEnabled && item.hasAction {
            let entry = NSMenuItem(title: item.name, action: #selector(performQuickWindowExtension(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = item.id
            menu.addItem(entry)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: uiText("No extensions in this profile."), action: nil, keyEquivalent: "") }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc private func performQuickWindowExtension(_ sender: NSMenuItem) {
        guard acceptsCommands, let surface, let id = sender.representedObject as? String else { return }
        try? engine.extensions?.performAction(extensionID: id, on: surface, anchor: extensionsButton)
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

    // MARK: Page surfaces (CH-ESSENTIALS): shown over the Little Circa document.

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
