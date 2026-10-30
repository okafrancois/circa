import AppKit
import BrowserCore

extension OrbitApplication {
    /// Only the macOS URL entry point calls this. Page navigation and internal new tabs
    /// keep their originating context, even when their URL matches an external route.
    func routeConfiguredExternalURLs(_ urls: [URL], routing: BrowserLinkRouting) {
        let source = windows.selectedWindow
        let context = source?.session.captureContextInCommandOrder()
        let sourceID = windows.selectedWindowID
        let sourceProfileID = source?.session.activeProfileID
            ?? sourceID.flatMap { inheritedWindowProfiles[$0] }
        for url in urls {
            let request = BrowserQuickWindowOpenRequest(url: url, profileID: sourceProfileID,
                opensInQuickWindow: routing.defaultDestination == .quickWindow, isExternalOpen: true)
            quickWindowOpenRequests.append(request)
            enqueueQuickWindowCommand { [weak self] in
                guard let self, let environment else { return }
                await windows.waitForPendingCommands()
                let captured: BrowserContext?
                if let context { captured = await context.value }
                else if let sourceID, let pendingSource = windows.windows[sourceID] {
                    captured = await pendingSource.session.captureContextInCommandOrder().value
                } else { captured = nil }
                let catalog = await environment.store.catalogSnapshot()
                let destination = routing.destination(for: url, availableSpaces: Set(catalog.spaces.map(\.id)))
                if case .space(let id) = destination,
                   let space = catalog.spaces.first(where: { $0.id == id }) {
                    request.spaceID = space.id
                    request.profileID = space.profileID
                    request.hasRoutingDestination = true
                    await deliverRoutedExternalRequest(request)
                } else if destination == .quickWindow {
                    request.spaceID = captured?.spaceID
                    request.profileID = captured?.profileID ?? sourceProfileID
                    do {
                        let little = try await environment.makeExternalQuickWindow(url: url, spaceID: request.spaceID, profileID: request.profileID)
                        request.spaceID = little.sourceSpaceID
                        request.profileID = little.profileID
                        configureQuickWindow(little)
                        presentAndScheduleUpdates { quickWindowPresenter(little) }
                        confirmQuickWindowRequest(request)
                    } catch { await openQuickWindowFallback(request) }
                } else {
                    let profileID = captured?.profileID ?? sourceProfileID
                    let spaces = catalog.spaces.filter { profileID == nil || $0.profileID == profileID }
                    let space = spaces.first { $0.id == captured?.spaceID }
                        ?? spaces.first { $0.id == environment.lastUsedSpaceID }
                        ?? spaces.first
                    guard let space else { retainQuickWindowRequest(request); return }
                    request.spaceID = space.id
                    request.profileID = space.profileID
                    request.hasRoutingDestination = true
                    await deliverRoutedExternalRequest(request, preferredWindowID: sourceID)
                }
            }
        }
    }

    /// The Space and its owning profile are validated again at the ordered mutation boundary.
    /// Another window becoming active while delivery waits cannot retarget the URL.
    func deliverRoutedExternalRequest(_ request: BrowserQuickWindowOpenRequest, preferredWindowID: UUID? = nil) async {
        guard let environment, let spaceID = request.spaceID, let profileID = request.profileID,
              let url = request.url else { retainQuickWindowRequest(request); return }
        let catalog = await environment.store.catalogSnapshot()
        guard catalog.spaces.contains(where: { $0.id == spaceID && $0.profileID == profileID }) else {
            retainQuickWindowRequest(request)
            return
        }
        let candidates = windows.windows.values.filter { !$0.session.isClosed && $0.session.activeProfileID == profileID }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let target: OrbitWindowController
        if let existing = candidates.first(where: { $0.id == preferredWindowID })
            ?? candidates.first(where: { $0.session.snapshot?.activeSpaceID == spaceID })
            ?? candidates.first(where: { $0.id == windows.selectedWindowID }) ?? candidates.first {
            target = existing
        } else {
            let id = UUID()
            quickWindowDestinationSpaces[id] = spaceID
            defer { quickWindowDestinationSpaces[id] = nil }
            guard windows.newWindow(id: id) != nil else { retainQuickWindowRequest(request); return }
            await windows.waitForPendingCommands()
            guard let created = windows.windows[id] else { retainQuickWindowRequest(request); return }
            target = created
        }
        let delivery = target.session.openTabForDelivery(url: url, expectedProfileID: profileID, expectedSpaceID: spaceID)
        guard await delivery.value != nil else { retainQuickWindowRequest(request); return }
        confirmQuickWindowRequest(request)
        if !target.session.isClosed {
            target.hideLibrary()
            windows.activate(target.id)
            windowPresenter(target, true)
            if NSApp.activationPolicy() != .prohibited { NSApp.activate() }
        }
    }
}
