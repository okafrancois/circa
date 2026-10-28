import BrowserCore
import Foundation

/// A draft is bound to one store and identity. Queued edits read the latest committed revision,
/// so fast controls cannot overwrite each other or escape into a newly selected profile.
@MainActor
final class BrowserBoostEditorSession {
    let store: BrowserBoostStore
    private(set) var boost: BrowserBoost
    private(set) var isClosed = false
    private(set) var error: Error?
    private(set) var pending: Task<Void, Never>?
    var onChange: (() -> Void)?
    var onCommit: (() async throws -> Void)?

    init(store: BrowserBoostStore, boost: BrowserBoost) {
        self.store = store
        self.boost = boost
    }

    static func create(in store: BrowserBoostStore, url: URL, title: String) async throws -> BrowserBoostEditorSession {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              let scheme = components.scheme.flatMap(BrowserBoostHostPattern.Scheme.init(rawValue:)),
              let host = components.encodedHost else { throw BrowserBoostError.invalidHostPattern }
        let pattern = try BrowserBoostHostPattern(host: host, schemes: [scheme], port: components.port)
        let boost = try await store.save(BrowserBoost(title: title, hostPattern: pattern))
        return BrowserBoostEditorSession(store: store, boost: boost)
    }

    func edit(_ mutation: @escaping (inout BrowserBoostContent) -> Void) {
        guard !isClosed else { return }
        let previous = pending
        pending = Task { [self] in
            await previous?.value
            var next = boost
            mutation(&next.content)
            do {
                boost = try await store.save(next, expectedRevision: boost.revision)
                error = nil
                try await onCommit?()
            } catch { self.error = error }
            onChange?()
        }
    }

    func zap(_ selector: String) {
        edit { if !$0.zapSelectors.contains(selector) { $0.zapSelectors.append(selector) } }
    }
    func unzap(_ selector: String) { edit { $0.zapSelectors.removeAll { $0 == selector } } }
    func resetColors() { edit { $0.colorScheme = nil } }
    func close() { isClosed = true }
}
