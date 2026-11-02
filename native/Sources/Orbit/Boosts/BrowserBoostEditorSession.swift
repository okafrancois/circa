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
    private var applyingGeneratedCSS: (generated: String, original: String)?
    private var applyingGeneratedJavaScript: (generated: String, original: String, consent: Bool)?
    private(set) var pending: Task<Void, Never>?
    var onInvalidateDraft: (() -> Void)?
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
        onInvalidateDraft?()
        let restoration = applyingGeneratedCSS
        let scriptRestoration = applyingGeneratedJavaScript
        enqueue { [self] in
            boost = try await store.update(boost.id) {
                if let restoration, $0.content.customCSS == restoration.generated { $0.content.customCSS = restoration.original }
                if let scriptRestoration, $0.content.customJavaScript == scriptRestoration.generated {
                    $0.content.customJavaScript = scriptRestoration.original
                    $0.javaScriptOptIn = scriptRestoration.consent
                }
                mutation(&$0)
            }
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
        onInvalidateDraft?()
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

    func applyGeneratedCSS(_ css: String, expected: BrowserBoostDocument, isCurrent: @escaping @MainActor () -> Bool) async throws {
        guard !isClosed, !isDeleting, isCurrent() else { throw CancellationError() }
        await pending?.value
        guard !isClosed, !isDeleting, isCurrent() else { throw CancellationError() }
        let original = boost
        applyingGeneratedCSS = (css, original.content.customCSS)
        defer { applyingGeneratedCSS = nil }
        let applied = try await store.applyGeneratedCSS(css, to: boost.id, expected: expected)
        boost = applied
        guard !isClosed, !isDeleting, isCurrent() else {
            if let restored = try? await store.save(original, expectedRevision: applied.revision) { boost = restored }
            throw CancellationError()
        }
        do { try await onCommit?() }
        catch {
            if let restored = try? await store.save(original, expectedRevision: applied.revision) {
                boost = restored
                try? await onCommit?()
            }
            throw error
        }
        guard !isClosed, !isDeleting, isCurrent() else {
            if let restored = try? await store.save(original, expectedRevision: applied.revision) {
                boost = restored
                try await onCommit?()
            }
            throw CancellationError()
        }
        onChange?()
    }

    func applyGeneratedJavaScript(_ source: String, expected: BrowserBoostDocument, isCurrent: @escaping @MainActor () -> Bool) async throws {
        guard !isClosed, !isDeleting, isCurrent() else { throw CancellationError() }
        await pending?.value
        guard !isClosed, !isDeleting, isCurrent() else { throw CancellationError() }
        let original = boost
        applyingGeneratedJavaScript = (source, original.content.customJavaScript, original.javaScriptOptIn)
        defer { applyingGeneratedJavaScript = nil }
        let applied = try await store.applyGeneratedJavaScript(source, to: boost.id, expected: expected)
        boost = applied
        func appliedSnapshotIsCurrent() async -> Bool {
            let current = await store.snapshot()
            return current.version == expected.version && current.profileID == expected.profileID
                && current.revision == expected.revision + 1
                && current.boosts == expected.boosts.map { $0.id == applied.id ? applied : $0 }
        }
        guard !isClosed, !isDeleting, isCurrent(), await appliedSnapshotIsCurrent(), !isClosed, !isDeleting, isCurrent() else {
            if let restored = try? await store.save(original, expectedRevision: applied.revision) { boost = restored }
            throw CancellationError()
        }
        do { try await onCommit?() }
        catch {
            if let restored = try? await store.save(original, expectedRevision: applied.revision) {
                boost = restored
                try? await onCommit?()
            }
            throw error
        }
        guard !isClosed, !isDeleting, isCurrent(), await appliedSnapshotIsCurrent(), !isClosed, !isDeleting, isCurrent() else {
            if let restored = try? await store.save(original, expectedRevision: applied.revision) {
                boost = restored
                try await onCommit?()
            }
            throw CancellationError()
        }
        onChange?()
    }

    func zap(_ selector: String) {
        edit { if !$0.zapSelectors.contains(selector) { $0.zapSelectors.append(selector) } }
    }
    func unzap(_ selector: String) { edit { $0.zapSelectors.removeAll { $0 == selector } } }
    func resetColors() { edit { $0.colorScheme = nil } }
    func close() { onInvalidateDraft?(); isClosed = true }
}
