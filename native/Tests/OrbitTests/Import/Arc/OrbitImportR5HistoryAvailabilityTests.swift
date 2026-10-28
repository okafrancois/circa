@testable import Orbit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing

/// Windowless application seam: no NSApplication, windows, real engine, network or Keychain.
extension NativeWebKitTests {
@Suite("source browser import R5 history availability", .serialized)
@MainActor
struct OrbitImportR5HistoryAvailabilityTests {
    enum Failure: CaseIterable, Sendable { case rootIsFile, ancestorIsLink, corruptDatabase }

    @Test("Unavailable history cannot prevent environment startup, tab commands or committed navigation", arguments: Failure.allCases)
    func startupAndNavigation(_ failure: Failure) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-import-r5-app-synthetic-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("History", isDirectory: true)
        switch failure {
        case .rootIsFile:
            try Data("synthetic obstruction".utf8).write(to: history)
        case .ancestorIsLink:
            let outside = root.appendingPathComponent("Outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: history, withDestinationURL: outside)
        case .corruptDatabase: break
        }
        let engine = R5HistoryEngine()
        let environment = try await BrowserEnvironment.open(engine: engine, sessionFile: root.appendingPathComponent("session.json"))
        let (space, profile) = try await environment.initialContext.value
        if failure == .corruptDatabase {
            let folder = history.appendingPathComponent(profile.rawValue.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("synthetic invalid SQLite document".utf8).write(to: folder.appendingPathComponent("history.sqlite"))
        }
        var persistenceErrors = 0
        environment.onPersistenceError = { _ in persistenceErrors += 1 }
        let delegate = R5HistoryDelegate(recorder: environment.historyRecorder)
        let session = BrowserWindowSession(store: environment.store, spaceID: space, makeSurface: { id, _ in
            engine.makeSurface(profileID: id, delegate: delegate)
        }, startSurface: { surface, url in surface.navigate(to: url) })
        session.openTab(url: URL(string: "https://synthetic.test/first")!)
        await session.waitForPendingCommands()
        await environment.historyRecorder.flush()
        #expect(session.selectedSurface?.currentURL?.path == "/first")
        session.openTab(url: URL(string: "https://synthetic.test/second")!)
        await session.waitForPendingCommands()
        await environment.historyRecorder.flush()
        #expect(session.selectedSurface?.currentURL?.path == "/second")
        #expect(environment.historyRecorder.issues[profile] == .openUnavailable)
        #expect(persistenceErrors == 0)
        if failure == .ancestorIsLink {
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Outside").path).isEmpty)
        }
        session.close()
        await session.waitForPendingCommands()
        try await environment.finalize()
    }

    @Test("Uncached profile retirement refuses an existing linked ancestor without deleting outside data")
    func uncachedDeletionRefusesAncestor() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-import-r5-retire-synthetic-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let original = root.appendingPathComponent("Original")
        let parked = root.appendingPathComponent("Parked")
        let outside = root.appendingPathComponent("Outside")
        let relative = "History/" + profile.rawValue.uuidString
        for ancestor in [original, outside] {
            let folder = ancestor.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("synthetic retained bytes".utf8).write(to: folder.appendingPathComponent("history.sqlite"))
        }
        let recorder = BrowserHistoryRecorder(directory: original.appendingPathComponent("History"), resolveProfile: {
            .init(profileID: $0, persistence: .persistent)
        })
        try FileManager.default.moveItem(at: original, to: parked)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        await #expect(throws: BrowserHistoryError.temporarilyUnavailable) {
            try await recorder.removeProfileHistory(for: profile)
        }
        for ancestor in [parked, outside] {
            #expect(try Data(contentsOf: ancestor.appendingPathComponent(relative + "/history.sqlite")) == Data("synthetic retained bytes".utf8))
        }
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: parked, to: original)
        try await recorder.removeProfileHistory(for: profile)
        #expect(!FileManager.default.fileExists(atPath: original.appendingPathComponent(relative).path))
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent(relative + "/history.sqlite").path))
        try await recorder.close()
    }

}
}

@MainActor
private final class R5HistoryEngine: BrowserEngine {
    let base = SiteSyntheticEngine()
    let kind = BrowserEngineKind.synthetic
    let capabilities: BrowserEngineCapabilities = [.persistentProfiles]
    var extensions: (any BrowserExtensionHost)? { nil }
    func profile(for id: ProfileID) -> BrowserEngineProfile { .init(profileID: id, persistence: .persistent) }
    func makeSurface(profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<SiteSyntheticSurface>) -> SiteSyntheticSurface {
        base.makeSurface(profileID: profileID, delegate: delegate)
    }
    func shutdown() async { await base.shutdown() }
}

@MainActor
private final class R5HistoryDelegate: BrowserEngineSurfaceDelegate {
    let recorder: BrowserHistoryRecorder
    init(recorder: BrowserHistoryRecorder) { self.recorder = recorder }
    func surfaceDidStartNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidCommitNavigation(_ surface: SiteSyntheticSurface) {
        recorder.committed(surface, profile: .init(profileID: surface.profileID, persistence: .persistent))
    }
    func surfaceDidFinishNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidFailNavigation(_ surface: SiteSyntheticSurface) {}
    func surface(_ surface: SiteSyntheticSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
    func surface(_ surface: SiteSyntheticSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> SiteSyntheticSurface) -> SiteSyntheticSurface? { nil }
    func surfaceDidRequestClose(_ surface: SiteSyntheticSurface) {}
    func surface(_ surface: SiteSyntheticSurface, didStartDownload download: any BrowserEngineDownload) {}
}
