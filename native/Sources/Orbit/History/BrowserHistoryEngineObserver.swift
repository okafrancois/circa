import BrowserCore
import BrowserEngine
import Foundation

/// Feature-owned registration for history. The router verifies ownership before delivery;
/// installation happens before the session starts any initial navigation.
@MainActor
final class BrowserHistoryEngineObserver<Surface: BrowserEngineSurface> {
    private let recorder: BrowserHistoryRecorder
    private let resolveProfile: (ProfileID) -> BrowserEngineProfile
    private var registration: BrowserHookRegistration?

    init(recorder: BrowserHistoryRecorder, resolveProfile: @escaping (ProfileID) -> BrowserEngineProfile) {
        self.recorder = recorder
        self.resolveProfile = resolveProfile
    }

    func install(in hooks: BrowserSurfaceEventHooks<Surface>) {
        registration?.cancel()
        registration = hooks.observe { [weak self] surface, event in
            switch event {
            case .navigationCommitted: self?.surfaceDidCommitNavigation(surface)
            case .stateChanged: self?.surfaceDidChange(surface)
            case .navigationFailed: self?.recorder.cancelTypedNavigation(surface)
            default: break
            }
        }
    }

    private var warmedProfile: ProfileID?
    private var warmup: Task<Void, Never>?

    func activateProfile(_ profileID: ProfileID?) {
        guard profileID != warmedProfile else { return }
        warmedProfile = profileID
        warmup?.cancel()
        guard let profileID else { warmup = nil; return }
        warmup = Task { [weak recorder] in await recorder?.prepareSuggestions(for: profileID) }
    }

    func suggestions(for profileID: ProfileID, query: String) async throws -> [BrowserHistorySuggestion] {
        try await recorder.suggestions(for: profileID, query: query)
    }

    /// Synchronous keystroke results from the warm per-profile memory index.
    func cachedSuggestions(for profileID: ProfileID, query: String, limit: Int = 12) -> [BrowserHistorySuggestion] {
        recorder.cachedSuggestions(for: profileID, query: query, limit: limit)
    }

    /// Opens the store and warms the memory index off the main actor.
    func prepareSuggestions(for profileID: ProfileID) async { await recorder.prepareSuggestions(for: profileID) }

    func markTypedNavigation(_ surface: Surface, url: URL) { recorder.markTypedNavigation(surface, url: url) }

    private func surfaceDidCommitNavigation(_ surface: Surface) {
        recorder.committed(surface, profile: resolveProfile(surface.profileID))
    }

    private func surfaceDidChange(_ surface: Surface) {
        recorder.metadataChanged(surface)
    }
}
