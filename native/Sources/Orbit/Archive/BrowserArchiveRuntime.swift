import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import OSLog

/// One scheduler per environment. Sessions and diagnostics never retain browsing content.
@MainActor
final class BrowserArchiveRuntime<Surface: BrowserEngineSurface> {
    enum Signal: String { case mediaStateTimedOut, mediaStateStillPending, clockDiscontinuity }
    private final class Entry {
        weak var session: BrowserWindowSession<Surface>?
        init(_ session: BrowserWindowSession<Surface>) { self.session = session }
    }
    private final class ProbeResult {
        var completion: ((BrowserMediaState?) -> Void)?
        @discardableResult
        func resolve(_ value: BrowserMediaState?) -> Bool {
            guard let callback = completion else { return false }
            completion = nil
            callback(value)
            return true
        }
    }
    private static var logger: Logger { Logger(subsystem: "local.orbit", category: "AutoArchive") }
    private var entries: [Entry] = []
    private var pendingProbes: Set<ObjectIdentifier> = []
    private var lastProtected: [TabID: TimeInterval] = [:]
    private let uptime: () -> TimeInterval
    private let wallClock: () -> Date
    private let launchGrace: TimeInterval
    private let mediaGrace: TimeInterval
    private let probeTimeout: Duration
    private let probeSleep: @MainActor (Duration) async throws -> Void
    private let readMedia: @MainActor (Surface) async -> BrowserMediaState
    private var graceUntil: TimeInterval
    private var previousClock: (wall: Date, uptime: TimeInterval)
    let store: BrowserStore
    let onMutation: @MainActor () -> Void
    var onSignal: (Signal) -> Void = { signal in
        logger.warning("Auto-archive signal: \(signal.rawValue, privacy: .public)")
    }
    lazy var scheduler = BrowserAutoArchiveScheduler(store: store, additionalProtection: { [weak self] in
        await self?.protectedTabs() ?? []
    })

    init(store: BrowserStore, launchGrace: TimeInterval = 300, mediaGrace: TimeInterval = 300,
         probeTimeout: Duration = .milliseconds(250),
         probeSleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallClock: @escaping () -> Date = Date.init,
         readMedia: @escaping @MainActor (Surface) async -> BrowserMediaState = { await $0.requestMediaState() },
         onMutation: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.onMutation = onMutation
        self.uptime = uptime
        self.wallClock = wallClock
        self.launchGrace = launchGrace
        self.mediaGrace = mediaGrace
        self.probeTimeout = probeTimeout
        self.probeSleep = probeSleep
        self.readMedia = readMedia
        let now = uptime()
        graceUntil = now + launchGrace
        previousClock = (wallClock(), now)
        scheduler.onArchive = { [weak self] _ in self?.onMutation() }
    }

    func register(_ session: BrowserWindowSession<Surface>) {
        entries.removeAll { $0.session == nil || $0.session?.isClosed == true }
        if !entries.contains(where: { $0.session === session }) { entries.append(Entry(session)) }
    }

    static func protects(_ media: BrowserMediaState) -> Bool {
        // Unknown engines remain protected. Chromium can report audio playback activity even
        // without an acoustic audibility API; known idle media must not protect every loaded tab.
        media.isAudible == true || media.isAudioPlaying == true
            || (media.isAudible == nil && media.isAudioPlaying == nil)
            || media.playback == .playing || media.playback == .suspended
            || media.camera == .active || media.camera == .muted
            || media.microphone == .active || media.microphone == .muted
    }

    /// Automatic sweeps query expired Today tabs plus previously protected media. Explicit Clear
    /// queries all Today tabs and bypasses launch grace, retaining visible/media tabs only.
    func protectedTabs(forClearToday: Bool = false) async -> Set<TabID> {
        let now = uptime(), wall = wallClock()
        let discontinuity = abs(wall.timeIntervalSince(previousClock.wall) - (now - previousClock.uptime)) > 300
        previousClock = (wall, now)
        let allToday = await store.autoArchiveCandidates(includeUnexpired: true)
        if discontinuity {
            onSignal(.clockDiscontinuity)
            graceUntil = now + launchGrace
            await store.touchArchiveProtectedTabs(allToday)
            onMutation()
        }
        if !forClearToday && now < graceUntil { return allToday }
        let expired = await store.autoArchiveCandidates()
        lastProtected = lastProtected.filter { allToday.contains($0.key) }
        let candidates = forClearToday ? allToday : expired.union(lastProtected.keys)
        let document = await store.sessionDocument()
        let tabIDs = Dictionary(uniqueKeysWithValues: document.tabs.map { ($0.occurrenceID, $0.id) })
        var protected: Set<TabID> = []
        for entry in entries {
            guard let session = entry.session, !session.isClosed else { continue }
            for surface in session.ownedSurfaces {
                guard let occurrence = session.occurrenceID(for: surface), let id = tabIDs[occurrence],
                      candidates.contains(id) else { continue }
                let media = await sample(surface)
                guard !Task.isCancelled, !session.isClosed, session.occurrenceID(for: surface) == occurrence else { continue }
                if media.map(Self.protects) ?? true {
                    lastProtected[id] = now
                    protected.insert(id)
                } else if let last = lastProtected[id], now - last < mediaGrace {
                    protected.insert(id)
                } else { lastProtected[id] = nil }
            }
        }
        if !protected.isEmpty {
            await store.touchArchiveProtectedTabs(protected)
            onMutation()
        }
        return protected
    }

    /// Unstructured race: a non-cooperative engine request cannot hold a task group open. At most
    /// one request per surface remains outstanding; later sweeps conservatively protect it.
    private func sample(_ surface: Surface) async -> BrowserMediaState? {
        let key = ObjectIdentifier(surface)
        guard pendingProbes.insert(key).inserted else { onSignal(.mediaStateStillPending); return nil }
        let readMedia = self.readMedia, timeout = probeTimeout, probeSleep = self.probeSleep
        return await withCheckedContinuation { continuation in
            let result = ProbeResult()
            result.completion = { continuation.resume(returning: $0) }
            let timer = Task { [weak self] in
                do { try await probeSleep(timeout) } catch { return }
                if result.resolve(nil) { self?.onSignal(.mediaStateTimedOut) }
            }
            Task { [weak self] in
                let media = await readMedia(surface)
                self?.pendingProbes.remove(key)
                timer.cancel()
                result.resolve(media)
            }
        }
    }
}
