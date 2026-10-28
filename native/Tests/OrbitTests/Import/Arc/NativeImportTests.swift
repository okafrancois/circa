import AppKit
import OrbitImportSynthetic
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing
@testable import Orbit
@testable import BrowserCore

/// Synthetic engine with persistent profiles, so imported history is accepted. No window is shown.
@MainActor
private final class ImportPersistentEngine: BrowserEngine {
    typealias Surface = SiteSyntheticSurface
    let base = SiteSyntheticEngine()
    let kind = BrowserEngineKind.synthetic
    var capabilities: BrowserEngineCapabilities { base.capabilities.union(.persistentProfiles) }
    var extensions: (any BrowserExtensionHost)? { nil }
    var conformanceProbe: (any BrowserEngineConformanceProbe<Surface>)? { nil }
    func profile(for id: ProfileID) -> BrowserEngineProfile { .init(profileID: id, persistence: .persistent) }
    func makeSurface(profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<Surface>) -> Surface {
        base.makeSurface(profileID: profileID, delegate: delegate)
    }
    func shutdown() async { await base.shutdown() }
}

private final class SwitchableOrbitProbe: ArcRunningProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    init(running: Bool) { self.running = running }
    func set(_ value: Bool) { lock.withLock { running = value } }
    func isArcRunning(sourceRoot: URL) -> Bool { lock.withLock { running } }
}

/// Records the dialogs instead of showing them.
@MainActor
private final class RecordingImportPresenter: ArcImportPresenting {
    var calls: [String] = []
    var chosenSource: URL?
    var confirms = true
    var onQuitArc: (() -> Bool)?
    /// Presses Cancel on the first progress shown after the confirmation.
    var cancelsApply = false
    private var armed = false
    var reports: [ArcImportReport] = []
    var outcomes: [ArcImportOutcome] = []
    var failures: [ArcImportError?] = []
    var phases: [ArcImportProgress.Phase] = []

    func chooseSourceDirectory() async -> URL? { calls.append("choose"); return chosenSource }
    func askToQuitArc() async -> Bool { calls.append("quitArc"); return onQuitArc?() ?? false }
    func showProgress(_ progress: ArcImportProgress, onCancel: @escaping @MainActor () -> Void) {
        phases.append(progress.phase)
        if armed, cancelsApply { armed = false; onCancel() }
    }
    func hideProgress() {}
    var acceptsReduction = true
    var reductions: [ArcImportExclusions] = []
    func confirmReducedImport(_ report: ArcImportReport, excluding parts: ArcImportExclusions) async -> Bool {
        calls.append("reduce")
        reductions.append(parts)
        return acceptsReduction
    }
    func confirm(_ report: ArcImportReport) async -> Bool {
        calls.append("confirm")
        reports.append(report)
        armed = confirms
        return confirms
    }
    func showCompletion(_ outcome: ArcImportOutcome) { calls.append("done"); outcomes.append(outcome) }
    func showFailure(_ error: ArcImportError?) { calls.append("failure"); failures.append(error) }
}

@MainActor
@Suite("Native source browser import", .serialized)
struct NativeOrbitImportTests {
    @MainActor
    private struct Harness {
        let root: URL
        let source: URL
        let sessionFile: URL
        let environment: BrowserEnvironment<ImportPersistentEngine>
        let presenter = RecordingImportPresenter()
        let probe: SwitchableOrbitProbe

        static func make(orbitRunning: Bool = false, sidebar: [String: Any] = ArcSyntheticData.sidebar()) async throws -> Harness {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let root = try ArcSyntheticData.temporaryDirectory("orbit-native-import")
            let source = try ArcSyntheticData.writeDataDirectory(at: root.appendingPathComponent("Arc", isDirectory: true),
                                                                 sidebar: sidebar)
            let sessionFile = root.appendingPathComponent("Orbit/session.json")
            // An existing session with one profile and Space, so the merge target is deterministic.
            let seed = BrowserStore()
            let profile = await seed.createProfile(name: "Synthetic Orbit Profile")
            _ = try await seed.createSpace(name: "Synthetic Orbit Space", profileID: profile)
            try BrowserSessionFileStore().save(await seed.sessionDocument(), to: sessionFile)
            let environment = try await BrowserEnvironment.open(engine: ImportPersistentEngine(), sessionFile: sessionFile)
            return Harness(root: root, source: source, sessionFile: sessionFile, environment: environment,
                           probe: SwitchableOrbitProbe(running: orbitRunning))
        }

        func coordinator() -> ArcImportCoordinator {
            let source = source, probe = probe
            let snapshots = root.appendingPathComponent("Snapshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            return ArcImportCoordinator(presenter: presenter, defaultSource: source) { chosen in
                var options = ArcImportOptions()
                options.historyChunkSize = 8
                options.naming = ArcImportText.naming
                return ArcImporter(source: chosen, options: options, probe: probe, logger: ArcImportSystemLog(),
                                   snapshotParent: snapshots)
            }
        }

        func run(_ coordinator: ArcImportCoordinator) async {
            await coordinator.start(target: ArcImportLiveTarget(environment: environment))?.value
        }

        func close() async {
            _ = try? await environment.finalize()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("The live import waits for source browser to quit, confirms counts, merges, saves and imports history")
    func liveImport() async throws {
        let harness = try await Harness.make(orbitRunning: true)
        let coordinator = harness.coordinator()
        harness.presenter.onQuitArc = { harness.probe.set(false); return true }
        var finished: ArcImportOutcome?
        coordinator.onFinished = { finished = $0 }
        await harness.run(coordinator)
        #expect(harness.presenter.calls == ["quitArc", "confirm", "done"])
        let report = try #require(harness.presenter.reports.first)
        #expect(report.target.spacesAdded == 3 && report.history.importable == 60)
        let outcome = try #require(harness.presenter.outcomes.first)
        #expect(finished == outcome)
        #expect(outcome.historyInserted == 60 && outcome.merge.addedItems == 13)
        #expect(harness.presenter.phases.contains(.importingHistory))
        // Saved durably before the ledger: the session file already holds the imported Spaces.
        let saved = try BrowserSessionFileStore().load(from: harness.sessionFile)
        #expect(saved.spaces.map(\.name).suffix(3) == ["Space a", "Space b", "Space c"])
        // Arc's Default profile merged into the session's first profile; its history is searchable.
        #expect(saved.profiles.first?.name == "Synthetic Orbit Profile")
        let first = try #require(saved.profiles.first?.id)
        let visits = try await harness.environment.historyRecorder.visits(for: first, limit: 1_000)
        #expect(visits.count == 30)
        #expect(!coordinator.isRunning)
        await harness.close()
    }

    @Test("Declining the confirmation imports nothing; a running import refuses a second start")
    func declineAndBusy() async throws {
        let harness = try await Harness.make()
        harness.presenter.confirms = false
        let before = await harness.environment.store.sessionDocument()
        let coordinator = harness.coordinator()
        let task = coordinator.start(target: ArcImportLiveTarget(environment: harness.environment))
        #expect(coordinator.start(target: ArcImportLiveTarget(environment: harness.environment)) == nil)
        await task?.value
        #expect(harness.presenter.calls == ["confirm"])
        #expect(await harness.environment.store.sessionDocument() == before)
        let snapshots = (try? FileManager.default.contentsOfDirectory(atPath: harness.root.appendingPathComponent("Snapshots").path)) ?? []
        #expect(snapshots.isEmpty, "a declined dry run deletes its snapshot")
        await harness.close()
    }

    @Test("Stopping during the apply keeps a resumable import without a failure alert")
    func cancelDuringHistory() async throws {
        let harness = try await Harness.make()
        harness.presenter.cancelsApply = true
        await harness.run(harness.coordinator())
        #expect(harness.presenter.calls == ["confirm"])
        #expect(harness.presenter.failures.isEmpty)
        let location = ArcImportDataLocation(sessionFile: harness.sessionFile)
        let journal = try JSONDecoder.iso8601.decode(ArcImportJournal.self, from: Data(contentsOf: location.journalFile))
        #expect(journal.state == .applying)
        harness.presenter.cancelsApply = false
        await harness.run(harness.coordinator())
        #expect(harness.presenter.reports.last?.interruptedImport == true)
        #expect(harness.presenter.outcomes.last?.merge.addedItems == 0)
        await harness.close()
    }

    @Test("A session over the launch limit needs explicit consent to leave optional parts out")
    func reducedImportConsent() async throws {
        let harness = try await Harness.make(sidebar: ArcSyntheticData.oversizedSidebar())
        harness.presenter.acceptsReduction = false
        let before = await harness.environment.store.sessionDocument()
        await harness.run(harness.coordinator())
        #expect(harness.presenter.calls == ["reduce"])
        #expect(harness.presenter.reductions == [[.archive, .today]])
        #expect(await harness.environment.store.sessionDocument() == before)
        harness.presenter.acceptsReduction = true
        await harness.run(harness.coordinator())
        #expect(harness.presenter.calls.suffix(3) == ["reduce", "confirm", "done"])
        #expect(harness.presenter.reports.last?.excluded == ["archive", "today"])
        let saved = try BrowserSessionFileStore().load(from: harness.sessionFile)
        #expect(saved.spaces.count == 4 && saved.organization.archive.isEmpty)
        #expect(ArcImportText.confirmation(try #require(harness.presenter.reports.last)).contains("Left out"))
        await harness.close()
    }

    @Test("Orbit holds its session shared: offline imports are refused while it runs, and it does not open during one")
    func sessionLockWithOfflineImports() async throws {
        let harness = try await Harness.make()
        #expect(throws: ArcImportError.targetInUse) {
            try ArcOfflineImportTarget(sessionFile: harness.sessionFile, usage: NoOrbitRunning())
        }
        let otherSession = harness.root.appendingPathComponent("Other/session.json")
        let offline = try ArcOfflineImportTarget(sessionFile: otherSession, usage: NoOrbitRunning())
        await #expect(throws: ArcImportError.targetInUse) {
            try await BrowserEnvironment.open(engine: ImportPersistentEngine(), sessionFile: otherSession)
        }
        await offline.close()
        let reopened = try await BrowserEnvironment.open(engine: ImportPersistentEngine(), sessionFile: otherSession)
        _ = try? await reopened.finalize()
        await harness.close()
    }

    @Test("Launching rolls back a restore interrupted mid-swap before reading the session")
    func launchRecoversInterruptedRestore() async throws {
        let harness = try await Harness.make()
        await harness.run(harness.coordinator())
        let imported = try BrowserSessionFileStore().load(from: harness.sessionFile)
        _ = try? await harness.environment.finalize()
        let location = ArcImportDataLocation(sessionFile: harness.sessionFile)
        let backup = try #require(ArcImportBackups.manifests(at: location).first?.id)
        // Simulated crash after two renames of a restore.
        try ArcImportRestore(id: backup, location: location).run(diskSpace: OrbitSystemDiskSpaceProbe(), interruption: 2)
        let environment = try await BrowserEnvironment.open(engine: ImportPersistentEngine(), sessionFile: harness.sessionFile)
        let restored = await environment.store.sessionDocument().spaces
        #expect(restored.map(\.id) == imported.spaces.map(\.id) && restored.map(\.name) == imported.spaces.map(\.name))
        #expect(restored.map(\.profileID) == imported.spaces.map(\.profileID))
        // ARC-THEMES: launching also turns the imported Space appearances into themes, once.
        #expect(restored.contains { $0.theme != nil } && imported.spaces.allSatisfy { $0.theme == nil })
        #expect(!FileManager.default.fileExists(atPath: location.importDirectory.appendingPathComponent("arc-import-restore.json").path))
        _ = try? await environment.finalize()
        try? FileManager.default.removeItem(at: harness.root)
    }

    @Test("Orbit does not open a session whose restore journal is unreadable; recover-restore unblocks it")
    func launchBlockedByUnreadableJournal() async throws {
        let harness = try await Harness.make()
        await harness.run(harness.coordinator())
        let imported = try BrowserSessionFileStore().load(from: harness.sessionFile)
        _ = try? await harness.environment.finalize()
        let location = ArcImportDataLocation(sessionFile: harness.sessionFile)
        let backup = try #require(ArcImportBackups.manifests(at: location).first?.id)
        try ArcImportRestore(id: backup, location: location).run(diskSpace: OrbitSystemDiskSpaceProbe(), interruption: 1)
        try Data("{".utf8).write(to: ArcImportRestore.journalFile(location))
        await #expect(throws: ArcImportError.restoreJournalUnreadable) {
            try await BrowserEnvironment.open(engine: ImportPersistentEngine(), sessionFile: harness.sessionFile)
        }
        #expect(FileManager.default.fileExists(atPath: ArcImportRestore.journalFile(location).path))
        #expect(!FileManager.default.fileExists(atPath: harness.sessionFile.path), "the parked session was not replaced")
        let report = try ArcImportBackups.recoverRestore(at: location, usage: NoOrbitRunning())
        #expect(!report.journalReadable && report.restoredEntries >= 1)
        let environment = try await BrowserEnvironment.open(engine: ImportPersistentEngine(), sessionFile: harness.sessionFile)
        // ARC-THEMES: opening converts imported Space appearances into themes, so compare identity.
        let recovered = await environment.store.sessionDocument().spaces
        #expect(recovered.map(\.id) == imported.spaces.map(\.id) && recovered.map(\.name) == imported.spaces.map(\.name))
        #expect(recovered.map(\.profileID) == imported.spaces.map(\.profileID))
        _ = try? await environment.finalize()
        try? FileManager.default.removeItem(at: harness.root)
    }

    @Test("A missing source browser folder asks for a copy; cancelling the panel imports nothing")
    func missingSource() async throws {
        let harness = try await Harness.make()
        try FileManager.default.removeItem(at: harness.source.appendingPathComponent("StorableSidebar.json"))
        await harness.run(harness.coordinator())
        #expect(harness.presenter.calls == ["choose"])
        await harness.close()
    }

    @Test("Temporary sessions have no import target")
    func temporarySession() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: ImportPersistentEngine())
        #expect(ArcImportLiveTarget(environment: environment) == nil)
        let presenter = RecordingImportPresenter()
        await ArcImportCoordinator(presenter: presenter).start(target: nil)?.value
        #expect(presenter.failures == [.targetUnreadable])
    }

    @Test("The first-run offer is limited to a fresh daily-build session at its default location")
    func firstRunEligibility() throws {
        let location = ArcImportDataLocation(sessionFile: URL(fileURLWithPath: "/synthetic/Orbit/session.json"))
        let source = URL(fileURLWithPath: "/synthetic/Arc")
        let arc = source.appendingPathComponent("StorableSidebar.json").path
        func eligible(_ bundle: String? = "io.github.okatech.orbit", arguments: [String] = [], restored: Int = 0,
                      existing: Set<String> = [arc]) -> Bool {
            ArcImportFirstRunOffer.isEligible(bundleIdentifier: bundle, arguments: arguments, restoredWindowCount: restored,
                                              location: location, orbitSource: source, fileExists: existing.contains)
        }
        #expect(eligible())
        #expect(!eligible("io.github.okatech.orbit.test.orbit.live"))
        #expect(!eligible(arguments: ["--session-file", "/synthetic/s.json"]))
        #expect(!eligible(arguments: ["--ephemeral"]))
        #expect(!eligible(arguments: ["--no-orbit-import-offer"]))
        #expect(!eligible(restored: 1))
        #expect(!eligible(existing: []))
        #expect(!eligible(existing: [arc, location.offerFile.path]))
        #expect(!eligible(existing: [arc, location.journalFile.path]))
        #expect(OrbitImportLaunchOptions.source(["--arc-import-source", "/synthetic/Copy"]).path == "/synthetic/Copy")
        #expect(OrbitImportLaunchOptions.source(["--arc-import-source", "relative"]) == ArcSourceSnapshot.defaultSourceRoot)
    }

    @Test("The source browser import command and the application menu import alias remain wired")
    func commands() {
        let app = OrbitApplication()
        let system = app.makeCommandSystem()
        let definition = system.registry.definition(.importFromArc)
        #expect(definition?.menu == "File" && definition?.requirement == .application)
        #expect(definition?.localizedTitle == "Import from Arc…")
        #expect(system.registry.isImplemented(.importFromArc))
        #expect(system.registry.isImplemented(.importFromAnotherBrowser))
        // menus-2026-10-27.md: the Arc application-menu alias owns the visible import entry.
        let application = system.menus.makeMenuBar().items.first?.submenu
        let item = application?.items.first { $0.identifier?.rawValue == BrowserCommandID.importFromAnotherBrowser.rawValue }
        #expect(item?.action != nil && item?.target != nil)
    }

    @Test("Dialog texts show counts and limits, never names, titles or URLs")
    func dialogText() throws {
        var report = ArcImportReport()
        report.source.profiles = 3
        report.target.spacesAdded = 5
        report.target.favoritesAdded = 12
        report.history.importable = 46_335
        report.target.itemsPresent = 2
        let text = ArcImportText.confirmation(report)
        #expect(text.contains("12") && text.contains("passwords") && text.contains("backup"))
        #expect(text.contains("Already imported"))
        var outcome = ArcImportOutcome()
        outcome.historyInserted = 7
        #expect(ArcImportText.completion(outcome).contains("7"))
        #expect(!ArcImportText.failure(.arcIsRunning).isEmpty)
        for phase in [ArcImportProgress.Phase.copying, .reading, .countingHistory, .backingUp, .applying, .saving, .importingHistory, .finished] {
            #expect(!ArcImportAlertPresenter.phaseText(phase).isEmpty)
        }
    }
}

private struct NoOrbitRunning: OrbitTargetUsageProbe {
    func isInUse(sessionFile: URL) -> Bool { false }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
