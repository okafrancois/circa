import BrowserCore
import BrowserEngine
import Foundation

/// Environment-owned stores survive tab and Space changes. Private environments use the
/// no-directory initializer; no regular-profile file or registration is inherited.
@MainActor
final class BrowserBoostsRuntime {
    private let directory: URL?
    private var stores: [ProfileID: BrowserBoostStore] = [:]
    private var generations: [ProfileID: UInt64] = [:]
    private(set) var acknowledgements: [ProfileID: BrowserBoostAcknowledgement] = [:]

    init(directory: URL? = nil) { self.directory = directory }

    func store(for profileID: ProfileID) throws -> BrowserBoostStore {
        if let store = stores[profileID] { return store }
        let store = try BrowserBoostStore(profileID: profileID,
                                         persistence: directory.map { .profileDirectory($0) } ?? .memoryOnly)
        stores[profileID] = store
        return store
    }

    /// Explicit synchronization seam for future editor commands; unavailable engines get no
    /// fallback injection. Every send has a fresh generation, including a global disable.
    func synchronize<Engine: BrowserEngine>(profileID: ProfileID, enabled: Bool, engine: Engine) async throws {
        guard engine.capabilities.contains(.boosts), let host = engine.boosts else {
            throw BrowserEngineError.unsupportedOperation
        }
        let store = try store(for: profileID)
        let generation = try nextGeneration(for: profileID)
        let table = await store.matchTable()
        guard generations[profileID] == generation else { throw BrowserBoostError.staleRevision }
        let acknowledgement = try await host.replaceBoosts(.init(profileID: profileID, revision: generation,
                                                                boosts: enabled ? table.payloads : []))
        guard generations[profileID] == generation, acknowledgement.profileID == profileID,
              acknowledgement.revision == generation else { throw BrowserBoostError.staleRevision }
        acknowledgements[profileID] = acknowledgement
    }

    func removeProfile<Engine: BrowserEngine>(_ profileID: ProfileID, engine: Engine) async throws {
        try await store(for: profileID).removeAll()
        if engine.capabilities.contains(.boosts), let host = engine.boosts {
            let generation = try nextGeneration(for: profileID)
            let acknowledgement = try await host.removeBoosts(profileID: profileID, revision: generation)
            guard generations[profileID] == generation, acknowledgement.profileID == profileID,
                  acknowledgement.revision == generation else { throw BrowserBoostError.staleRevision }
        }
        stores[profileID] = nil
        acknowledgements[profileID] = nil
    }

    private func nextGeneration(for profileID: ProfileID) throws -> UInt64 {
        let previous = generations[profileID] ?? 0
        guard previous < UInt64.max else { throw BrowserBoostError.revisionExhausted }
        generations[profileID] = previous + 1
        return previous + 1
    }
}
