import BrowserCore
import Foundation
import Testing

@Suite("Engine-independent download values")
struct BrowserDownloadTests {
    private func snapshot(
        state: BrowserDownloadState = .running, received: Int64 = 3, total: Int64? = nil,
        capabilities: BrowserDownloadCapabilities = [.cancel, .pause, .resume],
        pending: BrowserDownloadAction? = nil, cancelling: Bool = false,
        cancellationAccepted: Bool = false, controlError: BrowserDownloadError? = nil
    ) -> BrowserDownloadSnapshot {
        let owner = BrowserDownloadOwner(profileID: ProfileID())
        return BrowserDownloadSnapshot(
            key: .init(id: UUID(), profileID: owner.profileID, lifetime: UUID()),
            owner: owner, revision: 12, sequence: 4, suggestedFilename: "private-output.dat",
            state: state, receivedBytes: received, totalBytes: total, capabilities: capabilities,
            currentURL: URL(string: "https://synthetic.test/private?token=private-token"),
            destinationURL: URL(fileURLWithPath: "/synthetic/private-output.dat"),
            fileAvailability: .unknown, failure: nil, pendingAction: pending,
            isCancellationRequested: cancelling, controlError: controlError,
            isCancellationAccepted: cancellationAccepted
        )
    }

    @Test("Transfer outcomes are final while interruptions and pauses retain a lifetime")
    func transitions() {
        let expected: [(BrowserDownloadState, [BrowserDownloadState])] = [
            (.awaitingDestination, [.awaitingDestination, .running, .paused, .interrupted, .complete, .cancelled, .failed]),
            (.running, [.running, .paused, .interrupted, .complete, .cancelled, .failed]),
            (.paused, [.running, .paused, .interrupted, .complete, .cancelled, .failed]),
            (.interrupted, [.running, .paused, .interrupted, .complete, .cancelled, .failed]),
            (.complete, []), (.cancelled, []), (.failed, [])
        ]
        for (state, destinations) in expected {
            #expect(state.isTerminal == [.complete, .cancelled, .failed].contains(state))
            for (next, _) in expected {
                #expect(state.canTransition(to: next) == destinations.contains(next))
            }
        }
    }

    @Test("Unknown, empty and estimated totals never inflate the exact received-byte count")
    func progressKnowledge() {
        let unknown = snapshot(received: 43)
        #expect(unknown.totalBytes == nil && unknown.progressFraction == nil)
        let empty = snapshot(state: .complete, received: 0, total: 0)
        #expect(empty.progressFraction == nil && empty.receivedBytes == 0)
        let complete = snapshot(state: .complete, received: 7, total: 10)
        #expect(complete.progressFraction == 0.7 && complete.receivedBytes == 7)
        let underestimated = snapshot(received: 12, total: 10)
        #expect(underestimated.progressFraction == 1 && underestimated.receivedBytes == 12)
    }

    @Test("Menu eligibility combines engine capability, state and outstanding control intent")
    func controlEligibility() {
        #expect(snapshot(capabilities: [.cancel]).canPerform(.pause) == false)
        #expect(snapshot().canPerform(.pause))
        #expect(snapshot().canPerform(.resume) == false)
        #expect(snapshot(state: .interrupted).canPerform(.resume))
        #expect(snapshot(state: .interrupted, capabilities: [.cancel]).canPerform(.resume) == false)
        #expect(snapshot(state: .paused).canPerform(.resume))
        #expect(snapshot(pending: .pause).canPerform(.pause) == false)
        #expect(snapshot(pending: .pause).canPerform(.cancel))
        #expect(snapshot(pending: .cancel).canPerform(.cancel) == false)
        #expect(snapshot(state: .interrupted, cancelling: true).canPerform(.resume) == false)
        for state in [BrowserDownloadState.complete, .cancelled, .failed] {
            for action in [BrowserDownloadAction.pause, .resume, .cancel] {
                #expect(snapshot(state: state).canPerform(action) == false)
            }
        }
    }

    @Test("Accepted cancellation stays disabled while an explicitly rejected command permits retry")
    func cancellationAcknowledgementEligibility() {
        let waiting = snapshot(pending: .cancel, cancelling: true)
        #expect(!waiting.canPerform(.cancel) && !waiting.isCancellationAccepted)
        let accepted = snapshot(cancelling: true, cancellationAccepted: true)
        #expect(accepted.pendingAction == nil && !accepted.canPerform(.cancel))
        #expect(!accepted.canPerform(.pause) && !accepted.canPerform(.resume))
        let rejected = snapshot(cancelling: true, controlError: .transferRejected)
        #expect(rejected.canPerform(.cancel) && !rejected.isCancellationAccepted)
        #expect(!rejected.canPerform(.pause) && !rejected.canPerform(.resume))
    }

    @Test("The widget context captures profile, download lifetime and revision by value")
    func exactContext() {
        let value = snapshot()
        #expect(value.context == .init(key: value.key, revision: 12))
        let otherLifetime = BrowserDownloadKey(
            id: value.key.id, profileID: value.key.profileID, lifetime: UUID()
        )
        #expect(otherLifetime != value.key)
        #expect(BrowserDownloadContext(key: otherLifetime, revision: 12) != value.context)
        #expect(BrowserDownloadContext(key: value.key, revision: 13) != value.context)
    }

    @Test("Default value diagnostics redact URLs, paths, filenames and query credentials")
    func redactedDescriptions() {
        let value = snapshot()
        let update = BrowserDownloadUpdate(
            key: value.key, sequence: 1, state: .running,
            currentURL: value.currentURL, destinationURL: value.destinationURL
        )
        for description in [
            String(describing: value), String(reflecting: value),
            String(describing: update), String(reflecting: update)
        ] {
            #expect(!description.contains("synthetic.test"))
            #expect(!description.contains("private"))
            #expect(!description.contains("/synthetic/"))
        }
        #expect(BrowserDownloadFailure.engineFailure.rawValue == "engineFailure")
        #expect(BrowserDownloadError.transferRejected.rawValue == "transferRejected")
    }
}
