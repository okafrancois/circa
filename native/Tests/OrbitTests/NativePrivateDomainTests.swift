@testable import Orbit
import AppKit
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
import BrowserShell
import Foundation
import Testing

extension NativeWebKitTests {
@Suite("Private domain security", .serialized)
@MainActor
struct NativePrivateDomainTests {
    @Test("Private downloads use current global folder choices without sharing download history")
    func downloadPreferences() async throws {
        let normal = BrowserEnvironment(engine: PrivateTestEngine())
        let scope = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { PrivateTestEngine() }).makeScope()
        let lease = try await scope.acquire()
        let memory = try scope.environment(for: lease)
        try await normal.settings.updateDownloads { $0.folderPath = "/tmp/synthetic-downloads" }
        #expect(memory.downloads.preferencesProvider() == normal.settings.document.downloads)
        try await normal.settings.updateDownloads { $0.asksWhereToSave = true }
        #expect(memory.downloads.preferencesProvider().asksWhereToSave)
        #expect(memory.downloads !== normal.downloads)
        #expect(memory.settings.document.downloads == BrowserDownloadPreferences())
        try await scope.release(lease)
    }

    @Test("Persistent private factories are refused before profile creation or navigation")
    func persistentAdmission() throws {
        let engine = PrivateTestEngine(persistence: .persistent)
        #expect(throws: (any Error).self) { try BrowserEnvironment(memoryOnlyEngine: engine) }
        #expect(engine.profileLookups == 0)
        #expect(engine.backend.surfaces.isEmpty)
        #expect(!engine.backend.isShutDown)
    }

    @Test("A forced persistent domain factory cannot initialize services or fall back")
    func persistentFactoryAdmission() async throws {
        let normal = BrowserEnvironment(engine: PrivateTestEngine())
        let forced = PrivateTestEngine(persistence: .persistent)
        let scope = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { forced }).makeScope()
        await #expect(throws: BrowserPrivateDomainError.persistentEngine) { try await scope.acquire() }
        #expect(scope.isClosed && forced.profileLookups == 0 && forced.backend.surfaces.isEmpty)
        await #expect(throws: BrowserEngineError.unsupportedOperation) { try await forced.releasePrivateProfile(ProfileID()) }
        #expect(forced.removals.isEmpty)
        #expect(normal.engine.profileLookups == 0 && normal.engine.removals.isEmpty)
    }

    @Test("Normal periodic and final saves cannot serialize private service bindings or late callbacks")
    func bindingsAndPersistence() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("private-domain-synthetic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let normalEngine = PrivateTestEngine(persistence: .persistent)
        let normal = try await BrowserEnvironment.open(engine: normalEngine, sessionFile: root.appendingPathComponent("session.json"))
        let (normalSpace, normalProfile) = try await normal.initialContext.value
        let normalWindow = try await normal.store.createWindow(activeSpaceID: normalSpace)
        _ = try await normal.store.openTab(url: URL(string: "https://normal.example.test/kept")!,
            from: normal.store.captureContext(in: normalWindow), activate: true)
        let normalOrigin = BrowserSiteOrigin(url: URL(string: "https://normal.example.test")!)!
        try await normal.permissions.set(.allow, for: [.camera], origin: normalOrigin, profileID: normalProfile)
        try await normal.settings.store.setLastActiveWindow(normalWindow, spaceID: normalSpace)
        try await normal.saveNow()
        let before = try await normal.store.sessionDocument().encoded()

        let privateEngine = PrivateTestEngine()
        let factory = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { privateEngine })
        let scope = factory.makeScope()
        let lease = try await scope.acquire()
        let memory = try scope.environment(for: lease)
        let privateProfile = try scope.profileID(for: lease)
        let (privateSpace, _) = try await memory.initialContext.value
        #expect(memory !== normal && memory.store !== normal.store)
        #expect(memory.historyRecorder !== normal.historyRecorder)
        #expect(memory.permissions !== normal.permissions)
        #expect(memory.settings !== normal.settings)
        #expect(memory.downloads !== normal.downloads)
        #expect(memory.sessionFile == nil && privateProfile != normalProfile && privateSpace != normalSpace)
        #expect(ArcImportLiveTarget(environment: memory) == nil)
        await #expect(throws: BrowserSessionPersistence.PersistenceError.finalizationInProgress) { try await memory.saveNow() }
        let sentinel = "private-sentinel-\(UUID().uuidString)"
        let origin = BrowserSiteOrigin(url: URL(string: "https://\(sentinel).example.test")!)!
        let window = try await memory.store.createWindow(activeSpaceID: privateSpace)
        _ = try await memory.store.openTab(url: URL(string: origin.value + "/private")!,
            from: memory.store.captureContext(in: window), activate: true)
        try await memory.settings.store.setLastActiveWindow(window, spaceID: privateSpace)
        try await memory.permissions.set(.allow, for: [.camera], origin: origin, profileID: privateProfile)
        let privateBoosts = try memory.boosts.store(for: privateProfile)
        try await privateBoosts.save(.init(title: sentinel, hostPattern: try .init(host: "private.example.test")))
        try await memory.settings.setEnablesBoostsOnWebsites(false)
        #expect(normal.settings.document.enablesBoostsOnWebsites)
        #expect(try await normal.boosts.store(for: privateProfile).snapshot().boosts.isEmpty)
        let observer = PrivateTestDelegate()
        observer.downloads = memory.downloads
        let surface = try scope.makeSurface(for: lease, delegate: observer)
        surface.navigate(to: URL(string: origin.value + "/private")!)
        let privateDownload = surface.startDownload(suggestedFilename: "\(sentinel).bin")
        let normalObserver = PrivateTestDelegate()
        normalObserver.downloads = normal.downloads
        let normalSurface = normalEngine.makeSurface(profileID: normalProfile, delegate: normalObserver)
        let normalDownload = normalSurface.startDownload(suggestedFilename: "normal-kept.bin")
        let feedback = SidebarDownloadFeedback()
        feedback.update(memory.downloads.snapshots(profileID: privateProfile), profileID: privateProfile)
        feedback.hover(true)
        #expect(feedback.isPresented && feedback.hasActiveDownloads)
        #expect(memory.downloads.hasActiveTransfers && normal.downloads.hasActiveTransfers)
        #expect(normal.downloads.snapshots(profileID: privateProfile).isEmpty)
        memory.historyRecorder.committed(surface, profile: privateEngine.profile(for: privateProfile))
        #expect(try await memory.historyRecorder.importDocument(.init(profileID: privateProfile,
            visits: [.init(url: URL(string: origin.value)!, title: sentinel)])) == 0)
        let gate = PrivateTestGate()
        let delayed = Task {
            await gate.wait()
            memory.historyRecorder.committed(surface, profile: .init(profileID: privateProfile, persistence: .ephemeral))
            try await memory.permissions.set(.block, for: [.camera], origin: origin, profileID: privateProfile)
            memory.scheduleSave()
        }
        var periodicSaves = 0
        normal.onPersistenceSuccess = { periodicSaves += 1 }
        normal.scheduleSave()
        // Observe completion, not just an elapsed timer or the earlier initial session file.
        let saveDeadline = ContinuousClock.now + .seconds(10)
        while periodicSaves == 0, ContinuousClock.now < saveDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(periodicSaves > 0)
        try assertNoSentinel(sentinel, in: root)
        #expect(try await normal.store.sessionDocument().encoded() == before)
        try await scope.release(lease)
        feedback.reset()
        #expect(memory.downloads.coordinator.isClosed && feedback.items.isEmpty && !feedback.isPresented)
        #expect(privateDownload.transfer?.isInvalidated == true)
        #expect(normalDownload.transfer?.isInvalidated == false && normal.downloads.hasActiveTransfers)
        gate.open()
        try await delayed.value
        try await normal.finalize()
        try assertNoSentinel(sentinel, in: root)
        let saved = try BrowserSessionFileStore().load(from: root.appendingPathComponent("session.json"))
        #expect(try saved.encoded() == before)
        #expect(await normal.permissions.snapshot(origin: normalOrigin, profileID: normalProfile)[.camera] == .allow)
        #expect(await normal.settings.store.snapshot().lastActiveWindowID == normalWindow)
        #expect(await normal.permissions.configuredOrigins(profileID: privateProfile).isEmpty)
        #expect(!normalEngine.backend.isShutDown)
        normal.downloads.shutdown()
        normalSurface.dispose()
        try await normal.historyRecorder.close()
    }

    @Test("Single-flight scope leases retain native owners until the last asynchronous close")
    func scopedNativeLifetime() async throws {
        let normalEngine = PrivateTestEngine()
        let normal = BrowserEnvironment(engine: normalEngine)
        let engine = PrivateTestEngine(teardown: .delayed(.milliseconds(120)))
        let gate = PrivateTestGate()
        var builds = 0
        let factory = BrowserPrivateDomainFactory(normalEnvironment: normal, build: {
            builds += 1; await gate.wait(); return engine
        })
        let scope = factory.makeScope()
        let first = Task { try await scope.acquire() }
        let second = Task { try await scope.acquire() }
        await Task.yield()
        gate.open()
        let a = try await first.value
        let b = try await second.value
        #expect(builds == 1)
        #expect(try scope.environment(for: a) === scope.environment(for: b))
        let profile = try scope.profileID(for: a)
        let observer = PrivateTestDelegate()
        let surface = try scope.makeSurface(for: a, delegate: observer)
        surface.navigate(to: URL(string: "https://private.example.test/lifetime")!)
        try await scope.release(a)
        #expect(!scope.isClosed && engine.removals.isEmpty)
        #expect(surface.isDisposed)
        let closing = Task { try await scope.release(b) }
        try await closing.value
        #expect(scope.isClosed && surface.isTeardownComplete)
        #expect(engine.removals == [profile] && engine.backend.profiles.isEmpty)
        #expect(!engine.backend.isShutDown && !normalEngine.backend.isShutDown)
        #expect(throws: BrowserPrivateDomainError.foreignLease) { try scope.environment(for: a) }
        await #expect(throws: BrowserPrivateDomainError.scopeClosed) { try await scope.acquire() }
        try await scope.release(b)
        #expect(engine.removals.count == 1)
    }

    @Test("Cross-domain leases, spoofed profile IDs and normal engine reuse are refused")
    func crossDomainAdmission() async throws {
        let normalEngine = PrivateTestEngine()
        let normal = BrowserEnvironment(engine: normalEngine)
        let reused = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { normalEngine }).makeScope()
        await #expect(throws: BrowserPrivateDomainError.reusedEngine) { try await reused.acquire() }
        #expect(normalEngine.profileLookups == 0 && normalEngine.removals.isEmpty)
        let factory = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { PrivateTestEngine() })
        let left = factory.makeScope(), right = factory.makeScope()
        let a = try await left.acquire(), b = try await right.acquire()
        #expect(try left.profileID(for: a) != right.profileID(for: b))
        let observer = PrivateTestDelegate()
        let surface = try left.makeSurface(for: a, delegate: observer)
        #expect(throws: BrowserPrivateDomainError.foreignLease) { try right.validate(surface, for: a) }
        #expect(throws: BrowserPrivateDomainError.foreignSurface) { try right.validate(surface, for: b) }
        let leftEnvironment = try left.environment(for: a)
        let impostor = leftEnvironment.engine.backend.makeSurface(profileID: try left.profileID(for: a), delegate: observer)
        #expect(throws: BrowserPrivateDomainError.foreignSurface) { try left.validate(impostor, for: a) }
        impostor.dispose()
        try await left.release(a)
        try await right.release(b)
        #expect(!normalEngine.backend.isShutDown)
    }

    @Test("Failed initialization retains cleanup authority and never falls back to the normal engine")
    func failedCreationCleanup() async throws {
        let normal = BrowserEnvironment(engine: PrivateTestEngine())
        let engine = PrivateTestEngine()
        engine.failPreparation = true
        engine.failRemoval = true
        let factory = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { engine })
        let scope = factory.makeScope()
        await #expect(throws: BrowserEngineError.profileInUse) { try await scope.acquire() }
        #expect(!scope.isClosed && engine.backend.profiles.count == 1)
        #expect(factory.quarantinedScopes[scope.id] === scope)
        #expect(normal.engine.profileLookups == 0 && normal.engine.backend.surfaces.isEmpty)
        engine.failRemoval = false
        try await factory.retryQuarantinedScopes()
        #expect(factory.quarantinedScopes.isEmpty)
        #expect(scope.isClosed && engine.backend.profiles.isEmpty && engine.removals.count == 2)
        #expect(!normal.engine.backend.isShutDown && !engine.backend.isShutDown)
    }

    @Test("An untracked native owner blocks profile release and cleanup remains retryable")
    func nativeOwnerRefusal() async throws {
        let normal = BrowserEnvironment(engine: PrivateTestEngine())
        let engine = PrivateTestEngine()
        let scope = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { engine }).makeScope()
        let lease = try await scope.acquire()
        let profile = try scope.profileID(for: lease)
        let observer = PrivateTestDelegate()
        let pending = engine.backend.makeSurface(profileID: profile, delegate: observer)
        await #expect(throws: BrowserEngineError.profileInUse) { try await scope.release(lease) }
        #expect(!scope.isClosed && engine.backend.profiles[profile] != nil)
        #expect(throws: BrowserPrivateDomainError.foreignLease) { try scope.environment(for: lease) }
        pending.dispose()
        try await scope.close()
        #expect(scope.isClosed && pending.isTeardownComplete && engine.backend.profiles[profile] == nil)
    }

    @Test("Disposal before deferred creation settles cannot resurrect the released profile")
    func pendingCreationRelease() async throws {
        let normal = BrowserEnvironment(engine: PrivateTestEngine())
        let engine = PrivateTestEngine(readiness: .deferred, teardown: .delayed(.milliseconds(25)))
        let scope = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { engine }).makeScope()
        let lease = try await scope.acquire()
        let observer = PrivateTestDelegate()
        let surface = try scope.makeSurface(for: lease, delegate: observer)
        #expect(!surface.isReady)
        surface.navigate(to: URL(string: "https://pending.example.test/private")!)
        try await scope.release(lease)
        await Task.yield()
        #expect(scope.isClosed && surface.isDisposed && surface.isTeardownComplete)
        #expect(engine.backend.profiles.isEmpty && engine.removals.count == 1)
    }

    @Test("Cancelled acquisition cleans an initialized scope without cancelling another caller")
    func cancelledAcquisition() async throws {
        let normal = BrowserEnvironment(engine: PrivateTestEngine())
        let engine = PrivateTestEngine()
        let gate = PrivateTestGate()
        let scope = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { await gate.wait(); return engine }).makeScope()
        let cancelled = Task { try await scope.acquire() }
        await Task.yield()
        cancelled.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(scope.isClosed && engine.backend.profiles.isEmpty)
        #expect(engine.removals.count == 1 && !normal.engine.backend.isShutDown)
    }

    @Test("A cancelled waiter cannot tear down another caller's successful private lease")
    func cancellationWithSurvivingOwner() async throws {
        let normal = BrowserEnvironment(engine: PrivateTestEngine())
        let engine = PrivateTestEngine()
        let gate = PrivateTestGate()
        let factory = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { await gate.wait(); return engine })
        let scope = factory.makeScope()
        let cancelled = Task { try await scope.acquire() }
        let surviving = Task { try await scope.acquire() }
        await Task.yield()
        cancelled.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let owner = try await surviving.value
        #expect(!scope.isClosed && engine.removals.isEmpty)
        _ = try scope.environment(for: owner)
        try await scope.release(owner)
        #expect(scope.isClosed && engine.removals.count == 1)
    }

    @Test("A factory cannot reuse a private engine for another scope, including after cleanup")
    func privateEngineReuse() async throws {
        let normal = BrowserEnvironment(engine: PrivateTestEngine())
        let engine = PrivateTestEngine()
        let factory = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { engine })
        let scope = factory.makeScope()
        let lease = try await scope.acquire()
        await #expect(throws: BrowserPrivateDomainError.reusedEngine) { try await factory.makeScope().acquire() }
        #expect(engine.removals.isEmpty)
        let otherFactory = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { engine })
        await #expect(throws: BrowserPrivateDomainError.reusedEngine) { try await otherFactory.makeScope().acquire() }
        try await scope.release(lease)
        await #expect(throws: BrowserPrivateDomainError.reusedEngine) { try await factory.makeScope().acquire() }
        #expect(engine.removals.count == 1)
    }

    @Test("The composition factory creates an independent ephemeral engine without window wiring")
    func compositionFactory() {
        let normal = makeActiveEngine()
        let memory = makePrivateEngine()
        #expect(normal !== memory && memory.persistence == .ephemeral && memory.extensions == nil)
    }

    @Test("Close during preparation refuses without cancelling admission or granting a late lease")
    func closeDuringPreparation() async throws {
        let normal = BrowserEnvironment(engine: PrivateTestEngine())
        let engine = PrivateTestEngine()
        let gate = PrivateTestGate()
        engine.preparationGate = gate
        let scope = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { engine }).makeScope()
        let acquisition = Task { try await scope.acquire() }
        let prepared = await waitForReviewCondition { engine.profileLookups > 0 }
        gate.openIfReviewFails(prepared)
        try #require(prepared)
        await #expect(throws: BrowserPrivateDomainError.ownersRemain) { try await scope.close() }
        #expect(!scope.isClosed && engine.removals.isEmpty)
        acquisition.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { try await acquisition.value }
        #expect(scope.isClosed && engine.removals.count == 1 && engine.backend.profiles.isEmpty)
        await #expect(throws: BrowserPrivateDomainError.scopeClosed) { try await scope.acquire() }
        #expect(normal.engine.removals.isEmpty && !normal.engine.backend.isShutDown)
    }

    @Test("Concurrent cleanup callers share one refused removal and retain retry authority")
    func concurrentRefusedCleanup() async throws {
        let normal = BrowserEnvironment(engine: PrivateTestEngine())
        let engine = PrivateTestEngine()
        let factory = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { engine })
        let scope = factory.makeScope()
        let lease = try await scope.acquire()
        let gate = PrivateTestGate()
        engine.removalGate = gate
        engine.failRemoval = true
        let release = Task { try await scope.release(lease) }
        let removing = await waitForReviewCondition { !engine.removals.isEmpty }
        gate.openIfReviewFails(removing)
        try #require(removing)
        var secondStarted = false
        let secondClose = Task { secondStarted = true; try await scope.close() }
        let joined = await waitForReviewCondition { secondStarted }
        gate.openIfReviewFails(joined)
        try #require(joined)
        #expect(engine.removals.count == 1 && !scope.isClosed)
        gate.open()
        await #expect(throws: BrowserEngineError.profileInUse) { try await release.value }
        await #expect(throws: BrowserEngineError.profileInUse) { try await secondClose.value }
        #expect(engine.removals.count == 1 && factory.quarantinedScopes[scope.id] === scope)
        #expect(throws: BrowserPrivateDomainError.foreignLease) { try scope.environment(for: lease) }
        await #expect(throws: BrowserPrivateDomainError.scopeClosed) { try await scope.acquire() }
        engine.failRemoval = false
        try await factory.retryQuarantinedScopes()
        #expect(scope.isClosed && factory.quarantinedScopes.isEmpty && engine.removals.count == 2)
        #expect(engine.backend.profiles.isEmpty && !engine.backend.isShutDown)
    }

    @Test("A throwing engine builder cannot materialize or clean up the normal domain")
    func throwingBuilder() async throws {
        let normal = BrowserEnvironment(engine: PrivateTestEngine())
        let factory = BrowserPrivateDomainFactory(normalEnvironment: normal, build: {
            throw BrowserEngineError.unsupportedOperation
        })
        let scope = factory.makeScope()
        await #expect(throws: BrowserEngineError.unsupportedOperation) { try await scope.acquire() }
        #expect(scope.isClosed && factory.quarantinedScopes.isEmpty)
        #expect(normal.engine.profileLookups == 0 && normal.engine.removals.isEmpty)
        #expect(normal.engine.backend.surfaces.isEmpty && !normal.engine.backend.isShutDown)
    }

    private func assertNoSentinel(_ sentinel: String, in root: URL) throws {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in files {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                #expect(try Data(contentsOf: url).range(of: Data(sentinel.utf8)) == nil)
            }
        }
    }

    private func waitForReviewCondition(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
}

@MainActor
private final class PrivateTestEngine: BrowserPrivateEngine {
    let backend: SyntheticEngine
    let persistence: BrowserWebsiteDataPersistence
    var profileLookups = 0
    var removals: [ProfileID] = []
    var failPreparation = false
    var failRemoval = false
    var preparationGate: PrivateTestGate?
    var removalGate: PrivateTestGate?
    var kind: BrowserEngineKind { .synthetic }
    var capabilities: BrowserEngineCapabilities { backend.capabilities }
    var extensions: (any BrowserExtensionHost)? { nil }
    init(persistence: BrowserWebsiteDataPersistence = .ephemeral, readiness: SyntheticEngine.Readiness = .immediate,
         teardown: SyntheticEngine.Teardown = .nextTurn) {
        self.persistence = persistence
        backend = SyntheticEngine(readiness: readiness, teardown: teardown)
    }
    func profile(for id: ProfileID) -> BrowserEngineProfile {
        profileLookups += 1
        _ = backend.profile(for: id)
        return BrowserEngineProfile(profileID: id, persistence: persistence)
    }
    func makeSurface(profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<SyntheticSurface>) -> SyntheticSurface {
        backend.makeSurface(profileID: profileID, delegate: delegate)
    }
    func preparePrivateProfile(_ id: ProfileID) async throws {
        _ = profile(for: id)
        await preparationGate?.wait()
        if failPreparation { throw BrowserEngineError.unsupportedOperation }
    }
    func removeProfile(_ id: ProfileID) async throws {
        removals.append(id)
        await removalGate?.wait()
        if failRemoval { throw BrowserEngineError.profileInUse }
        try await backend.removeProfile(id)
    }
    func shutdown() async { await backend.shutdown() }
}

@MainActor
private final class PrivateTestDelegate: BrowserEngineSurfaceDelegate {
    var downloads: BrowserDownloadsController?
    func surfaceDidStartNavigation(_ surface: SyntheticSurface) {}
    func surfaceDidCommitNavigation(_ surface: SyntheticSurface) {}
    func surfaceDidFinishNavigation(_ surface: SyntheticSurface) {}
    func surfaceDidFailNavigation(_ surface: SyntheticSurface) {}
    func surfaceDidRequestClose(_ surface: SyntheticSurface) {}
    func surface(_ surface: SyntheticSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
    func surface(_ surface: SyntheticSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> SyntheticSurface) -> SyntheticSurface? { nil }
    func surface(_ surface: SyntheticSurface, didStartDownload download: any BrowserEngineDownload) {
        guard let downloads else { download.cancel(); return }
        _ = downloads.adopt(download, owner: .init(profileID: surface.profileID), sourceWindow: nil)
    }
}

@MainActor
private final class PrivateTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func openIfReviewFails(_ condition: Bool) { if !condition { open() } }
}
