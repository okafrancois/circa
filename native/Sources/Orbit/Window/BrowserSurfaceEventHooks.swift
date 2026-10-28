import BrowserEngine

/// Engine events of the surfaces one window holds, as delivered to feature observers.
enum BrowserSurfaceEvent: Equatable, Sendable {
    case navigationStarted
    /// A new document is visible: the event for visit recording.
    case navigationCommitted
    case navigationFinished
    case navigationFailed
    /// Coalesced URL, title, history or zoom change of the current document.
    case stateChanged
    /// The address changed without a new document (fragment, History API): no commit precedes it.
    case navigatedWithinDocument(BrowserSameDocumentNavigation.Kind)
}

/// What a new-target route did with an engine request.
enum BrowserNewTargetRouting<Surface> {
    case declined
    /// Handled: give this surface to the engine, or nil to refuse the target.
    case handled(Surface?)
}

/// What a navigation route did with a navigation of a held surface.
enum BrowserNavigationRouting: Equatable {
    /// Not handled: the next route, then the window's own policy, decides.
    case declined
    /// Handled: answer the engine with this policy. A route that takes the link elsewhere answers
    /// `.cancel` and opens it on a later turn, never inside the policy question.
    case handled(BrowserNavigationActionPolicy)
}

/// Registration point for features that react to engine events without editing the window
/// controller core or its `BrowserEngineSurfaceDelegate` conformance: Peek routes new targets,
/// history observes commits, engine lots add diagnostics. A feature registers once from its own
/// `install<Feature>(in:)`. Observers see only surfaces the window holds and the window's Peek
/// document (placement `.peek`), after the window's own handling; routes are consulted in
/// registration order after the window validated the request.
@MainActor
final class BrowserSurfaceEventHooks<Surface: BrowserEngineSurface> {
    typealias Observer = @MainActor (Surface, BrowserSurfaceEvent) -> Void
    typealias NewTargetRoute = @MainActor (
        _ source: Surface, _ request: BrowserNewSurfaceRequest, _ make: () -> Surface
    ) -> BrowserNewTargetRouting<Surface>

    private var observers: [(token: BrowserHookRegistration, observer: Observer)] = []
    private var routes: [(token: BrowserHookRegistration, route: NewTargetRoute)] = []
    typealias NavigationRoute = @MainActor (_ source: Surface, _ action: BrowserNavigationAction) -> BrowserNavigationRouting
    private var navigationRoutes: [(token: BrowserHookRegistration, route: NavigationRoute)] = []

    @discardableResult
    func observe(_ observer: @escaping Observer) -> BrowserHookRegistration {
        let token = BrowserHookRegistration()
        token.onCancel = { [weak self, weak token] in self?.observers.removeAll { $0.token === token } }
        observers.append((token, observer))
        return token
    }

    @discardableResult
    func routeNewTargets(_ route: @escaping NewTargetRoute) -> BrowserHookRegistration {
        let token = BrowserHookRegistration()
        token.onCancel = { [weak self, weak token] in self?.routes.removeAll { $0.token === token } }
        routes.append((token, route))
        return token
    }

    /// Routes main-frame navigations of tabs the window holds (Peek: Shift-click on engines that
    /// report modified clicks as navigations, such as WebKit). Consulted synchronously from the
    /// navigation policy, after the window's own scheme and download checks: keep routes cheap.
    @discardableResult
    func routeNavigations(_ route: @escaping NavigationRoute) -> BrowserHookRegistration {
        let token = BrowserHookRegistration()
        token.onCancel = { [weak self, weak token] in self?.navigationRoutes.removeAll { $0.token === token } }
        navigationRoutes.append((token, route))
        return token
    }

    func routeNavigation(from source: Surface, action: BrowserNavigationAction) -> BrowserNavigationRouting {
        for entry in navigationRoutes where !entry.token.isCancelled {
            if case .handled(let policy) = entry.route(source, action) { return .handled(policy) }
        }
        return .declined
    }

    func emit(_ event: BrowserSurfaceEvent, for surface: Surface) {
        for entry in observers where !entry.token.isCancelled {
            entry.observer(surface, event)
        }
    }

    func routeNewTarget(from source: Surface, request: BrowserNewSurfaceRequest,
                        make: () -> Surface) -> BrowserNewTargetRouting<Surface> {
        for entry in routes where !entry.token.isCancelled {
            if case .handled(let surface) = entry.route(source, request, make) { return .handled(surface) }
        }
        return .declined
    }
}

/// Keeps one hook registered until `cancel()`.
@MainActor
final class BrowserHookRegistration {
    fileprivate var onCancel: (() -> Void)?
    private(set) var isCancelled = false

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel?()
        onCancel = nil
    }
}
