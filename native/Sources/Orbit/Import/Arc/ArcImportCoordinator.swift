import BrowserCore
import BrowserEngine
import Foundation

/// The running app as an import target: merges into the live store (windows refresh through the
/// organization observers), saves through the session persistence, writes history through the
/// recorder so the palette index sees one bulk mutation per profile.
struct ArcImportLiveTarget: ArcImportTarget {
    let location: ArcImportDataLocation
    let history: any ArcHistoryImportSink
    let store: BrowserStore
    let save: @Sendable () async throws -> Void
    /// Orbit holds the data directory's shared lock; the in-process import lock serializes imports.
    var holdsExclusiveAccess: Bool { false }

    @MainActor
    init?<Engine: BrowserEngine>(environment: BrowserEnvironment<Engine>) {
        guard let sessionFile = environment.sessionFile else { return nil }
        location = ArcImportDataLocation(sessionFile: sessionFile)
        store = environment.store
        history = ArcRecorderHistorySink(recorder: environment.historyRecorder)
        save = { [weak environment] in
            guard let environment else { throw ArcImportError.targetUnreadable }
            try await environment.saveNow()
        }
    }

    func defaultProfile() async -> ProfileID? { await store.catalogSnapshot().profiles.first?.id }

    func preview(_ plan: BrowserImportPlan, ledger: BrowserImportLedger) async -> BrowserImportMergeCounts {
        await store.previewImport(plan, ledger: ledger)
    }

    func sessionBackup() async throws -> Data? { try await store.sessionDocument().encoded() }

    func apply(_ plan: BrowserImportPlan, ledger: BrowserImportLedger) async throws -> BrowserImportMergeResult {
        try await store.applyImport(plan, ledger: ledger)
    }

    func persist() async throws { try await save() }
}

struct ArcRecorderHistorySink: ArcHistoryImportSink {
    let recorder: BrowserHistoryRecorder

    func acceptsHistory(for profileID: ProfileID) async -> Bool { await recorder.acceptsImportedHistory(for: profileID) }
    func beginBulkImport(for profileID: ProfileID) async { await recorder.beginImport(for: profileID) }
    func importChunk(_ document: BrowserHistoryDocument) async throws -> Int { try await recorder.importChunk(document) }
    func endBulkImport(for profileID: ProfileID) async { await recorder.endImport(for: profileID) }
}

/// User interaction of the import. The AppKit implementation is `ArcImportAlertPresenter`; tests
/// record calls without showing any window.
@MainActor
protocol ArcImportPresenting: AnyObject {
    /// Asked when Arc's default data folder is missing; nil cancels.
    func chooseSourceDirectory() async -> URL?
    /// Arc is running: true means "Check Again", false cancels. Arc is never quit by Orbit.
    func askToQuitArc() async -> Bool
    func showProgress(_ progress: ArcImportProgress, onCancel: @escaping @MainActor () -> Void)
    func hideProgress()
    /// The full import does not fit Orbit's session limit: true agrees to leave `parts` out.
    func confirmReducedImport(_ report: ArcImportReport, excluding parts: ArcImportExclusions) async -> Bool
    func confirm(_ report: ArcImportReport) async -> Bool
    func showCompletion(_ outcome: ArcImportOutcome)
    func showFailure(_ error: ArcImportError?)
}

/// Dry run (counts only) → confirmation → apply. All reading, copying and parsing runs in a
/// detached task; the main actor only receives ordered progress values and presents dialogs.
@MainActor
final class ArcImportCoordinator {
    private let presenter: any ArcImportPresenting
    private let makeImporter: @MainActor (URL) -> ArcImporter
    private let defaultSource: URL
    private var cancelCurrent: (() -> Void)?
    private(set) var isRunning = false
    var onFinished: ((ArcImportOutcome?) -> Void)?

    init(presenter: any ArcImportPresenting, defaultSource: URL = ArcSourceSnapshot.defaultSourceRoot,
         makeImporter: @escaping @MainActor (URL) -> ArcImporter = { ArcImportCoordinator.productionImporter($0) }) {
        self.presenter = presenter
        self.defaultSource = defaultSource
        self.makeImporter = makeImporter
    }

    static func productionImporter(_ source: URL) -> ArcImporter {
        var options = ArcImportOptions()
        options.naming = ArcImportText.naming
        return ArcImporter(source: source, options: options)
    }

    /// Nil when an import is already running (the caller beeps).
    @discardableResult
    func start(target: (any ArcImportTarget)?) -> Task<Void, Never>? {
        guard !isRunning else { return nil }
        isRunning = true
        return Task { [self] in
            defer { isRunning = false; cancelCurrent = nil }
            let outcome = await run(target: target)
            onFinished?(outcome)
        }
    }

    func cancel() { cancelCurrent?() }

    private func run(target: (any ArcImportTarget)?) async -> ArcImportOutcome? {
        guard let target else { presenter.showFailure(.targetUnreadable); return nil }
        var source = defaultSource
        if !FileManager.default.fileExists(atPath: source.appendingPathComponent("StorableSidebar.json").path) {
            guard let chosen = await presenter.chooseSourceDirectory() else { return nil }
            source = chosen
        }
        let importer = makeImporter(source)
        var prepared: ArcImportPreparation?
        while prepared == nil {
            do {
                prepared = try await perform { progress in try await importer.prepare(for: target, progress: progress) }
            } catch ArcImportError.arcIsRunning {
                presenter.hideProgress()
                guard await presenter.askToQuitArc() else { return nil }
            } catch {
                fail(error)
                return nil
            }
        }
        presenter.hideProgress()
        guard var preparation = prepared else { return nil }
        let budget = preparation.report.sessionBudget
        if !budget.fits {
            // Never shrink silently: the user explicitly agrees to leave optional parts out.
            guard let parts = budget.suggestedExclusions else {
                preparation.discard()
                presenter.showFailure(.sessionTooLarge(projectedBytes: budget.projectedBytes, limitBytes: budget.limitBytes))
                return nil
            }
            guard await presenter.confirmReducedImport(preparation.report, excluding: parts) else {
                preparation.discard()
                return nil
            }
            preparation = await preparation.excluding(parts, for: target)
        }
        let confirmed = preparation
        guard await presenter.confirm(confirmed.report) else {
            preparation.discard()
            return nil
        }
        do {
            let outcome = try await perform { progress in try await importer.apply(confirmed, to: target, progress: progress) }
            presenter.hideProgress()
            presenter.showCompletion(outcome)
            return outcome
        } catch {
            fail(error)
            return nil
        }
    }

    private func fail(_ error: any Error) {
        presenter.hideProgress()
        guard (error as? ArcImportError) != .cancelled else { return }
        presenter.showFailure(error as? ArcImportError)
    }

    /// Runs `operation` off the main actor; progress arrives here in order (latest value kept).
    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable (@escaping @Sendable (ArcImportProgress) -> Void) async throws -> T
    ) async throws -> T {
        let (stream, continuation) = AsyncStream.makeStream(of: ArcImportProgress.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task.detached { () async throws -> T in
            defer { continuation.finish() }
            return try await operation { continuation.yield($0) }
        }
        cancelCurrent = { task.cancel() }
        for await value in stream {
            presenter.showProgress(value) { [weak self] in self?.cancel() }
        }
        return try await task.value
    }
}

/// First-run offer of the Orbit product (`ProductIdentity.bundleIdentifier`): only on a fresh session at the default
/// location, never in tests, previews with explicit session files or ephemeral sessions.
enum ArcImportFirstRunOffer {
    struct Record: Codable, Equatable {
        enum Decision: String, Codable { case accepted, declined }
        var version = 1
        var decision: Decision
        var date: Date
    }

    static let productBundleIdentifier = ProductIdentity.bundleIdentifier

    static func isEligible(bundleIdentifier: String?, arguments: [String], restoredWindowCount: Int,
                           location: ArcImportDataLocation?, orbitSource: URL,
                           fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        guard let location, restoredWindowCount == 0, bundleIdentifier == productBundleIdentifier,
              !arguments.contains("--session-file"), !arguments.contains("--ephemeral"),
              !arguments.contains("--no-orbit-import-offer") else { return false }
        // The first-run onboarding replaces this offer: any onboarding record ends it for good.
        let onboarding = BrowserOnboardingFiles.recordFile(dataDirectory: location.dataDirectory)
        return !fileExists(location.offerFile.path) && !fileExists(location.journalFile.path) && !fileExists(onboarding.path)
            && fileExists(orbitSource.appendingPathComponent("StorableSidebar.json").path)
    }

    static func record(_ decision: Record.Decision, at location: ArcImportDataLocation, now: Date = Date()) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Record(decision: decision, date: now)) else { return }
        try? location.writeOfferRecord(data)
    }
}
