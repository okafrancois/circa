import BrowserCore

extension BrowserStore {
    /// The displayed catalog and source authority are checked in the same actor turn as selection.
    func activateCatalogSpace(_ target: SpaceID, from context: BrowserContext,
                              catalog: BrowserCatalogSnapshot, admission: CatalogSelectionAdmission) throws -> BrowserWindowState {
        guard catalogSnapshot() == catalog, try captureContext(in: context.windowID) == context,
              admission.admit() else { throw BrowserStoreError.staleContext }
        return try activateSpace(target, from: context)
    }
}

public extension BrowserWindowSession {
    /// Explicit inventory selection must not be reinterpreted after its source window changes.
    func activateCatalogSpace(_ target: SpaceID, catalog: BrowserCatalogSnapshot, admission: CatalogSelectionAdmission,
                              isCurrent: @escaping @MainActor () -> Bool,
                              completion: @escaping @MainActor (Bool) -> Void) {
        guard let expected = activeContext, catalog.spaces.contains(where: { $0.id == target }) else {
            admission.revoke(); completion(false); return
        }
        enqueue { session in
            guard !session.isClosed, session.activeContext == expected, isCurrent() else {
                admission.revoke(); completion(false); return
            }
            do {
                let state = try await session.store.activateCatalogSpace(target, from: expected, catalog: catalog, admission: admission)
                session.install(state)
                completion(true)
            } catch { admission.revoke(); completion(false) }
        }
    }
}
