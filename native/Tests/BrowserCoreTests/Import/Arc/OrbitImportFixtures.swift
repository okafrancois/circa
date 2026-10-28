@testable import BrowserCore
import OrbitImportSynthetic
import Foundation

/// Test helpers over the synthetic Arc data of `OrbitImportSynthetic`.
typealias OrbitFixture = ArcSyntheticData

extension ArcSyntheticData {
    static func json(_ value: Any) -> ArcJSON {
        try! ArcJSON.parse(try! JSONSerialization.data(withJSONObject: value), allowingArray: true)
    }

    static func graph(sidebar: [String: Any] = sidebar(), archive: [String: Any]? = archive(),
                      legacy: [String: String] = [:]) throws -> ArcSidebarGraph {
        try ArcSidebarParser.parse(sidebar: json(sidebar), archive: archive.map(json), localState: json(localState()),
                                   legacyProfileDirectories: legacy)
    }

    /// Every personal-looking string of the fixture, for privacy assertions.
    static var sensitiveStrings: [String] {
        let ids = ["a-nested", "a-today-2", "a-pin-1", "a-pin-2", "a-renamed", "a-today-1", "fav-1", "fav-2", "b-pin",
                   "b-today-1", "fav-b", "closed-a", "closed-b", "closed-neutral"]
        return ids.flatMap { [url($0), title($0), "\($0).example.test"] } + historyHosts
            + ["Renamed synthetic tab", "Folder outer", "Folder inner", "Space a", "Space b", "Space c", "Synthetic visit"]
            + Array(profileNames.values)
    }
}

/// Synthetic Arc folder, session file and snapshot parent in one private temporary root.
struct OrbitImportTestFixture {
    let root: URL
    let source: URL
    let sessionFile: URL
    let snapshots: URL
    let log = CapturingImportLog()

    init(history: [OrbitFixture.HistoryRow] = OrbitFixture.historyRows(count: 30),
         sidebar: [String: Any] = OrbitFixture.sidebar()) throws {
        root = try OrbitFixture.temporaryDirectory()
        source = try OrbitFixture.writeDataDirectory(at: root.appendingPathComponent("Arc", isDirectory: true), historyRows: history,
                                                   sidebar: sidebar)
        sessionFile = root.appendingPathComponent("Orbit/session.json")
        snapshots = root.appendingPathComponent("Snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    }

    func importer(chunk: Int = 7, diskSpace: any OrbitDiskSpaceProbe = OrbitSystemDiskSpaceProbe(),
                  checkpoint: @escaping @Sendable (ArcImportCheckpoint) throws -> Void = { _ in }) -> ArcImporter {
        var options = ArcImportOptions()
        options.historyChunkSize = chunk
        var importer = ArcImporter(source: source, options: options, probe: NeverRunningProbe(), logger: log,
                                   snapshotParent: snapshots, clock: { Date(timeIntervalSince1970: 1_760_000_000) },
                                   diskSpace: diskSpace)
        importer.checkpoint = checkpoint
        return importer
    }

    func target() throws -> ArcOfflineImportTarget {
        try ArcOfflineImportTarget(sessionFile: sessionFile, usage: NeverRunningProbe())
    }

    /// An existing Orbit session with one profile, one Space and some history of its own.
    func seedExistingSession() async throws -> ProfileID {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic Orbit Profile")
        let space = try await store.createSpace(name: "Synthetic Orbit Space", profileID: profile)
        _ = try await store.createWindow(activeSpaceID: space)
        try BrowserSessionFileStore().save(await store.sessionDocument(), to: sessionFile)
        let history = try BrowserHistoryStore(profileID: profile, policy: .persistent,
                                              directory: ArcImportDataLocation(sessionFile: sessionFile).historyDirectory)
        _ = try await history.record(BrowserHistoryVisit(url: URL(string: "https://orbit-own.example.test/")!, visitedAt: Date()))
        try await history.close()
        return profile
    }

    func historyCount(_ profile: ProfileID) async throws -> Int {
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent,
                                            directory: ArcImportDataLocation(sessionFile: sessionFile).historyDirectory)
        defer { Task { try? await store.close() } }
        return try await store.visits(limit: 100_000).count
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

struct NeverRunningProbe: ArcRunningProbe, OrbitTargetUsageProbe {
    func isArcRunning(sourceRoot: URL) -> Bool { false }
    func isInUse(sessionFile: URL) -> Bool { false }
}

struct AlwaysRunningProbe: ArcRunningProbe, OrbitTargetUsageProbe {
    func isArcRunning(sourceRoot: URL) -> Bool { true }
    func isInUse(sessionFile: URL) -> Bool { true }
}

/// Captures every log event for privacy assertions.
final class CapturingImportLog: ArcImportLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ArcImportLogEvent] = []
    var events: [ArcImportLogEvent] { lock.withLock { storage } }
    var messages: [String] { events.map(\.message) }
    func log(_ event: ArcImportLogEvent) { lock.withLock { storage.append(event) } }
}

/// Reports a fixed amount of free space (switchable), for disk-space refusals.
final class FixedDiskSpace: OrbitDiskSpaceProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64?
    init(_ bytes: Int64?) { self.bytes = bytes }
    func set(_ value: Int64?) { lock.withLock { bytes = value } }
    func availableBytes(at url: URL) -> Int64? { lock.withLock { bytes } }
}
