import Foundation

/// One captured edit. UI revocation is a short independent lock; it never waits
/// for file I/O. Once publication wins, cancellation cannot undo that commit.
public final class BrowserSpaceSettingsAuthority: @unchecked Sendable {
    public let id = UUID()
    public let spaceID: SpaceID
    public let profileID: ProfileID
    fileprivate let ownership: BrowserSpaceSettingsOwnership
    fileprivate let epoch: UUID
    fileprivate let source: (WindowID, UUID)?
    private let lock = NSLock()
    private enum State { case pending, revoked, admitted }
    private var state = State.pending

    fileprivate init(spaceID: SpaceID, profileID: ProfileID, ownership: BrowserSpaceSettingsOwnership,
                     epoch: UUID, source: (WindowID, UUID)?) {
        self.spaceID = spaceID; self.profileID = profileID
        self.ownership = ownership; self.epoch = epoch; self.source = source
    }

    public func revoke() {
        lock.withLock { if state == .pending { state = .revoked } }
    }

    fileprivate func admit() -> Bool {
        lock.withLock {
            guard state == .pending else { return false }
            state = .admitted
            return true
        }
    }

    func publish<T>(_ body: () throws -> T) throws -> T {
        try ownership.publish(self, body)
    }
}

/// Only BrowserStore changes ownership. Publication and catalog mutation share
/// a barrier; fast capture uses a separate snapshot lock. No callback or await
/// runs while catalog ownership is changing.
final class BrowserSpaceSettingsOwnership: @unchecked Sendable {
    private struct Entry: Equatable { let profile: ProfileID; let epoch: UUID }
    private let barrier = NSLock()
    private let snapshotLock = NSLock()
    private var spaces: [SpaceID: Entry] = [:]
    private var windows: [WindowID: Entry] = [:]

    func synchronize(spaces next: [SpaceID: BrowserSpace], profiles: Set<ProfileID>,
                     excluding: Set<ProfileID>, windows nextWindows: [WindowID: WindowRecord]) {
        let owners = next.filter { profiles.contains($0.value.profileID) && !excluding.contains($0.value.profileID) }
            .mapValues(\.profileID)
        let sources = nextWindows.compactMapValues { owners[$0.activeSpaceID] }
        if snapshotLock.withLock({ spaces.mapValues(\.profile) == owners && windows.mapValues(\.profile) == sources }) { return }
        barrier.lock()
        defer { barrier.unlock() }
        snapshotLock.withLock {
            let oldSpaces = spaces, oldWindows = windows
            spaces = owners.mapValuesWithKey { id, profile in
                oldSpaces[id]?.profile == profile ? oldSpaces[id]! : Entry(profile: profile, epoch: UUID())
            }
            windows = sources.mapValuesWithKey { id, profile in
                oldWindows[id]?.profile == profile ? oldWindows[id]! : Entry(profile: profile, epoch: UUID())
            }
        }
    }

    func capture(spaceID: SpaceID, profileID: ProfileID, sourceWindow: WindowID?, sourceProfile: ProfileID?) -> BrowserSpaceSettingsAuthority? {
        snapshotLock.withLock {
            guard let entry = spaces[spaceID], entry.profile == profileID else { return nil }
            var source: (WindowID, UUID)?
            if let sourceWindow {
                guard let window = windows[sourceWindow], window.profile == sourceProfile else { return nil }
                source = (sourceWindow, window.epoch)
            }
            return BrowserSpaceSettingsAuthority(spaceID: spaceID, profileID: profileID, ownership: self,
                                                 epoch: entry.epoch, source: source)
        }
    }

    func publish<T>(_ authority: BrowserSpaceSettingsAuthority, _ body: () throws -> T) throws -> T {
        barrier.lock()
        defer { barrier.unlock() }
        let current = snapshotLock.withLock {
            guard let entry = spaces[authority.spaceID], entry.profile == authority.profileID,
                  entry.epoch == authority.epoch else { return false }
            if let (window, epoch) = authority.source { return windows[window]?.epoch == epoch }
            return true
        }
        guard current, authority.admit() else { throw BrowserStoreError.staleContext }
        // The settings actor has already prepared its candidate. Only validation,
        // private file publication and memory assignment run inside this barrier.
        return try body()
    }
}

private extension Dictionary {
    func mapValuesWithKey<T>(_ transform: (Key, Value) -> T) -> [Key: T] {
        Dictionary<Key, T>(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}
