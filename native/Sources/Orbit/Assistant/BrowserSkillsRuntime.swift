import BrowserCore
import Foundation
import Observation

/// Regular profiles receive a confined destination; private environments remain memory-only.
@MainActor
@Observable final class BrowserSkillsRuntime {
    private(set) var documents: [ProfileID: BrowserAISkillDocument] = [:]
    func refresh(_ profile: ProfileID) async {
        guard let store = try? store(for: profile) else { return }
        let value = await store.snapshot()
        guard !removed.contains(profile), stores[profile] === store else { return }
        documents[profile] = value
    }
    private let directory: URL?
    private var removed: Set<ProfileID> = []
    private var stores: [ProfileID: BrowserAISkillStore] = [:]
    init(directory: URL? = nil) { self.directory = directory }
    func store(for profile: ProfileID) throws -> BrowserAISkillStore {
        guard !removed.contains(profile) else { throw BrowserAISkillError.wrongProfile }
        if let store = stores[profile] { return store }
        let store = try BrowserAISkillStore(profileID: profile,
            persistence: directory.map { .profileDirectory($0) } ?? .memoryOnly)
        stores[profile] = store
        return store
    }
    func removeProfile(_ profile: ProfileID) async throws {
        let store = try store(for: profile)
        removed.insert(profile)
        try await store.removeAll()
        stores[profile] = nil
        documents[profile] = nil
    }
}
