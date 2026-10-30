import AppKit
import BrowserCore
import BrowserShell

extension OrbitApplication {
    var activeQuickWindow: BrowserQuickWindowWindowController<ActiveEngine>? {
        environment?.quickWindows.values.first { !$0.isClosed && $0.ownsCommandWindow(NSApp?.keyWindow) }
    }

    func installQuickWindowCommands(in registry: BrowserCommandRegistry<OrbitWindowController>) {
        BrowserQuickWindowCommands.install(in: registry, active: { [weak self] in self?.activeQuickWindow },
            promote: { [weak self] in self?.promoteQuickWindow($0) },
            chooseSpace: { [weak self] in self?.showQuickWindowSpaces($0) })
        try! registry.registerApplication(.newQuickWindowWindow) { [weak self] in self?.openQuickWindow() }
        // The visible Orbit menu entry and the scoped supplemental shortcut share one action.
        try! registry.registerApplication(.openQuickWindowOrPeekIn, replace: true) { [weak self] in
            guard let self else { return }
            if let little = activeQuickWindow { promoteQuickWindow(little) }
            else { withBrowserWindow(createIfMissing: false) { $0.promotePeekToTab() } }
        }
        registry.registerPrerequisite(.openQuickWindowOrPeekIn) { [weak self] window, _ in
            if let little = self?.activeQuickWindow { return !little.isPromotionInProgress && !little.isClosed }
            return window?.isPeekPresented == true
        }
    }

    /// Capture the last selected Space in session command order, before any asynchronous work.
    func openQuickWindow(url: URL? = nil, spaceID: SpaceID? = nil, source: OrbitWindowController? = nil, acceptedBeforeTermination: Bool = false) {
        guard environment != nil, !isPreparingToQuit || acceptedBeforeTermination else { return }
        guard source?.isPrivateWindow != true, !(source == nil && spaceID == nil && windows.selectedWindow?.isPrivateWindow == true) else { return }
        let source = spaceID == nil ? source ?? windows.selectedWindow : nil
        let request = BrowserQuickWindowOpenRequest(url: url, spaceID: spaceID, profileID: source?.session.activeProfileID)
        quickWindowOpenRequests.append(request)
        scheduleQuickWindowRequest(request, source: source)
    }

    func scheduleQuickWindowRequest(_ request: BrowserQuickWindowOpenRequest, source: OrbitWindowController? = nil) {
        request.isRouting = true
        let context = source?.session.captureContextInCommandOrder()
        enqueueQuickWindowCommand { [weak self] in
            guard let self, let environment else { return }
            let captured = await context?.value
            if let captured {
                request.spaceID = captured.spaceID
                request.profileID = captured.profileID
                environment.lastUsedSpaceID = captured.spaceID
            } else if request.profileID == nil, let spaceID = request.spaceID {
                request.profileID = await environment.store.sessionDocument().spaces.first { $0.id == spaceID }?.profileID
            }
            do {
                if !request.opensInQuickWindow || (context != nil && captured == nil) {
                    await openQuickWindowFallback(request)
                    return
                }
                let little: BrowserQuickWindowWindowController<ActiveEngine>
                if request.isExternalOpen, let url = request.url {
                    little = try await environment.makeExternalQuickWindow(url: url, spaceID: request.spaceID, profileID: request.profileID)
                } else {
                    little = try await environment.makeQuickWindow(spaceID: request.spaceID,
                        url: request.url, preferredProfileID: request.profileID)
                }
                request.profileID = little.profileID
                request.spaceID = little.sourceSpaceID
                configureQuickWindow(little)
                presentAndScheduleUpdates { quickWindowPresenter(little) }
                confirmQuickWindowRequest(request)
            } catch { await openQuickWindowFallback(request) }
        }
    }

    func retainQuickWindowRequest(_ request: BrowserQuickWindowOpenRequest) {
        request.isRouting = false
        quickWindowRoutingFailure()
    }

    func confirmQuickWindowRequest(_ request: BrowserQuickWindowOpenRequest) {
        quickWindowOpenRequests.removeAll { $0 === request }
    }

    /// A failed Little Circa becomes a tab in its captured profile. If that account is unavailable,
    /// keep the complete request for retry; another account must never receive its URL.
    func openQuickWindowFallback(_ request: BrowserQuickWindowOpenRequest) async {
        guard let environment else { retainQuickWindowRequest(request); return }
        let catalog = await environment.store.catalogSnapshot()
        if let profileID = request.profileID,
           !catalog.profiles.contains(where: { $0.id == profileID }) {
            retainQuickWindowRequest(request)
            return
        }
        if let target = windows.selectedWindow, !target.session.isClosed,
           catalog.spaces.contains(where: { $0.id == target.session.snapshot?.activeSpaceID }),
           request.profileID == nil || target.session.activeProfileID == request.profileID {
            request.profileID = target.session.activeProfileID
            if await deliverQuickWindowRequest(request, to: target) { return }
        }
        let space = catalog.spaces.first { $0.id == request.spaceID && $0.profileID == request.profileID }
            ?? catalog.spaces.first { $0.profileID == request.profileID }
            ?? (request.profileID == nil ? environment.lastUsedSpaceID.flatMap { id in catalog.spaces.first { $0.id == id } }
                ?? catalog.spaces.first : nil)
        guard let space else { retainQuickWindowRequest(request); return }
        request.profileID = space.profileID
        request.spaceID = space.id
        let id = UUID()
        quickWindowDestinationSpaces[id] = space.id
        windows.newWindow(id: id)
        await windows.waitForPendingCommands()
        guard let target = windows.windows[id] else {
            quickWindowDestinationSpaces[id] = nil
            retainQuickWindowRequest(request)
            return
        }
        if await !deliverQuickWindowRequest(request, to: target) { retainQuickWindowRequest(request) }
    }

    private func deliverQuickWindowRequest(_ request: BrowserQuickWindowOpenRequest, to target: OrbitWindowController) async -> Bool {
        guard request.profileID == target.session.activeProfileID else { return false }
        let delivery = target.session.openTabForDelivery(url: request.url ?? URL(string: "about:blank")!,
                                                        expectedProfileID: request.profileID)
        guard let tab = await delivery.value else { return false }
        request.spaceID = tab.spaceID
        confirmQuickWindowRequest(request)
        if !target.session.isClosed {
            target.hideLibrary()
            windowPresenter(target, true)
        }
        return true
    }

    func retryUnroutedQuickWindowURLs() {
        for request in quickWindowOpenRequests where !request.isRouting {
            if request.hasRoutingDestination {
                request.isRouting = true
                enqueueQuickWindowCommand { [weak self] in await self?.deliverRoutedExternalRequest(request) }
            } else { scheduleQuickWindowRequest(request) }
        }
    }

    func enqueueQuickWindowCommand(_ operation: @escaping @MainActor () async -> Void) {
        let previous = quickWindowCommands
        quickWindowCommands = Task { await previous?.value; await operation() }
    }

    func waitForQuickWindowCommands() async { await quickWindowCommands?.value }

    func configureQuickWindow(_ little: BrowserQuickWindowWindowController<ActiveEngine>) {
        environment?.onQuickWindowDestinationChange = { [weak self] in self?.refreshQuickWindowDestinations() }
        let registry = commands.registry
        little.promotionShortcut = { [weak registry] in registry?.definition(.promoteQuickWindow)?.shortcuts.first?.displayLabel }
        refreshQuickWindowDestinations()
        little.onPromote = { [weak self, weak little] in if let little { self?.promoteQuickWindow(little) } }
        little.onChooseSpace = { [weak self, weak little] in if let little { self?.showQuickWindowSpaces(little) } }
        little.onNewTarget = { [weak self, weak little] _, _, make in
            guard let self, let little, let environment, !isPreparingToQuit, !little.isClosed else { return nil }
            let child = environment.registerQuickWindow(spaceID: little.sourceSpaceID, profileID: little.profileID,
                                                      spaceName: little.sourceSpaceName)
            configureQuickWindow(child)
            let surface = make()
            guard child.adoptNewTarget(surface) else { child.retire(); return nil }
            presentAndScheduleUpdates { quickWindowPresenter(child) }
            return surface
        }
    }

    func refreshQuickWindowDestinations() {
        guard let environment else { return }
        let target = windows.selectedWindow
        let spaces = target?.session.catalog?.spaces ?? []
        for little in environment.quickWindows.values {
            let sourceName = spaces.first { $0.id == little.sourceSpaceID }?.name ?? little.sourceSpaceName
            let targetSpaceID = target?.session.activeProfileID == little.profileID
                ? target?.session.snapshot?.activeSpaceID : little.sourceSpaceID
            let name = spaces.first { $0.id == targetSpaceID }?.name ?? sourceName
            little.updateDestinationName(name, sourceName: sourceName)
        }
    }

    func promoteQuickWindow(_ little: BrowserQuickWindowWindowController<ActiveEngine>, to spaceID: SpaceID? = nil) {
        guard let environment, environment.quickWindows[little.id] === little,
              !isPreparingToQuit, !little.isClosed, !little.isPromotionInProgress else { return }
        // Capture the chosen address before asynchronous window creation or navigation changes it.
        let sourceURL = little.surface?.currentURL
        // A selected main window of the same profile receives the document in its current Space.
        // Without an explicit choice, use a window of the Little Circa's captured profile.
        if let target = windows.selectedWindow, target.engine === environment.engine,
           target.isPrivateWindow == environment.isPrivate, target.session.activeProfileID == little.profileID,
           spaceID == nil || target.session.snapshot?.activeSpaceID == spaceID {
            if let adoption = little.promote(to: target) {
                enqueueQuickWindowCommand { [weak self, weak target] in
                    if await adoption.value != nil, let self, let target {
                        await rememberQuickWindowProfile(url: sourceURL, profileID: little.profileID, selectedSpace: spaceID)
                        presentQuickWindowDestination(target)
                    }
                }
            } else if !environment.engine.capabilities.contains(.liveSurfaceTransfer) {
                presentQuickWindowDestination(target)
            }
            return
        }
        // Land in the selected Space of the existing main window.
        if let spaceID, let target = windows.selectedWindow, target.engine === environment.engine,
           target.isPrivateWindow == environment.isPrivate {
            guard little.beginPromotionPreparation() else { return }
            enqueueQuickWindowCommand { [weak self, weak little, weak target] in
                guard let self, let little, let target else { return }
                defer { little.endPromotionPreparation() }
                let catalog = await environment.store.catalogSnapshot()
                guard !isPreparingToQuit, !little.isClosed, target.acceptsCommands,
                      let space = catalog.spaces.first(where: { $0.id == spaceID }) else { return }
                if space.profileID != little.profileID {
                    if await copyQuickWindow(little, url: sourceURL, to: target, spaceID: space.id, profileID: space.profileID) {
                        presentQuickWindowDestination(target)
                    }
                    return
                }
                target.session.activateSpace(spaceID)
                await target.session.waitForPendingCommands()
                guard !little.isClosed, !isPreparingToQuit, target.acceptsCommands,
                      target.session.snapshot?.activeSpaceID == spaceID,
                      target.session.activeProfileID == little.profileID else { return }
                if let adoption = little.promote(to: target), await adoption.value != nil {
                    await rememberQuickWindowProfile(url: sourceURL, profileID: little.profileID, selectedSpace: spaceID)
                    presentQuickWindowDestination(target)
                }
            }
            return
        }
        if !environment.engine.capabilities.contains(.liveSurfaceTransfer), little.surface?.currentURL == nil { return }
        guard little.beginPromotionPreparation() else { return }
        let destinationSpaceID = spaceID ?? little.sourceSpaceID
        enqueueQuickWindowCommand { [weak self, weak little] in
            guard let self, let little else { return }
            defer { little.endPromotionPreparation() }
            let catalog = await environment.store.catalogSnapshot()
            guard !little.isClosed, !isPreparingToQuit,
                  let space = catalog.spaces.first(where: { $0.id == destinationSpaceID }) else { return }
            let id = UUID()
            quickWindowDestinationSpaces[id] = space.id
            provisionalQuickWindowWindows.insert(id)
            defer { provisionalQuickWindowWindows.remove(id); quickWindowDestinationSpaces[id] = nil }
            windows.newWindow(id: id)
            await windows.waitForPendingCommands()
            guard let target = windows.windows[id] else { return }
            quickWindowPromotionWindowPrepared?(target)
            if space.profileID != little.profileID {
                let copied = await copyQuickWindow(little, url: sourceURL, to: target, spaceID: space.id, profileID: space.profileID)
                await target.session.waitForPendingCommands()
                if copied || target.session.snapshot?.tabs.isEmpty == false {
                    provisionalQuickWindowWindows.remove(id)
                    presentQuickWindowDestination(target)
                } else { target.window?.close() }
                return
            }
            let adoption = little.isClosed ? nil : little.promote(to: target)
            let occurrence = await adoption?.value
            await target.session.waitForPendingCommands()
            if occurrence != nil {
                await rememberQuickWindowProfile(url: sourceURL, profileID: little.profileID, selectedSpace: spaceID)
                provisionalQuickWindowWindows.remove(id)
                presentQuickWindowDestination(target)
            } else if target.session.snapshot?.tabs.isEmpty == true {
                target.window?.close()
                await target.session.waitForPendingCommands()
            } else if !target.session.isClosed, target.session.snapshot?.tabs.isEmpty == false {
                provisionalQuickWindowWindows.remove(id)
                presentQuickWindowDestination(target)
            }
        }
    }

    /// A different account receives a fresh GET, never the source document or its POST body.
    /// Session-bound and privileged URLs leave the original Little window intact.
    private func copyQuickWindow(_ little: BrowserQuickWindowWindowController<ActiveEngine>,
                                 url: URL?, to target: OrbitWindowController, spaceID: SpaceID, profileID: ProfileID) async -> Bool {
        guard !isPreparingToQuit, !little.isClosed, target.acceptsCommands,
              target.engine === little.engine, let surface = little.surface,
              !surface.isDisposed, little.owns(surface), let url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return false }
        let delivery = target.session.openTabForDelivery(url: url, expectedProfileID: profileID, expectedSpaceID: spaceID)
        guard await delivery.value != nil else { return false }
        await rememberQuickWindowProfile(url: url, profileID: profileID, selectedSpace: spaceID)
        little.retire()
        little.window?.close()
        target.hideLibrary()
        return true
    }

    private func rememberQuickWindowProfile(url: URL?, profileID: ProfileID, selectedSpace: SpaceID?) async {
        guard selectedSpace != nil, let url, let environment, !environment.isPrivate else { return }
        do {
            try await environment.settings.store.rememberQuickWindowProfile(for: url, profileID: profileID)
            await environment.settings.refresh()
        } catch { environment.onPersistenceError?(error) }
    }

    private func presentQuickWindowDestination(_ target: OrbitWindowController) {
        windowPresenter(target, true)
        if NSApp.activationPolicy() != .prohibited { NSApp.activate() }
    }

    func showQuickWindowSpaces(_ little: BrowserQuickWindowWindowController<ActiveEngine>) {
        guard let environment, environment.quickWindows[little.id] === little, !little.isClosed else { return }
        Task { [weak self, weak little] in
            let catalog = await environment.store.catalogSnapshot()
            guard let self, let little, self.environment === environment,
                  environment.quickWindows[little.id] === little, !little.isClosed, !little.isPromotionInProgress else { return }
            let rows = catalog.spaces.map { space in
                let icon = SpaceIconImages.view(environment.settings.document.space(space.id).iconSelection, pointSize: 20)
                return BrowserQuickWindowSearchRow(id: space.id.rawValue.uuidString, title: space.name,
                    image: (icon as? NSImageView)?.image,
                    iconBackground: OrbitSpaceThemes.accent(for: environment.spaceTheme(for: space.id)).soft) { [weak self, weak little] in
                        guard let little else { return }
                        little.spaceChooser?.hide()
                        self?.promoteQuickWindow(little, to: space.id)
                    }
            }
            little.showSpaceChooser(rows)
        }
    }

}
