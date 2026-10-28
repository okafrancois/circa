import Foundation

/// Canonical HTTP(S) tuple origin. Paths, credentials and query strings are never retained.
public struct BrowserSiteOrigin: Hashable, Sendable, Codable {
    public let value: String

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        if let port = url.port {
            guard (1...65535).contains(port) else { return nil }
            if !(scheme == "https" && port == 443 || scheme == "http" && port == 80) { components.port = port }
        }
        guard let origin = components.url?.absoluteString else { return nil }
        value = origin
    }

    /// Engine requests must already be origins, not arbitrary page addresses.
    public init?(requestOrigin: String) {
        guard let url = URL(string: requestOrigin), url.path.isEmpty || url.path == "/",
              url.query == nil, url.fragment == nil else { return nil }
        self.init(url: url)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let origin = Self(requestOrigin: raw), origin.value == raw else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid permission origin")
        }
        self = origin
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Chrome site settings vocabulary. Availability and enforcement are engine capabilities,
/// not implied by the presence of a setting in this engine-independent catalog.
public enum BrowserSitePermission: String, CaseIterable, Codable, Sendable {
    case camera, microphone, geolocation, notifications, clipboardRead, clipboardWrite
    case autoplay, sound, popupsAndRedirects, automaticDownloads, screenSharing, midi, midiSysex
    case cookies, javascript, images, backgroundSync, sensors, usb, serial, bluetooth, hid
    case fileSystem, paymentHandler, idleDetection, windowManagement, localFonts, vr, ar
    case insecureContent, automaticPictureInPicture, capturedSurfaceControl, localNetwork

    /// Reconstruction defaults. Chromium must reconcile these with its content-settings map.
    public var defaultDecision: BrowserSitePermissionSetting {
        switch self {
        case .sound, .cookies, .javascript, .images, .backgroundSync, .sensors, .clipboardWrite: .allow
        case .popupsAndRedirects, .insecureContent: .block
        default: .ask
        }
    }

    /// A system picker or a fresh grant remains necessary for each screen capture.
    public var supportsPersistentAllow: Bool { self != .screenSharing }
}

public enum BrowserSitePermissionSetting: String, Codable, Sendable, CaseIterable {
    case ask, allow, block
}

public enum BrowserSitePermissionChoice: Sendable {
    case allowOnce, alwaysAllow, block, dismiss
}

public struct BrowserSitePermissionState: Sendable {
    public let settings: [BrowserSitePermission: BrowserSitePermissionSetting]
    public let revision: UInt64
    public let isDurable: Bool
}

public enum BrowserPermissionStoreError: Error, Equatable {
    case unsupportedVersion, duplicateEntry, invalidPersistentGrant, unavailable
}

/// One serialized authority shared by all windows. Nil destination is explicitly ephemeral.
/// Durable writes complete atomically before the in-memory state is published.
public actor BrowserSitePermissionStore {
    private struct Entry: Codable {
        let profileID: ProfileID
        let origin: BrowserSiteOrigin
        let permission: BrowserSitePermission
        let setting: BrowserSitePermissionSetting
    }
    private struct Document: Codable {
        var version = 1
        var entries: [Entry]
    }
    private struct Key: Hashable {
        let profileID: ProfileID
        let origin: BrowserSiteOrigin
        let permission: BrowserSitePermission
    }
    private struct Scope: Hashable {
        let profileID: ProfileID
        let origin: BrowserSiteOrigin
    }
    private var revisions: [Scope: UInt64] = [:]
    private var volatileRestrictions: [Key: BrowserSitePermissionSetting] = [:]
    private var isReadOnlyUnavailable = false
    private var durabilityUncertain = false
    private let destination: URL?
    private var settings: [Key: BrowserSitePermissionSetting] = [:]

    public static func ephemeral() -> BrowserSitePermissionStore { BrowserSitePermissionStore(ephemeral: ()) }
    private init(ephemeral: Void) { destination = nil }

    /// Fail-closed degraded mode never reads or writes the damaged permission file.
    public static func unavailable() -> BrowserSitePermissionStore { BrowserSitePermissionStore(unavailable: ()) }
    private init(unavailable: Void) {
        destination = nil
        durabilityUncertain = true
        isReadOnlyUnavailable = true
    }

    public init(destination: URL? = nil) throws {
        self.destination = destination
        if let destination, let data = try BrowserPermissionFile.load(destination) {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw BrowserPermissionStoreError.unsupportedVersion }
            for entry in document.entries {
                let key = Key(profileID: entry.profileID, origin: entry.origin, permission: entry.permission)
                guard settings[key] == nil else { throw BrowserPermissionStoreError.duplicateEntry }
                guard entry.setting != .allow || entry.permission.supportsPersistentAllow else {
                    throw BrowserPermissionStoreError.invalidPersistentGrant
                }
                settings[key] = entry.setting
            }
        }
    }

    /// Explicitly configured sites only, scoped to the selected settings profile.
    public func configuredOrigins(profileID: ProfileID) -> [BrowserSiteOrigin] {
        Set(settings.keys.filter { $0.profileID == profileID }.map(\.origin))
            .union(volatileRestrictions.keys.filter { $0.profileID == profileID }.map(\.origin))
            .sorted { $0.value < $1.value }
    }

    public func setting(for permission: BrowserSitePermission, origin: BrowserSiteOrigin,
                        profileID: ProfileID) -> BrowserSitePermissionSetting {
        let key = Key(profileID: profileID, origin: origin, permission: permission)
        return volatileRestrictions[key] ?? settings[key] ?? permission.defaultDecision
    }

    public func snapshot(origin: BrowserSiteOrigin, profileID: ProfileID) -> [BrowserSitePermission: BrowserSitePermissionSetting] {
        Dictionary(uniqueKeysWithValues: BrowserSitePermission.allCases.map {
            ($0, setting(for: $0, origin: origin, profileID: profileID))
        })
    }

    /// The compact panel omits defaults, including a request dismissed without a stored choice.
    /// Current capture use is added by the presentation, independently of persistent grants.
    public func relevantPermissions(origin: BrowserSiteOrigin, profileID: ProfileID) -> Set<BrowserSitePermission> {
        Set(BrowserSitePermission.allCases.filter {
            setting(for: $0, origin: origin, profileID: profileID) != $0.defaultDecision
        })
    }

    public func state(origin: BrowserSiteOrigin, profileID: ProfileID) -> BrowserSitePermissionState {
        let scope = Scope(profileID: profileID, origin: origin)
        if revisions[scope] == nil { revisions[scope] = 0 }
        return BrowserSitePermissionState(settings: snapshot(origin: origin, profileID: profileID),
                                          revision: revisions[scope] ?? 0, isDurable: !durabilityUncertain)
    }

    /// A prompt cannot overwrite a newer choice made in another window. One-shot grants
    /// validate the same revision without writing anything to disk.
    public func commit(_ choice: BrowserSitePermissionChoice, for permissions: [BrowserSitePermission],
                       origin: BrowserSiteOrigin, profileID: ProfileID, expectedRevision: UInt64) throws -> Bool {
        guard !durabilityUncertain, revisions[Scope(profileID: profileID, origin: origin), default: 0] == expectedRevision else { return false }
        switch choice {
        case .dismiss: return false
        case .allowOnce: return true
        case .alwaysAllow, .block:
            try set(choice == .block ? .block : .allow, for: permissions, origin: origin, profileID: profileID)
            return true
        }
    }

    public func set(_ setting: BrowserSitePermissionSetting, for permissions: [BrowserSitePermission],
                    origin: BrowserSiteOrigin, profileID: ProfileID) throws {
        guard setting != .allow || permissions.allSatisfy(\.supportsPersistentAllow) else {
            throw BrowserPermissionStoreError.invalidPersistentGrant
        }
        var next = settings
        for permission in permissions {
            next[Key(profileID: profileID, origin: origin, permission: permission)] = setting
        }
        do {
            try publish(next)
            for permission in permissions { volatileRestrictions.removeValue(forKey: Key(profileID: profileID, origin: origin, permission: permission)) }
        } catch {
            if setting != .allow {
                for permission in permissions { volatileRestrictions[Key(profileID: profileID, origin: origin, permission: permission)] = setting }
                revisions[Scope(profileID: profileID, origin: origin), default: 0] &+= 1
            }
            throw error
        }
        revisions[Scope(profileID: profileID, origin: origin), default: 0] &+= 1
    }

    public func reset(origin: BrowserSiteOrigin, profileID: ProfileID) throws {
        do {
            try publish(settings.filter { $0.key.origin != origin || $0.key.profileID != profileID })
            volatileRestrictions = volatileRestrictions.filter { $0.key.origin != origin || $0.key.profileID != profileID }
        } catch {
            for permission in BrowserSitePermission.allCases {
                let previous = setting(for: permission, origin: origin, profileID: profileID)
                let fallback = permission.defaultDecision
                let restriction: BrowserSitePermissionSetting = previous == .block || fallback == .block ? .block
                    : (previous == .ask || fallback == .ask ? .ask : .allow)
                volatileRestrictions[Key(profileID: profileID, origin: origin, permission: permission)] = restriction
            }
            revisions[Scope(profileID: profileID, origin: origin), default: 0] &+= 1
            throw error
        }
        revisions[Scope(profileID: profileID, origin: origin), default: 0] &+= 1
    }

    public func clear(profileID: ProfileID) throws {
        try publish(settings.filter { $0.key.profileID != profileID })
        volatileRestrictions = volatileRestrictions.filter { $0.key.profileID != profileID }
        for scope in Array(revisions.keys) where scope.profileID == profileID { revisions[scope, default: 0] &+= 1 }
    }

    private func publish(_ next: [Key: BrowserSitePermissionSetting]) throws {
        guard !isReadOnlyUnavailable else { throw BrowserPermissionStoreError.unavailable }
        if let destination {
            let entries = next.map { Entry(profileID: $0.key.profileID, origin: $0.key.origin,
                                           permission: $0.key.permission, setting: $0.value) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Document(entries: entries))
            do { try BrowserPermissionFile.save(data, to: destination) }
            catch BrowserPermissionFile.Failure.committedButNotDurable {
                // The new inode is already visible. Keep memory consistent but report the
                // durability failure; the requesting action still fails closed.
                settings = next
                durabilityUncertain = true
                throw BrowserPermissionFile.Failure.committedButNotDurable
            }
        }
        settings = next
        durabilityUncertain = false
    }
}
