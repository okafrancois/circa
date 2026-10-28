import Foundation

public struct BrowserSitePreferences: Codable, Equatable, Sendable {
    public var developerMode = false
    public var automaticPictureInPicture = true
    public init() {}
}

/// Orbit's Developer Mode is host-scoped. Schemes and ports of one host share preferences
/// within a profile; permissions continue to use their stricter origin scope.
@MainActor
public final class BrowserSitePreferenceStore {
    private struct Entry: Codable {
        var profileID: ProfileID
        var host: String
        var preferences: BrowserSitePreferences
    }
    private struct Document: Codable {
        var version = 1
        var entries: [Entry] = []
    }
    private let destination: URL?
    private var document = Document()
    private let writable: Bool

    public init(destination: URL? = nil, writable: Bool = true) throws {
        self.destination = destination
        self.writable = writable
        if let destination, let data = try BrowserPermissionFile.load(destination) {
            document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw BrowserPermissionStoreError.unsupportedVersion }
        }
    }

    public func preferences(url: URL?, profileID: ProfileID) -> BrowserSitePreferences {
        guard let host = Self.host(url) else { return .init() }
        return document.entries.first { $0.profileID == profileID && $0.host == host }?.preferences ?? .init()
    }

    public func set(_ preferences: BrowserSitePreferences, url: URL?, profileID: ProfileID) throws {
        guard writable, let host = Self.host(url) else { throw BrowserPermissionStoreError.unavailable }
        var next = document
        next.entries.removeAll { $0.profileID == profileID && $0.host == host }
        next.entries.append(Entry(profileID: profileID, host: host, preferences: preferences))
        try publish(next)
    }

    public func clear(profileID: ProfileID) throws {
        var next = document
        next.entries.removeAll { $0.profileID == profileID }
        try publish(next)
    }

    private func publish(_ next: Document) throws {
        guard writable else { throw BrowserPermissionStoreError.unavailable }
        if let destination {
            if let previous = try BrowserPermissionFile.load(destination) {
                try BrowserPermissionFile.save(previous, to: destination.appendingPathExtension("backup"))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try BrowserPermissionFile.save(encoder.encode(next), to: destination)
        }
        document = next
    }

    public static func host(_ url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()), let host = url.host,
              !host.isEmpty else { return nil }
        return host.lowercased()
    }
}
