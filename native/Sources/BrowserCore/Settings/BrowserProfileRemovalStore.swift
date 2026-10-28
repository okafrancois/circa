import Foundation

/// Durable intent is independent of both the session document and the optional settings file.
/// A restarted environment quarantines every entry before constructing any window or surface.
public struct BrowserProfileRemoval: Codable, Sendable, Equatable {
    public enum Step: Int, Codable, Sendable { case organization, permissions, history, engine, settings }
    public let profileID: ProfileID
    public let spaceIDs: Set<SpaceID>
    public var nextStep: Step
    public init(profileID: ProfileID, spaceIDs: Set<SpaceID>, nextStep: Step = .organization) {
        self.profileID = profileID
        self.spaceIDs = spaceIDs
        self.nextStep = nextStep
    }
}

public actor BrowserProfileRemovalStore {
    private struct Document: Codable { var version = 1; var entries: [BrowserProfileRemoval] }
    private let destination: URL?
    private var entries: [ProfileID: BrowserProfileRemoval] = [:]

    public init(destination: URL? = nil) throws {
        self.destination = destination
        if let destination, let data = try BrowserPermissionFile.load(destination) {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw BrowserSettingsError.unsupportedVersion }
            for entry in document.entries {
                guard entries[entry.profileID] == nil else { throw BrowserPermissionStoreError.duplicateEntry }
                entries[entry.profileID] = entry
            }
        }
    }

    public func pending() -> [BrowserProfileRemoval] {
        entries.values.sorted { $0.profileID.rawValue.uuidString < $1.profileID.rawValue.uuidString }
    }
    public func entry(_ id: ProfileID) -> BrowserProfileRemoval? { entries[id] }
    public func put(_ entry: BrowserProfileRemoval) throws {
        var next = entries
        next[entry.profileID] = entry
        try publish(next)
    }
    public func complete(_ id: ProfileID) throws {
        var next = entries
        next[id] = nil
        try publish(next)
    }
    private func publish(_ next: [ProfileID: BrowserProfileRemoval]) throws {
        if let destination {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do {
                try BrowserPermissionFile.save(encoder.encode(Document(entries: next.values.sorted {
                    $0.profileID.rawValue.uuidString < $1.profileID.rawValue.uuidString
                })), to: destination)
            } catch BrowserPermissionFile.Failure.committedButNotDurable {
                entries = next
                throw BrowserPermissionFile.Failure.committedButNotDurable
            }
        }
        entries = next
    }
}
