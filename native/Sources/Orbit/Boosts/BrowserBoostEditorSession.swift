import BrowserCore
import Foundation

/// A draft is bound to one store and identity. Queued edits read the latest committed revision,
/// so fast controls cannot overwrite each other or escape into a newly selected profile.
@MainActor
final class BrowserBoostEditorSession {
    let store: BrowserBoostStore
    private(set) var boost: BrowserBoost
    private(set) var isDeleted = false
    private(set) var isDeleting = false
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

    private func update(_ mutation: @escaping @Sendable (inout BrowserBoost) -> Void) {
        guard !isClosed, !isDeleting else { return }
        enqueue { [self] in
            boost = try await store.update(boost.id, mutation: mutation)
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) {
        let previous = pending
        pending = Task { [self] in
            await previous?.value
            do {
                try await operation()
                error = nil
                try await onCommit?()
            } catch { self.error = error }
            onChange?()
        }
    }

    func edit(_ mutation: @escaping @Sendable (inout BrowserBoostContent) -> Void) {
        update { mutation(&$0.content) }
    }

    static func canRename(to title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func rename(to title: String) {
        guard Self.canRename(to: title) else { return }
        update { $0.title = title }
    }

    func resetAllEdits() {
        update { $0.content = .init(); $0.javaScriptOptIn = false }
    }

    func setJavaScriptConsent(_ consent: Bool) { update { $0.javaScriptOptIn = consent } }

    /// Accepted deletion drains earlier edits and prevents later writes from recreating the item.
    func delete() {
        guard !isClosed, !isDeleting else { return }
        isDeleting = true
        enqueue { [self] in
            do {
                try await store.removeCurrent(boost.id)
                isDeleted = true; isClosed = true
            } catch {
                isDeleting = false
                throw error
            }
        }
    }

    func zap(_ selector: String) {
        edit { if !$0.zapSelectors.contains(selector) { $0.zapSelectors.append(selector) } }
    }
    func unzap(_ selector: String) { edit { $0.zapSelectors.removeAll { $0 == selector } } }
    func resetColors() { edit { $0.colorScheme = nil } }
    func close() { isClosed = true }
}
