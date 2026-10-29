@testable import Orbit
import AppKit
@testable import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing

extension NativeWebKitTests {
@Suite("History engine recording", .serialized)
@MainActor
struct BrowserHistoryRecorderTests {
    @Test("Deletion drains visits that are still queued for write before mutating the database")
    func queuedWriteThenDelete() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-library-r2-queued-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: { .init(profileID: $0, persistence: .persistent) })
        let surface = HistoryTestSurface()
        surface.navigationState.committedURL = URL(string: "https://queued.library.test/visit")!
        let profile = BrowserEngineProfile(profileID: surface.profileID, persistence: .persistent)
        for _ in 0..<20 { recorder.committed(surface, profile: profile) }
        // Intentionally no explicit flush: delete is the public barrier for accepted writes.
        #expect(try await recorder.delete(for: profile.profileID, .all) == 20)
        await recorder.flush()
        #expect(try await recorder.visits(for: profile.profileID).isEmpty)
        try await recorder.close()
    }

    @Test("Only committed persistent documents record and later titles update the exact visit")
    func commitAndTitle() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-recorder-synthetic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: { BrowserEngineProfile(profileID: $0, persistence: .persistent) })
        var errors = 0
        recorder.onIssue = { _, issue in if issue != nil { errors += 1 } }
        let surface = HistoryTestSurface()
        let profile = BrowserEngineProfile(profileID: surface.profileID, persistence: .persistent)
        surface.navigationState.url = URL(string: "https://example.test/provisional")!
        recorder.committed(surface, profile: profile)
        recorder.metadataChanged(surface)
        await recorder.flush()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        surface.navigationState.committedURL = URL(string: "https://example.test/committed")!
        recorder.committed(surface, profile: profile)
        surface.navigationState.title = "First title"
        recorder.metadataChanged(surface)
        // A second commit to the same address is a distinct visit (reload/history navigation).
        recorder.committed(surface, profile: profile)
        surface.navigationState.title = "Reload title"
        recorder.metadataChanged(surface)
        await recorder.flush()
        let visits = try await recorder.visits(for: surface.profileID)
        #expect(visits.count == 2)
        #expect(visits.first?.title == "Reload title")
        #expect(visits.last?.title == "First title")
        #expect(errors == 0)
        try await recorder.close()
    }

    @Test("The initial synchronous engine commit must be observed after ownership installation")
    func initialCommitOwnershipRegression() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-initial-history-synthetic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: { BrowserEngineProfile(profileID: $0, persistence: .persistent) })
        let model = BrowserStore()
        let profileID = await model.createProfile(name: "Synthetic history profile")
        let spaceID = try await model.createSpace(name: "Synthetic history space", profileID: profileID)
        let engine = HistoryTestEngine()
        // This window is never shown or activated. The engine performs no network requests.
        let controller = BrowserWindowController(id: UUID(), store: model, spaceID: spaceID,
            engine: engine, history: recorder, onClose: {}, onActivate: {})
        controller.session.openTab(url: URL(string: "https://example.test/initial-visit")!)
        await controller.session.waitForPendingCommands()
        await recorder.flush()
        let visits = try await recorder.visits(for: profileID)
        #expect(visits.filter { $0.url.path == "/initial-visit" }.count == 1)
        let surface = try #require(controller.session.selectedSurface)
        #expect(surface.placement != .detached)
        surface.navigationState.title = "Initial title"
        surface.onChange?()
        await recorder.flush()
        // The router emits stateChanged before navigationCommitted. On a same-URL reload,
        // that earlier state belongs to the new generation and must not retitle the old visit.
        surface.navigationState.title = "Reload title"
        surface.navigate(to: URL(string: "https://example.test/initial-visit")!)
        await recorder.flush()
        let repeated = try await recorder.visits(for: profileID).filter { $0.url.path == "/initial-visit" }
        #expect(repeated.count == 2)
        #expect(repeated.first?.title == "Reload title")
        #expect(repeated.last?.title == "Initial title")
        surface.navigate(to: URL(string: "https://example.test/owned-visit")!)
        await recorder.flush()
        #expect(try await recorder.visits(for: profileID).filter { $0.url.path == "/owned-visit" }.count == 1)
        controller.window?.close()
        await controller.session.waitForPendingCommands()
        try await recorder.close()
    }

    @Test("Every public history entry rejects ephemeral profiles, including cached stores after a policy change")
    func policyCheckedAtEveryEntry() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-history-policy-synthetic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var persistence = BrowserWebsiteDataPersistence.ephemeral
        let opens = SyntheticOpenProbe()
        let id = ProfileID()
        let recorder = BrowserHistoryRecorder(directory: root,
            resolveProfile: { BrowserEngineProfile(profileID: $0, persistence: persistence) },
            openStore: { id, root in
                opens.attempt()
                return try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
            })
        let document = BrowserHistoryDocument(profileID: id, visits: [BrowserHistoryVisit(url: URL(string: "https://example.test/policy")!)])
        #expect(try await recorder.suggestions(for: id, query: "policy").isEmpty)
        #expect(try await recorder.visits(for: id).isEmpty)
        #expect(try await recorder.days(for: id).isEmpty)
        #expect(try await recorder.importDocument(document) == 0)
        #expect(try await recorder.delete(for: id, .all) == 0)
        try await recorder.removeProfileHistory(for: id)
        #expect(opens.attempts == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        persistence = .persistent
        #expect(try await recorder.importDocument(document) == 1)
        persistence = .ephemeral
        #expect(try await recorder.visits(for: id).isEmpty)
        #expect(try await recorder.suggestions(for: id, query: "policy").isEmpty)
        #expect(try await recorder.importDocument(document) == 0)
        #expect(try await recorder.delete(for: id, .all) == 0)
        persistence = .persistent
        #expect(try await recorder.visits(for: id).count == 1)
        #expect(opens.attempts == 1)
        try await recorder.close()
    }

    @Test("Failed opens are cached, bounded to three timed attempts and emit one non-modal incident")
    func boundedOpenRetries() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-history-retry-synthetic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        var timestamp = Date(timeIntervalSince1970: 1000)
        let probe = SyntheticOpenProbe(canOpen: false)
        var attempts: Int { probe.attempts }
        var incidents = 0
        var recoveries = 0
        let recorder = BrowserHistoryRecorder(directory: root,
            resolveProfile: { BrowserEngineProfile(profileID: $0, persistence: .persistent) }, now: { timestamp },
            openStore: { id, root in
                guard probe.attempt() else { throw BrowserHistoryError.storageFailure(14) }
                return try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
            })
        recorder.onIssue = { _, issue in if issue == nil { recoveries += 1 } else { incidents += 1 } }
        let surface = HistoryTestSurface(profileID: id)
        surface.navigationState.committedURL = URL(string: "https://example.test/retry")!
        let profile = BrowserEngineProfile(profileID: id, persistence: .persistent)
        for _ in 0..<5 { recorder.committed(surface, profile: profile) }
        await recorder.flush()
        #expect(attempts == 1 && incidents == 1)
        await #expect(throws: BrowserHistoryError.temporarilyUnavailable) { try await recorder.visits(for: id) }
        #expect(attempts == 1)
        timestamp = timestamp.addingTimeInterval(5)
        await #expect(throws: BrowserHistoryError.temporarilyUnavailable) { try await recorder.visits(for: id) }
        #expect(attempts == 2)
        timestamp = timestamp.addingTimeInterval(29)
        await #expect(throws: BrowserHistoryError.temporarilyUnavailable) { try await recorder.visits(for: id) }
        #expect(attempts == 2)
        timestamp = timestamp.addingTimeInterval(1)
        await #expect(throws: BrowserHistoryError.temporarilyUnavailable) { try await recorder.visits(for: id) }
        #expect(attempts == 3)
        timestamp = timestamp.addingTimeInterval(10000)
        await #expect(throws: BrowserHistoryError.temporarilyUnavailable) { try await recorder.visits(for: id) }
        #expect(attempts == 3 && incidents == 1)
        #expect(recorder.issues[id] == .openUnavailable)
        probe.canOpen = true
        recorder.retryOpening(for: id)
        #expect(try await recorder.visits(for: id).isEmpty)
        #expect(attempts == 4 && recoveries == 1)
        #expect(recorder.issues[id] == nil)
        try await recorder.close()
    }

    @Test("History failures stay on their own non-modal environment channel and never become session-save alerts")
    func separateEnvironmentErrorChannel() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: "/private/tmp/orbit-history-channel-synthetic-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A regular file at the history root deterministically prevents any history directory opening.
        try Data("synthetic".utf8).write(to: root.appendingPathComponent("History"))
        let environment = try await BrowserEnvironment.open(engine: HistoryTestEngine(), sessionFile: root.appendingPathComponent("session.json"))
        var sessionErrors = 0
        var historyIncidents = 0
        environment.onPersistenceError = { _ in sessionErrors += 1 }
        environment.onHistoryIssue = { _, issue in if issue != nil { historyIncidents += 1 } }
        let controller = try await environment.makeWindow()
        let surface = try #require(controller.session.selectedSurface)
        for index in 0..<5 { surface.navigate(to: URL(string: "https://example.test/channel/\(index)")!) }
        try await environment.finalize()
        controller.window?.close()
        await controller.session.waitForPendingCommands()
        #expect(sessionErrors == 0)
        #expect(historyIncidents == 1)
        #expect(environment.historyIssues[surface.profileID] == .openUnavailable)
    }

    @Test("Profile cleanup prevents stale engine callbacks from recreating history")
    func profileCleanup() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-history-cleanup-synthetic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: { BrowserEngineProfile(profileID: $0, persistence: .persistent) })
        let surface = HistoryTestSurface(profileID: id)
        surface.navigationState.committedURL = URL(string: "https://example.test/remove")!
        let profile = BrowserEngineProfile(profileID: id, persistence: .persistent)
        recorder.committed(surface, profile: profile)
        await recorder.flush()
        try await recorder.removeProfileHistory(for: id)
        recorder.committed(surface, profile: profile)
        recorder.metadataChanged(surface)
        await recorder.flush()
        #expect(try await recorder.visits(for: id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id.rawValue.uuidString).path))
    }

    @Test("Ephemeral, mismatched and destination-free recorders never touch disk")
    func privacyGate() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-recorder-disabled-\(UUID())")
        let recorder = BrowserHistoryRecorder(directory: root)
        let surface = HistoryTestSurface()
        surface.navigationState.committedURL = URL(string: "https://example.test/private")!
        recorder.committed(surface, profile: BrowserEngineProfile(profileID: surface.profileID, persistence: .ephemeral))
        recorder.committed(surface, profile: BrowserEngineProfile(profileID: ProfileID(), persistence: .persistent))
        recorder.metadataChanged(surface)
        await recorder.flush()
        let disabled = BrowserHistoryRecorder()
        disabled.committed(surface, profile: BrowserEngineProfile(profileID: surface.profileID, persistence: .persistent))
        await disabled.flush()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Opening and migrating run off the main actor; concurrent entries share one attempt")
    func openOffMainActor() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-history-offmain-synthetic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        let probe = SyntheticOpenProbe()
        let recorder = BrowserHistoryRecorder(directory: root,
            resolveProfile: { BrowserEngineProfile(profileID: $0, persistence: .persistent) },
            openStore: { id, root in
                probe.attempt()
                // A slow open (large migration) must not hold the main actor.
                Thread.sleep(forTimeInterval: 0.3)
                return try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
            })
        let clock = ContinuousClock()
        let start = clock.now
        let prepare = Task { await recorder.prepareSuggestions(for: id) }
        let query = Task { try await recorder.suggestions(for: id, query: "synthetic") }
        let listing = Task { try await recorder.visits(for: id) }
        // The main actor keeps serving while the open is in flight.
        await Task.yield()
        #expect(recorder.cachedSuggestions(for: id, query: "synthetic").isEmpty)
        #expect(start.duration(to: clock.now) < .milliseconds(200))
        await prepare.value
        #expect(try await query.value.isEmpty)
        #expect(try await listing.value.isEmpty)
        #expect(probe.attempts == 1)
        #expect(probe.allOffMain)
        #expect(recorder.issues[id] == nil)
        try await recorder.close()
    }

    @Test("Cached suggestions are profile-bound, follow commits and agree with complete results")
    func cachedSuggestionsFollowCommits() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-history-cache-synthetic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = ProfileID(), b = ProfileID()
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: { BrowserEngineProfile(profileID: $0, persistence: .persistent) })
        let visits = ["https://cat.test/", "https://animal.test/a-cat", "https://other.test/concatenate", "https://docs.cathedral.test/"]
            .enumerated().map { BrowserHistoryVisit(url: URL(string: $1)!, title: $0 == 1 ? "A-cat handbook" : "Reference", typedCount: $0) }
        #expect(try await recorder.importDocument(BrowserHistoryDocument(profileID: a, visits: visits)) == 4)
        #expect(recorder.cachedSuggestions(for: a, query: "cat").isEmpty)
        await recorder.prepareSuggestions(for: a)
        await recorder.prepareSuggestions(for: b)
        for query in ["cat", "ca", "c", "a-c", "reference", "doc", ""] {
            let cached = recorder.cachedSuggestions(for: a, query: query).map(\.url)
            let complete = try await recorder.suggestions(for: a, query: query).map(\.url)
            #expect(cached == complete, "query length \(query.count)")
        }
        #expect(recorder.cachedSuggestions(for: b, query: "cat").isEmpty)
        // A committed visit updates the warm index with the authoritative aggregate.
        let surface = HistoryTestSurface(profileID: a)
        surface.navigationState.committedURL = URL(string: "https://other.test/concatenate")!
        recorder.markTypedNavigation(surface, url: URL(string: "https://other.test/concatenate")!)
        recorder.committed(surface, profile: BrowserEngineProfile(profileID: a, persistence: .persistent))
        surface.navigationState.title = "Concatenation guide"
        recorder.metadataChanged(surface)
        await recorder.flush()
        let updated = try #require(recorder.cachedSuggestions(for: a, query: "concat").first)
        #expect(updated.visitCount == 2 && updated.typedCount == 3 && updated.title == "Concatenation guide")
        #expect(recorder.cachedSuggestions(for: a, query: "cat").map(\.url) == (try await recorder.suggestions(for: a, query: "cat").map(\.url)))
        try await recorder.close()
    }

    @Test("Deletion, import, policy change and profile removal invalidate cached suggestions")
    func cachedSuggestionsInvalidate() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-history-cache-invalidate-synthetic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = ProfileID()
        var persistence = BrowserWebsiteDataPersistence.persistent
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: { BrowserEngineProfile(profileID: $0, persistence: persistence) })
        let keep = BrowserHistoryVisit(url: URL(string: "https://keep.test/synthetic")!, title: "Synthetic keep", typedCount: 1)
        let drop = BrowserHistoryVisit(url: URL(string: "https://drop.test/synthetic")!, title: "Synthetic drop", typedCount: 1)
        _ = try await recorder.importDocument(BrowserHistoryDocument(profileID: id, visits: [keep, drop]))
        await recorder.prepareSuggestions(for: id)
        #expect(recorder.cachedSuggestions(for: id, query: "synthetic").count == 2)
        #expect(try await recorder.delete(for: id, .site("drop.test")) == 1)
        #expect(!recorder.cachedSuggestions(for: id, query: "synthetic").contains { $0.url == drop.url })
        await recorder.prepareSuggestions(for: id)
        #expect(recorder.cachedSuggestions(for: id, query: "synthetic").map(\.url) == [keep.url])
        let imported = BrowserHistoryVisit(url: URL(string: "https://imported.test/synthetic")!, title: "Synthetic import", typedCount: 2)
        _ = try await recorder.importDocument(BrowserHistoryDocument(profileID: id, visits: [imported]))
        await recorder.prepareSuggestions(for: id)
        #expect(recorder.cachedSuggestions(for: id, query: "synthetic").map(\.url) == [imported.url, keep.url])
        persistence = .ephemeral
        #expect(recorder.cachedSuggestions(for: id, query: "synthetic").isEmpty)
        persistence = .persistent
        #expect(recorder.cachedSuggestions(for: id, query: "synthetic").isEmpty)
        await recorder.prepareSuggestions(for: id)
        #expect(recorder.cachedSuggestions(for: id, query: "synthetic").count == 2)
        try await recorder.removeProfileHistory(for: id)
        #expect(recorder.cachedSuggestions(for: id, query: "synthetic").isEmpty)
        await recorder.prepareSuggestions(for: id)
        #expect(recorder.cachedSuggestions(for: id, query: "synthetic").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(id.rawValue.uuidString).path))
        #expect(recorder.issues[id] == nil)
    }

    @Test("Cancelling one suggestion request is not an incident and leaves sibling requests intact")
    func suggestionCancellation() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-history-cancel-synthetic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = ProfileID(), b = ProfileID()
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: { BrowserEngineProfile(profileID: $0, persistence: .persistent) })
        for id in [a, b] {
            _ = try await recorder.importDocument(BrowserHistoryDocument(profileID: id, visits: [
                BrowserHistoryVisit(url: URL(string: "https://sibling.test/synthetic")!, title: "Synthetic sibling")]))
        }
        var incidents = 0
        recorder.onIssue = { _, issue in if issue != nil { incidents += 1 } }
        let cancelled = Task { try await recorder.suggestions(for: a, query: "synthetic") }
        let sameProfile = Task { try await recorder.suggestions(for: a, query: "sibling") }
        let otherProfile = Task { try await recorder.suggestions(for: b, query: "synthetic") }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await sameProfile.value.count == 1)
        #expect(try await otherProfile.value.count == 1)
        #expect(incidents == 0 && recorder.issues.isEmpty)
        try await recorder.close()
    }
}

/// Thread-safe open probe: `openStore` runs off the main actor.
private final class SyntheticOpenProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var allowed = true
    private var offMain = true
    var attempts: Int { lock.withLock { count } }
    var allOffMain: Bool { lock.withLock { offMain } }
    var canOpen: Bool {
        get { lock.withLock { allowed } }
        set { lock.withLock { allowed = newValue } }
    }
    init(canOpen: Bool = true) { allowed = canOpen }
    /// Records one attempt; returns whether opening is currently allowed.
    @discardableResult func attempt() -> Bool {
        lock.withLock {
            count += 1
            if Thread.isMainThread { offMain = false }
            return allowed
        }
    }
}

/// Inert contract surface: no engine, windows, application activation, network or Keychain.
@MainActor
private final class HistoryTestSurface: BrowserEngineSurface {
    let profileID: ProfileID
    init(profileID: ProfileID = ProfileID()) { self.profileID = profileID }
    let hostView = NSView()
    var navigationState = BrowserNavigationState()
    var currentURL: URL? { navigationState.url }
    var isDisposed = false
    var pageZoom = 1.0
    var findDocumentGeneration: UInt64 = 0
    var onChange: (() -> Void)?
    var onDispose: (() -> Void)?
    weak var delegate: (any BrowserEngineSurfaceDelegate<HistoryTestSurface>)?
    var placement: BrowserSurfacePlacement = .detached
    func navigate(to url: URL) {
        guard !isDisposed else { return }
        findDocumentGeneration += 1
        navigationState.url = url
        navigationState.committedURL = url
        delegate?.surfaceDidStartNavigation(self)
        delegate?.surfaceDidCommitNavigation(self)
        delegate?.surfaceDidFinishNavigation(self)
        onChange?()
    }
    func goBack() -> URL? { nil }
    func goForward() -> URL? { nil }
    func reload() {}
    func stopLoading() {}
    func cancelStoppedNavigationTracking() {}
    func performZoom(_ command: BrowserPageZoomCommand) {}
    func focusDocument() -> Bool { false }
    func captureSnapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserSurfaceSnapshot { throw BrowserEngineError.unsupportedOperation }
    func requestMediaState() async -> BrowserMediaState { BrowserMediaState() }
    func setAudioMuted(_ muted: Bool) throws {}
    func dispose() { isDisposed = true; onDispose?() }
    func performFind(_ request: BrowserFindRequest, update: @escaping @MainActor (BrowserFindUpdate) -> Void) {}
    func stopFinding(clearSelection: Bool) {}
}

@MainActor
private final class HistoryTestEngine: BrowserEngine {
    let kind = BrowserEngineKind.synthetic
    let capabilities: BrowserEngineCapabilities = [.persistentProfiles]
    var extensions: (any BrowserExtensionHost)? { nil }
    func profile(for profileID: ProfileID) -> BrowserEngineProfile {
        BrowserEngineProfile(profileID: profileID, persistence: .persistent)
    }
    func makeSurface(profileID: ProfileID,
                     delegate: any BrowserEngineSurfaceDelegate<HistoryTestSurface>) -> HistoryTestSurface {
        let surface = HistoryTestSurface(profileID: profileID)
        surface.delegate = delegate
        return surface
    }
    func shutdown() {}
}

}

extension NativeWebKitTests.BrowserHistoryRecorderTests {
    @Test("Remote visits refresh a warm Command Bar index and private recorders never export them")
    func remoteHistoryIndex() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-history-remote-index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID(), now = Date()
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: { .init(profileID: $0, persistence: .persistent) })
        await recorder.prepareSuggestions(for: profile)
        let visit = BrowserHistoryVisit(url: URL(string: "https://remote.synthetic.test/page")!, title: "Remote synthetic", visitedAt: now, transition: .typed, typedCount: 2)
        let batch = BrowserHistorySyncBatch(profileID: profile, cutoff: BrowserHistorySyncSchema.cutoff(now), events: [.init(visit: visit)])
        try await recorder.applySync([batch], for: profile, now: now)
        await recorder.prepareSuggestions(for: profile)
        // A rebuild queued after the mutation can share the in-flight warm-up.
        for _ in 0..<50 where recorder.cachedSuggestions(for: profile, query: "remote").isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.cachedSuggestions(for: profile, query: "remote").first?.typedCount == 2)
        #expect(try await recorder.suggestions(for: profile, query: "remote").first?.visitCount == 1)
        let privateRecorder = BrowserHistoryRecorder()
        try await privateRecorder.applySync([batch], for: profile, now: now)
        #expect(try await privateRecorder.syncBatches(for: profile, now: now).isEmpty)
        #expect(try await privateRecorder.visits(for: profile).isEmpty)
        try await recorder.close()
    }
}
