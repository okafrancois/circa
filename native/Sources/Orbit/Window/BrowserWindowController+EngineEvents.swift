import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

extension BrowserWindowController: BrowserEngineSurfaceDelegate {
    func surfaceDidStartNavigation(_ surface: Surface) {
        refreshNavigation(for: surface)
        notifyHooks(.navigationStarted, for: surface)
    }

    func surfaceDidCommitNavigation(_ surface: Surface) {
        if owns(surface), let url = surface.navigationState.committedURL {
            session.recordPinnedNavigation(for: surface, to: url, committed: true)
        }
        pageSurfaceDidCommit(surface)
        if owns(surface) {
            findSession.documentDidChange(on: surface)
            surfaceDidChange(surface)
        }
        nativeCreationDidCommit(surface)
        refreshNavigation(for: surface)
        notifyHooks(.navigationCommitted, for: surface)
    }

    func surfaceDidFinishNavigation(_ surface: Surface) {
        refreshNavigation(for: surface)
        notifyHooks(.navigationFinished, for: surface)
    }

    func surfaceDidFailNavigation(_ surface: Surface) {
        if !isPreparingForTermination, owns(surface) { surfaceDidChange(surface) }
        refreshNavigation(for: surface)
        notifyHooks(.navigationFailed, for: surface)
    }

    /// A fragment or History API navigation: same document, new address (for history and the
    /// tab's destination).
    func surface(_ surface: Surface, didNavigateWithinDocument navigation: BrowserSameDocumentNavigation) {
        if !isPreparingForTermination, owns(surface) { surfaceDidChange(surface) }
        refreshNavigation(for: surface)
        notifyHooks(.navigatedWithinDocument(navigation.kind), for: surface)
    }

    private func notifyHooks(_ event: BrowserSurfaceEvent, for surface: Surface) {
        guard session.holds(surface) else { return }
        engineEventHooks.emit(event, for: surface)
    }

    /// Records where this window shows a surface, for engines that expose it to extensions. The
    /// engine learns the NSWindow of the model window first (`shellWindowDidOpen`).
    func surfaceMembershipDidChange(_ surface: Surface, _ membership: BrowserSurfaceMembership?) {
        if membership == nil { passwordPrompt.surfaceDidLeave(surface) }
        if let membership { announceEngineWindow(membership.windowID) }
        surface.placement = membership.map { .tab(windowID: $0.windowID, occurrenceID: $0.occurrenceID) } ?? .detached
    }

    /// Tells the engine which NSWindow shows the surfaces of `windowID` (idempotent).
    func announceEngineWindow(_ windowID: WindowID) {
        guard let window else { return }
        let isNew = engineWindowIDs.insert(windowID).inserted
        engine.shellWindowDidOpen(windowID, window: window)
        if isNew {
            engine.setEngineTabAdoption(for: windowID) { [weak self] request, make in
                self?.adoptEngineCreatedTab(request, make: make)
            }
        }
    }

    /// After this window's surfaces were disposed or moved away (closing, termination).
    func releaseEngineWindows() {
        for windowID in engineWindowIDs {
            engine.setEngineTabAdoption(for: windowID, nil)
            engine.shellWindowWillClose(windowID)
        }
        engineWindowIDs.removeAll()
    }

    /// (EXT-OUTCOME-R1) A tab the engine created by itself in this window's native browser of
    /// `request.profileID` (an extension's `chrome.tabs.create`, an options page): recorded like a
    /// new target of the selected tab of that profile — after it, in its Space — and selected when
    /// the engine activates it. Nil, leaving the tab unhosted, when the window is closing or its
    /// selection belongs to another profile: an engine tab never crosses profiles.
    func adoptEngineCreatedTab(_ request: BrowserEngineTabRequest, make: () -> Surface) -> Surface? {
        guard acceptsCommands, !isPreparingForTermination, !session.isClosed,
              let source = session.selectedSurface, source.profileID == request.profileID else { return nil }
        return surface(source, createSurfaceFor: BrowserNewSurfaceRequest(
            url: request.url ?? URL(string: "about:blank")!,
            modifiers: request.isForeground ? [] : [.command],
            kind: .other, isUserGesture: false,
            disposition: request.isForeground ? .newForegroundTab : .newBackgroundTab), make: make)
    }

    // MARK: Page-first keyboard (BL-CONTRACT-KEY-RECEIPT)

    /// Shortcut candidates typed in the selected document go to the page first. The receipt keeps
    /// the command context the key would target if the page declines it.
    func surface(_ surface: Surface, willSendKeyToPage event: NSEvent) -> BrowserKeyRouting {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           elementFullscreenSurfaceKey == ObjectIdentifier(surface), exitElementFullscreenIfNeeded() {
            return .browser
        }
        guard session.selectedSurface === surface, let context = commandState.context else { return .page(receipt: nil) }
        return .page(receipt: BrowserKeyReceipt(context: BrowserPageKeyContext(windowID: id, context: context)))
    }

    /// A key the page declined takes the menu route (the root menu's post-page resolution, as for
    /// WebKit) only while the same document of the same selection keeps the focus of the key
    /// window. Otherwise it is dropped: never applied to a newly selected tab or document.
    func surface(_ surface: Surface, pageDidNotHandleKey event: NSEvent, receipt: BrowserKeyReceipt) -> Bool {
        let responder = window?.firstResponder as? NSView
        guard BrowserPageKeyContext.accepts(receipt, windowID: id, current: commandState.context,
                                            isKeyWindow: window?.isKeyWindow == true,
                                            isSelected: session.selectedSurface === surface,
                                            focusInsideDocument: responder?.isDescendant(of: surface.hostView) == true)
        else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    // MARK: Policy

    func surface(_ surface: Surface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        let policy = navigationActionPolicy(for: action, in: surface)
        if policy == .allow, action.isMainFrame == true, owns(surface), let url = action.url {
            session.recordPinnedNavigation(for: surface, to: url, isRedirect: action.kind == .redirect)
        }
        decision.decide(policy)
    }

    func navigationActionPolicy(for action: BrowserNavigationAction, in surface: Surface) -> BrowserNavigationActionPolicy {
        guard holdsForNavigation(surface) else { return .cancel }
        if action.isMainFrame != false, [.typed, .reload, .backForward].contains(action.kind), let url = action.url {
            restoreLocalDocumentGrant(for: surface, target: url)
        }
        if !isPreparingForTermination, handleExternalApplicationLink(action, from: surface) { return .cancel }
        return BrowserNavigationPolicy.action(action, surface: surface, held: true,
            routesEnabled: !isPreparingForTermination && owns(surface), hooks: engineEventHooks,
            extensionDocuments: engine.capabilities.contains(.extensionDocuments))
    }

    func surface(_ surface: Surface, decidePolicyFor response: BrowserNavigationResponse,
                 decision: BrowserPolicyDecision<BrowserNavigationResponsePolicy>) {
        decision.decide(decideNavigationResponse(response.response, canShowMIMEType: response.canShowMIMEType,
                                                 isForMainFrame: response.isForMainFrame, in: surface))
    }

    /// Asked only by engines with `navigationResponsePolicy` (WebKit). A safety net, never a
    /// dependency: download versus render is the engine's native decision, and new targets are
    /// promoted at their first commit.
    func decideNavigationResponse(_ response: URLResponse, canShowMIMEType: Bool,
                                  isForMainFrame: Bool, in surface: Surface) -> BrowserNavigationResponsePolicy {
        BrowserNavigationPolicy.response(.init(response: response, canShowMIMEType: canShowMIMEType, isForMainFrame: isForMainFrame),
            surface: surface, held: holdsForNavigation(surface),
            extensionDocuments: engine.capabilities.contains(.extensionDocuments))
    }

    /// A surface accepted synchronously (created, adopted or transferred here) may navigate while
    /// its model tab is recorded; if that later fails, the surface is disposed, never replayed.
    private func holdsForNavigation(_ surface: Surface) -> Bool {
        !pendingNativeClosures.contains(ObjectIdentifier(surface)) && session.holds(surface)
    }

    /// The first main-frame commit of a foreground new target selects it, unless the user acted
    /// after its creation. Commit is the contract-level "displayable" signal, delivered by every
    /// engine (CEF `OnLoadStart`); no response policy is needed. Selection follows in command order.
    private func nativeCreationDidCommit(_ surface: Surface) {
        let key = ObjectIdentifier(surface)
        guard var creation = nativeCreations[key], !creation.hasCommitted else { return }
        creation.hasCommitted = true
        nativeCreations[key] = creation
        guard creation.foreground else { return }
        // Visible from the commit on (`hasPendingNativePromotion`), before the adoption resolves.
        promotionsAwaitingAdoption += 1
        Task { [weak self] in
            let occurrence = await creation.adoption.value
            let context = await creation.previousContext.value
            guard let self else { return }
            promotionsAwaitingAdoption -= 1
            guard let occurrence, let context,
                  creation.inputToken == explicitInputToken, !pendingNativeClosures.contains(key),
                  !creation.surface.isDisposed else { return }
            nativePromotion?.intent.revoke()
            let promotion = NativePromotion(surface: creation.surface, intent: BrowserSelectionIntent())
            nativePromotion = promotion
            _ = await session.selectOccurrence(occurrence, ifContextMatches: context, while: promotion.intent).value
            if nativePromotion?.id == promotion.id { nativePromotion = nil }
        }
    }

    // MARK: New targets

    func surface(_ source: Surface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> Surface) -> Surface? {
        guard acceptsCommands, owns(source),
              let sourceOccurrence = session.occurrenceID(for: source),
              let url = request.url else { return nil }
        let extensionDocument = engine.capabilities.contains(.extensionDocuments)
            && BrowserNavigationPolicy.isExtensionDocument(url)
        guard extensionDocument || ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") else {
            // CH-ESSENTIALS: a target=_blank application link asks like a navigation would.
            _ = handleExternalApplicationLink(BrowserNavigationAction(url: url, isMainFrame: true, kind: request.kind,
                                                                      isUserGesture: request.isUserGesture), from: source)
            return nil
        }
        if case .handled(let routed) = engineEventHooks.routeNewTarget(from: source, request: request, make: make) {
            return routed
        }
        let surface = make()
        bindSurface(surface)
        let key = ObjectIdentifier(surface)
        let previous = session.captureContextInCommandOrder()
        let adoption = session.adoptSurface(surface, from: source, profileID: source.profileID, url: url)
        let background = (request.modifiers.contains(.command) && !request.modifiers.contains(.shift))
            || request.buttonNumber == 2
        nativeCreations[key] = NativeCreation(surface: surface, adoption: adoption, previousContext: previous,
            sourceOccurrenceID: sourceOccurrence, foreground: !background, inputToken: explicitInputToken)
        guard !session.isClosed, !surface.isDisposed else {
            nativeCreations.removeValue(forKey: key)
            return nil
        }
        Task { [weak self, weak surface] in
            let occurrence = await adoption.value
            guard let surface else { return }
            guard occurrence != nil else {
                self?.nativeCreations.removeValue(forKey: key)
                self?.provisionalDownloads.removeValue(forKey: key)
                surface.dispose()
                return
            }
            self?.reconcileProvisionalEvents(of: surface, recordedAs: occurrence)
        }
        // The engine transfers the original request and opener into this exact surface.
        return surface
    }

    func surfaceDidRequestClose(_ surface: Surface) {
        let key = ObjectIdentifier(surface)
        if let creation = nativeCreations.removeValue(forKey: key) {
            closeNativeCreation(creation)
        } else if owns(surface) {
            pendingNativeClosures.insert(key)
            _ = session.closeOwnedSurface(surface)
        } else if session.holds(surface) {
            // A moved-in surface whose tab is still being recorded: honoured once it resolves.
            pendingNativeClosures.insert(key)
            provisionalCloses.insert(key)
        }
    }

    func surfaceDidRequestActivation(_ surface: Surface) {
        guard acceptsCommands, owns(surface), window?.isVisible == true || window?.isMiniaturized == true,
              session.selectedSurface !== surface || window?.isKeyWindow != true else { return }
        let activation = session.activateOwnedSurface(surface)
        Task { [weak self, weak surface] in
            guard await activation.value, let self, let surface, acceptsCommands,
                  owns(surface), session.selectedSurface === surface else { return }
            window?.deminiaturize(nil)
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            _ = surface.focusDocument()
        }
    }

    /// Closes an engine-created target once its adoption has resolved; a rejected adoption has
    /// already disposed it.
    private func closeNativeCreation(_ creation: NativeCreation) {
        let key = ObjectIdentifier(creation.surface)
        pendingNativeClosures.insert(key)
        Task { [weak self] in
            let occurrence = await creation.adoption.value
            guard let self else { return }
            guard occurrence != nil else {
                pendingNativeClosures.remove(key)
                return
            }
            _ = await session.closeOwnedSurface(creation.surface).value
        }
    }

    // MARK: Downloads

    func surface(_ surface: Surface, didStartDownload download: any BrowserEngineDownload) {
        let key = ObjectIdentifier(surface)
        // A target that turns into a download before its first commit belongs to its source tab,
        // even while its own adoption is still being recorded; after a commit it is its own.
        let auxiliary = nativeCreations[key].flatMap { $0.hasCommitted ? nil : $0 }
        guard !isPreparingForTermination, !pendingNativeClosures.contains(key), session.holds(surface),
              let windowID = session.snapshot?.id else {
            download.cancel()
            return
        }
        // Nil while the surface's own tab is still being recorded: a provisional owner, completed
        // when recording resolves (`reconcileProvisionalEvents`), never a cancelled download.
        let sourceOccurrence = auxiliary?.sourceOccurrenceID ?? session.occurrenceID(for: surface)
        let downloadKey = downloads.adopt(download, owner: BrowserDownloadOwner(profileID: surface.profileID,
            sourceWindowID: windowID, sourceOccurrenceID: sourceOccurrence),
            sourceWindow: window)
        if let auxiliary {
            nativeCreations.removeValue(forKey: key)
            closeNativeCreation(auxiliary)
        } else if sourceOccurrence == nil, let downloadKey {
            provisionalDownloads[key, default: []].append(downloadKey)
        }
    }

    /// Applies events that arrived while a held surface's tab was being recorded. Recorded: its
    /// downloads get their source occurrence and a requested close runs. Not recorded (the move
    /// failed and the surface went back to its source or a rescue holder): downloads follow the
    /// current owner, or keep only their profile when the document has no recorded window. A
    /// close request is forwarded to the current delegate.
    func reconcileProvisionalEvents(of surface: Surface, recordedAs occurrence: TabOccurrenceID?) {
        let key = ObjectIdentifier(surface)
        let pendingDownloads = provisionalDownloads.removeValue(forKey: key) ?? []
        let closeRequested = provisionalCloses.remove(key) != nil
        if let occurrence, session.occurrenceID(for: surface) == occurrence, let windowID = session.snapshot?.id {
            for downloadKey in pendingDownloads {
                downloads.attributeSource(downloadKey, windowID: windowID, occurrenceID: occurrence)
            }
            if closeRequested { _ = session.closeOwnedSurface(surface) }
        } else {
            if !surface.isDisposed, let owner = surface.delegate as? BrowserWindowController,
               owner !== self, owner.session.holds(surface) {
                owner.reconcileReturnedDownloads(pendingDownloads, of: surface)
            } else {
                for downloadKey in pendingDownloads { downloads.clearProvisionalSourceWindow(downloadKey) }
            }
            if closeRequested {
                pendingNativeClosures.remove(key)
                if !surface.isDisposed, let owner = surface.delegate, owner !== self {
                    owner.surfaceDidRequestClose(surface)
                }
            }
        }
    }

    private func reconcileReturnedDownloads(_ keys: [BrowserDownloadKey], of surface: Surface) {
        let matching = keys.filter { $0.profileID == surface.profileID }
        if let occurrence = session.occurrenceID(for: surface), let windowID = session.snapshot?.id {
            for key in matching { downloads.attributeSource(key, windowID: windowID, occurrenceID: occurrence) }
        } else {
            // The rescue holder may already have handed this surface to another receiver whose
            // recording is still pending. That receiver's adoption will reconcile these keys.
            provisionalDownloads[ObjectIdentifier(surface), default: []].append(contentsOf: matching)
        }
    }
}
