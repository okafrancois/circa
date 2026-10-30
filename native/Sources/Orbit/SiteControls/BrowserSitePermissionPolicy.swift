import BrowserCore
import BrowserEngine
import Foundation

/// Applies a single permission request. No engine default is used for unknown kinds or stale
/// requests. Prompt lifetime and context validation belong to the host, not the page.
@MainActor
final class BrowserSitePermissionPolicy {
    var store: BrowserSitePermissionStore
    var onPersistenceFailure: ((BrowserSitePermissionChoice) -> Void)?
    var onPersistedDecision: ((ProfileID, BrowserSiteOrigin, [BrowserSitePermission], BrowserSitePermissionSetting) async -> Void)?
    init(store: BrowserSitePermissionStore) { self.store = store }

    static func permissions(for kind: BrowserPermissionKind) -> [BrowserSitePermission]? {
        switch kind {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        case .geolocation: [.geolocation]
        case .notifications: [.notifications]
        case .other(let name): BrowserSitePermission(rawValue: name).map { [$0] }
        }
    }

    static func isTrustworthy(_ origin: BrowserSiteOrigin) -> Bool {
        let url = URL(string: origin.value)
        return url?.scheme == "https" || ["localhost", "127.0.0.1", "[::1]", "::1"].contains(url?.host ?? "")
    }

    func resolve(_ request: BrowserPermissionRequest, profileID: ProfileID,
                 isCurrent: @escaping @MainActor () -> Bool,
                 prompt: @escaping @MainActor (BrowserSiteOrigin, [BrowserSitePermission]) async -> BrowserSitePermissionChoice
    ) async -> BrowserPermissionDecision {
        guard isCurrent(), let origin = BrowserSiteOrigin(requestOrigin: request.origin),
              let permissions = Self.permissions(for: request.kind), !permissions.isEmpty else { return .deny }
        // No new hardware grants on insecure remote origins. Loopback is allowed for fixtures.
        guard Self.isTrustworthy(origin) else { return .deny }
        let state = await store.state(origin: origin, profileID: profileID)
        guard isCurrent() else { return .deny }
        guard state.isDurable else { onPersistenceFailure?(.dismiss); return .deny }
        let settings = permissions.map { state.settings[$0] ?? .ask }
        if settings.contains(.block) { return .deny }
        if settings.allSatisfy({ $0 == .allow }) { return .grant }
        let choice = await prompt(origin, permissions)
        guard isCurrent(), !Task.isCancelled else { return .deny }
        if choice == .dismiss { return .dismiss }
        do {
            let accepted = try await store.commit(choice, for: permissions, origin: origin,
                                                   profileID: profileID, expectedRevision: state.revision)
            guard accepted, isCurrent(), !Task.isCancelled else { return .deny }
            if choice == .block || choice == .alwaysAllow {
                await onPersistedDecision?(profileID, origin, permissions, choice == .block ? .block : .allow)
            }
            guard isCurrent(), !Task.isCancelled else { return .deny }
            switch choice {
            case .allowOnce: return .grantOnce
            case .alwaysAllow: return .grant
            case .block: return .deny
            case .dismiss: return .dismiss
            }
        } catch {
            if choice == .block { await onPersistedDecision?(profileID, origin, permissions, .block) }
            onPersistenceFailure?(choice)
            return .deny
        }
    }
}
