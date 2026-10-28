import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

extension BrowserWindowController {
    // MARK: Installation

    func installPeek(in root: NSView) {
        let overlay = peek.overlay
        overlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: root.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        overlay.contentAnchor = contentCard
        overlay.scrimCornerRadius = 10
        overlay.onClose = { [weak self] in self?.submitInput { $0.dismissPeek() } }
        overlay.onClickOutside = { [weak self] in self?.submitInput { $0.dismissPeek() } }
        overlay.onOpenInTab = { [weak self] in self?.submitInput { $0.promotePeekToTab() } }
        overlay.onOpenInSplit = { [weak self] in self?.submitInput { $0.openPeekInSplit() } }
        overlay.onPresentationStart = { [weak self] in
            guard let self else { return }
            contentCard.setPeekDimmed(true, animated: window?.isVisible == true)
        }

        peek.windowID = { [weak self] in self?.session?.snapshot?.id }
        peek.sourceClassifier = { [weak self] occurrenceID in self?.peekSourceClassification(for: occurrenceID) }
        peek.onStateChange = { [weak self] in
            if self?.peek.isPresented == true { self?.sidebar.spaceSwipe.cancel() }
            if let self, !peek.isPresented, peek.handoffTask == nil {
                contentCard.setPeekDimmed(false, animated: window?.isVisible == true)
            }
            self?.peek.refreshToolbar()
            self?.refreshPageZoom()
        }
        peek.onEngineEvent = { [weak self] surface, event in self?.peekSurfaceEvent(event, on: surface) }
        peek.onSurfaceDispose = { [weak self] surface in
            self?.findSession.retire(surface)
            self?.pageSurfaceDidLeave(surface)
            self?.renderPeekPageTools()
        }
        peek.onCloseRequest = { [weak self] in self?.dismissPeek() }
        peek.onNewTarget = { [weak self] _, request, make in self?.adoptNewTargetFromPeek(request, make: make) }
        peek.onDownload = { [weak self] surface, download, presentation in
            self?.adoptPeekDownload(download, from: surface, presentation: presentation) ?? download.cancel()
        }
        peek.pageDelegate = self
        peek.onExternalLink = { [weak self] surface, action in _ = self?.handleExternalApplicationLink(action, from: surface) }
        peek.allowsExtensionDocuments = engine.capabilities.contains(.extensionDocuments)
        peek.onPermission = { [weak self] surface, request in
            // Attributed to this window, as for its tabs (SITE implements the decision).
            await self?.surface(surface, requestsPermission: request) ?? .deny
        }
        engineEventHooks.routeNewTargets { [weak self] source, request, make in
            self?.routeNewTargetToPeek(from: source, request: request, make: make) ?? .declined
        }
        engineEventHooks.routeNavigations { [weak self] source, action in
            self?.routeNavigationToPeek(from: source, action: action) ?? .declined
        }
        let center = NotificationCenter.default
        peek.retain(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.peek.close() }
        })
        // The command bar and address entry replace the Peek (prototype: palette closes Peek).
        peek.retain(center.addObserver(forName: NSControl.textDidBeginEditingNotification, object: addressField, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissPeek() }
        })
    }

    var isPeekPresented: Bool { peek.isPresented }
    var presentedPeekSurface: Surface? { peek.presentedSurface }

    // MARK: Page focus

    /// The page that page commands (find, zoom, reload, back/forward, copy URL) act on: the Peek
    /// document while it has focus, otherwise the selected tab. Focus in the find bar or the Peek
    /// toolbar keeps the page that last had it.
    func pageCommandSurface() -> Surface? {
        if library.isPresented { return peek.presentedSurface }
        guard let peekSurface = peek.presentedSurface else { return session.selectedSurface }
        if let responder = window?.firstResponder as? NSView {
            if responder.isDescendant(of: peek.overlay) {
                peek.pageFocus = .peek
            } else if let tab = session.selectedSurface, responder.isDescendant(of: tab.hostView) {
                peek.pageFocus = .tab
            }
        }
        return peek.pageFocus == .peek ? peekSurface : session.selectedSurface
    }

    /// Documents whose permission requests this window decides: the selected tab, and the
    /// presented Peek document of the same profile, owned by this window's Peek container.
    func isSitePermissionTarget(_ surface: Surface) -> Bool {
        guard !surface.isDisposed else { return false }
        if owns(surface) { return session.selectedSurface === surface }
        return peek.presentedSurface === surface && peek.owns(surface)
            && surface.profileID == session.activeProfileID
    }

    var isPeekPageFocused: Bool {
        guard let peekSurface = peek.presentedSurface else { return false }
        return pageCommandSurface() === peekSurface
    }

    /// The find bar searching a Peek document sits in the Peek card, never under it.
    func placeFindBar(for page: Surface) {
        if page === peek.presentedSurface {
            placeFindBar(in: peek.overlay, over: peek.overlay.pageArea)
        } else if let home = peek.overlay.superview ?? contentCard.superview {
            placeFindBar(in: home, over: contentCard)
        }
    }

    /// Find and zoom follow the focused page when a Peek appears, closes or leaves.
    func renderPeekPageTools() {
        findSession.select(pageCommandSurface())
        renderFind()
        refreshPageZoom()
    }

    /// Peek documents report like tabs: find and zoom indicators, then feature observers through
    /// `engineEventHooks` (history records Peek visits; it skips private profiles itself).
    private func peekSurfaceEvent(_ event: BrowserSurfaceEvent, on surface: Surface) {
        guard !isPreparingForTermination else { return }
        if event == .navigationCommitted {
            findSession.documentDidChange(on: surface)
            renderPeekPageTools()
            pageSurfaceDidCommit(surface)
        }
        engineEventHooks.emit(event, for: surface)
    }

    /// Favorites, Pinned and Today, from the organization model (ORG-MODEL), with the saved home
    /// address of Pinned tabs and Favorites.
    func peekSourceClassification(for occurrenceID: TabOccurrenceID) -> (role: BrowserPeekSourceRole, homeURL: URL?)? {
        guard let tab = session.organization?.allTabs.first(where: { $0.occurrenceID == occurrenceID }) else { return nil }
        switch tab.section {
        case .favorites: return (.favorite, tab.pinnedURL)
        case .pinned: return (.pinned, tab.pinnedURL)
        case .today: return (.unpinned, nil)
        }
    }

    // MARK: Routing

    func routeNewTargetToPeek(from source: Surface, request: BrowserNewSurfaceRequest,
                              make: () -> Surface) -> BrowserNewTargetRouting<Surface> {
        guard !peek.isForwardingNewTarget, acceptsCommands,
              let sourceOccurrence = session.occurrenceID(for: source) else { return .declined }
        let link = peekLinkRequest(kind: .newTarget, source: source, sourceOccurrenceID: sourceOccurrence,
                                   destination: request.url, modifiers: request.modifiers,
                                   buttonNumber: request.buttonNumber, isMainFrame: nil,
                                   metadata: pendingNavigationMetadata(on: source) ?? BrowserNavigationMetadata(
                                    kind: request.kind == .linkActivation && request.isUserGesture != false ? .linkActivation : .other,
                                    httpMethod: nil, hasBody: true))
        guard case .peek(let trigger) = BrowserPeekRouting.decide(link, settings: peek.settings) else { return .declined }
        let child = make()
        guard peek.claim(child) else { return .handled(nil) }
        presentPeek(child, source: source, sourceOccurrenceID: sourceOccurrence, trigger: trigger,
                    activationPoint: peekActivationPoint(in: source))
        return .handled(child)
    }

    /// The `routeNavigations` hook: a qualifying link click in a tab (WebKit reports Shift-click and
    /// plain clicks as navigations of the tab) is cancelled there and its address opens in a new
    /// Peek on the next turn. Only a user link activation with a GET without body qualifies, as
    /// reported by the engine; unknown metadata keeps the navigation in the tab.
    func routeNavigationToPeek(from source: Surface, action: BrowserNavigationAction) -> BrowserNavigationRouting {
        guard acceptsCommands, action.isMainFrame == true, !action.shouldPerformDownload,
              let url = action.url, let sourceOccurrence = session.occurrenceID(for: source) else { return .declined }
        let link = peekLinkRequest(kind: .navigation, source: source, sourceOccurrenceID: sourceOccurrence,
                                   destination: url, modifiers: action.modifiers,
                                   buttonNumber: action.buttonNumber, isMainFrame: action.isMainFrame,
                                   metadata: pendingNavigationMetadata(on: source) ?? BrowserNavigationMetadata(
                                    kind: action.kind == .linkActivation && action.isUserGesture != false ? .linkActivation : .other,
                                    httpMethod: action.httpMethod, hasBody: action.hasBody != false))
        guard case .peek(let trigger) = BrowserPeekRouting.decide(link, settings: peek.settings) else { return .declined }
        let origin = peekActivationPoint(in: source)
        let generation = source.documentGeneration
        Task { [weak self, weak source] in
            guard let self, let source, owns(source), session.selectedSurface === source,
                  source.documentGeneration == generation else { return }
            openPeek(url, trigger: trigger, activationPoint: origin)
        }
        return .handled(.cancel)
    }

    func peekLinkRequest(kind: BrowserPeekRequestKind, source: Surface, sourceOccurrenceID: TabOccurrenceID,
                         destination: URL?, modifiers: BrowserModifierKeys, buttonNumber: Int,
                         isMainFrame: Bool?, metadata: BrowserNavigationMetadata?) -> BrowserPeekLinkRequest {
        let classification = peek.sourceClassifier?(sourceOccurrenceID)
        return BrowserPeekLinkRequest(
            kind: kind, sourceRole: classification?.role ?? .unclassified,
            sourceURL: source.navigationState.committedURL ?? source.currentURL,
            sourceHomeURL: classification?.homeURL, destinationURL: destination,
            modifiers: modifiers, buttonNumber: buttonNumber, isMainFrame: isMainFrame,
            isUserLinkActivation: metadata?.isUserLinkActivation == true,
            isReplayableRequest: metadata?.isReplayableGET == true)
    }

    /// What the engine reports about the question being asked on `surface`, if it can tell.
    private func pendingNavigationMetadata(on surface: Surface) -> BrowserNavigationMetadata? {
        (engine as? any BrowserNavigationMetadataSource)?.pendingNavigationMetadata(for: surface)
    }

    @discardableResult
    func openPeek(_ url: URL, trigger: BrowserPeekTrigger = .command, activationPoint: NSPoint? = nil) -> Surface? {
        guard acceptsCommands, !session.isClosed, BrowserPeekRouting.isWebURL(url),
              let source = session.selectedSurface,
              let sourceOccurrence = session.occurrenceID(for: source) else { return nil }
        let surface = engine.makeSurface(profileID: source.profileID, delegate: peek)
        guard peek.claim(surface) else {
            surface.dispose()
            return nil
        }
        presentPeek(surface, source: source, sourceOccurrenceID: sourceOccurrence, trigger: trigger, activationPoint: activationPoint)
        // Ownership, delegate and placement are recorded: the first load may start.
        surface.navigate(to: url)
        return surface
    }

    /// Read the initiating event before deferring the navigation. Keyboard activation must not
    /// hit-test an unrelated link that happens to be underneath the pointer.
    private func peekActivationPoint(in source: Surface) -> NSPoint? {
        guard let event = NSApp.currentEvent, event.window === window,
              [.leftMouseDown, .leftMouseUp, .otherMouseDown, .otherMouseUp].contains(event.type) else {
            return (source as? any BrowserLinkGeometrySource)?.linkActivationPoint
        }
        let host = source.hostView
        let point = host.convert(event.locationInWindow, from: nil)
        guard host.bounds.contains(point) else { return nil }
        return NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
    }

    private func presentPeek(_ surface: Surface, source: Surface, sourceOccurrenceID: TabOccurrenceID,
                             trigger: BrowserPeekTrigger, activationPoint: NSPoint? = nil) {
        peek.overlay.scrimCornerRadius = contentCard.cornerRadius
        let pointer = peek.overlay.convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        peek.overlay.sourceRect = BrowserPeekMotion.pointerFallback(at: pointer)
        peek.overlay.sourceCornerRadius = 0
        peek.overlay.prepareSource = nil
        if trigger != .command, let geometry = source as? any BrowserLinkGeometrySource,
           let viewportPoint = activationPoint ?? peekActivationPoint(in: source) {
            let generation = source.documentGeneration
            peek.overlay.prepareSource = { [weak self, weak source, weak geometry] in
                guard let self, let source, let geometry,
                      let link = await geometry.linkGeometry(at: viewportPoint),
                      source.documentGeneration == generation, owns(source) else { return nil }
                let rect = link.bounds
                let snapshot = try? await source.captureSnapshot(.init(afterScreenUpdates: false, documentGeneration: generation))
                guard source.documentGeneration == generation, owns(source) else { return nil }
                let host = source.hostView
                let local = NSRect(x: rect.minX, y: host.isFlipped ? rect.minY : host.bounds.height - rect.maxY,
                                   width: rect.width, height: rect.height)
                var image: CGImage?
                if let snapshot, host.bounds.width > 0, host.bounds.height > 0 {
                    let sx = CGFloat(snapshot.image.width) / host.bounds.width
                    let sy = CGFloat(snapshot.image.height) / host.bounds.height
                    image = snapshot.image.cropping(to: CGRect(x: rect.minX * sx, y: rect.minY * sy,
                                                               width: rect.width * sx, height: rect.height * sy))
                }
                return (peek.overlay.convert(local, from: host), link.cornerRadius, image)
            }
        }
        peek.present(surface, source: source, sourceOccurrenceID: sourceOccurrenceID, trigger: trigger,
                     animated: window?.isVisible == true)
        // Opening a Peek is a user action in this window: its document takes keyboard focus.
        surface.focusDocument()
        renderPeekPageTools()
    }

    // MARK: Dismissal

    /// Closes the Peek (×, Esc, ⌘W, click outside, `window.close()`), disposing its document.
    /// Focus held by the Peek document returns to the tab underneath; focus elsewhere (the
    /// address field that replaced the Peek) is left alone.
    func dismissPeek(animated: Bool = true) {
        let hadFocus = peekHoldsFocus
        guard let dismissed = peek.dismiss(animated: animated && window?.isVisible == true, remember: true) else { return }
        // A permission prompt of the closed document has no target any more.
        if siteControls.hasPendingPermission(for: dismissed.surface) { siteControls.cancelPermission() }
        if hadFocus { focusSelectedDocument() }
        renderPeekPageTools()
    }

    /// True when the first responder is inside the Peek card.
    private var peekHoldsFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: peek.overlay)
    }

    /// The window's projection: a Peek belongs to the tab it was opened from. Selecting another
    /// tab or Space, or losing the source, closes it ().
    func renderPeek() {
        let selected = session.snapshot?.selectedOccurrenceID
        if let presentation = peek.presentation {
            let sourceAlive = presentation.source.map { owns($0) } ?? false
            if session.isClosed || !sourceAlive || selected != presentation.sourceOccurrenceID {
                dismissPeek(animated: !session.isClosed)
            }
        }
        if let dismissed = peek.lastDismissed, dismissed.sourceOccurrenceID != selected {
            peek.forgetDismissed()
        }
    }

    // MARK: Promotion and Split

    /// Opens the Peek as a tab of the active Space: the same live document moves, without reload,
    /// with its history, form and script state (prototype: appended to Today and selected).
    @discardableResult
    func promotePeekToTab() -> Task<TabOccurrenceID?, Never>? {
        guard let presentation = peek.presentation else { return nil }
        if let task = peek.handoffTask { return task }
        guard window?.isVisible == true else { return performPeekPromotion() }
        let task = Task<TabOccurrenceID?, Never> { [weak self, weak surface = presentation.surface] in
            guard let self, let surface else { return nil }
            let image = try? await surface.captureSnapshot(.init(afterScreenUpdates: false, documentGeneration: surface.documentGeneration))
            guard !Task.isCancelled, peek.presentation?.id == presentation.id, acceptsCommands else { return nil }
            if let image { peek.overlay.retainPromotionImage(image.image) }
            var destinationImage: CGImage?
            if image != nil, !BrowserPeekStyle.prefersReducedMotion {
                window?.contentView?.layoutSubtreeIfNeeded()
                peek.overlay.preparePromotionViewport(surface.hostView, size: contentCard.pageViewportSize)
                let destination = try? await surface.captureSnapshot(.init(afterScreenUpdates: true,
                    documentGeneration: surface.documentGeneration))
                destinationImage = destination?.image
            }
            defer { peek.overlay.restorePromotionViewport(restoreLayout: peek.owns(surface)) }
            guard !Task.isCancelled, peek.presentation?.id == presentation.id, acceptsCommands else { return nil }
            let result = await performPeekPromotion(destinationImage: destinationImage)?.value
            if peek.presentation?.id == presentation.id { peek.handoffTask = nil }
            return result
        }
        peek.handoffTask = task
        return task
    }

    private func performPeekPromotion(destinationImage: CGImage? = nil) -> Task<TabOccurrenceID?, Never>? {
        guard acceptsCommands, let surface = peek.presentedSurface, let presentation = peek.presentation else { return nil }
        let hadFocus = peekHoldsFocus
        let outcome = BrowserPeekTransfer.handOff(surface, from: peek) { transfer in
            acceptSurface(transfer, activate: true)
        }
        guard case .accepted(let adoption) = outcome else {
            peek.overlay.discardPromotionImage()
            NSSound.beep()
            return nil
        }
        finishPeekHandoff(surface, presentation: presentation, adoption: adoption, hadFocus: hadFocus, expanding: true, destinationImage: destinationImage)
        return adoption
    }

    private func finishPeekHandoff(_ surface: Surface, presentation: BrowserPeekController<Surface>.Presentation,
                                  adoption: Task<TabOccurrenceID?, Never>, hadFocus: Bool, expanding: Bool, destinationImage: CGImage? = nil) {
        let retainsImage = expanding && window?.isVisible == true
        let revealsOnPlacement = retainsImage && !BrowserPeekStyle.prefersReducedMotion
        if revealsOnPlacement {
            peek.revealPromotionWhenPlaced(surface.hostView) { [weak self, weak surface] in
                guard let self, let surface else { return }
                if !peek.isPresented {
                    contentCard.setPeekDimmed(false, animated: false)
                    if let destinationImage {
                        let target = peek.overlay.convert(surface.hostView.bounds, from: surface.hostView)
                        peek.overlay.retainDestinationImage(destinationImage, in: target)
                        Task { [weak self, weak surface] in
                            guard let self, let surface else { return }
                            _ = try? await surface.captureSnapshot(.init(afterScreenUpdates: true,
                                documentGeneration: surface.documentGeneration))
                            if !peek.isPresented { peek.overlay.completePromotion() }
                            if hadFocus, session.selectedSurface === surface { surface.focusDocument() }
                        }
                    } else { peek.overlay.completePromotion() }
                }
                if destinationImage == nil, hadFocus, session.selectedSurface === surface { surface.focusDocument() }
            }
        } else { contentCard.setPeekDimmed(false, animated: false) }
        peek.endPresentationAfterHandOff()
        renderPeekPageTools()
        // Keep the last painted frame until adoption completes. The destination and the
        // overlay then change in one turn, without scaling a second copy of the document.
        if retainsImage, BrowserPeekStyle.prefersReducedMotion { surface.hostView.isHidden = true }
        if !retainsImage { peek.overlay.hide(animated: false) }
        Task { [weak self, weak surface] in
            let occurrence = await adoption.value
            guard let self, let surface else { return }
            guard occurrence != nil else {
                peek.cancelPromotionPlacement()
                surface.hostView.isHidden = false
                surface.hostView.alphaValue = 1
                // CONTRACT-R2: the tab could not be recorded and the live document came back to
                // Peek; show it again rather than leaving it hidden.
                if peek.owns(surface), !peek.isPresented {
                    peek.present(surface, source: presentation.source, sourceOccurrenceID: presentation.sourceOccurrenceID,
                                 trigger: presentation.trigger, animated: false)
                }
                return
            }
            if revealsOnPlacement {
                peek.revealPromotionIfPlaced(in: contentCard)
                return
            }
            let reveal: @MainActor () -> Void = { [weak self, weak surface] in
                guard let surface else { return }
                surface.hostView.isHidden = false
                surface.hostView.alphaValue = 1
                if hadFocus, self?.session.selectedSurface === surface { surface.focusDocument() }
            }
            if retainsImage, !peek.isPresented {
                peek.overlay.completePromotion(completion: reveal)
                if BrowserPeekStyle.prefersReducedMotion {
                    // A newer presentation can replace the crossfade's exit completion.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(BrowserPeekStyle.reducedMotionCrossfade + BrowserPeekStyle.exitCompletionGrace))
                        reveal()
                    }
                }
            } else { reveal() }
        }
    }

    /// The Peek → Split seam (official notes January 2024). SPLIT installs `peek.splitHandoff`;
    /// until then, and whenever it declines, the document stays in Peek.
    @discardableResult
    func openPeekInSplit() -> Bool {
        guard peek.handoffTask == nil else { return false }
        guard acceptsCommands, let surface = peek.presentedSurface, let presentation = peek.presentation,
              let handoff = peek.splitHandoff else {
            NSSound.beep()
            return false
        }
        let hadFocus = peekHoldsFocus
        let outcome = BrowserPeekTransfer.handOff(surface, from: peek) { transfer in handoff(transfer) }
        guard case .accepted(let receipt) = outcome, let adoption = receipt else {
            NSSound.beep()
            return false
        }
        finishPeekHandoff(surface, presentation: presentation, adoption: adoption, hadFocus: hadFocus, expanding: false)
        return true
    }

    // MARK: Reopening a closed Peek

    var canReopenPeek: Bool {
        guard let dismissed = peek.lastDismissed, !peek.isPresented else { return false }
        return dismissed.sourceOccurrenceID == session.snapshot?.selectedOccurrenceID
    }

    /// ⇧⌘T after closing a Peek reopens it over the same tab (official notes O23). The document
    /// was closed, so its address loads again, as for a reopened tab.
    func reopenClosedPeek() {
        guard canReopenPeek, let dismissed = peek.lastDismissed else { return }
        openPeek(dismissed.url, trigger: .command)
    }

    // MARK: Attribution of Peek events

    /// A new target of the Peek document becomes a tab next to the Peek's source tab, through the
    /// window's own adoption (opener kept, ⌘-click in the background, downloads attributed to the
    /// source tab before rendering). A foreground tab replaces the Peek once it renders.
    private func adoptNewTargetFromPeek(_ request: BrowserNewSurfaceRequest, make: () -> Surface) -> Surface? {
        guard let presentation = peek.presentation, let source = presentation.source, owns(source) else { return nil }
        peek.isForwardingNewTarget = true
        defer { peek.isForwardingNewTarget = false }
        return surface(source, createSurfaceFor: request, make: make)
    }

    /// Downloads of the Peek document belong to this window and to the tab that opened the Peek.
    /// A Peek whose document became a download before rendering anything closes.
    private func adoptPeekDownload(_ download: any BrowserEngineDownload, from surface: Surface,
                                   presentation: BrowserPeekController<Surface>.Presentation) {
        guard !isPreparingForTermination, let windowID = session.snapshot?.id else {
            download.cancel()
            return
        }
        downloads.adopt(download, owner: BrowserDownloadOwner(profileID: surface.profileID, sourceWindowID: windowID,
                                                              sourceOccurrenceID: presentation.sourceOccurrenceID),
                        sourceWindow: window)
        if !presentation.hasRendered { dismissPeek() }
    }

    // MARK: Commands

    /// Command state while a Peek is presented: the `.peek` scope (Esc closes it) and, while the
    /// Peek has focus, navigation availability of the Peek document that page commands target.
    func applyPeekCommandState(to state: inout BrowserCommandState) {
        if canReopenPeek { state.canReopen = true }
        guard peek.isPresented else { return }
        state.scope = .peek
        guard isPeekPageFocused, let surface = peek.presentedSurface else { return }
        let navigation = surface.navigationState
        state.hasSurface = true
        state.hasURL = navigation.url != nil
        state.canGoBack = navigation.canGoBack
        state.canGoForward = navigation.canGoForward
        state.isLoading = navigation.isLoading
        if let context = state.context {
            state.context = BrowserCommandContext(revision: context.revision, surface: ObjectIdentifier(surface),
                                                  documentGeneration: surface.findDocumentGeneration,
                                                  inputToken: context.inputToken)
        }
    }

    // MARK: Test and diagnostics accessors

    var peekOverlay: BrowserPeekOverlayView { peek.overlay }
}
