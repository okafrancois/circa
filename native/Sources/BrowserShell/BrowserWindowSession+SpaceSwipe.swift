import BrowserCore

extension BrowserStore {
    /// Atomic catalog validation and selection: no await can reassign a target's profile between them.
    func activateSpaceFromSwipe(_ target: SpaceID, from context: BrowserContext,
                                catalog: BrowserCatalogSnapshot, admission: SpaceSwipeAdmission) throws -> BrowserWindowState {
        guard catalogSnapshot() == catalog else { throw BrowserStoreError.staleContext }
        guard try captureContext(in: context.windowID) == context, admission.admit() else { throw BrowserStoreError.staleContext }
        return try activateSpace(target, from: context)
    }
}

public extension BrowserWindowSession {
    /// Read-only projection input. Does not create occurrences, navigate or activate a Space.
    func spaceSwipeDocument() async -> BrowserSessionDocument { await store.sessionDocument() }

    /// The source context is captured now and checked again in command order. Unlike keyboard
    /// relative movement, a stale gesture must never be reinterpreted against a new context.
    func activateSpaceFromSwipe(_ target: SpaceID, catalog: BrowserCatalogSnapshot,
                                admission: SpaceSwipeAdmission = .init(),
                                waitForPresentation: @escaping @MainActor () async -> Void = {},
                                isCurrent: @escaping @MainActor () -> Bool,
                                completion: @escaping @MainActor (Bool) -> Void) {
        guard let expected = activeContext else { completion(false); return }
        enqueue { session in
            await waitForPresentation()
            guard isCurrent(), !session.isClosed, session.activeContext == expected else {
                completion(false); return
            }
            do {
                let state = try await session.store.activateSpaceFromSwipe(target, from: expected, catalog: catalog, admission: admission)
                session.install(state)
                completion(true)
            } catch {
                completion(false)
            }
        }
    }
}
