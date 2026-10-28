import BrowserCore

/// Theme edits keep their captured Space/profile authority and join the session command queue.
/// Accepted final drafts still commit after the presenting window closes; the store validates
/// that their Space and profile remain valid independently of window lifetime.
extension BrowserWindowSession {
    public func setSpaceTheme(_ theme: BrowserSpaceTheme?, for spaceID: SpaceID,
                              profileID: ProfileID) async throws -> BrowserSpaceThemeChange {
        try await queuedThemeMutation { store in
            try await store.setSpaceTheme(theme, for: spaceID, profileID: profileID)
        }
    }

    public func applySpaceThemeChange(_ change: BrowserSpaceThemeChange) async throws {
        try await queuedThemeMutation { store in try await store.applySpaceThemeChange(change) }
    }

    private func queuedThemeMutation<Value: Sendable>(
        _ mutation: @escaping @Sendable (BrowserStore) async throws -> Value
    ) async throws -> Value {
        pendingCommandCount += 1
        let previous = pending
        let task = Task<Value, Error> { [self] in
            defer { pendingCommandCount -= 1 }
            await previous?.value
            return try await mutation(store)
        }
        pending = Task { _ = try? await task.value }
        return try await task.value
    }
}
