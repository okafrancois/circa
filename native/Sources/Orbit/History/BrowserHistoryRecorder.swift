import BrowserCore
import BrowserEngine
import Foundation
import OSLog

/// Redacted, non-modal state. No browsing content, paths or raw storage errors escape here.
enum BrowserHistoryIssue: String, Sendable {
    case openUnavailable, operationUnavailable, checkpointDeferred
}

/// Opens (and migrates) a profile store. Always invoked off the main actor.
typealias BrowserHistoryStoreOpener = @Sendable (ProfileID, URL) throws -> BrowserHistoryStore

/// Shared by windows. Every access re-resolves policy; no caller receives a raw store.
@MainActor
final class BrowserHistoryRecorder {
    private let directory: URL?
    private let resolveProfile: (ProfileID) -> BrowserEngineProfile
    private let now: () -> Date
    private let openStore: BrowserHistoryStoreOpener
    private var stores: [ProfileID: BrowserHistoryStore] = [:]
    /// One in-flight open per profile; concurrent callers share its single attempt.
    private var openings: [ProfileID: Task<BrowserHistoryStore, Error>] = [:]
    /// Per-profile bounded memory index for synchronous keystroke suggestions.
    private var memoryIndexes: [ProfileID: BrowserHistoryMemoryIndex] = [:]
    private var memoryQueries: [ProfileID: BrowserHistoryMemoryIndex.QueryCache] = [:]
    /// Bumped by every committed mutation; a snapshot built across a bump is discarded.
    private var indexGenerations: [ProfileID: UInt64] = [:]
    private var indexBuilds: [ProfileID: Task<Void, Never>] = [:]
    /// Deletions and imports in progress; no snapshot is installed while one is running.
    private var bulkMutations: [ProfileID: Int] = [:]
    /// Open multi-chunk imports and whether the palette index was warm when they began.
    private var importBrackets: [ProfileID: Bool] = [:]
    private var failedOpens: [ProfileID: OpenFailure] = [:]
    private var removedProfiles: Set<ProfileID> = []
    private var documents: [ObjectIdentifier: Document] = [:]
    private var pending: Task<Void, Never>?
    private var typedNavigations: [ObjectIdentifier: (surface: WeakHistorySurface, url: URL)] = [:]
    private(set) var issues: [ProfileID: BrowserHistoryIssue] = [:]
    /// Emits once on entering an incident, and once on recovery; never routed to session alerts.
    var onIssue: ((ProfileID, BrowserHistoryIssue?) -> Void)?
    private static let logger = Logger(subsystem: "local.orbit", category: "history")

    init(directory: URL? = nil,
         resolveProfile: @escaping (ProfileID) -> BrowserEngineProfile = {
             BrowserEngineProfile(profileID: $0, persistence: .ephemeral)
         },
         now: @escaping () -> Date = Date.init,
         openStore: @escaping BrowserHistoryStoreOpener = {
             try BrowserHistoryStore(profileID: $0, policy: .persistent, directory: $1)
         }) {
        self.directory = directory
        self.resolveProfile = resolveProfile
        self.now = now
        self.openStore = openStore
    }

    func committed<Surface: BrowserEngineSurface>(_ surface: Surface, profile: BrowserEngineProfile) {
        guard profile.persistence == .persistent, profile.profileID == surface.profileID,
              isPersistent(surface.profileID),
              let url = surface.navigationState.committedURL,
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        documents = documents.filter { $0.value.surface != nil }
        let intent = typedNavigations.removeValue(forKey: ObjectIdentifier(surface))
        let typed = intent?.surface.value === surface && intent?.url == url
        let visit = BrowserHistoryVisit(url: url, title: surface.navigationState.title ?? "",
                                       transition: typed ? .typed : .unknown,
                                       faviconReference: faviconReference(for: surface), typedCount: typed ? 1 : 0)
        documents[ObjectIdentifier(surface)] = Document(surface: surface, profileID: profile.profileID, visitID: visit.id, url: url, generation: surface.findDocumentGeneration)
        enqueue(profileID: profile.profileID) { recorder in
            let page = try await recorder.access(profileID: profile.profileID, disabled: nil as BrowserHistoryIndexedPage?) {
                try await $0.recordReturningPage(visit)
            }
            recorder.committedPage(page, profileID: profile.profileID)
        }
    }

    /// Conservative attribution: only an exact next commit counts. Redirect destinations are
    /// not guessed without a navigation receipt from the engine contract.
    func markTypedNavigation<Surface: BrowserEngineSurface>(_ surface: Surface, url: URL) {
        typedNavigations = typedNavigations.filter { $0.value.surface.value != nil }
        guard isPersistent(surface.profileID) else { return }
        typedNavigations[ObjectIdentifier(surface)] = (WeakHistorySurface(surface), url)
    }

    func cancelTypedNavigation<Surface: BrowserEngineSurface>(_ surface: Surface) {
        typedNavigations.removeValue(forKey: ObjectIdentifier(surface))
    }

    func metadataChanged<Surface: BrowserEngineSurface>(_ surface: Surface) {
        guard let document = documents[ObjectIdentifier(surface)], document.surface === surface,
              isPersistent(document.profileID), surface.navigationState.committedURL == document.url,
              surface.findDocumentGeneration == document.generation else { return }
        let title = surface.navigationState.title ?? ""
        let favicon = faviconReference(for: surface)
        guard title != document.title || favicon != document.favicon else { return }
        document.title = title
        document.favicon = favicon
        let profileID = document.profileID
        let visitID = document.visitID
        enqueue(profileID: profileID) { recorder in
            let page = try await recorder.access(profileID: profileID, disabled: nil as BrowserHistoryIndexedPage?) {
                try await $0.updateMetadata(visitID: visitID, title: title, faviconReference: favicon)
            }
            recorder.committedPage(page, profileID: profileID)
        }
    }

    private func faviconReference<Surface: BrowserEngineSurface>(for surface: Surface) -> URL? {
        if let image = surface.navigationState.faviconImage,
           image.sourceURL == surface.navigationState.faviconURL {
            return BrowserHistoryFavicon.reference(png: image.png)
        }
        return surface.navigationState.faviconURL.flatMap { BrowserHistoryFavicon.accepts($0) ? $0 : nil }
    }

    /// Complete suggestions from the read-only connection. Each call is its own request:
    /// cancelling the caller's task interrupts only this query and throws `CancellationError`,
    /// without affecting other windows or profiles and without raising a history incident.
    func suggestions(for profileID: ProfileID, query: String, mode: BrowserHistorySearchMode = .substring,
                     limit: Int = 12) async throws -> [BrowserHistorySuggestion] {
        let timestamp = now()
        return try await access(profileID: profileID, disabled: []) {
            try Task.checkCancellation()
            return try await $0.suggestions(query, mode: mode, limit: limit, now: timestamp)
        }
    }

    /// Synchronous, main-actor keystroke results from the profile's warm memory index.
    /// Empty until `prepareSuggestions(for:)` completes, and for non-persistent profiles.
    func cachedSuggestions(for profileID: ProfileID, query: String, limit: Int = 12) -> [BrowserHistorySuggestion] {
        guard isPersistent(profileID) else {
            memoryIndexes.removeValue(forKey: profileID)
            memoryQueries.removeValue(forKey: profileID)
            return []
        }
        guard let index = memoryIndexes[profileID] else { memoryQueries[profileID] = nil; return [] }
        var cache = memoryQueries.removeValue(forKey: profileID) ?? .init()
        let result = index.suggestions(query, cache: &cache, limit: limit, now: now())
        memoryQueries[profileID] = cache
        return result
    }

    /// Opens the store and builds the memory index off the main actor. Idempotent and shared:
    /// concurrent callers await the same build. Failures follow the normal incident policy.
    func prepareSuggestions(for profileID: ProfileID) async {
        guard isPersistent(profileID), memoryIndexes[profileID] == nil else { return }
        await startMemoryIndexBuild(for: profileID).value
    }

    /// The current index, if any, keeps serving until the new snapshot replaces it.
    @discardableResult
    private func startMemoryIndexBuild(for profileID: ProfileID) -> Task<Void, Never> {
        if let build = indexBuilds[profileID] { return build }
        let build = Task { [self] in await buildMemoryIndex(for: profileID) }
        indexBuilds[profileID] = build
        return build
    }

    private func buildMemoryIndex(for profileID: ProfileID) async {
        defer { indexBuilds.removeValue(forKey: profileID) }
        // A mutation committed while the snapshot was read invalidates it; retry a bounded number of times.
        for _ in 0..<3 {
            let generation = indexGenerations[profileID, default: 0]
            let timestamp = now()
            guard let index = try? await access(profileID: profileID, disabled: nil as BrowserHistoryMemoryIndex?, operation: {
                try await $0.memoryIndex(now: timestamp)
            }), isPersistent(profileID) else { return }
            // A deletion or import in progress rebuilds on completion; do not race it.
            guard bulkMutations[profileID] == nil else { return }
            if generation == indexGenerations[profileID, default: 0] {
                memoryIndexes[profileID] = index
                return
            }
        }
    }

    /// Applies an authoritative aggregate after a committed record or metadata update.
    private func committedPage(_ page: BrowserHistoryIndexedPage?, profileID: ProfileID) {
        guard let page else { return }
        indexGenerations[profileID, default: 0] &+= 1
        memoryQueries.removeValue(forKey: profileID)
        guard isPersistent(profileID), var index = memoryIndexes[profileID] else { return }
        memoryIndexes.removeValue(forKey: profileID)
        index.upsert(page, now: now().timeIntervalSince1970)
        memoryIndexes[profileID] = index
        if index.needsTrim { refreshMemoryIndex(for: profileID) }
    }

    /// Drops the profile index synchronously and blocks snapshot installation until the matching
    /// `endBulkMutation`, so a snapshot read mid-transaction can never be installed.
    /// Returns whether the index was warm (or warming) and should be rebuilt afterwards.
    private func beginBulkMutation(for profileID: ProfileID) -> Bool {
        bulkMutations[profileID, default: 0] += 1
        indexGenerations[profileID, default: 0] &+= 1
        memoryQueries.removeValue(forKey: profileID)
        return memoryIndexes.removeValue(forKey: profileID) != nil || indexBuilds[profileID] != nil
    }

    private func endBulkMutation(for profileID: ProfileID, rebuild: Bool) {
        bulkMutations[profileID, default: 1] -= 1
        if bulkMutations[profileID] == 0 { bulkMutations.removeValue(forKey: profileID) }
        indexGenerations[profileID, default: 0] &+= 1
        memoryQueries.removeValue(forKey: profileID)
        memoryIndexes.removeValue(forKey: profileID)
        if rebuild { refreshMemoryIndex(for: profileID) }
    }

    /// Rebuilds after the in-flight build (if any) settles, since that one may predate a mutation.
    private func refreshMemoryIndex(for profileID: ProfileID) {
        Task { [self] in
            if let build = indexBuilds[profileID] { await build.value }
            guard isPersistent(profileID) else { return }
            await startMemoryIndexBuild(for: profileID).value
        }
    }

    func visits(for profileID: ProfileID, search: String = "", interval: DateInterval? = nil,
                limit: Int = 100, offset: Int = 0) async throws -> [BrowserHistoryVisit] {
        try await access(profileID: profileID, disabled: []) {
            try await $0.visits(search: search, interval: interval, limit: limit, offset: offset)
        }
    }

    func days(for profileID: ProfileID, search: String = "", interval: DateInterval? = nil, calendar: Calendar = .current,
              limit: Int = 100, offset: Int = 0) async throws -> [BrowserHistoryDay] {
        try await access(profileID: profileID, disabled: []) {
            try await $0.days(search: search, interval: interval, calendar: calendar, limit: limit, offset: offset)
        }
    }

    func importDocument(_ document: BrowserHistoryDocument) async throws -> Int {
        let wasWarm = beginBulkMutation(for: document.profileID)
        defer { endBulkMutation(for: document.profileID, rebuild: wasWarm) }
        return try await access(profileID: document.profileID, disabled: 0) { try await $0.importDocument(document) }
    }

    func syncBatches(for profileID: ProfileID, now: Date = Date()) async throws -> [BrowserHistorySyncBatch] {
        await flush()
        let maintenance = try await access(profileID: profileID, disabled: false) { try await $0.historySyncNeedsApply([], now: now) }
        let wasWarm = maintenance ? beginBulkMutation(for: profileID) : false
        defer { if maintenance { endBulkMutation(for: profileID, rebuild: wasWarm) } }
        return try await access(profileID: profileID, disabled: []) { try await $0.historySyncBatches(now: now) }
    }

    @discardableResult func applySync(_ batches: [BrowserHistorySyncBatch], for profileID: ProfileID, now: Date = Date()) async throws -> Bool {
        guard isPersistent(profileID), try await access(profileID: profileID, disabled: false, operation: {
            try await $0.historySyncNeedsApply(batches, now: now)
        }) else { return false }
        let wasWarm = beginBulkMutation(for: profileID)
        defer { endBulkMutation(for: profileID, rebuild: wasWarm) }
        return try await access(profileID: profileID, disabled: false) { try await $0.applyHistorySync(batches, now: now) }
    }

    // MARK: Multi-chunk import (CORE-IMPORT)

    /// True when imported visits of the profile would be persisted (never for ephemeral profiles).
    func acceptsImportedHistory(for profileID: ProfileID) -> Bool { isPersistent(profileID) }

    /// One bulk mutation for a whole profile import: the palette index is dropped once and rebuilt
    /// once at `endImport`, not after every chunk. Chunks still commit one transaction each.
    func beginImport(for profileID: ProfileID) {
        guard importBrackets[profileID] == nil else { return }
        importBrackets[profileID] = beginBulkMutation(for: profileID)
    }

    func importChunk(_ document: BrowserHistoryDocument) async throws -> Int {
        guard importBrackets[document.profileID] != nil else { return try await importDocument(document) }
        return try await access(profileID: document.profileID, disabled: 0) { try await $0.importDocument(document) }
    }

    func endImport(for profileID: ProfileID) {
        guard let wasWarm = importBrackets.removeValue(forKey: profileID) else { return }
        endBulkMutation(for: profileID, rebuild: wasWarm)
    }

    func delete(for profileID: ProfileID, _ deletion: BrowserHistoryDeletion) async throws -> Int {
        await flush()
        // Deleted pages disappear from keystroke results before the write starts.
        let wasWarm = beginBulkMutation(for: profileID)
        defer { endBulkMutation(for: profileID, rebuild: wasWarm) }
        return try await access(profileID: profileID, disabled: 0) { store in
            let count = try await store.delete(deletion)
            if case .checkpointDeferred = await store.maintenanceStatus {
                publishIssue(.checkpointDeferred, for: profileID)
            } else if issues[profileID] == .checkpointDeferred {
                clearIssue(for: profileID)
            }
            return count
        }
    }

    /// Clears the cooldown and attempt budget for an explicit user retry.
    /// Automatic opening attempts: immediately, after 5 s, after 30 s; then cached indefinitely.
    func retryOpening(for profileID: ProfileID) {
        guard isPersistent(profileID) else { return }
        failedOpens.removeValue(forKey: profileID)
    }

    /// The caller quarantines the model identity before retiring its history. Stale/queued
    /// callbacks cannot recreate files until an explicit cancellation lifts the tombstone.
    func removeProfileHistory(for profileID: ProfileID) async throws {
        let profile = resolveProfile(profileID)
        guard directory != nil, profile.profileID == profileID, profile.persistence == .persistent,
              let directory else { return }
        // Keep the tombstone even if cleanup fails. An explicit cleanup retry is still allowed.
        removedProfiles.insert(profileID)
        indexGenerations[profileID, default: 0] &+= 1
        memoryQueries.removeValue(forKey: profileID)
        memoryIndexes.removeValue(forKey: profileID)
        await flush()
        // An open in flight must settle before the directory is removed.
        if let opening = openings[profileID], let store = try? await opening.value { stores[profileID] = store }
        do {
            if let store = stores[profileID] {
                try await store.removeProfileHistory()
                stores.removeValue(forKey: profileID)
            } else {
                try BrowserHistoryStore.removeUnopenedProfileHistory(profileID: profileID, directory: directory)
            }
            failedOpens.removeValue(forKey: profileID)
            documents = documents.filter { $0.value.profileID != profileID }
            clearIssue(for: profileID)
        } catch {
            publishIssue(.operationUnavailable, for: profileID)
            throw BrowserHistoryError.temporarilyUnavailable
        }
    }

    /// A failed multi-store removal must not silently disable recording for a retained identity.
    /// Discard closed connections as well as the tombstone so an explicit retry can reopen them.
    func cancelProfileRemoval(for profileID: ProfileID) {
        guard removedProfiles.remove(profileID) != nil else { return }
        stores.removeValue(forKey: profileID)
        openings.removeValue(forKey: profileID)
        failedOpens.removeValue(forKey: profileID)
        indexGenerations[profileID, default: 0] &+= 1
        memoryQueries.removeValue(forKey: profileID)
    }

    func flush() async { await pending?.value }

    func close() async throws {
        await flush()
        for opening in openings.values { _ = try? await opening.value }
        memoryIndexes.removeAll()
        memoryQueries.removeAll()
        for store in stores.values { try await store.close() }
    }

    private func isPersistent(_ profileID: ProfileID) -> Bool {
        guard directory != nil, !removedProfiles.contains(profileID) else { return false }
        let profile = resolveProfile(profileID)
        return profile.profileID == profileID && profile.persistence == .persistent
    }

    private func enqueue(profileID: ProfileID, _ operation: @escaping @MainActor (BrowserHistoryRecorder) async throws -> Void) {
        let previous = pending
        pending = Task { [self] in
            await previous?.value
            do { try await operation(self) }
            catch { if issues[profileID] == nil { publishIssue(.operationUnavailable, for: profileID) } }
        }
    }

    private func access<T: Sendable>(profileID: ProfileID, disabled: T,
                                    operation: @MainActor (BrowserHistoryStore) async throws -> T) async throws -> T {
        do {
            guard let store = try await store(for: profileID) else { return disabled }
            let result = try await operation(store)
            if issues[profileID] == .operationUnavailable { clearIssue(for: profileID) }
            return result
        } catch is CancellationError {
            // A superseded query is not a storage incident.
            throw CancellationError()
        } catch {
            // A removed profile (or one whose policy changed) closes its store; that is not an incident.
            if issues[profileID] == nil, isPersistent(profileID) { publishIssue(.operationUnavailable, for: profileID) }
            throw error
        }
    }

    /// Opening and migrating run off the main actor. Policy is re-resolved after the await.
    private func store(for profileID: ProfileID) async throws -> BrowserHistoryStore? {
        guard isPersistent(profileID), let directory else { return nil }
        if let store = stores[profileID] { return store }
        let opening: Task<BrowserHistoryStore, Error>
        if let existing = openings[profileID] {
            opening = existing
        } else {
            let timestamp = now()
            if let failure = failedOpens[profileID], failure.retryAt.map({ timestamp < $0 }) ?? true {
                throw BrowserHistoryError.temporarilyUnavailable
            }
            let open = openStore
            opening = Task { [self] in
                defer { openings.removeValue(forKey: profileID) }
                do {
                    let store = try await Task.detached(priority: .userInitiated) { try open(profileID, directory) }.value
                    stores[profileID] = store
                    failedOpens.removeValue(forKey: profileID)
                    clearIssue(for: profileID)
                    return store
                } catch {
                    let attempts = (failedOpens[profileID]?.attempts ?? 0) + 1
                    let delay: TimeInterval? = attempts == 1 ? 5 : attempts == 2 ? 30 : nil
                    failedOpens[profileID] = OpenFailure(attempts: attempts, retryAt: delay.map { timestamp.addingTimeInterval($0) })
                    publishIssue(.openUnavailable, for: profileID)
                    // Never expose Foundation errors that could contain a storage path.
                    throw BrowserHistoryError.temporarilyUnavailable
                }
            }
            openings[profileID] = opening
        }
        let store = try await opening.value
        return isPersistent(profileID) ? store : nil
    }

    private func publishIssue(_ issue: BrowserHistoryIssue, for profileID: ProfileID) {
        let first = issues[profileID] == nil
        issues[profileID] = issue
        guard first else { return }
        if issue == .checkpointDeferred {
            Self.logger.notice("History WAL cleanup deferred; deletion is committed.")
        } else {
            Self.logger.error("History storage unavailable; consult non-modal history status.")
        }
        onIssue?(profileID, issue)
    }

    private func clearIssue(for profileID: ProfileID) {
        guard issues.removeValue(forKey: profileID) != nil else { return }
        onIssue?(profileID, nil)
    }

    private struct OpenFailure {
        let attempts: Int
        let retryAt: Date?
    }

    private final class Document {
        weak var surface: AnyObject?
        let profileID: ProfileID
        let visitID: UUID
        let url: URL
        let generation: UInt64
        var title = ""
        var favicon: URL?
        init(surface: AnyObject, profileID: ProfileID, visitID: UUID, url: URL, generation: UInt64) {
            self.surface = surface
            self.profileID = profileID
            self.visitID = visitID
            self.url = url
            self.generation = generation
        }
    }
}

@MainActor
private final class WeakHistorySurface {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}
