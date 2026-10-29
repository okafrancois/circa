import BrowserCore
import Foundation

public extension BrowserWindowSession {
    /// Published identity only. Pending work is drained at acceptance, never during typing.
    var paletteContext: BrowserContext? { isClosed ? nil : activeContext }

    func paletteDocument() async -> BrowserSessionDocument { await store.sessionDocument() }

    /// A palette invocation joins the existing queue synchronously. Only a window or selected
    /// occurrence identity is retained; redirects and document generations cannot revoke input.
    @discardableResult
    func navigateFromPalette(from expected: BrowserContext, newTab: Bool,
                             navigate: @escaping @MainActor (Surface) -> Void) -> Task<Bool, Never> {
        var attemptedCreation = false
        return paletteOperation { session, context in
            guard context.windowID == expected.windowID,
                  newTab || context.selectedOccurrenceID == expected.selectedOccurrenceID else { return false }
            if newTab || session.selectedSurface == nil {
                // Creation owns its pre-commit retries. Never replay it through the outer
                // organization retry if a future post-commit validation begins to throw.
                guard !attemptedCreation else { throw BrowserStoreError.staleContext }
                attemptedCreation = true
                let existing = Set(session.snapshot?.tabs.map(\.occurrenceID) ?? [])
                // The uncaptured creation path retries only an open refused before its commit,
                // then adopts peer organization reconciliation without replaying the creation.
                try await session.createTab(url: URL(string: "about:blank")!, activate: true)
                guard let selected = session.snapshot?.selectedOccurrenceID, !existing.contains(selected) else { return false }
            }
            guard !session.isClosed, let surface = session.selectedSurface else { return false }
            navigate(surface)
            return true
        }
    }

    @discardableResult
    func restoreFromPalette(_ id: TabID, from expected: BrowserContext) -> Task<Bool, Never> {
        paletteOperation { session, context in
            guard context.windowID == expected.windowID, context.profileID == expected.profileID else { return false }
            let state = try await session.store.restoreArchivedTab(id, activate: true, from: context)
            session.install(state)
            return !session.isClosed
        }
    }

    /// Switching targets an existing logical identity in the accepted profile. URL replay is
    /// never a substitute for selecting an occurrence or restoring its original identity.
    @discardableResult
    func selectFromPalette(_ id: TabID, from expected: BrowserContext, spaceID: SpaceID?) -> Task<Bool, Never> {
        paletteOperation { session, context in
            guard context.windowID == expected.windowID, context.profileID == expected.profileID else { return false }
            var target = context
            if let spaceID, spaceID != context.spaceID {
                guard session.catalog?.spaces.contains(where: { $0.id == spaceID && $0.profileID == expected.profileID }) == true else { return false }
                let state = try await session.store.activateSpace(spaceID, from: context)
                session.install(state)
                target = state.context
            }
            let state = try await session.selectTabState(id, from: target)
            session.install(state)
            return !session.isClosed
        }
    }
}

extension BrowserWindowSession {
    func paletteOperation(_ action: @escaping @MainActor (BrowserWindowSession, BrowserContext) async throws -> Bool) -> Task<Bool, Never> {
        guard !isClosed else { return Task { false } }
        pendingCommandCount += 1
        let previous = pending
        let task = Task<Bool, Never> { [self] in
            defer { pendingCommandCount -= 1 }
            await previous?.value
            guard !isClosed, !Task.isCancelled else { return false }
            do {
                return try await runOrganizationCommand { session, context in
                    guard !Task.isCancelled else { return false }
                    return try await action(session, context)
                } ?? false
            } catch {
                if !isClosed, !Task.isCancelled { onError?(error) }
                return false
            }
        }
        pending = Task { _ = await task.value }
        return task
    }
}
