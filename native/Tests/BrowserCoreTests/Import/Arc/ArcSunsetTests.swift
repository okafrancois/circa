import Foundation
import ObjectiveC
import Testing
import OrbitImportSynthetic
@testable import BrowserCore

@Suite("Arc local-only import", .serialized)
struct ArcSunsetTests {
    @Test("Closed, uninstalled and signed-out sources need only local data", arguments: ["closed", "uninstalled", "signed-out", "stale-markers"])
    func localOnly(state: String) async throws {
        let fixture = try OrbitImportTestFixture()
        defer { fixture.remove() }
        // No app inventory, account or network provider is supplied to this production path.
        if state == "signed-out" {
            try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("User Data/Local State"))
        } else if state == "stale-markers" {
            // Deliberately unreadable irrelevant marker, not a claim about a vendor account schema.
            try FileManager.default.createSymbolicLink(atPath: fixture.source.appendingPathComponent("account.json").path,
                                                       withDestinationPath: "/nonexistent-synthetic-account")
        }
        let target = try fixture.target()
        let importer = fixture.importer()
        let prepared = try await importer.prepare(for: target)
        #expect(prepared.report.source.spaces == 3)
        #expect(prepared.report.source.profiles == 3)
        #expect(prepared.report.source.pinnedTabs == 5)
        #expect(prepared.report.source.pinnedFolders == 2)
        #expect(prepared.report.source.todayTabs == 3)
        #expect(prepared.report.source.favorites == 3)
        #expect(prepared.report.source.archivedTabs == 2)
        let outcome = try await importer.apply(prepared, to: target)
        #expect(outcome.historyInserted == 60)
        await target.close()
        let reopened = try fixture.target()
        #expect(await reopened.sessionDocument().spaces.count == 3)
        await reopened.close()
        try ArcImportBackups.restore(outcome.backupID, at: target.location, usage: NeverRunningProbe())
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionFile.path))
    }

    @Test("Unknown versions and keys, and absent optional fields retain structural counts", arguments: [0, 999])
    func schema(version: Int) async throws {
        var sidebar = ArcSyntheticData.sidebar(version: version)
        var body = sidebar["sidebar"] as! [String: Any]
        var containers = body["containers"] as! [Any]
        var container = containers[1] as! [String: Any]
        var spaces = container["spaces"] as! [Any]
        for index in stride(from: 1, to: spaces.count, by: 2) {
            var space = spaces[index] as! [String: Any]
            for name in ["customInfo", "newContainerIDs", "title", "futureSpaceField"] { space.removeValue(forKey: name) }
            spaces[index] = space
        }
        container["spaces"] = spaces; containers[1] = container; body["containers"] = containers; sidebar["sidebar"] = body
        let fixture = try OrbitImportTestFixture(sidebar: sidebar)
        defer { fixture.remove() }
        let target = try fixture.target()
        let preparation = try await fixture.importer().prepare(for: target)
        #expect(preparation.report.source.spaces == 3 && preparation.report.source.pinnedTabs == 5)
        #expect(preparation.report.source.todayTabs == 3 && preparation.report.source.favorites == 3)
        preparation.discard()
        await target.close()
    }

    struct UnavailableKeys: ArcSiteSessionKeyProviding {
        let error: BrowserAuthenticationImportError
        func sourcePassword() throws -> Data { throw error }
        func targetPassword() throws -> Data { Issue.record("Target key must not be queried"); return Data() }
    }
    @Test("Denied or absent Safe Storage keeps the structural import and makes no connection mutation",
          arguments: [BrowserAuthenticationImportError.sourceKeyMissing, .keychainDenied])
    func unavailableKeys(error: BrowserAuthenticationImportError) async throws {
        let fixture = try OrbitImportTestFixture()
        defer { fixture.remove() }
        let target = try fixture.target()
        _ = try await fixture.importer().apply(try await fixture.importer().prepare(for: target), to: target)
        let document = await target.sessionDocument()
        await target.close()
        let importer = ArcSiteSessionImport(dataRoot: target.location.dataDirectory)
        let request = ArcSiteSessionRequest(sourceRoot: fixture.source.appendingPathComponent("User Data"), profiles: [
            .init(sourceDirectory: "Default", targetID: try #require(document.profiles.first?.id))])
        try importer.schedule(request)
        #expect(throws: error) { try importer.consumePending(keys: UnavailableKeys(error: error)) }
        #expect(!importer.hasBackup && !FileManager.default.fileExists(atPath: importer.pendingFile.path))
        #expect(try BrowserSessionFileStore().load(from: fixture.sessionFile) == document)
        #expect(!FileManager.default.fileExists(atPath: target.location.dataDirectory.appendingPathComponent("Chromium").path))
    }

    @Test("Structural import and the pending offline connection job issue zero URLSession requests")
    func networkForbidden() async throws {
        // URLSession does not consistently honor URLProtocol's global registry on macOS.
        // Trap the configuration getter used by all newly created default/ephemeral sessions.
        let getter = try #require(class_getInstanceMethod(type(of: URLSessionConfiguration.default),
            #selector(getter: URLSessionConfiguration.protocolClasses)))
        let block: @convention(block) (AnyObject) -> NSArray = { _ in [RejectImportNetwork.self] as NSArray }
        let replacement = imp_implementationWithBlock(block)
        let original = method_setImplementation(getter, replacement)
        RejectImportNetwork.enable(true)
        defer {
            RejectImportNetwork.enable(false)
            method_setImplementation(getter, original); imp_removeBlock(replacement)
        }
        let session = URLSession(configuration: .default)
        let ephemeral = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel(); ephemeral.invalidateAndCancel() }
        for control in [session, ephemeral, URLSession.shared] {
            do {
                _ = try await control.data(for: URLRequest(url: URL(string: "https://network-control.example.test/")!, timeoutInterval: 1))
                Issue.record("The network trap must reject its positive control")
            } catch {}
        }
        #expect(RejectImportNetwork.takeCount() == 3)
        let fixture = try OrbitImportTestFixture()
        defer { fixture.remove() }
        let target = try fixture.target()
        let importer = fixture.importer()
        let outcome = try await importer.apply(try await importer.prepare(for: target), to: target)
        #expect(outcome.historyInserted == 60)
        await target.close()
        let connections = try OrbitSiteSessionImportTests.Fixture()
        defer { connections.remove() }
        let keys = OrbitSiteSessionImportTests.Keys()
        try connections.database(at: connections.source, password: keys.source, rows: [("session", "synthetic", false)])
        try connections.storage(at: connections.source, value: "synthetic storage")
        try connections.importer.schedule(connections.request)
        let result = try connections.importer.consumePending(keys: keys)
        #expect(result?.cookies == 1 && result?.profiles == 1)
        #expect(try connections.importer.consumePending(keys: keys) == nil)
        _ = try connections.importer.restoreLatest()
        try ArcImportBackups.restore(outcome.backupID, at: target.location, usage: NeverRunningProbe())
        #expect(RejectImportNetwork.takeCount() == 0)
    }

    @Test("A long page title ending at whitespace remains valid after import sanitization")
    func truncatedTitle() {
        let title = String(repeating: "x", count: 1_023) + " tail"
        let sanitized = BrowserOrganizationState.sanitizedPageTitle(title)
        #expect(sanitized?.count == 1_023)
        #expect(BrowserOrganizationState.sanitizedPageTitle(sanitized) == sanitized)
    }

    @Test("Large local source imports, reloads and restores exact counts")
    func scale() async throws {
        guard ProcessInfo.processInfo.environment["ORBIT_SUNSET_SCALE"] == "1" else { return }
        let root = try ArcSyntheticData.temporaryDirectory("arc-sunset-scale")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try ArcSyntheticData.writeSunsetScaleDirectory(at: source)
        #expect(try Data(contentsOf: source.appendingPathComponent("StorableSidebar.json")).count >= 20 * 1024 * 1024)
        let session = root.appendingPathComponent("Target/session.json")
        let target = try ArcOfflineImportTarget(sessionFile: session, usage: NeverRunningProbe())
        let snapshots = root.appendingPathComponent("Snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let importer = ArcImporter(source: source, probe: NeverRunningProbe(), snapshotParent: snapshots)
        let prepared = try await importer.prepare(for: target)
        #expect(prepared.report.sessionBudget.fits)
        #expect(prepared.report.source.spaces == 30 && prepared.report.source.profiles == 3)
        #expect(prepared.report.source.pinnedFolders == 150 && prepared.report.source.pinnedTabs == 1_050)
        #expect(prepared.report.source.todayTabs == 1_050 && prepared.report.source.favorites == 3)
        #expect(prepared.report.source.archivedTabs == 1_002 && prepared.report.history.importable == 51_000)
        let outcome = try await importer.apply(prepared, to: target)
        #expect(outcome.historyInserted == 51_000)
        await target.close()
        let reopened = try ArcOfflineImportTarget(sessionFile: session, usage: NeverRunningProbe())
        let document = await reopened.sessionDocument()
        #expect(document.spaces.count == 30 && document.organization.archive.count == 1_002)
        await reopened.close()
        try ArcImportBackups.restore(outcome.backupID, at: target.location, usage: NeverRunningProbe())
        #expect(!FileManager.default.fileExists(atPath: session.path))
    }
}

/// Global URLSession trap with a positive control; no hostname or request content is recorded.
private final class RejectImportNetwork: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var attempts = 0
    nonisolated(unsafe) private static var enabled = false
    static func enable(_ value: Bool) { lock.withLock { enabled = value } }
    static func takeCount() -> Int { lock.withLock { defer { attempts = 0 }; return attempts } }
    override class func canInit(with request: URLRequest) -> Bool { lock.withLock { enabled } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.attempts += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
