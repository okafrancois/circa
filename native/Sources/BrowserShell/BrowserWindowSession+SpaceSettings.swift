import BrowserCore

public extension BrowserWindowSession {
    /// Capture before presentation, including the source window's profile epoch.
    func captureSpaceSettingsAuthority(for spaceID: SpaceID, profileID: ProfileID) -> BrowserSpaceSettingsAuthority? {
        guard !isClosed, let windowID, let sourceProfile = activeProfileID else { return nil }
        return store.captureSpaceSettingsAuthority(for: spaceID, profileID: profileID,
                                                  sourceWindow: windowID, sourceProfile: sourceProfile)
    }

    /// Accepted settings mutations join the window queue and therefore settle before Quit.
    /// Closing the window revokes mutations still waiting for settings publication.
    func updateSpaceIcon(_ icon: BrowserSpaceIcon, authority: BrowserSpaceSettingsAuthority,
                         settings: BrowserSettingsStore, sourceProfile: ProfileID) async throws {
        guard !isClosed, icon.isValid else { throw BrowserStoreError.staleContext }
        let diagnostic = trackCommand(kind: #function)
        let previous = pending
        pendingCommandCount += 1
        spaceSettingsActions[authority.id] = authority
        let operation = Task { @MainActor [self] in
            defer {
                pendingCommandCount -= 1
                spaceSettingsActions.removeValue(forKey: authority.id)
            }
            defer { diagnostic.finish() }
            await previous?.value
            activeCommandDiagnostic = diagnostic
            diagnostic.step = "model-or-surface-publication"
            guard !isClosed, activeProfileID == sourceProfile else { throw BrowserStoreError.staleContext }
            try await settings.updateSpace(authority.spaceID, authority: authority) { $0.iconSelection = icon }
        }
        pending = Task { _ = try? await operation.value }
        try await operation.value
    }
}
