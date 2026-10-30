import BrowserCore
import BrowserEngine
import Combine
import Foundation

/// Keep drafts independent of asynchronous settings acknowledgements. Each accepted input
/// queues its write immediately, so a later removal cannot be followed by a stale row save.
@MainActor
final class BrowserLinkRoutingEditor<Engine: BrowserEngine>: ObservableObject {
    @Published private(set) var routes: [BrowserLinkRoute] = []
    private let model: BrowserSettingsModel<Engine>

    init(model: BrowserSettingsModel<Engine>) { self.model = model }

    func load() {
        routes = model.runtime.document.linkRouting.rules.filter { route in
            model.catalog.spaces.contains { $0.id == route.spaceID }
        }
    }

    func add() {
        guard model.acceptsActions, !routes.contains(where: { !$0.isValid }),
              let space = model.catalog.spaces.first else { return }
        routes.append(.init(value: "", spaceID: space.id))
    }

    func update<Value>(_ id: UUID, keyPath: WritableKeyPath<BrowserLinkRoute, Value>, value: Value) {
        guard model.acceptsActions, let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index][keyPath: keyPath] = value
        let route = routes[index]
        guard route.isValid else { return }
        model.perform { [model] in try await model.saveLinkRoute(route) }
    }

    func remove(_ id: UUID) {
        guard model.acceptsActions, routes.contains(where: { $0.id == id }) else { return }
        routes.removeAll { $0.id == id }
        model.perform { [model] in
            try await model.runtime.store.removeLinkRoute(id)
            await model.runtime.refresh()
        }
    }

    func move(_ id: UUID, offset: Int) {
        guard model.acceptsActions, !routes.contains(where: { !$0.isValid }),
              let index = routes.firstIndex(where: { $0.id == id }),
              routes.indices.contains(index + offset) else { return }
        routes.swapAt(index, index + offset)
        model.perform { [model] in
            try await model.runtime.store.moveLinkRoute(id, offset: offset)
            await model.runtime.refresh()
        }
    }
}
