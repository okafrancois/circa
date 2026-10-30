import BrowserCore
import BrowserEngine
import Foundation

enum BrowserPrivateDomainError: Error, Equatable {
    case persistentEngine, extensionsEnabled, cleanupUnsupported, reusedEngine
    case scopeClosed, foreignLease, foreignSurface, ownersRemain
}

/// One factory per normal environment. Creating a scope does not create an engine, profile or
/// window. The caller must eventually close each scope; no window-sharing policy is implied.
@MainActor
final class BrowserPrivateDomainFactory<Engine: BrowserPrivateEngine> {
    private weak var normalEngine: Engine?
    fileprivate let downloadPreferences: @MainActor () -> BrowserDownloadPreferences
    private let build: @MainActor () async throws -> Engine
    private(set) var quarantinedScopes: [UUID: BrowserPrivateDomainScope<Engine>] = [:]

    init(normalEnvironment: BrowserEnvironment<Engine>, build: @escaping @MainActor () async throws -> Engine) {
        normalEngine = normalEnvironment.engine
        downloadPreferences = { [weak normalEnvironment] in normalEnvironment?.settings.document.downloads ?? .init() }
        self.build = build
        PrivateEngineReservations.markNormal(normalEnvironment.engine)
    }

    func makeScope() -> BrowserPrivateDomainScope<Engine> { BrowserPrivateDomainScope(factory: self) }

    /// Failed creation may return no lease. Retain its cleanup authority until an explicit retry
    /// succeeds, instead of losing a still-live native context when the caller drops the error.
    fileprivate func quarantine(_ scope: BrowserPrivateDomainScope<Engine>) { quarantinedScopes[scope.id] = scope }
    fileprivate func didClose(_ scope: BrowserPrivateDomainScope<Engine>) { quarantinedScopes[scope.id] = nil }
    func retryQuarantinedScopes() async throws {
        var firstError: (any Error)?
        for scope in Array(quarantinedScopes.values) {
            do { try await scope.close() }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    fileprivate func admittedEngine() async throws -> Engine {
        let engine = try await build()
        // These queries cannot materialize a profile. Never clean up an unadmitted engine:
        // a broken factory might have returned the normal engine itself.
        guard engine !== normalEngine else { throw BrowserPrivateDomainError.reusedEngine }
        guard engine.persistence == .ephemeral else { throw BrowserPrivateDomainError.persistentEngine }
        guard engine.extensions == nil else { throw BrowserPrivateDomainError.extensionsEnabled }
        guard engine.capabilities.contains(.profileRemoval) else { throw BrowserPrivateDomainError.cleanupUnsupported }
        try PrivateEngineReservations.reserve(engine)
        return engine
    }
}

/// Reservations span factories too. Weak values permit allocator address reuse after an engine
/// dies, while forbidding reuse of a still-alive engine even after its first scope closed.
@MainActor
private enum PrivateEngineReservations {
    private final class Entry {
        weak var engine: AnyObject?
        init(_ engine: AnyObject) { self.engine = engine }
    }
    private static var entries: [ObjectIdentifier: Entry] = [:]
    static func markNormal(_ engine: AnyObject) { entries[ObjectIdentifier(engine)] = Entry(engine) }
    static func reserve(_ engine: AnyObject) throws {
        entries = entries.filter { $0.value.engine != nil }
        guard entries[ObjectIdentifier(engine)] == nil else { throw BrowserPrivateDomainError.reusedEngine }
        entries[ObjectIdentifier(engine)] = Entry(engine)
    }
}

@MainActor
final class BrowserPrivateDomainLease {
    fileprivate let scopeID: UUID
    fileprivate let id = UUID()
    fileprivate var released = false
    // An outstanding lease keeps its scope and cleanup authority alive. Release is explicit;
    // dropping a Swift wrapper is not evidence that a native owner has closed.
    fileprivate var owner: AnyObject?
    fileprivate init(scopeID: UUID, owner: AnyObject) { self.scopeID = scopeID; self.owner = owner }
}

/// Backend ownership only. No menus, window presentation, implicit normal-profile inheritance,
/// or automatic cross-scope adoption. A fresh scope has a fresh identity, even after cleanup.
@MainActor
final class BrowserPrivateDomainScope<Engine: BrowserPrivateEngine> {
    private struct Context {
        let environment: BrowserEnvironment<Engine>
        let profileID: ProfileID
    }
    let id = UUID()
    private let factory: BrowserPrivateDomainFactory<Engine>
    private var creation: Task<Context, Error>?
    private var context: Context?
    private var leases: Set<UUID> = []
    private var surfaces: [UUID: [Engine.Surface]] = [:]
    private var pendingAcquisitions = 0
    private var cleanup: Task<Void, Error>?
    private var closing = false
    private(set) var isClosed = false

    fileprivate init(factory: BrowserPrivateDomainFactory<Engine>) { self.factory = factory }

    func acquire() async throws -> BrowserPrivateDomainLease {
        guard !closing, !isClosed else { throw BrowserPrivateDomainError.scopeClosed }
        pendingAcquisitions += 1
        if creation == nil {
            creation = Task {
                let engine = try await factory.admittedEngine()
                let environment = try BrowserEnvironment(memoryOnlyEngine: engine)
                environment.downloads.preferencesProvider = factory.downloadPreferences
                let (_, profileID) = try await environment.initialContext.value
                let candidate = Context(environment: environment, profileID: profileID)
                // Retain failed initialization too: cleanup failure must remain retryable.
                context = candidate
                try await engine.preparePrivateProfile(profileID)
                return candidate
            }
        }
        do {
            _ = try await creation!.value
            try Task.checkCancellation()
            let lease = BrowserPrivateDomainLease(scopeID: id, owner: self)
            leases.insert(lease.id)
            pendingAcquisitions -= 1
            return lease
        } catch {
            pendingAcquisitions -= 1
            if pendingAcquisitions == 0, leases.isEmpty { try await close() }
            throw error
        }
    }

    /// The actual services to bind future private controllers to, never the normal environment.
    /// A released/cross-scope lease cannot obtain services or create a late document.
    func environment(for lease: BrowserPrivateDomainLease) throws -> BrowserEnvironment<Engine> {
        try validate(lease)
        guard let context else { throw BrowserPrivateDomainError.scopeClosed }
        return context.environment
    }

    func profileID(for lease: BrowserPrivateDomainLease) throws -> ProfileID {
        _ = try environment(for: lease)
        return context!.profileID
    }

    func makeSurface(for lease: BrowserPrivateDomainLease,
                     delegate: any BrowserEngineSurfaceDelegate<Engine.Surface>) throws -> Engine.Surface {
        let environment = try environment(for: lease)
        let surface = environment.engine.makeSurface(profileID: context!.profileID, delegate: delegate)
        surfaces[lease.id, default: []].append(surface)
        return surface
    }

    /// Admission checks object ownership as well as profile identity; spoofing a profile ID or
    /// keeping an old callback does not grant a surface access to another scope.
    func validate(_ surface: Engine.Surface, for lease: BrowserPrivateDomainLease) throws {
        try validate(lease)
        guard surface.profileID == context?.profileID,
              surfaces[lease.id]?.contains(where: { $0 === surface }) == true,
              !surface.isDisposed else { throw BrowserPrivateDomainError.foreignSurface }
    }

    private func validate(_ lease: BrowserPrivateDomainLease) throws {
        guard lease.scopeID == id, !lease.released, leases.contains(lease.id) else {
            throw BrowserPrivateDomainError.foreignLease
        }
        guard !closing, !isClosed else { throw BrowserPrivateDomainError.scopeClosed }
    }

    func release(_ lease: BrowserPrivateDomainLease) async throws {
        guard lease.scopeID == id else { throw BrowserPrivateDomainError.foreignLease }
        guard !lease.released else { return }
        guard leases.remove(lease.id) != nil else { throw BrowserPrivateDomainError.foreignLease }
        lease.released = true
        for surface in surfaces[lease.id] ?? [] { surface.dispose() }
        // Retain the native owners through their asynchronous teardown, even after this lease.
        if leases.isEmpty, pendingAcquisitions == 0 { try await close() }
        lease.owner = nil
    }

    /// Idempotent, single-flight and retryable after native release failure. It never invokes
    /// engine.shutdown() or the process runtime's quit path. A failed release stays quarantined.
    func close() async throws {
        guard leases.isEmpty, pendingAcquisitions == 0 else { throw BrowserPrivateDomainError.ownersRemain }
        if isClosed { return }
        if let cleanup { return try await cleanup.value }
        closing = true
        let task = Task {
            guard let context else { return }
            let environment = context.environment
            // Controllers retire their sessions before the last window releases this scope.
            // Never release a context while a window or a rescued document still owns it.
            guard environment.liveControllers.isEmpty, environment.quickWindows.isEmpty,
                  environment.rescue.surfaces.isEmpty else { throw BrowserPrivateDomainError.ownersRemain }
            environment.downloads.shutdown()
            for owned in surfaces.values { for surface in owned { surface.dispose() } }
            try await environment.finalize()
            try await environment.historyRecorder.close()
            try await environment.permissions.clear(profileID: context.profileID)
            // The engine must await native close/pending creation. A refusal is not success.
            try await environment.engine.releasePrivateProfile(context.profileID)
        }
        cleanup = task
        do {
            try await task.value
            surfaces.removeAll()
            context = nil
            creation = nil
            cleanup = nil
            isClosed = true
            factory.didClose(self)
        } catch {
            cleanup = nil
            factory.quarantine(self)
            throw error
        }
    }
}
