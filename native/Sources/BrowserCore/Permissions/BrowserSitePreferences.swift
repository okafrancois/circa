import Foundation
import os

public struct BrowserSitePreferences: Codable, Equatable, Sendable {
    public var developerMode = false
    public var automaticPictureInPicture = true
    public var neverTranslate = false
    /// False adds the host, with its subdomains, to the profile's content blocking allow-list.
    public var blocksAdsAndTrackers = true
    /// The engine chosen for this host with "Reload with WebKit/Chromium"; nil follows the
    /// built-in protected-streaming list (`BrowserProtectedStreamingSites`).
    public var siteEngine: BrowserSiteEngine?
    public init() {}

    private enum CodingKeys: String, CodingKey { case developerMode, automaticPictureInPicture, neverTranslate, blocksAdsAndTrackers, siteEngine }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        developerMode = try values.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
        automaticPictureInPicture = try values.decodeIfPresent(Bool.self, forKey: .automaticPictureInPicture) ?? true
        neverTranslate = try values.decodeIfPresent(Bool.self, forKey: .neverTranslate) ?? false
        blocksAdsAndTrackers = try values.decodeIfPresent(Bool.self, forKey: .blocksAdsAndTrackers) ?? true
        // An unknown future engine name reads as "follow the default" instead of failing the file.
        siteEngine = (try? values.decodeIfPresent(String.self, forKey: .siteEngine)).flatMap(BrowserSiteEngine.init(rawValue:))
    }
}

/// Orbit's Developer Mode is host-scoped. Schemes and ports of one host share preferences
/// within a profile; permissions continue to use their stricter origin scope.
///
/// Reads and writes update memory synchronously. The file is written durably (two full
/// syncs: backup, then document) on a background serial queue, coalescing a burst of toggles
/// into one write. Quit flushes pending writes before the session is finalized; reopening
/// the same file flushes first. After a crash or power loss, at most the toggles of the last
/// `BrowserSitePreferenceWriter.coalescingDelay` (250 ms) are lost. Clearing a profile is
/// written through before it returns.
@MainActor
public final class BrowserSitePreferenceStore {
    private struct Entry: Codable {
        var profileID: ProfileID
        var host: String
        var preferences: BrowserSitePreferences
    }
    private struct Document: Codable {
        var version = 1
        var entries: [Entry] = []
    }
    private var document = Document()
    private let writable: Bool
    private let writer: BrowserSitePreferenceWriter?

    public init(destination: URL? = nil, writable: Bool = true) throws {
        self.writable = writable
        writer = destination.map(BrowserSitePreferenceWriter.shared(for:))
        // Another store for the same file may still have a coalesced write in flight.
        try? writer?.flushNow()
        if let destination, let data = try BrowserPermissionFile.load(destination) {
            document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw BrowserPermissionStoreError.unsupportedVersion }
        }
    }

    public func preferences(url: URL?, profileID: ProfileID) -> BrowserSitePreferences {
        guard let host = Self.host(url) else { return .init() }
        if let saved = document.entries.first(where: { $0.profileID == profileID && $0.host == host }) { return saved.preferences }
        var defaults = BrowserSitePreferences()
        defaults.developerMode = host == "localhost" || host.hasSuffix(".localhost")
        return defaults
    }

    public func set(_ preferences: BrowserSitePreferences, url: URL?, profileID: ProfileID) throws {
        guard writable, let host = Self.host(url) else { throw BrowserPermissionStoreError.unavailable }
        var next = document
        next.entries.removeAll { $0.profileID == profileID && $0.host == host }
        next.entries.append(Entry(profileID: profileID, host: host, preferences: preferences))
        try publish(next)
    }

    /// Hosts of the profile where the user turned ad and tracker blocking off, sorted.
    public func contentBlockingExceptions(profileID: ProfileID) -> [String] {
        document.entries.filter { $0.profileID == profileID && !$0.preferences.blocksAdsAndTrackers }.map(\.host).sorted()
    }

    /// Removal is durable before this returns: profile data must not survive a crash.
    public func clear(profileID: ProfileID) throws {
        var next = document
        next.entries.removeAll { $0.profileID == profileID }
        try publish(next)
        try writer?.flushNow()
    }

    /// Waits off the main thread until every accepted change is durable on disk.
    public func flushPendingWrites() async throws { try await writer?.flush() }
    /// Blocking variant for teardown paths that cannot await.
    public func flushPendingWritesNow() throws { try writer?.flushNow() }

    private func publish(_ next: Document) throws {
        guard writable else { throw BrowserPermissionStoreError.unavailable }
        if let writer {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            writer.schedule(try encoder.encode(next))
        }
        document = next
    }

    nonisolated public static func host(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()), let host = url.host,
              !host.isEmpty else { return nil }
        return host.lowercased()
    }
}

/// One per preference file, shared by every store opened on it. The latest document wins;
/// a burst of changes within `coalescingDelay` becomes a single durable write.
final class BrowserSitePreferenceWriter: Sendable {
    static let coalescingDelay: DispatchTimeInterval = .milliseconds(250)
    private static let registry = OSAllocatedUnfairLock(initialState: [String: BrowserSitePreferenceWriter]())

    static func shared(for destination: URL) -> BrowserSitePreferenceWriter {
        registry.withLock { writers in
            // The literal path: standardizing consults the file system, so one file would get
            // two keys (and two writers) before and after it exists.
            let key = destination.path
            if let writer = writers[key] { return writer }
            let writer = BrowserSitePreferenceWriter(destination: destination)
            writers[key] = writer
            return writer
        }
    }

    private struct State {
        var pending: Data?
        var isScheduled = false
        var lastError: (any Error)?
        var completedWrites = 0
    }
    private let destination: URL
    private let queue = DispatchQueue(label: "orbit.site-preferences.writer", qos: .utility)
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    private init(destination: URL) { self.destination = destination }

    /// Durable writes performed so far (tests observe coalescing through it).
    var completedWrites: Int { state.withLock { $0.completedWrites } }

    func schedule(_ data: Data) {
        let startsTimer = state.withLock { state -> Bool in
            state.pending = data
            defer { state.isScheduled = true }
            return !state.isScheduled
        }
        guard startsTimer else { return }
        queue.asyncAfter(deadline: .now() + Self.coalescingDelay) { [self] in try? writePending() }
    }

    func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do { try writePending(); continuation.resume() } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func flushNow() throws { try queue.sync { try writePending() } }

    /// Runs on `queue` only. A failed write stays pending (unless a newer document replaced
    /// it) and is retried by the next change or flush; the failure is reported to flushes.
    private func writePending() throws {
        let data = state.withLock { state -> Data? in
            state.isScheduled = false
            defer { state.pending = nil }
            return state.pending
        }
        guard let data else {
            if let error = state.withLock({ $0.lastError }) { throw error }
            return
        }
        do {
            if let previous = try BrowserPermissionFile.load(destination) {
                try BrowserPermissionFile.save(previous, to: destination.appendingPathExtension("backup"))
            }
            try BrowserPermissionFile.save(data, to: destination)
            state.withLock { $0.lastError = nil; $0.completedWrites += 1 }
        } catch {
            state.withLock { state in
                if state.pending == nil { state.pending = data }
                state.lastError = error
            }
            throw error
        }
    }
}
