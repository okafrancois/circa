import Foundation
@preconcurrency import Translation

/// One system availability client for one translation strategy.
@MainActor
protocol BrowserLanguageAvailabilityBackend: AnyObject {
    func supportedLanguages() async -> [Locale.Language]
    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status
}

/// Wraps the system client. Instances are created once per strategy and never released.
@MainActor
final class SystemLanguageAvailability: BrowserLanguageAvailabilityBackend {
    private let availability: LanguageAvailability

    init(highFidelity: Bool) {
        if #available(macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: highFidelity ? .highFidelity : .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
    }

    func supportedLanguages() async -> [Locale.Language] { await availability.supportedLanguages }

    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        await availability.status(from: source, to: target)
    }
}

/// Process-wide gateway to translation language availability.
///
/// Every short-lived `LanguageAvailability` opens a status stream that the system tears down
/// when the object is released. Releasing one while the system is still answering another
/// request on its connection can crash inside the system framework (observed on macOS 27.3
/// with one client per status query while listing target languages). This gateway therefore:
/// - keeps exactly one client per strategy for the lifetime of the gateway;
/// - runs one query at a time;
/// - memoizes supported languages and recent pair statuses so documents share answers.
@MainActor
final class BrowserTranslationAvailability {
    typealias Status = LanguageAvailability.Status
    typealias BackendFactory = @MainActor (_ highFidelity: Bool) -> any BrowserLanguageAvailabilityBackend

    static let shared = BrowserTranslationAvailability()

    /// High-fidelity models exist from macOS 26.4.
    let highFidelityAvailable: Bool
    private let statusLifetime: Duration
    private let makeBackend: BackendFactory
    private var backends: [Bool: any BrowserLanguageAvailabilityBackend] = [:]
    private var languages: [Bool: [Locale.Language]] = [:]
    private var statuses: [StatusKey: (status: Status, time: ContinuousClock.Instant)] = [:]
    private var tail: Task<Void, Never>?

    private struct StatusKey: Hashable {
        let source: String
        let target: String
        let highFidelity: Bool
    }

    init(highFidelityAvailable: Bool? = nil, statusLifetime: Duration = .seconds(60),
         makeBackend: @escaping BackendFactory = { SystemLanguageAvailability(highFidelity: $0) }) {
        if let highFidelityAvailable {
            self.highFidelityAvailable = highFidelityAvailable
        } else if #available(macOS 26.4, *) {
            self.highFidelityAvailable = true
        } else {
            self.highFidelityAvailable = false
        }
        self.statusLifetime = statusLifetime
        self.makeBackend = makeBackend
    }

    func supportedLanguages(highFidelity: Bool) async -> [Locale.Language] {
        let highFidelity = highFidelity && highFidelityAvailable
        if let cached = languages[highFidelity] { return cached }
        return await serialized { [self] in
            if let cached = languages[highFidelity] { return cached }
            let value = await backend(highFidelity).supportedLanguages()
            languages[highFidelity] = value
            return value
        }
    }

    /// `refresh` bypasses the memoized answer, for checks that gate private documents.
    func status(from source: String, to target: String, highFidelity: Bool, refresh: Bool = false) async -> Status {
        let highFidelity = highFidelity && highFidelityAvailable
        let key = StatusKey(source: Locale.Language(identifier: source).minimalIdentifier,
                            target: Locale.Language(identifier: target).minimalIdentifier, highFidelity: highFidelity)
        if !refresh, let cached = recent(key) { return cached }
        return await serialized { [self] in
            if !refresh, let cached = recent(key) { return cached }
            let value = await backend(highFidelity).status(from: Locale.Language(identifier: source),
                                                           to: Locale.Language(identifier: target))
            statuses[key] = (value, .now)
            return value
        }
    }

    /// Model downloads change pair statuses; supported language lists do not.
    func invalidateStatuses() { statuses.removeAll() }

    private func recent(_ key: StatusKey) -> Status? {
        guard let entry = statuses[key], ContinuousClock.now - entry.time < statusLifetime else { return nil }
        return entry.status
    }

    private func backend(_ highFidelity: Bool) -> any BrowserLanguageAvailabilityBackend {
        if let backend = backends[highFidelity] { return backend }
        let backend = makeBackend(highFidelity)
        backends[highFidelity] = backend
        return backend
    }

    private func serialized<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await work()
        }
        tail = Task { @MainActor in _ = await task.value }
        return await task.value
    }
}
