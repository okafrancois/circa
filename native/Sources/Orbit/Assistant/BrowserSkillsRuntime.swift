import BrowserCore
import Foundation

/// Regular profiles receive a confined destination; private environments remain memory-only.
@MainActor
final class BrowserSkillsRuntime {
    private let directory: URL?
    private var stores: [ProfileID: BrowserAISkillStore] = [:]
    init(directory: URL? = nil) { self.directory = directory }
    func store(for profile: ProfileID) throws -> BrowserAISkillStore {
        if let store = stores[profile] { return store }
        let store = try BrowserAISkillStore(profileID: profile,
            persistence: directory.map { .profileDirectory($0) } ?? .memoryOnly)
        stores[profile] = store
        return store
    }
    func removeProfile(_ profile: ProfileID) async throws {
        try await store(for: profile).removeAll()
        stores[profile] = nil
    }
}
