import AppKit
import BrowserEngine
import OrbitImportSynthetic
import BrowserCore
import Foundation
import CryptoKit
import Testing
@testable import Orbit

@MainActor
private final class ReviewProfileEngine: BrowserEngine {
    typealias Surface = SiteSyntheticSurface
    let base = SiteSyntheticEngine()
    var requests: [ProfileID] = []
    let kind = BrowserEngineKind.synthetic
    var capabilities: BrowserEngineCapabilities { base.capabilities.union(.persistentProfiles) }
    var extensions: (any BrowserExtensionHost)? { nil }
    var conformanceProbe: (any BrowserEngineConformanceProbe<Surface>)? { nil }
    func profile(for id: ProfileID) -> BrowserEngineProfile {
        requests.append(id)
        return .init(profileID: id, persistence: .persistent)
    }
    func makeSurface(profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<Surface>) -> Surface {
        base.makeSurface(profileID: profileID, delegate: delegate)
    }
    func shutdown() async { await base.shutdown() }
}

struct BrowserImportUITests {
    @Test func metadataOnlyInventoryKeepsProfilesAndUnavailableSources() throws {
        let root = URL(fileURLWithPath: "/private/tmp/import-ui-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = ChromiumImportRegistry.descriptors[0], firefox = FirefoxImportRegistry.descriptors[0]
        let chromeRoot = root.appendingPathComponent(chrome.supportPath), firefoxRoot = root.appendingPathComponent(firefox.supportPath)
        try FileManager.default.createDirectory(at: chromeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: firefoxRoot, withIntermediateDirectories: true)
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 1":{"name":"Work"},"Guest Profile":{"name":"Guest"}}}}"#.utf8).write(to: chromeRoot.appendingPathComponent("Local State"))
        try Data("[Profile0]\nName=Research\nIsRelative=1\nPath=Profiles/research\n".utf8).write(to: firefoxRoot.appendingPathComponent("profiles.ini"))
        // No content directories exist: discovery must still return metadata, without opening DBs.
        let choices = BrowserImportInventory.choices(descriptors: [chrome, firefox, ChromiumImportRegistry.descriptors[1]], support: root)
        try #require(choices.count == 4)
        #expect(choices[0].profile?.name == "Personal")
        #expect(choices[1].profile?.name == "Work")
        #expect(choices[2].profile?.name == "Research")
        #expect(choices[3].profile == nil)
        #expect(!choices.contains { $0.descriptor.id == "arc" })
        #expect(BrowserImportInventory.choices(descriptors: [], support: root).isEmpty)
    }
    @Test func metadataAndCSVRefuseLinksAndInvalidInput() throws {
        let root = URL(fileURLWithPath: "/private/tmp/import-ui-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("sentinel".utf8).write(to: root.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Local State"), withDestinationURL: root.appendingPathComponent("original"))
        #expect(throws: (any Error).self) { try BrowserImportMetadata.read(root: root, name: "Local State") }
        #expect(throws: (any Error).self) { try BrowserImportMetadata.read(root: root, name: "Cookies") }
        try Data("invalid".utf8).write(to: root.appendingPathComponent("logins.csv"))
        #expect(throws: (any Error).self) { try BrowserImportMetadata.readCSV(root.appendingPathComponent("logins.csv")) }
        #expect(try Data(contentsOf: root.appendingPathComponent("original")) == Data("sentinel".utf8))
    }
    @Test func reviewExplainsUnavailableCategoriesBeforeMutation() {
        var report = ArcImportReport()
        report.capabilities = ["bookmarks": .needsExport, "tabs": .failed, "history": .supported]
        report.historyDatabasesUnreadable = 1
        let review = BrowserImportText.review(report)
        #expect(review.contains(uiText("export required")))
        #expect(review.contains(uiText("could not be read")))
        #expect(review.contains(uiText("Some history could not be read and will not be imported.")))
        #expect(!review.contains("needsExport"))
        #expect(!review.contains(": Available"))
        report.capabilities?["passwords"] = .needsExport
        #expect(BrowserImportText.review(report, passwordCSV: true).contains(uiText("from selected CSV")))
        #expect(BrowserImportText.review(report, sourceID: "safari").contains("Cookies: " + uiText("not supported for Safari exports")))
        for error in [BrowserAuthenticationImportError.keychainDenied, .sourceKeyMissing, .keychainFailure] {
            #expect(BrowserImportText.failure(error).contains("Nothing was imported"))
        }
    }
    @Test func importSummariesUsePluralRulesAndOmitEmptyCounts() {
        var report = ArcImportReport()
        report.target.spacesAdded = 1
        report.target.todayTabsAdded = 1
        report.history.importable = 1
        report.capabilities = ["bookmarks": .supported, "history": .supported, "tabs": .supported]
        let review = BrowserImportText.review(report)
        for phrase in ["1 Space", "1 tab or folder", "1 history visit"] { #expect(review.contains(phrase)) }
        #expect(!review.contains("0 "))
        #expect(!review.contains("1 Spaces"))
        #expect(!review.contains("1 history visits"))
        var outcome = ArcImportOutcome()
        outcome.merge = report.target
        outcome.historyInserted = 1
        let result = BrowserImportText.completion(outcome, passwords: 1, cookies: 1, report: report)
        for phrase in ["1 Space", "1 tab or folder", "1 history visit", "1 password", "1 cookie"] { #expect(result.contains(phrase)) }
        for omitted in ["0 ", "1 passwords", "1 cookies", "archived", "unsupported", "kept", "Bookmarks:", "History:", "Open tabs:", "Available"] {
            #expect(!result.contains(omitted))
        }
        #expect(BrowserImportText.review(.init()).hasPrefix(uiText("A new Orbit profile will be created.")))
        #expect(BrowserImportText.completion(nil) == uiText("Added a new Orbit profile."))
    }
    @Test func completionKeepsOnlyApplicableWarningsAndCounts() {
        var report = ArcImportReport()
        report.capabilities = ["bookmarks": .needsExport, "history": .supported, "tabs": .empty, "passwords": .needsExport, "cookies": .unsupported]
        report.sourceCounts = ["aggregateVisitsWithoutTimestamps": 1]
        let result = BrowserImportText.completion(nil, passwords: 3, cookies: 2, unsupportedPasswords: 1,
            keptPasswords: 1, report: report, passwordCSV: true, sourceID: "safari")
        #expect(result.contains("2 passwords"))
        #expect(result.contains("2 cookies"))
        #expect(result.contains("1 password could not be imported."))
        #expect(result.contains("1 existing password was kept."))
        #expect(result.contains("1 additional history visit had no date in the export and was not added."))
        #expect(result.contains(uiText("export required")))
        #expect(result.contains(uiText("not supported for Safari exports")))
        #expect(!result.contains(uiText("no data found")))
        #expect(!result.contains(uiText("from selected CSV")))
        #expect(!result.contains("History"))
        var outcome = ArcImportOutcome()
        outcome.merge.archivedTabsAdded = 1
        #expect(BrowserImportText.completion(outcome).contains("1 archived tab"))
        outcome.merge.archivedTabsAdded = 2
        #expect(BrowserImportText.completion(outcome).contains("2 archived tabs"))
    }
    @Test @MainActor func cancelledJobDiscardsWithoutTargetMutation() throws {
        let root = URL(fileURLWithPath: "/private/tmp/import-ui-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = OrbitProductConfiguration(dataRoot: root, secureStorage: .mockKeychain)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        var job: BrowserImportOfflineJob? = .init(configuration: configuration)
        job?.discard(); job = nil
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == before)
    }
    @Test func offlineJobRetainsPreparedSnapshotThroughShutdownAndRestore() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/import-ui-job-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Target"), source = base.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Synthetic"}}}}"#.utf8).write(to: source.appendingPathComponent("Local State"))
        try Data(repeating: 33, count: 32).write(to: root.appendingPathComponent("import-auth-fixture-key"))
        let store = BrowserStore()
        _ = await store.createProfile(name: "Existing")
        try BrowserSessionFileStore().save(await store.sessionDocument(), to: root.appendingPathComponent("session.json"))
        let configuration = OrbitProductConfiguration(dataRoot: root, secureStorage: .mockKeychain)
        let adapter = ChromiumBrowserImportAdapter(descriptor: ChromiumImportRegistry.descriptors[0], installationID: UUID(),
            profile: .init(directory: "Default", name: "Synthetic"), placement: .init(importedSpace: "Imported", bookmarkFolder: "Bookmarks", windowName: "Window"))
        let probe = BrowserImportRunningProbe(running: { false })
        let snapshots = base.appendingPathComponent("Snapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        var importer = BrowserImportOrchestrator(source: source, probe: probe, snapshotParent: snapshots)
        importer.adapter = adapter
        let target = try ArcOfflineImportTarget(sessionFile: configuration.sessionFile, usage: ImportRecoveryAlert.OfflineUsage())
        let prepared = try await importer.prepare(for: target)
        await target.close()
        let authentication = try ChromiumAuthenticationSnapshot.capture(source: source, adapter: adapter, consent: true, parent: snapshots, probe: probe)
        let job = BrowserImportOfflineJob(configuration: configuration, importer: importer, preparation: prepared, adapter: adapter,
            authentication: .init(snapshot: authentication, sourcePassword: Data("synthetic".utf8), targetPassword: Data("mock_password".utf8)))
        try await Task.detached { try await job.run() }.value
        let run = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: SymmetricKey(data: Data(repeating: 33, count: 32)))
        #expect(run.status.outcome?.merge.profilesAdded == 1)
        #expect(try BrowserSessionFileStore().load(from: configuration.sessionFile).profiles.count == 2)
        try run.beginPasswordApplication(); try run.markVerified()
        try run.restore(confirmDeletingLaterChanges: true, usage: ImportRecoveryAlert.OfflineUsage())
        #expect(try BrowserSessionFileStore().load(from: configuration.sessionFile).profiles.count == 1)
    }

    @Test @MainActor func reviewDoesNotResolveProvisionalNativeProfiles() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/import-ui-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Source"), snapshots = base.appendingPathComponent("Snapshots")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Synthetic"}}}}"#.utf8).write(to: source.appendingPathComponent("Local State"))
        try ArcSyntheticData.writeHistory(ArcSyntheticData.historyRows(count: 1, base: Date()), to: source.appendingPathComponent("Default/History"))
        let seed = BrowserStore()
        let profile = await seed.createProfile(name: "Existing")
        _ = try await seed.createSpace(name: "Existing", profileID: profile)
        let session = base.appendingPathComponent("Target/session.json")
        try BrowserSessionFileStore().save(await seed.sessionDocument(), to: session)
        let engine = ReviewProfileEngine()
        let environment = try await BrowserEnvironment.open(engine: engine, sessionFile: session)
        let live = try #require(ArcImportLiveTarget(environment: environment))
        let document = await environment.store.sessionDocument()
        let review = try BrowserImportReviewTarget(live: live, document: document)
        engine.requests = []
        var importer = BrowserImportOrchestrator(source: source, probe: BrowserImportRunningProbe(running: { false }), snapshotParent: snapshots)
        importer.adapter = ChromiumBrowserImportAdapter(descriptor: ChromiumImportRegistry.descriptors[0], installationID: UUID(),
            profile: .init(directory: "Default", name: "Synthetic"), placement: .init(importedSpace: "Imported", bookmarkFolder: "Bookmarks", windowName: "Window"))
        let preparation = try await importer.prepare(for: review)
        #expect(preparation.report.history.importable == 1)
        #expect(engine.requests.isEmpty)
        let after = await environment.store.sessionDocument()
        #expect(after.profiles == document.profiles)
        #expect(after.spaces == document.spaces)
        #expect(after.organization.tabs == document.organization.tabs)
        #expect(after.organization.folders == document.organization.folders)
        preparation.discard()
        try await environment.finalize()
        _ = await environment.shutDown()
    }

}
