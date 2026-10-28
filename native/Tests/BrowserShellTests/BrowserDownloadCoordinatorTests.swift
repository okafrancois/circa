import BrowserCore
import BrowserShell
import Foundation
import Testing

private final class WeakDownloadObject<Object: AnyObject> {
    weak var value: Object?
    init(_ value: Object?) { self.value = value }
}

@MainActor
private final class DownloadTransfer: BrowserDownloadTransfer {
    typealias Completion = @MainActor (Result<Void, BrowserDownloadError>) -> Void
    // Two distinct adapters intentionally share this engine-local identifier in the tests.
    let engineID = 7
    var actions: [BrowserDownloadAction] = []
    var completions: [Completion] = []
    var invalidations = 0
    var depth = 0
    var maximumDepth = 0
    var onPerform: ((BrowserDownloadAction) -> Void)?
    var onInvalidate: (() -> Void)?

    func perform(_ action: BrowserDownloadAction, completion: @escaping Completion) {
        depth += 1
        maximumDepth = max(maximumDepth, depth)
        defer { depth -= 1 }
        actions.append(action)
        completions.append(completion)
        onPerform?(action)
    }

    func invalidate() {
        depth += 1
        maximumDepth = max(maximumDepth, depth)
        defer { depth -= 1 }
        invalidations += 1
        onInvalidate?()
    }
}

@MainActor
private final class DownloadSource {}

@Suite("Engine-independent active download lifecycle")
@MainActor
struct BrowserDownloadCoordinatorTests {
    private func register(
        _ coordinator: BrowserDownloadCoordinator, _ transfer: DownloadTransfer,
        profileID: ProfileID = ProfileID(), id: UUID = UUID()
    ) throws -> BrowserDownloadRegistration {
        try coordinator.register(
            owner: .init(profileID: profileID), transfer: transfer,
            suggestedFilename: "same-name.dat", sourceURL: URL(string: "https://synthetic.test/same"), id: id
        )
    }

    private func report(
        _ registration: BrowserDownloadRegistration, sequence: UInt64 = 1,
        state: BrowserDownloadState = .running, received: Int64 = 0, total: Int64? = nil,
        capabilities: BrowserDownloadCapabilities = [.cancel, .pause, .resume],
        failure: BrowserDownloadFailure? = nil
    ) -> Result<Void, BrowserDownloadError> {
        registration.report(.init(
            key: registration.key, sequence: sequence, state: state, receivedBytes: received,
            totalBytes: total, capabilities: capabilities, failure: failure
        ))
    }

    private func value(
        _ coordinator: BrowserDownloadCoordinator, _ registration: BrowserDownloadRegistration
    ) throws -> BrowserDownloadSnapshot {
        try #require(coordinator.snapshot(for: registration.key))
    }

    private func rejection(_ result: Result<Void, BrowserDownloadError>) -> BrowserDownloadError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    @Test("Clearing a rejected provisional window preserves the profile and cannot rewrite recorded provenance")
    func provisionalWindowRollback() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let profile = ProfileID()
        let rejectedWindow = WindowID()
        let registration = try coordinator.register(owner: .init(profileID: profile, sourceWindowID: rejectedWindow),
                                                    transfer: transfer)
        let before = try value(coordinator, registration)
        let forgedProfile = BrowserDownloadKey(id: registration.key.id, profileID: ProfileID(),
                                               lifetime: registration.key.lifetime)
        coordinator.clearProvisionalSourceWindow(forgedProfile)
        let forgedLifetime = BrowserDownloadKey(id: registration.key.id, profileID: profile, lifetime: UUID())
        coordinator.clearProvisionalSourceWindow(forgedLifetime)
        #expect(try value(coordinator, registration) == before)
        coordinator.clearProvisionalSourceWindow(registration.key)
        let rescued = try value(coordinator, registration)
        #expect(rescued.owner == .init(profileID: profile))
        #expect(rescued.revision == before.revision + 1)
        coordinator.clearProvisionalSourceWindow(registration.key)
        #expect(try value(coordinator, registration) == rescued)
        let returnedWindow = WindowID()
        let returnedOccurrence = TabOccurrenceID()
        coordinator.attributeSource(registration.key, windowID: returnedWindow, occurrenceID: returnedOccurrence)
        let recorded = try value(coordinator, registration)
        coordinator.clearProvisionalSourceWindow(registration.key)
        coordinator.attributeSource(registration.key, windowID: WindowID(), occurrenceID: TabOccurrenceID())
        #expect(try value(coordinator, registration) == recorded)
        #expect(recorded.owner == .init(profileID: profile, sourceWindowID: returnedWindow,
                                        sourceOccurrenceID: returnedOccurrence))
        coordinator.shutdown()
    }

    @Test("Registration publishes an existing record and does not start the engine")
    func synchronousRegistration() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let profile = ProfileID()
        var publications = 0
        coordinator.onChange = {
            publications += 1
            #expect(coordinator.snapshots(profileID: profile).count == 1)
            #expect(transfer.actions.isEmpty)
        }
        let registration = try register(coordinator, transfer, profileID: profile)
        #expect(publications == 1 && transfer.invalidations == 0)
        let initial = try value(coordinator, registration)
        #expect(initial.state == .awaitingDestination && initial.receivedBytes == 0)
        #expect(initial.totalBytes == nil && initial.sequence == 0)
        coordinator.onChange = nil
        #expect(rejection(report(registration, state: .complete)) == nil)
        #expect(try value(coordinator, registration).state == .complete)
        #expect(transfer.actions.isEmpty && transfer.invalidations == 1)
    }

    @Test("Asynchronous reports use the same pre-registered lifetime")
    func asynchronousReport() async throws {
        let coordinator = BrowserDownloadCoordinator()
        let registration = try register(coordinator, DownloadTransfer())
        let task = Task { @MainActor in
            report(registration, received: 24)
        }
        #expect(rejection(await task.value) == nil)
        #expect(try value(coordinator, registration).receivedBytes == 24)
        coordinator.shutdown()
    }

    @Test("Concurrent equal URLs and basenames remain separate across profiles and engine IDs")
    func independentTransfers() throws {
        let coordinator = BrowserDownloadCoordinator()
        let first = DownloadTransfer()
        let second = DownloadTransfer()
        let third = DownloadTransfer()
        let profileA = ProfileID()
        let profileB = ProfileID()
        let a = try register(coordinator, first, profileID: profileA)
        let b = try register(coordinator, second, profileID: profileB)
        let c = try register(coordinator, third, profileID: profileA)
        #expect(first.engineID == second.engineID)
        #expect(a.key != b.key && a.key != c.key)
        #expect(coordinator.snapshots(profileID: profileA).map(\.key) == [a.key, c.key])
        #expect(coordinator.snapshots(profileID: profileB).map(\.key) == [b.key])
        _ = report(a, received: 4)
        _ = report(b, received: 17)
        #expect(try value(coordinator, a).receivedBytes == 4)
        #expect(try value(coordinator, b).receivedBytes == 17)
        #expect(try value(coordinator, c).receivedBytes == 0)
        coordinator.shutdown()
    }

    @Test("Source objects may disappear without cancelling or retargeting an accepted transfer")
    func sourceLifetimeIndependence() throws {
        let coordinator = BrowserDownloadCoordinator()
        let owner = BrowserDownloadOwner(
            profileID: ProfileID(), sourceWindowID: WindowID(), sourceOccurrenceID: TabOccurrenceID()
        )
        var source: DownloadSource? = DownloadSource()
        let weakSource = WeakDownloadObject(source)
        var transfer: DownloadTransfer? = DownloadTransfer()
        let weakTransfer = WeakDownloadObject(transfer)
        let registration = try coordinator.register(owner: owner, transfer: try #require(transfer))
        source = nil
        transfer = nil
        #expect(weakSource.value == nil && weakTransfer.value != nil)
        _ = report(registration, received: 8)
        #expect(try value(coordinator, registration).owner == owner)
        #expect(weakTransfer.value?.actions.isEmpty == true)
        _ = report(registration, sequence: 2, state: .complete, received: 8)
        #expect(weakTransfer.value == nil)
    }

    @Test("Duplicate IDs are rejected and foreign widget contexts cannot act on a transfer")
    func exactIdentity() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        let current = try value(coordinator, registration)
        #expect(throws: BrowserDownloadError.duplicateID) {
            try register(coordinator, DownloadTransfer(), id: registration.key.id)
        }
        let foreignProfile = BrowserDownloadKey(
            id: current.key.id, profileID: ProfileID(), lifetime: current.key.lifetime
        )
        let foreignLifetime = BrowserDownloadKey(
            id: current.key.id, profileID: current.key.profileID, lifetime: UUID()
        )
        let missing = BrowserDownloadKey(id: UUID(), profileID: current.key.profileID, lifetime: UUID())
        for (key, error) in [
            (foreignProfile, BrowserDownloadError.profileMismatch),
            (foreignLifetime, .staleLifetime), (missing, .unknownDownload)
        ] {
            #expect(throws: error) {
                try coordinator.perform(.cancel, in: .init(key: key, revision: current.revision))
            }
            #expect(coordinator.snapshot(for: key) == nil)
        }
        #expect(transfer.actions.isEmpty)
        coordinator.shutdown()
    }

    @Test("Updates cannot forge another download or profile through a registration callback")
    func callbackIdentity() throws {
        let coordinator = BrowserDownloadCoordinator()
        let registration = try register(coordinator, DownloadTransfer())
        let foreign = BrowserDownloadKey(id: UUID(), profileID: registration.key.profileID, lifetime: UUID())
        #expect(rejection(registration.report(.init(key: foreign, sequence: 1, state: .running))) == .unknownDownload)
        let otherProfile = BrowserDownloadKey(
            id: registration.key.id, profileID: ProfileID(), lifetime: registration.key.lifetime
        )
        #expect(rejection(registration.report(.init(key: otherProfile, sequence: 1, state: .running))) == .profileMismatch)
        let otherLifetime = BrowserDownloadKey(
            id: registration.key.id, profileID: registration.key.profileID, lifetime: UUID()
        )
        #expect(rejection(registration.report(.init(key: otherLifetime, sequence: 1, state: .running))) == .staleLifetime)
        #expect(try value(coordinator, registration).sequence == 0)
        coordinator.shutdown()
    }

    @Test("Unknown totals, sequence ordering and cumulative bytes survive pause and resume")
    func progressAndSequence() throws {
        let coordinator = BrowserDownloadCoordinator()
        let registration = try register(coordinator, DownloadTransfer())
        #expect(rejection(report(registration, sequence: 0)) == .staleSequence)
        _ = report(registration, sequence: 2, received: 7)
        let current = try value(coordinator, registration)
        #expect(current.totalBytes == nil && current.progressFraction == nil)
        #expect(rejection(report(registration, sequence: 1, received: 8)) == .staleSequence)
        #expect(rejection(report(registration, sequence: 2, received: 8)) == .staleSequence)
        #expect(rejection(report(registration, sequence: 3, received: 6)) == .invalidUpdate)
        #expect(rejection(report(registration, sequence: 3, received: 7, total: -1)) == .invalidUpdate)
        #expect(try value(coordinator, registration) == current)
        _ = report(registration, sequence: 3, state: .paused, received: 7, total: 12)
        _ = report(registration, sequence: 4, state: .running, received: 9)
        _ = report(registration, sequence: 5, state: .complete, received: 9, total: 12)
        let complete = try value(coordinator, registration)
        #expect(complete.receivedBytes == 9 && complete.totalBytes == 12)
        #expect(complete.progressFraction == 0.75)
        #expect(rejection(report(registration, sequence: 6, received: 10)) == .terminalState)
        #expect(try value(coordinator, registration) == complete)
    }

    @Test("Invalid reports do not publish or modify state")
    func invalidUpdates() throws {
        let coordinator = BrowserDownloadCoordinator()
        let registration = try register(coordinator, DownloadTransfer())
        _ = report(registration, received: 4)
        let original = try value(coordinator, registration)
        var changes = 0
        coordinator.onChange = { changes += 1 }
        #expect(rejection(report(registration, sequence: 2, state: .awaitingDestination, received: 4)) == .invalidTransition)
        #expect(rejection(report(registration, sequence: 2, state: .failed, received: 4)) == .invalidUpdate)
        #expect(rejection(report(registration, sequence: 2, received: 4, failure: .network)) == .invalidUpdate)
        #expect(rejection(registration.report(.init(
            key: registration.key, sequence: 2, state: .running, receivedBytes: 4,
            destinationURL: URL(string: "https://synthetic.test/not-a-file")
        ))) == .invalidUpdate)
        #expect(try value(coordinator, registration) == original)
        #expect(changes == 0)
        coordinator.shutdown()
    }

    @Test("Every widget action requires the captured current revision")
    func staleRevision() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        let stale = try value(coordinator, registration).context
        _ = report(registration)
        #expect(throws: BrowserDownloadError.staleRevision) { try coordinator.perform(.cancel, in: stale) }
        #expect(throws: BrowserDownloadError.staleRevision) { try coordinator.remove(in: stale) }
        #expect(throws: BrowserDownloadError.staleRevision) { try coordinator.setFileAvailability(.missing, in: stale) }
        #expect(transfer.actions.isEmpty)
        coordinator.shutdown()
    }

    @Test("Pause and resume await engine reports without replaying a URL or inventing state")
    func pauseResumeControls() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        _ = report(registration, received: 5, total: 20)
        try coordinator.perform(.pause, in: value(coordinator, registration).context)
        let pending = try value(coordinator, registration)
        #expect(pending.state == .running && pending.pendingAction == .pause)
        #expect(throws: BrowserDownloadError.actionPending) {
            try coordinator.perform(.pause, in: pending.context)
        }
        _ = report(registration, sequence: 2, state: .paused, received: 5, total: 20)
        transfer.completions[0](.success(()))
        try coordinator.perform(.resume, in: value(coordinator, registration).context)
        #expect(try value(coordinator, registration).state == .paused)
        transfer.completions[1](.success(()))
        _ = report(registration, sequence: 3, received: 8, total: 20)
        #expect(try value(coordinator, registration).state == .running)
        #expect(transfer.actions == [.pause, .resume])
        #expect(transfer.maximumDepth == 1)
        coordinator.shutdown()
    }

    @Test("Missing native pause or resume support is rejected until the adapter has a real handle")
    func actualCapabilities() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        _ = report(registration, capabilities: [.cancel])
        #expect(throws: BrowserDownloadError.unsupportedOperation) {
            try coordinator.perform(.pause, in: value(coordinator, registration).context)
        }
        _ = report(registration, sequence: 2, state: .interrupted, capabilities: [.cancel], failure: .network)
        #expect(throws: BrowserDownloadError.unsupportedOperation) {
            try coordinator.perform(.resume, in: value(coordinator, registration).context)
        }
        _ = report(registration, sequence: 3, state: .interrupted, capabilities: [.cancel, .resume])
        try coordinator.perform(.resume, in: value(coordinator, registration).context)
        transfer.completions[0](.failure(.unsupportedOperation))
        let rejected = try value(coordinator, registration)
        #expect(rejected.state == .interrupted && rejected.controlError == .unsupportedOperation)
        #expect(rejected.pendingAction == nil && rejected.receivedBytes == 0)
        coordinator.shutdown()
    }

    @Test("Cancel supersedes pending resume, rejects nonterminal updates, and awaits an engine outcome")
    func cancelSupersedesResume() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        _ = report(registration, state: .interrupted, received: 4)
        try coordinator.perform(.resume, in: value(coordinator, registration).context)
        try coordinator.perform(.cancel, in: value(coordinator, registration).context)
        let cancelling = try value(coordinator, registration)
        #expect(cancelling.state == .interrupted && cancelling.isCancellationRequested)
        #expect(cancelling.pendingAction == .cancel)
        transfer.completions[0](.success(()))
        #expect(try value(coordinator, registration) == cancelling)
        #expect(rejection(report(registration, sequence: 2, received: 5)) == .cancellationRequested)
        transfer.completions[1](.success(()))
        #expect(try value(coordinator, registration).state == .interrupted)
        #expect(throws: BrowserDownloadError.cancellationRequested) {
            try coordinator.perform(.resume, in: value(coordinator, registration).context)
        }
        _ = report(registration, sequence: 3, state: .cancelled, received: 6)
        #expect(try value(coordinator, registration).state == .cancelled)
        #expect(try value(coordinator, registration).receivedBytes == 6)
        #expect(transfer.invalidations == 1)
        #expect(rejection(report(registration, sequence: 4, state: .complete, received: 8)) == .terminalState)
    }

    @Test("Rejected cancellation retains intent and allows explicit cancellation retry")
    func cancellationFailure() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        _ = report(registration, received: 5)
        try coordinator.perform(.cancel, in: value(coordinator, registration).context)
        transfer.completions[0](.failure(.transferRejected))
        let rejected = try value(coordinator, registration)
        #expect(rejected.state == .running && rejected.isCancellationRequested)
        #expect(!rejected.isCancellationAccepted && rejected.canPerform(.cancel))
        #expect(rejected.pendingAction == nil && rejected.controlError == .transferRejected)
        try coordinator.perform(.cancel, in: rejected.context)
        #expect(transfer.actions == [.cancel, .cancel])
        transfer.completions[0](.success(()))
        #expect(try value(coordinator, registration).pendingAction == .cancel)
        #expect(try value(coordinator, registration).isCancellationAccepted == false)
        transfer.completions[1](.success(()))
        let accepted = try value(coordinator, registration)
        #expect(accepted.isCancellationAccepted && !accepted.canPerform(.cancel))
        #expect(throws: BrowserDownloadError.cancellationRequested) {
            try coordinator.perform(.cancel, in: accepted.context)
        }
        #expect(transfer.actions == [.cancel, .cancel])
        _ = report(registration, sequence: 2, state: .failed, received: 5, failure: .engineFailure)
        #expect(try value(coordinator, registration).state == .failed)
        #expect(try value(coordinator, registration).failure == .engineFailure)
    }

    @Test("Reentrant observers cancel a queued resume before it reaches the adapter")
    func observerRevokesQueuedControl() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        _ = report(registration, state: .interrupted)
        coordinator.onChange = {
            guard let state = coordinator.snapshot(for: registration.key), state.pendingAction == .resume else { return }
            try? coordinator.perform(.cancel, in: state.context)
        }
        try coordinator.perform(.resume, in: value(coordinator, registration).context)
        #expect(transfer.actions == [.cancel])
        #expect(try value(coordinator, registration).pendingAction == .cancel)
        coordinator.onChange = nil
        coordinator.shutdown()
        #expect(transfer.actions == [.cancel] && transfer.invalidations == 1)
    }

    @Test("Synchronous reports and observer shutdown never nest native controls or revive callbacks")
    func reentrantShutdown() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        _ = report(registration)
        var lateResult: BrowserDownloadError?
        transfer.onPerform = { action in
            if action == .pause {
                _ = report(registration, sequence: 2, state: .paused)
            } else {
                lateResult = rejection(report(registration, sequence: 3, state: .cancelled))
            }
        }
        coordinator.onChange = {
            if coordinator.snapshot(for: registration.key)?.state == .paused { coordinator.shutdown() }
        }
        try coordinator.perform(.pause, in: value(coordinator, registration).context)
        #expect(coordinator.isClosed && lateResult == .coordinatorStopped)
        #expect(transfer.actions == [.pause, .cancel])
        #expect(transfer.invalidations == 1 && transfer.maximumDepth == 1)
        let closed = try value(coordinator, registration)
        transfer.completions[0](.success(()))
        #expect(try value(coordinator, registration) == closed)
    }

    @Test("A synchronous terminal report invalidates only after the native control returns")
    func synchronousTerminalReport() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        _ = report(registration)
        transfer.onPerform = { action in
            #expect(action == .cancel)
            _ = report(registration, sequence: 2, state: .cancelled)
            #expect(transfer.invalidations == 0)
            transfer.completions[0](.success(()))
        }
        try coordinator.perform(.cancel, in: value(coordinator, registration).context)
        #expect(try value(coordinator, registration).state == .cancelled)
        #expect(transfer.invalidations == 1 && transfer.maximumDepth == 1)
    }

    @Test("Shutdown revokes every callback before cancelling owned active transfers")
    func shutdownOwnership() throws {
        let coordinator = BrowserDownloadCoordinator()
        let active = DownloadTransfer()
        let awaiting = DownloadTransfer()
        let complete = DownloadTransfer()
        let a = try register(coordinator, active)
        let b = try register(coordinator, awaiting)
        let c = try register(coordinator, complete)
        _ = report(a)
        _ = report(c, state: .complete)
        var callbackRejections: [BrowserDownloadError?] = []
        active.onPerform = { _ in callbackRejections.append(rejection(report(a, sequence: 2, state: .cancelled))) }
        awaiting.onPerform = { _ in callbackRejections.append(rejection(report(b, state: .cancelled))) }
        coordinator.shutdown()
        coordinator.shutdown()
        #expect(callbackRejections == [.coordinatorStopped, .coordinatorStopped])
        #expect(active.actions == [.cancel] && awaiting.actions == [.cancel])
        #expect(complete.actions.isEmpty)
        #expect(active.invalidations == 1 && awaiting.invalidations == 1 && complete.invalidations == 1)
        #expect(try value(coordinator, a).state == .running)
        #expect(try value(coordinator, b).state == .awaitingDestination)
        #expect(try value(coordinator, c).state == .complete)
        #expect(throws: BrowserDownloadError.coordinatorStopped) { try register(coordinator, DownloadTransfer()) }
        #expect(throws: BrowserDownloadError.coordinatorStopped) {
            try coordinator.perform(.cancel, in: value(coordinator, a).context)
        }
    }

    @Test("Observer disposal revokes queued work before adapter calls")
    func disposeBeforeDispatch() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        _ = report(registration)
        coordinator.onChange = {
            if coordinator.snapshot(for: registration.key)?.pendingAction == .pause { coordinator.shutdown() }
        }
        try coordinator.perform(.pause, in: value(coordinator, registration).context)
        #expect(transfer.actions == [.cancel])
        #expect(transfer.invalidations == 1)
        #expect(rejection(report(registration, sequence: 2, state: .complete)) == .coordinatorStopped)
    }

    @Test("A retained registration and action completion do not retain the coordinator")
    func weakCoordinatorLifetime() throws {
        var coordinator: BrowserDownloadCoordinator? = BrowserDownloadCoordinator()
        let weakCoordinator = WeakDownloadObject(coordinator)
        let transfer = DownloadTransfer()
        let registration = try register(try #require(coordinator), transfer)
        _ = report(registration)
        try coordinator?.perform(.pause, in: value(try #require(coordinator), registration).context)
        coordinator = nil
        #expect(weakCoordinator.value == nil)
        #expect(rejection(report(registration, sequence: 2, state: .complete)) == .coordinatorStopped)
        transfer.completions[0](.success(()))
        #expect(weakCoordinator.value == nil)
    }

    @Test("File metadata may change after completion without changing the transfer outcome")
    func completedFileAvailability() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        _ = report(registration, state: .complete, received: 3, total: 9)
        let complete = try value(coordinator, registration)
        try coordinator.setFileAvailability(.available, in: complete.context)
        let available = try value(coordinator, registration)
        #expect(available.state == .complete && available.revision == complete.revision + 1)
        #expect(available.fileAvailability == .available && available.receivedBytes == 3)
        #expect(throws: BrowserDownloadError.staleRevision) {
            try coordinator.setFileAvailability(.missing, in: complete.context)
        }
        try coordinator.setFileAvailability(.missing, in: available.context)
        let missing = try value(coordinator, registration)
        #expect(missing.state == .complete && missing.failure == nil)
        #expect(missing.fileAvailability == .missing && missing.sequence == complete.sequence)
        #expect(missing.totalBytes == 9 && missing.capabilities.isEmpty)
        #expect(transfer.invalidations == 1 && transfer.actions.isEmpty)
    }

    @Test("Removal requires a terminal record and old lifetimes cannot affect a reused UUID")
    func removalAndLifetimeReuse() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let old = try register(coordinator, transfer)
        #expect(throws: BrowserDownloadError.activeDownload) {
            try coordinator.remove(in: value(coordinator, old).context)
        }
        #expect(transfer.actions.isEmpty && transfer.invalidations == 0)
        _ = report(old, state: .complete)
        let terminal = try value(coordinator, old)
        #expect(throws: BrowserDownloadError.terminalState) {
            try coordinator.perform(.cancel, in: terminal.context)
        }
        try coordinator.remove(in: terminal.context)
        #expect(coordinator.snapshot(for: old.key) == nil)
        let replacement = try register(coordinator, DownloadTransfer(), profileID: old.key.profileID, id: old.key.id)
        #expect(replacement.key.lifetime != old.key.lifetime)
        #expect(rejection(report(old, sequence: 2)) == .staleLifetime)
        #expect(throws: BrowserDownloadError.staleLifetime) {
            try coordinator.perform(.cancel, in: terminal.context)
        }
        #expect(try value(coordinator, replacement).state == .awaitingDestination)
        #expect(transfer.invalidations == 1 && transfer.actions.isEmpty)
        coordinator.shutdown()
    }

    @Test("One transfer adapter cannot be registered twice or cross a profile boundary")
    func duplicateAdapterRejected() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        _ = try register(coordinator, transfer)
        #expect(throws: BrowserDownloadError.duplicateTransfer) { try register(coordinator, transfer) }
        #expect(transfer.actions.isEmpty && transfer.invalidations == 0)
        coordinator.shutdown()
        #expect(transfer.actions == [.cancel] && transfer.invalidations == 1)
    }

    @Test("Reentrant engine reports revoke queued controls that lose their state or capability")
    func queuedControlRevalidation() throws {
        for losesCapability in [true, false] {
            let coordinator = BrowserDownloadCoordinator()
            let transfer = DownloadTransfer()
            let registration = try register(coordinator, transfer)
            _ = report(registration)
            coordinator.onChange = {
                guard let state = coordinator.snapshot(for: registration.key),
                      state.pendingAction == .pause, state.sequence == 1 else { return }
                _ = report(
                    registration, sequence: 2, state: losesCapability ? .running : .interrupted,
                    capabilities: losesCapability ? [.cancel] : [.cancel, .pause, .resume]
                )
            }
            try coordinator.perform(.pause, in: value(coordinator, registration).context)
            let changed = try value(coordinator, registration)
            #expect(changed.pendingAction == nil)
            #expect(changed.controlError == (losesCapability ? .unsupportedOperation : .invalidState))
            #expect(transfer.actions.isEmpty)
            coordinator.onChange = nil
            coordinator.shutdown()
        }
    }

    @Test("Disposal during initial publication prevents an adapter from starting after registration")
    func registrationDisposedReentrantly() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        coordinator.onChange = { coordinator.shutdown() }
        #expect(throws: BrowserDownloadError.coordinatorStopped) { try register(coordinator, transfer) }
        #expect(transfer.actions == [.cancel] && transfer.invalidations == 1)
    }

    @Test("A successful cancel acknowledgement rejects repeats until the terminal report")
    func acceptedCancellationCannotRepeat() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        _ = report(registration, received: 9)
        try coordinator.perform(.cancel, in: value(coordinator, registration).context)
        transfer.completions[0](.success(()))
        let accepted = try value(coordinator, registration)
        #expect(accepted.state == .running && accepted.pendingAction == nil)
        #expect(accepted.isCancellationRequested && accepted.isCancellationAccepted)
        #expect(!accepted.canPerform(.cancel))
        #expect(throws: BrowserDownloadError.cancellationRequested) {
            try coordinator.perform(.cancel, in: accepted.context)
        }
        #expect(try value(coordinator, registration) == accepted)
        #expect(transfer.actions == [.cancel])
        transfer.completions[0](.failure(.transferRejected))
        #expect(try value(coordinator, registration) == accepted)
        #expect(rejection(report(registration, sequence: 2, state: .complete, received: 9)) == nil)
        #expect(try value(coordinator, registration).state == .complete)
        #expect(transfer.actions == [.cancel] && transfer.invalidations == 1)
    }

    @Test("Accepted cancellation remains single dispatch during a synchronous acknowledgement")
    func synchronousCancellationAcknowledgement() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        _ = report(registration)
        var attemptedRepeat = false
        coordinator.onChange = {
            guard let current = coordinator.snapshot(for: registration.key),
                  current.isCancellationAccepted, !attemptedRepeat else { return }
            attemptedRepeat = true
            #expect(throws: BrowserDownloadError.cancellationRequested) {
                try coordinator.perform(.cancel, in: current.context)
            }
        }
        transfer.onPerform = { _ in transfer.completions[0](.success(())) }
        try coordinator.perform(.cancel, in: value(coordinator, registration).context)
        #expect(attemptedRepeat && transfer.actions == [.cancel])
        coordinator.onChange = nil
        coordinator.shutdown()
        #expect(transfer.actions == [.cancel] && transfer.invalidations == 1)
        #expect(transfer.maximumDepth == 1)
    }

    @Test("Adapter reservations survive terminal observers, removal and reentrant invalidation")
    func terminalAdapterCannotCrossProfiles() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let profileA = ProfileID()
        let profileB = ProfileID()
        let registration = try register(coordinator, transfer, profileID: profileA)
        var observedTerminal = false
        var observedInvalidation = false
        coordinator.onChange = {
            guard let current = coordinator.snapshot(for: registration.key),
                  current.state == .complete, !observedTerminal else { return }
            observedTerminal = true
            #expect(transfer.invalidations == 0)
            #expect(throws: BrowserDownloadError.duplicateTransfer) {
                try register(coordinator, transfer, profileID: profileB)
            }
            try? coordinator.remove(in: current.context)
            #expect(throws: BrowserDownloadError.duplicateTransfer) {
                try register(coordinator, transfer, profileID: profileB)
            }
        }
        transfer.onInvalidate = {
            observedInvalidation = true
            #expect(throws: BrowserDownloadError.duplicateTransfer) {
                try register(coordinator, transfer, profileID: profileB)
            }
        }
        _ = report(registration, state: .complete)
        #expect(observedTerminal && observedInvalidation)
        #expect(coordinator.snapshots(profileID: profileA).isEmpty)
        #expect(coordinator.snapshots(profileID: profileB).isEmpty)
        #expect(throws: BrowserDownloadError.duplicateTransfer) {
            try register(coordinator, transfer, profileID: profileB)
        }
        #expect(transfer.invalidations == 1 && transfer.actions.isEmpty)
        coordinator.onChange = nil
        coordinator.shutdown()
    }

    @Test("Retired adapter reservations do not retain the adapter or prevent fresh registrations")
    func retiredAdapterReservationIsWeak() throws {
        let coordinator = BrowserDownloadCoordinator()
        var transfer: DownloadTransfer? = DownloadTransfer()
        let weakTransfer = WeakDownloadObject(transfer)
        let registration = try register(coordinator, try #require(transfer))
        _ = report(registration, state: .complete)
        transfer = nil
        #expect(weakTransfer.value == nil)
        try coordinator.remove(in: value(coordinator, registration).context)
        let fresh = try register(coordinator, DownloadTransfer())
        #expect(try value(coordinator, fresh).state == .awaitingDestination)
        coordinator.shutdown()
    }

    @Test("A rejected cancel command does not block an authoritative sequenced completion")
    func rejectedCancellationCanStillComplete() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        _ = report(registration, received: 5)
        try coordinator.perform(.cancel, in: value(coordinator, registration).context)
        transfer.completions[0](.failure(.transferRejected))
        let rejected = try value(coordinator, registration)
        #expect(rejected.isCancellationRequested && !rejected.isCancellationAccepted)
        #expect(rejected.state == .running && rejected.controlError == .transferRejected)
        #expect(rejection(report(registration, sequence: 1, state: .complete, received: 7)) == .staleSequence)
        let staleKey = BrowserDownloadKey(
            id: registration.key.id, profileID: registration.key.profileID, lifetime: UUID()
        )
        #expect(rejection(registration.report(.init(
            key: staleKey, sequence: 2, state: .complete, receivedBytes: 7
        ))) == .staleLifetime)
        #expect(try value(coordinator, registration) == rejected)
        #expect(rejection(report(registration, sequence: 2, state: .complete, received: 7, total: 11)) == nil)
        let completed = try value(coordinator, registration)
        #expect(completed.state == .complete && completed.receivedBytes == 7 && completed.totalBytes == 11)
        #expect(completed.pendingAction == nil && completed.controlError == nil && completed.failure == nil)
        #expect(transfer.actions == [.cancel] && transfer.invalidations == 1)
        transfer.completions[0](.success(()))
        #expect(try value(coordinator, registration) == completed)
        #expect(rejection(report(registration, sequence: 3, state: .cancelled, received: 7)) == .terminalState)
        try coordinator.remove(in: completed.context)
        #expect(coordinator.snapshot(for: registration.key) == nil)
        coordinator.shutdown()
        #expect(transfer.actions == [.cancel] && transfer.invalidations == 1)
    }

    @Test("Reentrant completion before native cancel dispatch retires the adapter without cancelling it")
    func completionBeforeCancellationDispatch() throws {
        let coordinator = BrowserDownloadCoordinator()
        let transfer = DownloadTransfer()
        let registration = try register(coordinator, transfer)
        _ = report(registration, received: 5)
        var completedReentrantly = false
        coordinator.onChange = {
            guard let current = coordinator.snapshot(for: registration.key),
                  current.pendingAction == .cancel, !completedReentrantly else { return }
            completedReentrantly = true
            #expect(transfer.actions.isEmpty && transfer.invalidations == 0)
            #expect(rejection(report(
                registration, sequence: 2, state: .complete, received: 6, total: 9
            )) == nil)
            #expect(transfer.actions.isEmpty && transfer.invalidations == 0)
        }
        try coordinator.perform(.cancel, in: value(coordinator, registration).context)
        let completed = try value(coordinator, registration)
        #expect(completedReentrantly && completed.state == .complete)
        #expect(completed.isCancellationRequested && !completed.isCancellationAccepted)
        #expect(completed.pendingAction == nil && completed.receivedBytes == 6)
        #expect(transfer.actions.isEmpty && transfer.invalidations == 1)
        #expect(rejection(report(registration, sequence: 3, state: .cancelled, received: 6)) == .terminalState)
        coordinator.onChange = nil
        coordinator.shutdown()
        #expect(transfer.actions.isEmpty && transfer.invalidations == 1)
    }
}
