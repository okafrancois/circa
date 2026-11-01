import BrowserCore
import Foundation
import Darwin

/// The coordinator retains accepted transfers independently of source tabs and windows.
/// Implementations must support cancellation during shutdown, even before engine startup.
/// Resume must use an actual engine handle or private engine resume data, never URL replay.
/// An adapter instance belongs to one registration and cannot be reused after invalidation.
@MainActor
public protocol BrowserDownloadTransfer: AnyObject {
    /// Acknowledges command delivery only. State changes require a sequenced engine report.
    /// Errors must be mapped to generic BrowserDownloadError values before calling completion.
    func perform(
        _ action: BrowserDownloadAction,
        completion: @escaping @MainActor (Result<Void, BrowserDownloadError>) -> Void
    )

    /// Releases delegates, observers and resume data. Idempotent; must not delete output files.
    /// Shutdown calls this after requesting cancellation without waiting for acknowledgement.
    func invalidate()
}

/// This callback does not retain the coordinator or a source UI object.
@MainActor
public struct BrowserDownloadRegistration {
    public let key: BrowserDownloadKey
    private let callback: @MainActor (BrowserDownloadUpdate) -> Result<Void, BrowserDownloadError>

    fileprivate init(
        key: BrowserDownloadKey,
        callback: @escaping @MainActor (BrowserDownloadUpdate) -> Result<Void, BrowserDownloadError>
    ) {
        self.key = key
        self.callback = callback
    }

    @discardableResult
    public func report(_ update: BrowserDownloadUpdate) -> Result<Void, BrowserDownloadError> {
        callback(update)
    }
}

/// Transfer lifetimes and owned terminal-file name leases; no persistence, UI, or engine dependencies.
/// The application owns one coordinator; closing a source window does not shut it down.
@MainActor
public final class BrowserDownloadCoordinator {
    public var onChange: (() -> Void)?
    /// Item notifications coalesce byte-only progress to at most ten deliveries per second.
    /// Model reads and the legacy synchronous lifecycle observer remain exact at every report.
    public struct Delta {
        public let changed: [BrowserDownloadSnapshot]
        public let removed: [BrowserDownloadKey]
        public let historyChanged: Bool
    }
    public var onDelta: ((Delta) -> Void)?
    private var pendingProgress: [BrowserDownloadKey: BrowserDownloadSnapshot] = [:]
    private var progressTask: Task<Void, Never>?

    public private(set) var isClosed = false

    @MainActor
    private final class Entry {
        let key: BrowserDownloadKey
        var owner: BrowserDownloadOwner
        let suggestedFilename: String
        var transfer: (any BrowserDownloadTransfer)?
        var revision: UInt64 = 0
        var actionRevision: UInt64 = 0
        var sequence: UInt64 = 0
        var state: BrowserDownloadState = .awaitingDestination
        var receivedBytes: Int64 = 0
        var totalBytes: Int64?
        var startedAt: Date?
        var completedAt: Date?
        var capabilities: BrowserDownloadCapabilities = [.cancel]
        var currentURL: URL?
        var destinationURL: URL?
        var fileAvailability: BrowserDownloadFileAvailability = .unknown
        var failure: BrowserDownloadFailure?
        var pendingAction: BrowserDownloadAction?
        var isCancellationRequested = false
        var isCancellationAccepted = false
        var hasDispatchedCancellation = false
        var controlError: BrowserDownloadError?
        var controlToken = UUID()
        var dispatchedControlToken: UUID?

        init(
            key: BrowserDownloadKey, owner: BrowserDownloadOwner, suggestedFilename: String,
            sourceURL: URL?, transfer: (any BrowserDownloadTransfer)?
        ) {
            self.key = key
            self.owner = owner
            self.suggestedFilename = suggestedFilename.isEmpty ? BrowserText.string("Download") : suggestedFilename
            currentURL = sourceURL
            self.transfer = transfer
        }

        var snapshot: BrowserDownloadSnapshot {
            BrowserDownloadSnapshot(
                key: key, owner: owner, revision: revision, sequence: sequence,
                suggestedFilename: suggestedFilename, state: state, receivedBytes: receivedBytes,
                totalBytes: totalBytes, capabilities: capabilities, currentURL: currentURL,
                destinationURL: destinationURL, fileAvailability: fileAvailability, failure: failure,
                pendingAction: pendingAction, isCancellationRequested: isCancellationRequested,
                controlError: controlError, isCancellationAccepted: isCancellationAccepted,
                startedAt: startedAt, completedAt: completedAt
            )
        }
    }

    @MainActor
    private final class TransferReservation {
        weak var transfer: (any BrowserDownloadTransfer)?

        init(_ transfer: any BrowserDownloadTransfer) { self.transfer = transfer }
    }

    private enum Effect {
        case control(Entry, UUID, BrowserDownloadAction)
        case retire(any BrowserDownloadTransfer, cancel: Bool)
    }

    private var entries: [UUID: Entry] = [:]
    // Weak reservations survive terminal publication, removal and reentrant invalidation.
    // A living retired adapter must never be adopted while its old retirement can still run.
    private var transferReservations: [ObjectIdentifier: TransferReservation] = [:]
    private var order: [UUID] = []
    private var effects: [Effect] = []
    private var isDrainingEffects = false
    private var publicationDepth = 0

    private let clock: @MainActor () -> Date

    public init(clock: @escaping @MainActor () -> Date = { Date() }) { self.clock = clock }

    /// Inserts before publication and performs no engine startup or callback installation.
    /// Configure the adapter with the returned registration before starting any engine work.
    public func register(
        owner: BrowserDownloadOwner, transfer: any BrowserDownloadTransfer,
        suggestedFilename: String = BrowserText.string("Download"), sourceURL: URL? = nil, id: UUID = UUID()
    ) throws -> BrowserDownloadRegistration {
        guard !isClosed else { throw BrowserDownloadError.coordinatorStopped }
        guard entries[id] == nil else { throw BrowserDownloadError.duplicateID }
        transferReservations = transferReservations.filter { $0.value.transfer != nil }
        let transferID = ObjectIdentifier(transfer)
        guard transferReservations[transferID]?.transfer !== transfer else {
            throw BrowserDownloadError.duplicateTransfer
        }
        transferReservations[transferID] = TransferReservation(transfer)
        let key = BrowserDownloadKey(id: id, profileID: owner.profileID, lifetime: UUID())
        entries[id] = Entry(
            key: key, owner: owner, suggestedFilename: suggestedFilename,
            sourceURL: sourceURL, transfer: transfer
        )
        entries[id]?.startedAt = clock()
        order.append(id)
        let registration = BrowserDownloadRegistration(key: key) { [weak self] update in
            guard let self else { return .failure(.coordinatorStopped) }
            do {
                try self.receive(update, registeredKey: key)
                return .success(())
            } catch let error as BrowserDownloadError {
                return .failure(error)
            } catch {
                return .failure(.invalidUpdate)
            }
        }
        publish(entry: entries[id])
        drainEffects()
        guard !isClosed else { throw BrowserDownloadError.coordinatorStopped }
        return registration
    }

    /// Restored records have a fresh lifetime and no live controls or source UI ownership.
    public func restore(_ records: [BrowserDownloadHistoryRecord]) throws {
        guard !isClosed else { throw BrowserDownloadError.coordinatorStopped }
        guard records.allSatisfy(\.isValid), Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ entries[$0.id] == nil }) else { throw BrowserDownloadError.invalidUpdate }
        for record in records {
            let key = BrowserDownloadKey(id: record.id, profileID: record.profileID, lifetime: UUID())
            let entry = Entry(key: key, owner: .init(profileID: record.profileID),
                              suggestedFilename: record.filename, sourceURL: nil, transfer: nil)
            entry.startedAt = record.startedAt
            entry.completedAt = record.completedAt
            entry.state = record.state
            entry.receivedBytes = record.receivedBytes
            entry.totalBytes = record.totalBytes
            entry.destinationURL = record.destinationURL
            entry.failure = record.failure
            entry.capabilities = []
            entries[key.id] = entry
            order.append(key.id)
        }
        publish(changed: records.compactMap { entries[$0.id]?.snapshot }, historyChanged: true)
        drainEffects()
    }

    public var allSnapshots: [BrowserDownloadSnapshot] { order.compactMap { entries[$0]?.snapshot } }

    public func snapshots(profileID: ProfileID) -> [BrowserDownloadSnapshot] {
        order.compactMap { entries[$0] }.filter { $0.owner.profileID == profileID }.map(\.snapshot)
    }

    public func snapshot(for key: BrowserDownloadKey) -> BrowserDownloadSnapshot? {
        guard let entry = entries[key.id], entry.key == key else { return nil }
        return entry.snapshot
    }

    /// A displayed row can lag byte-only progress. Rebase its action context only across those
    /// reports; state, ownership, availability and control changes retain strict stale rejection.
    public func currentActionContext(_ context: BrowserDownloadContext) -> BrowserDownloadContext? {
        guard !isClosed, let entry = try? resolve(context.key),
              context.revision >= entry.actionRevision, context.revision <= entry.revision else { return nil }
        return entry.snapshot.context
    }

    /// Cancellation supersedes pending pause/resume commands before their engine effects run.
    /// No control command fabricates an engine state or changes the received-byte count.
    /// A genuine completion may win until a terminal engine outcome has been recorded.
    public func perform(_ action: BrowserDownloadAction, in context: BrowserDownloadContext) throws {
        let entry = try resolve(context)
        guard !entry.state.isTerminal else { throw BrowserDownloadError.terminalState }
        if action != .cancel, entry.isCancellationRequested { throw BrowserDownloadError.cancellationRequested }
        if entry.pendingAction != nil && (action != .cancel || entry.pendingAction == .cancel) {
            throw BrowserDownloadError.actionPending
        }
        if action == .cancel, entry.isCancellationAccepted { throw BrowserDownloadError.cancellationRequested }
        guard entry.capabilities.supports(action) else { throw BrowserDownloadError.unsupportedOperation }
        switch action {
        case .cancel: break
        case .pause:
            guard entry.state == .running else { throw BrowserDownloadError.invalidState }
        case .resume:
            guard entry.state == .paused || entry.state == .interrupted else {
                throw BrowserDownloadError.invalidState
            }
        }
        try advance(entry)
        entry.controlToken = UUID()
        entry.pendingAction = action
        entry.controlError = nil
        if action == .cancel { entry.isCancellationRequested = true }
        effects.append(.control(entry, entry.controlToken, action))
        publish(entry: entry)
        drainEffects()
    }

    /// Completes a provisional owner. A download that started while its source surface was still
    /// being recorded as a tab (a live move or a new target in flight) has no source occurrence
    /// yet; this fills it once, within the same profile. Known provenance is never rewritten.
    public func attributeSource(_ key: BrowserDownloadKey, windowID: WindowID, occurrenceID: TabOccurrenceID) {
        guard !isClosed, let entry = entries[key.id], entry.key == key, entry.owner.sourceOccurrenceID == nil,
              entry.revision < .max else { return }
        entry.owner = BrowserDownloadOwner(profileID: entry.owner.profileID, sourceWindowID: windowID,
                                           sourceOccurrenceID: occurrenceID)
        entry.revision += 1
        publish(entry: entry)
        drainEffects()
    }

    /// A rejected receiver is no longer the source window. A rescued document without a window
    /// leaves only its immutable profile as provenance until a recorded owner can fill it in.
    /// Already attributed occurrences and download profiles can never be changed here.
    public func clearProvisionalSourceWindow(_ key: BrowserDownloadKey) {
        guard !isClosed, let entry = entries[key.id], entry.key == key,
              entry.owner.sourceOccurrenceID == nil, entry.owner.sourceWindowID != nil,
              entry.revision < .max else { return }
        entry.owner = BrowserDownloadOwner(profileID: entry.owner.profileID)
        entry.revision += 1
        publish(entry: entry)
        drainEffects()
    }

    /// Metadata only. The adapter probes, opens and reveals files; this method never touches disk.
    public func setFileAvailability(
        _ availability: BrowserDownloadFileAvailability, in context: BrowserDownloadContext
    ) throws {
        let entry = try resolve(context)
        try advance(entry)
        entry.fileAvailability = availability
        publish(entry: entry)
        drainEffects()
    }

    /// A regular-file lease captured before requesting a suggested name. No file data is read.
    public struct RenameLease: Equatable, Sendable {
        public let context: BrowserDownloadContext
        public let url: URL
        fileprivate let device: dev_t
        fileprivate let inode: ino_t
        fileprivate let size: off_t
        fileprivate let modified: timespec
        fileprivate let changed: timespec
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.context == rhs.context && lhs.url == rhs.url && lhs.device == rhs.device
                && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    public func renameLease(in context: BrowserDownloadContext) -> RenameLease? {
        guard let entry = try? resolve(context), entry.state == .complete,
              let url = entry.destinationURL, url.isFileURL else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return RenameLease(context: context, url: url, device: info.st_dev, inode: info.st_ino,
                           size: info.st_size, modified: info.st_mtimespec, changed: info.st_ctimespec)
    }

    /// Main-actor compare-and-move: publication and file mutation have no suspension point.
    /// RENAME_EXCL atomically refuses existing files, including dangling symlinks.
    public func rename(_ lease: RenameLease, to name: String) -> RenameLease? {
        guard let safe = BrowserAIHelperName.download(name, original: lease.url.lastPathComponent), safe == name,
              safe != lease.url.lastPathComponent, renameLease(in: lease.context) == lease,
              let entry = try? resolve(lease.context), entry.revision < .max else { return nil }
        let destination = lease.url.deletingLastPathComponent().appendingPathComponent(safe)
        guard renamex_np(lease.url.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { return nil }
        entry.destinationURL = destination
        entry.revision += 1
        entry.fileAvailability = .available
        let result = renameLease(in: entry.snapshot.context)
        publish(entry: entry, historyChanged: true)
        drainEffects()
        return result
    }

    /// Applies a background availability batch in one publication; stale contexts are ignored.
    public func setFileAvailabilities(_ checks: [(BrowserDownloadContext, BrowserDownloadFileAvailability)]) {
        var changed: [BrowserDownloadSnapshot] = []
        for (context, availability) in checks {
            guard let entry = try? resolve(context), entry.state == .complete,
                  entry.fileAvailability != availability, (try? advance(entry)) != nil else { continue }
            entry.fileAvailability = availability
            changed.append(entry.snapshot)
        }
        if !changed.isEmpty { publish(changed: changed); drainEffects() }
    }

    /// Removing an active item is rejected. Cancel first and wait for a terminal engine report.
    /// Removing a record never deletes, moves, opens or reveals a downloaded file.
    public func remove(in context: BrowserDownloadContext) throws {
        let entry = try resolve(context)
        guard entry.state.isTerminal else { throw BrowserDownloadError.activeDownload }
        entries.removeValue(forKey: entry.key.id)
        order.removeAll { $0 == entry.key.id }
        publish(removed: [entry.key], historyChanged: true)
        drainEffects()
    }

    /// Revokes reports and completions before any adapter callback, retaining known outcomes.
    /// Active entries retain their last engine state and gain cancellation intent, not fake success.
    public func shutdown() {
        guard !isClosed else { return }
        isClosed = true
        for id in order {
            guard let entry = entries[id] else { continue }
            entry.controlToken = UUID()
            entry.pendingAction = nil
            if !entry.state.isTerminal { entry.isCancellationRequested = true }
            if entry.revision < .max { entry.revision += 1 }
            if let transfer = entry.transfer {
                entry.transfer = nil
                effects.append(.retire(
                    transfer, cancel: !entry.state.isTerminal && !entry.hasDispatchedCancellation
                ))
            }
        }
        progressTask?.cancel()
        progressTask = nil
        pendingProgress.removeAll()
        publish(changed: allSnapshots)
        onChange = nil
        onDelta = nil
        drainEffects()
    }

    private func resolve(_ context: BrowserDownloadContext) throws -> Entry {
        guard !isClosed else { throw BrowserDownloadError.coordinatorStopped }
        let entry = try resolve(context.key)
        guard entry.revision == context.revision else { throw BrowserDownloadError.staleRevision }
        return entry
    }

    private func resolve(_ key: BrowserDownloadKey) throws -> Entry {
        guard let entry = entries[key.id] else { throw BrowserDownloadError.unknownDownload }
        guard entry.owner.profileID == key.profileID else { throw BrowserDownloadError.profileMismatch }
        guard entry.key.lifetime == key.lifetime else { throw BrowserDownloadError.staleLifetime }
        return entry
    }

    private func advance(_ entry: Entry) throws {
        guard entry.revision < .max else { throw BrowserDownloadError.revisionExhausted }
        entry.revision += 1
    }

    private func receive(_ update: BrowserDownloadUpdate, registeredKey: BrowserDownloadKey) throws {
        guard !isClosed else { throw BrowserDownloadError.coordinatorStopped }
        guard update.key.profileID == registeredKey.profileID else { throw BrowserDownloadError.profileMismatch }
        guard update.key.id == registeredKey.id else { throw BrowserDownloadError.unknownDownload }
        guard update.key.lifetime == registeredKey.lifetime else { throw BrowserDownloadError.staleLifetime }
        let entry = try resolve(registeredKey)
        guard update.sequence > entry.sequence else { throw BrowserDownloadError.staleSequence }
        guard !entry.state.isTerminal else { throw BrowserDownloadError.terminalState }
        guard !entry.isCancellationRequested || update.state.isTerminal else {
            throw BrowserDownloadError.cancellationRequested
        }
        guard entry.state.canTransition(to: update.state) else { throw BrowserDownloadError.invalidTransition }
        guard update.receivedBytes >= entry.receivedBytes,
              update.totalBytes.map({ $0 >= 0 }) ?? true,
              update.destinationURL.map(\.isFileURL) ?? true,
              update.state != .failed || update.failure != nil,
              update.failure == nil || update.state == .failed || update.state == .interrupted else {
            throw BrowserDownloadError.invalidUpdate
        }
        let progressOnly = entry.state == .running && update.state == .running
            && entry.capabilities == update.capabilities && entry.currentURL == update.currentURL
            && entry.destinationURL == update.destinationURL && entry.fileAvailability == update.fileAvailability
            && entry.failure == update.failure && entry.pendingAction == nil && entry.controlError == nil
        try advance(entry)
        entry.sequence = update.sequence
        entry.state = update.state
        if update.state == .complete { entry.completedAt = clock() }
        entry.receivedBytes = update.receivedBytes
        entry.totalBytes = update.totalBytes
        entry.capabilities = update.state.isTerminal ? [] : update.capabilities
        entry.currentURL = update.currentURL
        entry.destinationURL = update.destinationURL
        entry.fileAvailability = update.fileAvailability
        entry.failure = update.failure
        entry.controlError = nil
        if update.state.isTerminal {
            entry.controlToken = UUID()
            entry.pendingAction = nil
            if let transfer = entry.transfer {
                entry.transfer = nil
                effects.append(.retire(transfer, cancel: false))
            }
        } else if let action = entry.pendingAction,
                  entry.dispatchedControlToken != entry.controlToken,
                  let error = rejectionForDispatch(action, entry: entry) {
            entry.controlToken = UUID()
            entry.pendingAction = nil
            entry.controlError = error
        }
        publish(entry: entry, progressOnly: progressOnly, historyChanged: update.state.isTerminal)
        drainEffects()
    }

    private func acknowledge(
        _ result: Result<Void, BrowserDownloadError>, entry: Entry, token: UUID
    ) {
        guard !isClosed, entries[entry.key.id] === entry, entry.controlToken == token,
              entry.pendingAction != nil, !entry.state.isTerminal, entry.revision < .max else { return }
        entry.revision += 1
        if case .failure(let error) = result {
            entry.controlError = error
            if entry.pendingAction == .cancel { entry.hasDispatchedCancellation = false }
        } else if entry.pendingAction == .cancel {
            entry.isCancellationAccepted = true
        }
        entry.pendingAction = nil
        publish(entry: entry)
        drainEffects()
    }

    private func publish(entry: Entry?, progressOnly: Bool = false, historyChanged: Bool = false) {
        publish(changed: entry.map { [$0.snapshot] } ?? [], progressOnly: progressOnly, historyChanged: historyChanged)
    }

    private func publish(changed: [BrowserDownloadSnapshot] = [], removed: [BrowserDownloadKey] = [],
                         progressOnly: Bool = false, historyChanged: Bool = false) {
        publicationDepth += 1
        defer { publicationDepth -= 1 }
        // Snapshot values are captured before reentrant observers can mutate the coordinator.
        if progressOnly {
            for item in changed { pendingProgress[item.key] = item }
            if progressTask == nil {
                progressTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self else { return }
                    self.progressTask = nil
                    let items = Array(self.pendingProgress.values)
                    self.pendingProgress.removeAll()
                    self.publicationDepth += 1
                    if !items.isEmpty { self.onDelta?(Delta(changed: items, removed: [], historyChanged: false)) }
                    self.publicationDepth -= 1
                    self.drainEffects()
                }
            }
        } else {
            for item in changed {
                if let entry = entries[item.key.id], entry.key == item.key { entry.actionRevision = item.revision }
            }
            for key in changed.map(\.key) + removed { pendingProgress[key] = nil }
            onDelta?(Delta(changed: changed, removed: removed, historyChanged: historyChanged))
        }
        onChange?()
    }

    private func rejectionForDispatch(_ action: BrowserDownloadAction, entry: Entry) -> BrowserDownloadError? {
        if action != .cancel && entry.isCancellationRequested { return .cancellationRequested }
        if !entry.capabilities.supports(action) { return .unsupportedOperation }
        switch action {
        case .cancel: return nil
        case .pause: return entry.state == .running ? nil : .invalidState
        case .resume: return entry.state == .paused || entry.state == .interrupted ? nil : .invalidState
        }
    }

    /// Serializes native effects, even when reports, observers and completions are synchronous.
    /// Every queued command is revalidated after observers have had a chance to revoke it.
    private func drainEffects() {
        guard !isDrainingEffects, publicationDepth == 0 else { return }
        isDrainingEffects = true
        defer { isDrainingEffects = false }
        while !effects.isEmpty {
            switch effects.removeFirst() {
            case let .control(entry, token, action):
                guard !isClosed, entries[entry.key.id] === entry,
                      entry.controlToken == token, entry.pendingAction == action,
                      !entry.state.isTerminal, let transfer = entry.transfer else { continue }
                if let error = rejectionForDispatch(action, entry: entry) {
                    acknowledge(.failure(error), entry: entry, token: token)
                    continue
                }
                entry.dispatchedControlToken = token
                if action == .cancel { entry.hasDispatchedCancellation = true }
                transfer.perform(action) { [weak self, weak entry] result in
                    guard let self, let entry else { return }
                    self.acknowledge(result, entry: entry, token: token)
                }
            case let .retire(transfer, cancel):
                if cancel { transfer.perform(.cancel) { _ in } }
                transfer.invalidate()
            }
        }
    }
}
