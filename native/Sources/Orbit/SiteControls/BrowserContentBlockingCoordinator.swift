import BrowserCore
import BrowserEngine

/// Keeps each prepared profile's built-in blocker in step with its Settings switch and the
/// per-site exceptions. Only profiles prepared in this launch are configured; a profile is
/// prepared before its first page loads.
@MainActor
final class BrowserContentBlockingCoordinator {
    private let blocker: any BrowserContentBlocking
    private let isEnabled: (ProfileID) -> Bool
    private let exceptions: (ProfileID) -> [String]
    private var applied: [ProfileID: BrowserContentBlockingConfiguration] = [:]
    private var prepared: Set<ProfileID> = []
    var onError: ((any Error) -> Void)?

    init(blocker: any BrowserContentBlocking, isEnabled: @escaping (ProfileID) -> Bool,
         exceptions: @escaping (ProfileID) -> [String]) {
        self.blocker = blocker
        self.isEnabled = isEnabled
        self.exceptions = exceptions
    }

    func blocks(in profileID: ProfileID) -> Bool { isEnabled(profileID) }

    func configuration(for profileID: ProfileID) -> BrowserContentBlockingConfiguration {
        let enabled = isEnabled(profileID)
        return .init(isEnabled: enabled, allowedHosts: enabled ? exceptions(profileID) : [])
    }

    /// Applies the profile's current configuration when it differs from the last applied one.
    func synchronize(_ profileID: ProfileID, waitsForAcknowledgement: Bool = false) async {
        prepared.insert(profileID)
        let next = configuration(for: profileID)
        guard applied[profileID] != next else { return }
        do {
            try await blocker.configure(next, profileID: profileID, waitsForAcknowledgement: waitsForAcknowledgement)
            applied[profileID] = next
        } catch {
            applied[profileID] = nil
            onError?(error)
        }
    }

    func synchronizePrepared() async {
        for profile in prepared.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            await synchronize(profile)
        }
    }

    func forget(_ profileID: ProfileID) {
        prepared.remove(profileID)
        applied[profileID] = nil
    }
}
