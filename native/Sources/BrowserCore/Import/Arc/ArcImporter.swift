import CryptoKit
import Foundation

/// The store an import writes into: the running app's environment, or a session file opened by
/// an offline tool while Orbit is closed.
public protocol ArcImportTarget: Sendable {
    var location: ArcImportDataLocation { get }
    /// True when this target holds the data directory's exclusive lock (offline targets, from
    /// before loading the session until `close`). The app's live target relies on the shared
    /// lock Orbit holds and on the in-process import lock instead.
    var holdsExclusiveAccess: Bool { get }
    var history: any ArcHistoryImportSink { get }
    /// The first profile, into which Arc's `Default` profile is merged.
    func defaultProfile() async -> ProfileID?
    func preview(_ plan: BrowserImportPlan, ledger: BrowserImportLedger) async -> BrowserImportMergeCounts
    /// The current session document, encoded, for the backup; nil when there is none yet.
    func sessionBackup() async throws -> Data?
    func apply(_ plan: BrowserImportPlan, ledger: BrowserImportLedger) async throws -> BrowserImportMergeResult
    /// Returns once the merged session is durably saved.
    func persist() async throws
}

public struct ArcImportProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Codable {
        case copying, reading, countingHistory, backingUp, applying, saving, importingHistory, finished
    }
    public let phase: Phase
    public let completed: Int
    public let total: Int

    public init(_ phase: Phase, completed: Int = 0, total: Int = 0) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }

    public var fraction: Double? { total > 0 ? min(1, Double(completed) / Double(total)) : nil }
}

/// Dry-run report. Counts only: safe to show, log and paste into a report.
public struct ArcImportReport: Codable, Equatable, Sendable {
    /// Categories outside the structural and subsequent authentication steps.
    public static let notImported = ["cookies", "extensions", "siteData", "settings", "downloads"]

    public var passwordProfileCounts: [Int]?
    public var capabilities: [String: BrowserImportCapability]?
    public var sourceCounts: [String: Int]?
    public var formatVersion: Int?
    /// What Arc holds that maps to the native model.
    public var source = BrowserImportPlanCounts()
    /// What applying now would add or find already present.
    public var target = BrowserImportMergeCounts()
    public var history = ArcHistoryScanCounts()
    public var historyProfiles = 0
    public var historyProfilesWithoutDatabase = 0
    public var historyProfilesNotPersistent = 0
    public var historyDatabasesUnreadable = 0
    public var archiveDocumentUnreadable = false
    public var skipped = BrowserImportPlanSkips()
    public var diagnostics = ArcSidebarDiagnostics()
    public var interruptedImport = false
    public var notImported = ArcImportReport.notImported
    /// Projected session size against the launch read limit, with the reductions that would fit.
    public var sessionBudget = ArcImportSessionBudget()
    /// Digest of the target's session and ledger as loaded for this dry run: any change of the
    /// target (a recovery, a browsing session, another import) changes the confirmation code.
    public var targetStateDigest = ""
    /// Free space the apply needs before its proportional margin (backup with WAL content,
    /// session copies, history growth from the visits' text).
    public var diskEstimateBytes: Int64 = 0
    /// Optional parts left out with the user's explicit consent (`archive`, `today`).
    public var excluded: [String] = []

    public init() {}

    /// Short code over every count: `apply --confirm` must quote the code of the dry run the user
    /// read, and a fresh dry run must produce the same code.
    public var confirmationCode: String {
        var copy = self
        copy.interruptedImport = false
        // Byte sizes depend on the encoding of the import time; the code covers what they decide
        // (fits, suggested reduction), not the bytes themselves, so a dry run and its apply agree.
        copy.target.projectedSessionBytes = 0
        copy.diskEstimateBytes = 0
        let fits = sessionBudget.fits, suggestion = sessionBudget.suggestedExclusions?.rawValue ?? -1
        copy.sessionBudget = ArcImportSessionBudget()
        var data = (try? ArcImportFiles.encoder().encode(copy)) ?? Data()
        data.append(Data("|fits:\(fits)|reduce:\(suggestion)".utf8))
        let hex = SHA256.hash(data: data).prefix(4).map { String(format: "%02X", $0) }.joined()
        return String(hex.prefix(4)) + "-" + String(hex.suffix(4))
    }
}

public struct ArcImportSessionBudget: Codable, Equatable, Sendable {
    public var limitBytes = BrowserStore.importSessionBudgetBytes
    public var projectedBytes = 0
    /// Only computed when the full import does not fit.
    public var withoutArchiveBytes: Int?
    public var withoutArchiveAndTodayBytes: Int?

    public init() {}

    public var fits: Bool { projectedBytes <= limitBytes }

    /// The smallest explicit reduction that fits, if any.
    public var suggestedExclusions: ArcImportExclusions? {
        if fits { return [] }
        if let bytes = withoutArchiveBytes, bytes <= limitBytes { return [.archive] }
        if let bytes = withoutArchiveAndTodayBytes, bytes <= limitBytes { return [.archive, .today] }
        return nil
    }
}

/// Optional parts the user may agree to leave out when the full import does not fit.
public struct ArcImportExclusions: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let archive = ArcImportExclusions(rawValue: 1)
    public static let today = ArcImportExclusions(rawValue: 2)

    /// Report form (`ArcImportReport.excluded`).
    public var names: [String] { (contains(.archive) ? ["archive"] : []) + (contains(.today) ? ["today"] : []) }

    public init(names: [String]) {
        self = names.reduce(into: []) { result, name in
            if name == "archive" { result.insert(.archive) }
            if name == "today" { result.insert(.today) }
        }
    }
}

extension BrowserImportPlan {
    func excluding(_ parts: ArcImportExclusions) -> BrowserImportPlan {
        var plan = self
        if parts.contains(.archive) {
            plan.skipped.archivedTabsExcluded += plan.archive.count
            plan.archive = []
        }
        if parts.contains(.today) {
            plan.skipped.todayTabsExcluded += plan.sections.reduce(0) { $0 + $1.today.count }
            plan.sections = plan.sections.map { .init(spaceID: $0.spaceID, pinned: $0.pinned, today: []) }
        }
        return plan
    }
}

public struct ArcImportOutcome: Codable, Equatable, Sendable {
    public var merge = BrowserImportMergeCounts()
    public var historyInserted = 0
    public var historyAlreadyPresent = 0
    public var historyProfilesSkipped = 0
    public var backupID = ""
    public init() {}
}

/// Result of a dry run, holding the private snapshot until `apply` or `discard`.
public struct ArcImportPreparation: Sendable {
    public let report: ArcImportReport
    let plan: BrowserImportPlan
    let snapshot: ArcSourceSnapshot

    public func discard() { snapshot.remove() }

    /// The same dry run without optional parts, after the user agreed to leave them out (the
    /// counts, and therefore the confirmation code, change accordingly).
    public func excluding(_ parts: ArcImportExclusions, for target: some ArcImportTarget) async -> ArcImportPreparation {
        let reduced = plan.excluding(parts)
        var report = report
        let ledger = (try? ArcImportFiles.readExisting(BrowserImportLedger.self, from: target.location.ledgerFile)) ?? BrowserImportLedger()
        report.target = await target.preview(reduced, ledger: ledger)
        report.source = reduced.counts
        report.skipped = reduced.skipped
        report.sessionBudget.projectedBytes = report.target.projectedSessionBytes
        report.excluded = Array(Set(report.excluded + parts.names)).sorted()
        return ArcImportPreparation(report: report, plan: reduced, snapshot: snapshot)
    }
}

/// Fault-injection points for crash tests.
enum ArcImportCheckpoint: Equatable, Sendable {
    case afterLock, afterBackup, afterJournal, afterApply, afterPersist, afterLedger, afterAppearance, afterHistoryChunk(Int), afterCompletion
}

/// Dry run → confirmation → apply. Work runs on the caller's task (never the main actor); the
/// store and history actors serialize their own writes. Progress closures receive counts only.
public typealias ArcImporter = BrowserImportOrchestrator

public struct BrowserImportOrchestrator: Sendable {
    public var adapter: (any BrowserImportSourceAdapter)?
    public var source: URL
    public var options: ArcImportOptions
    public var probe: any ArcRunningProbe
    public var logger: any ArcImportLogging
    public var snapshotParent: URL
    public var clock: @Sendable () -> Date
    public var diskSpace: any OrbitDiskSpaceProbe
    var checkpoint: @Sendable (ArcImportCheckpoint) throws -> Void = { _ in }
    /// Upper bound of the history growth: fixed bytes per visit plus a factor of its URL and title
    /// text (visits row, JSON payload, pages, trigram and word indexes). Calibrated on the synthetic
    /// measurements: ~547 B/visit for short URLs over 20 000 pages, ~557 B/visit for 100 000 distinct
    /// short URLs, ~46.6 KB/visit for 4 KB URLs with 1 KB titles on distinct pages (IMPORT-R3/R4).
    static func estimatedHistoryBytes(visits: Int, textBytes: Int64) -> Int64 {
        Int64(visits) * 384 + textBytes * 12
    }

    static func applyRequirement(projectedSessionBytes: Int, backupBytes: Int64, visits: Int, textBytes: Int64) -> Int64 {
        Int64(projectedSessionBytes) * 3 + backupBytes + estimatedHistoryBytes(visits: visits, textBytes: textBytes)
    }

    /// A restore journal present after the load means the loaded state cannot be trusted; an
    /// unreadable one blocks everything until `recoverRestore` (IMPORT-R4 #C).
    static func refuseInterruptedRestore(_ location: ArcImportDataLocation) throws {
        guard ArcImportBackups.hasInterruptedRestore(at: location) else { return }
        if ArcImportBackups.hasUnreadableRestoreJournal(at: location) { throw ArcImportError.restoreJournalUnreadable }
        throw ArcImportError.restoreInterrupted
    }

    /// Existing history folders must be real directories with regular database files.
    private func validateHistoryDirectories(_ location: ArcImportDataLocation, _ profiles: [ProfileID]) throws {
        guard let history = try? OrbitSecureDirectory.open(location.historyDirectory, create: false) else {
            try ArcImportPaths.validateNoSymbolicLinks(location.historyDirectory)
            return
        }
        for profile in profiles where history.exists(profile.rawValue.uuidString) {
            guard history.kind(profile.rawValue.uuidString) == S_IFDIR else { throw ArcImportError.symbolicLinkInPath }
            _ = try ArcImportFiles.historyDirectory(location, profile, create: false)
        }
    }

    public init(source: URL = ArcSourceSnapshot.defaultSourceRoot, options: ArcImportOptions = ArcImportOptions(),
                probe: any ArcRunningProbe = ArcSystemRunningProbe(), logger: any ArcImportLogging = ArcImportSystemLog(),
                snapshotParent: URL = FileManager.default.temporaryDirectory, clock: @escaping @Sendable () -> Date = { Date() },
                diskSpace: any OrbitDiskSpaceProbe = OrbitSystemDiskSpaceProbe()) {
        self.source = source
        self.options = options
        self.probe = probe
        self.logger = logger
        self.snapshotParent = snapshotParent
        self.clock = clock
        self.diskSpace = diskSpace
    }

    /// Source and destination never overlap; no symbolic link anywhere in the destination.
    private func validatePaths(_ location: ArcImportDataLocation) throws {
        for url in [location.dataDirectory, location.importDirectory, location.historyDirectory, location.backupsDirectory] {
            try ArcImportPaths.validateNoSymbolicLinks(url)
        }
        try ArcImportPaths.validateSeparated(source: source, destination: location.dataDirectory)
    }

    // MARK: Dry run

    public func prepare(for target: some ArcImportTarget,
                        progress: @escaping @Sendable (ArcImportProgress) -> Void = { _ in }) async throws -> ArcImportPreparation {
        logger.log(.preparing)
        do {
            try validatePaths(target.location)
            // Recovery runs where the target takes its lock, before loading (IMPORT-R3 #1); a
            // journal present now means the loaded state cannot be trusted.
            try Self.refuseInterruptedRestore(target.location)
            progress(ArcImportProgress(.copying))
            let snapshot = try (adapter ?? ArcBrowserImportAdapter(options: options)).snapshot(
                source: source, parent: snapshotParent, probe: probe, diskSpace: diskSpace)
            do {
                logger.log(.snapshotCaptured(historyDatabases: snapshot.historyDatabases.count))
                return try await prepare(snapshot, for: target, progress: progress)
            } catch {
                snapshot.remove()
                throw error
            }
        } catch {
            throw failure(error)
        }
    }

    private func prepare(_ snapshot: ArcSourceSnapshot, for target: some ArcImportTarget,
                         progress: @escaping @Sendable (ArcImportProgress) -> Void) async throws -> ArcImportPreparation {
        progress(ArcImportProgress(.reading))
        var report = ArcImportReport()
        let location = target.location
        let ledger = try ArcImportFiles.readExisting(BrowserImportLedger.self, from: location.ledgerFile) ?? BrowserImportLedger()
        let importedAt = Date(timeIntervalSinceReferenceDate: clock().timeIntervalSinceReferenceDate.rounded(.down))
        let prepared = try (adapter ?? ArcBrowserImportAdapter(options: options)).makePlan(
            snapshot: snapshot, ledger: ledger, defaultProfile: await target.defaultProfile(), importedAt: importedAt)
        let plan = prepared.plan
        report.formatVersion = prepared.formatVersion
        report.diagnostics = prepared.diagnostics
        report.archiveDocumentUnreadable = prepared.archiveUnreadable
        report.capabilities = prepared.capabilities
        report.sourceCounts = prepared.sourceCounts
        report.notImported = prepared.notImported ?? report.notImported
        if adapter == nil || adapter is ArcBrowserImportAdapter {
            report.passwordProfileCounts = plan.profiles.compactMap { profile in
                profile.sourceDirectory.map { directory in
                    (snapshot.passwordDatabases[directory] ?? []).reduce(0) { $0 + ((try? ArcPasswordImportSource.count(snapshotFile: $1)) ?? 0) }
                }
            }
        }
        report.source = plan.counts
        report.skipped = plan.skipped
        logger.log(.parsed(spaces: report.source.spaces, favorites: report.source.favorites, pinned: report.source.pinnedTabs,
                           folders: report.source.pinnedFolders, today: report.source.todayTabs, archived: report.source.archivedTabs))
        report.target = await target.preview(plan, ledger: ledger)
        report.sessionBudget.projectedBytes = report.target.projectedSessionBytes
        if !report.sessionBudget.fits {
            report.sessionBudget.withoutArchiveBytes = await target.preview(plan.excluding(.archive), ledger: ledger).projectedSessionBytes
            report.sessionBudget.withoutArchiveAndTodayBytes =
                await target.preview(plan.excluding([.archive, .today]), ledger: ledger).projectedSessionBytes
        }

        try validateHistoryDirectories(location, plan.historySources.map(\.profileID))
        let digest = SHA256.hash(data: (try await target.sessionBackup() ?? Data()) + Data([0x1F])
            + (ArcImportFiles.readData(location.ledgerFile) ?? Data()))
        report.targetStateDigest = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        report.historyProfiles = plan.historySources.count
        let total = plan.historySources.compactMap { snapshot.historyDatabases[$0.directory] }.count
        for (index, source) in plan.historySources.enumerated() {
            try Task.checkCancellation()
            guard let file = snapshot.historyDatabases[source.directory] else {
                report.historyProfilesWithoutDatabase += 1
                continue
            }
            if !(await target.history.acceptsHistory(for: source.profileID)) { report.historyProfilesNotPersistent += 1 }
            do {
                let reader = try historyReader(file: file, directory: source.directory)
                while try reader.nextChunk(size: options.historyChunkSize) != nil {
                    try Task.checkCancellation()
                    progress(ArcImportProgress(.countingHistory, completed: index, total: total))
                }
                report.history.add(reader.counts)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.historyDatabasesUnreadable += 1
            }
        }
        logger.log(.historyCounted(importable: report.history.importable, filtered: report.history.rows - report.history.importable))
        report.diskEstimateBytes = Self.applyRequirement(
            projectedSessionBytes: report.target.projectedSessionBytes,
            backupBytes: ArcImportBackups.estimatedBytes(at: location, historyProfiles: plan.historySources.map(\.profileID)),
            visits: report.history.importable, textBytes: report.history.importableTextBytes)
        if try ArcImportFiles.readExisting(ArcImportJournal.self, from: location.journalFile)?.state == .applying {
            report.interruptedImport = true
            logger.log(.interruptedImportDetected)
        }
        return ArcImportPreparation(report: report, plan: plan, snapshot: snapshot)
    }

    private func historyReader(file: URL, directory: String) throws -> any BrowserImportHistoryReader {
        try (adapter ?? ArcBrowserImportAdapter(options: options)).historyReader(file: file, directory: directory)
    }

    private func readSource(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch { throw ArcImportError.unreadableSourceDocument }
    }

    // MARK: Apply

    /// Backs up, merges, saves, then imports history chunk by chunk. Interrupting at any point
    /// leaves a consistent state: re-running completes the import; the backup undoes it.
    public func apply(_ preparation: ArcImportPreparation, to target: some ArcImportTarget,
                      progress: @escaping @Sendable (ArcImportProgress) -> Void = { _ in }) async throws -> ArcImportOutcome {
        defer { preparation.discard() }
        let location = target.location
        guard ArcImportLock.acquire(location) else { throw failure(ArcImportError.importInProgress) }
        defer { ArcImportLock.release(location) }
        do {
            try validatePaths(location)
            try Self.refuseInterruptedRestore(location)
            let plan = preparation.plan
            let report = preparation.report
            // Refused before any write: Orbit must be able to read the session back at launch.
            guard report.target.projectedSessionBytes <= BrowserStore.importSessionBudgetBytes else {
                throw ArcImportError.sessionTooLarge(projectedBytes: report.target.projectedSessionBytes,
                                                     limitBytes: BrowserStore.importSessionBudgetBytes)
            }
            try validateHistoryDirectories(location, plan.historySources.map(\.profileID))
            // Backup (WAL content included), session copies and history growth, recomputed now.
            let required = Self.applyRequirement(
                projectedSessionBytes: report.target.projectedSessionBytes,
                backupBytes: ArcImportBackups.estimatedBytes(at: location, historyProfiles: plan.historySources.map(\.profileID)),
                visits: report.history.importable, textBytes: report.history.importableTextBytes)
            try OrbitDiskSpace.require(required, at: location.dataDirectory, probe: diskSpace)
            let recovery: BrowserImportRecovery?
            if plan.registration != nil, report.target.profilesAdded == plan.profiles.count,
               plan.profiles.allSatisfy({ !$0.isAdopted }) {
                recovery = try BrowserImportRecovery.begin(at: location, profiles: plan.profiles.map { $0.id.rawValue }, authentication: false)
            } else { recovery = nil }
            try checkpoint(.afterLock)
            var outcome = ArcImportOutcome()
            progress(ArcImportProgress(.backingUp))
            let backupID = try ArcImportBackups.create(at: location, session: try await target.sessionBackup(),
                                                       historyProfiles: plan.historySources.map(\.profileID), now: clock())
            outcome.backupID = backupID
            logger.log(.backupCreated)
            try checkpoint(.afterBackup)
            var journal = ArcImportJournal(state: .applying, backupID: backupID, startedAt: clock(), updatedAt: clock())
            try ArcImportFiles.write(journal, to: location.journalFile)
            try checkpoint(.afterJournal)

            progress(ArcImportProgress(.applying))
            var ledger = try ArcImportFiles.readExisting(BrowserImportLedger.self, from: location.ledgerFile) ?? BrowserImportLedger()
            let merged = try await target.apply(plan, ledger: ledger)
            outcome.merge = merged.counts
            logger.log(.applied(added: merged.counts.addedItems + merged.counts.archivedTabsAdded,
                                present: merged.counts.itemsPresent, removedBefore: merged.counts.itemsPreviouslyRemoved))
            try checkpoint(.afterApply)
            progress(ArcImportProgress(.saving))
            try await target.persist()
            logger.log(.saved)
            try checkpoint(.afterPersist)
            // Written only once the session is durable: an entry never names an unsaved object.
            ledger.formUnion(merged.ledger)
            try ArcImportFiles.write(ledger, to: location.ledgerFile)
            try checkpoint(.afterLedger)
            var appearance = try ArcImportFiles.readExisting(BrowserSpaceAppearanceDocument.self, from: location.appearanceFile)
                ?? BrowserSpaceAppearanceDocument()
            appearance.addMissing(plan.spaces.filter { merged.ledger.spaces.contains($0.id.rawValue) }
                .map { .init(spaceID: $0.id, appearance: $0.appearance) })
            try ArcImportFiles.write(appearance, to: location.appearanceFile)
            try checkpoint(.afterAppearance)

            var processedChunks = 0
            for (index, source) in plan.historySources.enumerated() {
                guard let file = preparation.snapshot.historyDatabases[source.directory],
                      merged.ledger.profiles.contains(source.profileID.rawValue) || plan.profiles.contains(where: { $0.id == source.profileID && $0.isAdopted }),
                      await target.history.acceptsHistory(for: source.profileID) else {
                    outcome.historyProfilesSkipped += 1
                    logger.log(.historySkipped(profile: index))
                    continue
                }
                let reader = try historyReader(file: file, directory: source.directory)
                // Created and verified through descriptors; re-verified after SQLite wrote there.
                let destination = try ArcImportFiles.historyDirectory(location, source.profileID, create: true)
                // Pinned for the whole profile import: SQLite cannot be redirected elsewhere, and a
                // store already open on another folder for this path is refused (IMPORT-R4 #A).
                let pin = try OrbitSQLiteGuard.pin(destination)
                defer { pin.release() }
                await target.history.beginBulkImport(for: source.profileID)
                do {
                    while let visits = try reader.nextChunk(size: options.historyChunkSize) {
                        try Task.checkCancellation()
                        if !visits.isEmpty {
                            let inserted = try await target.history.importChunk(
                                BrowserHistoryDocument(profileID: source.profileID, visits: visits))
                            outcome.historyInserted += inserted
                            outcome.historyAlreadyPresent += visits.count - inserted
                        }
                        processedChunks += 1
                        logger.log(.historyChunk(profile: index, inserted: outcome.historyInserted, processed: reader.counts.rows))
                        progress(ArcImportProgress(.importingHistory, completed: reader.counts.rows, total: reader.totalVisits))
                        try checkpoint(.afterHistoryChunk(processedChunks))
                    }
                } catch {
                    await target.history.endBulkImport(for: source.profileID)
                    throw error
                }
                await target.history.endBulkImport(for: source.profileID)
                _ = try destination.verifiedPath("history.sqlite")
            }
            journal.state = .complete
            journal.updatedAt = clock()
            try ArcImportFiles.write(journal, to: location.journalFile)
            try checkpoint(.afterCompletion)
            if let recovery, !recovery.isAuthentication { try recovery.complete() }
            progress(ArcImportProgress(.finished))
            logger.log(.completed(added: merged.counts.addedItems + merged.counts.archivedTabsAdded,
                                  historyInserted: outcome.historyInserted))
            return outcome
        } catch {
            throw failure(error)
        }
    }

    /// Logs a redacted code and maps unexpected errors to import codes.
    private func failure(_ error: any Error) -> any Error {
        if error is CancellationError || (error as? ArcImportError) == .cancelled {
            logger.log(.cancelled)
            return ArcImportError.cancelled
        }
        if let error = error as? ArcImportError {
            logger.log(.failed(error))
            return error
        }
        logger.log(.failedUnexpectedly)
        return error
    }
}

/// One import per data location per process.
enum ArcImportLock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: Set<String> = []

    static func acquire(_ location: ArcImportDataLocation) -> Bool {
        lock.withLock { held.insert(location.dataDirectory.path).inserted }
    }

    static func release(_ location: ArcImportDataLocation) {
        _ = lock.withLock { held.remove(location.dataDirectory.path) }
    }
}

/// A session file opened while no Orbit uses it (offline tool, tests). The store is restored from
/// the file and saved back atomically by `BrowserSessionFileStore`.
public actor ArcOfflineImportTarget: ArcImportTarget {
    public nonisolated let location: ArcImportDataLocation
    public nonisolated let history: any ArcHistoryImportSink
    private let directHistory: ArcDirectHistorySink
    private let store: BrowserStore
    private var sessionBytes: Data?
    private let lock: OrbitDataDirectoryLock
    public nonisolated var holdsExclusiveAccess: Bool { true }

    /// Takes the data directory's exclusive lock **before** loading the session and keeps it until
    /// `close()`: a concurrent import or a running Orbit (shared lock) is refused with `targetInUse`
    /// instead of saving over each other (IMPORT-R2 #2).
    /// - Parameter separatedFrom: the Arc source folder, refused if it overlaps the data folder
    ///   before the lock can create anything there.
    public init(sessionFile: URL, usage: any OrbitTargetUsageProbe = ArcSystemRunningProbe(),
                separatedFrom source: URL? = nil) throws {
        let location = ArcImportDataLocation(sessionFile: sessionFile)
        try ArcImportPaths.validateNoSymbolicLinks(location.dataDirectory)
        if let source { try ArcImportPaths.validateSeparated(source: source, destination: location.dataDirectory) }
        let lock = try OrbitDataDirectoryLock.acquire(location.dataDirectory, exclusive: true)
        guard !usage.isInUse(sessionFile: location.sessionFile) else { lock.release(); throw ArcImportError.targetInUse }
        // Before anything is read: a half-restored data directory is rolled back first (IMPORT-R3 #1).
        do { try ArcImportBackups.recoverInterruptedRestore(at: location, holdingLock: true) }
        catch { lock.release(); throw error }
        self.lock = lock
        self.location = location
        // The session is replaced by rename, but its content must not be shared with another file.
        if let directory = try? OrbitSecureDirectory.open(location.dataDirectory, create: false),
           let links = directory.linkCount(location.sessionFile.lastPathComponent) {
            guard directory.kind(location.sessionFile.lastPathComponent) == S_IFREG, links == 1 else {
                lock.release()
                throw links > 1 ? ArcImportError.hardLinkedFile : ArcImportError.targetUnreadable
            }
        }
        if FileManager.default.fileExists(atPath: location.sessionFile.path) {
            do {
                let loaded = try BrowserSessionFileStore().loadWithRawBytes(from: location.sessionFile)
                store = try BrowserStore(restoring: loaded.document)
                sessionBytes = loaded.data
            }
            catch { throw ArcImportError.targetUnreadable }
        } else {
            store = BrowserStore()
            sessionBytes = nil
        }
        let sink = ArcDirectHistorySink(directory: location.historyDirectory)
        directHistory = sink
        history = sink
    }

    public func defaultProfile() async -> ProfileID? { await store.catalogSnapshot().profiles.first?.id }

    public func preview(_ plan: BrowserImportPlan, ledger: BrowserImportLedger) async -> BrowserImportMergeCounts {
        await store.previewImport(plan, ledger: ledger)
    }

    public func sessionBackup() async throws -> Data? {
        sessionBytes
    }

    public func apply(_ plan: BrowserImportPlan, ledger: BrowserImportLedger) async throws -> BrowserImportMergeResult {
        try await store.applyImport(plan, ledger: ledger)
    }

    public func persist() async throws {
        let document = await store.sessionDocument()
        let files = BrowserSessionFileStore()
        try files.save(document, to: location.sessionFile)
        sessionBytes = try files.loadWithRawBytes(from: location.sessionFile).data
    }

    public func sessionDocument() async -> BrowserSessionDocument { await store.sessionDocument() }

    public func close() async {
        await directHistory.close()
        lock.release()
    }
}
