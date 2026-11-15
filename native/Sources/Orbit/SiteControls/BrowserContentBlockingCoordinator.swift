import BrowserCore
import BrowserEngine
import Foundation

/// Keeps each prepared profile's built-in blocker in step with its Settings switch and the
/// per-site exceptions. Only profiles prepared in this launch are configured; a profile is
/// prepared before its first page loads.
///
/// Private windows share one engine configuration (the private session). Each window follows
/// its parent profile's switch and persistent exceptions, read-only; exceptions added in a
/// private window live here, in memory, until the last private window closes. When open private
/// windows have different parents, blocking needs every parent's switch on, and every parent's
/// exceptions apply.
@MainActor
final class BrowserContentBlockingCoordinator {
    private let blocker: any BrowserContentBlocking
    private let isEnabled: (ProfileID) -> Bool
    private let exceptions: (ProfileID) -> [String]
    private var applied: [ProfileID: BrowserContentBlockingConfiguration] = [:]
    private var prepared: Set<ProfileID> = []
    private var privateParents: [UUID: ProfileID] = [:]
    private var privateExceptions: Set<String> = []
    private var privateApplied: BrowserContentBlockingConfiguration?
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
        if applied[profileID] != next {
            do {
                try await blocker.configure(next, profileID: profileID, waitsForAcknowledgement: waitsForAcknowledgement)
                applied[profileID] = next
            } catch {
                applied[profileID] = nil
                onError?(error)
            }
        }
        // A parent's persistent exceptions also apply in its private windows.
        if privateParents.values.contains(profileID) { await synchronizePrivate() }
    }

    func synchronizePrepared() async {
        for profile in prepared.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            await synchronize(profile)
        }
        await synchronizePrivate()
    }

    func forget(_ profileID: ProfileID) {
        prepared.remove(profileID)
        applied[profileID] = nil
    }

    // MARK: Private windows

    var supportsPrivateWindows: Bool { blocker.supportsPrivateWindows }

    /// True while private windows are filtered: at least one is open, every parent's switch is on
    /// and the engine accepted that configuration.
    var blocksPrivately: Bool { wantsPrivateBlocking && privateApplied?.isEnabled == true }

    private var wantsPrivateBlocking: Bool {
        !privateParents.isEmpty && Set(privateParents.values).allSatisfy(isEnabled)
    }

    var privateConfiguration: BrowserContentBlockingConfiguration {
        guard wantsPrivateBlocking else { return .init(isEnabled: false) }
        let inherited = Set(privateParents.values).flatMap(exceptions)
        return .init(isEnabled: true, allowedHosts: inherited + privateExceptions)
    }

    /// The site row's state for `host` in a private window. A parent's persistent exception
    /// shows as allowed and cannot be changed from the private window.
    func privateSiteState(host: String) -> (blocked: Bool, editable: Bool) {
        let host = host.lowercased()
        if Set(privateParents.values).contains(where: { exceptions($0).contains(host) }) { return (false, false) }
        return (!privateExceptions.contains(host), true)
    }

    /// Readies the engine before a private window's context is created. False when private
    /// windows cannot be filtered; the window then opens without blocking or its row.
    func preparePrivateWindow() async -> Bool {
        guard blocker.supportsPrivateWindows else { return false }
        do { try await blocker.preparePrivateWindows(); return true }
        catch { onError?(error); return false }
    }

    /// Registers a private window before its first page, then applies the session's configuration
    /// to every open private context, the new one included.
    func openPrivateWindow(_ id: UUID, parent: ProfileID) async {
        privateParents[id] = parent
        privateApplied = nil
        await synchronizePrivate(waitsForAcknowledgement: true)
    }

    /// The last private window ends the session: its exceptions are forgotten and the private
    /// configuration turns off.
    func closePrivateWindow(_ id: UUID) async {
        endPrivateWindow(id)
        await synchronizePrivate()
    }

    /// The bookkeeping half of `closePrivateWindow`, effective at once, so a window opened right
    /// after the last one closed starts a fresh session even before the engine is updated.
    func endPrivateWindow(_ id: UUID) {
        guard privateParents.removeValue(forKey: id) != nil, privateParents.isEmpty else { return }
        privateExceptions.removeAll()
        privateApplied = nil
        blocker.endPrivateWindowSession()
    }

    /// Records a private exception at once (the row shows it); `synchronizePrivate` applies it.
    @discardableResult
    func setPrivateException(host: String, allowed: Bool) -> Bool {
        guard !privateParents.isEmpty, BrowserContentBlockingConfiguration.isHost(host.lowercased()) else { return false }
        if allowed { privateExceptions.insert(host.lowercased()) } else { privateExceptions.remove(host.lowercased()) }
        return true
    }

    /// Applies the session's configuration to the open private contexts when it changed.
    func synchronizePrivate(waitsForAcknowledgement: Bool = false) async {
        guard blocker.supportsPrivateWindows, !privateParents.isEmpty else { return }
        let next = privateConfiguration
        guard privateApplied != next else { return }
        do {
            try await blocker.configurePrivateWindows(next, waitsForAcknowledgement: waitsForAcknowledgement)
            privateApplied = next
        } catch {
            privateApplied = nil
            onError?(error)
        }
    }
}
