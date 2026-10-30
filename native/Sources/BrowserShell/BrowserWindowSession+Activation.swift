import BrowserCore

private extension BrowserStore {
    func activateOwnedSurface(_ authority: BrowserOccurrenceAuthority, from context: BrowserContext,
                              lifetime: SurfaceCommandLifetime, targetLifetime: SurfaceCommandLifetime) throws -> BrowserWindowState? {
        try lifetime.whileActive {
            try targetLifetime.whileActive {
                let before = try captureWindowState(from: context)
                guard authority.windowID == context.windowID,
                      before.occurrenceAuthorities[authority.occurrenceID] == authority else { return nil }
                let active = try activateSpace(authority.spaceID, from: context)
                try selectOccurrence(authority.occurrenceID, from: active.context)
                return try captureWindowState(in: authority.windowID)
            } ?? nil
        } ?? nil
    }
}

public extension BrowserWindowSession {
    /// A native notification/focus action selects the existing occurrence, never a URL lookalike.
    /// A close or transfer revokes it; the receiving window's current delegate owns later actions.
    @discardableResult
    func activateOwnedSurface(_ surface: Surface) -> Task<Bool, Never> {
        let occurrence = occurrenceID(for: surface)
        let authority = occurrence.flatMap { authorities[$0] }
        let ownership = BrowserSurfaceProvenance.ownedRecord(for: surface, owner: self)
        pendingCommandCount += 1
        let diagnostic = trackCommand(kind: #function)
        let previous = pending
        let activation = Task<Bool, Never> { [self] in
            defer { pendingCommandCount -= 1 }
            defer { diagnostic.finish() }
            await previous?.value
            activeCommandDiagnostic = diagnostic
            diagnostic.step = "model-or-surface-publication"
            guard !isClosed, let occurrence, let authority, let ownership,
                  surfaces[occurrence] === surface, authorities[occurrence] == authority,
                  BrowserSurfaceProvenance.ownedRecord(for: surface, owner: self) === ownership else { return false }
            do {
                guard let context = try await validatedContext(),
                      let state = try await store.activateOwnedSurface(authority, from: context,
                        lifetime: surfaceCommandLifetime, targetLifetime: ownership.lifetime), !isClosed else { return false }
                install(state)
                return selectedSurface === surface
            } catch { onError?(error); return false }
        }
        pending = Task { _ = await activation.value }
        return activation
    }
}
