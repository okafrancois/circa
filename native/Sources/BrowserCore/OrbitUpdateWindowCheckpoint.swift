import Foundation

/// Only transient windows need an update checkpoint; regular windows use the session document.
public struct OrbitUpdateWindowCheckpoint: Codable, Equatable, Sendable {
    public var url: URL?
    public var profileID: ProfileID
    public var spaceID: SpaceID
    public var frame: BrowserWindowPlacement?

    public init(url: URL?, profileID: ProfileID, spaceID: SpaceID, frame: BrowserWindowPlacement?) {
        self.url = url; self.profileID = profileID; self.spaceID = spaceID; self.frame = frame
    }

    public static func load(from file: URL) throws -> [Self] {
        guard let data = try BrowserPermissionFile.load(file) else { return [] }
        return try JSONDecoder().decode([Self].self, from: data)
    }

    public static func save(_ windows: [Self], to file: URL) throws {
        try BrowserPermissionFile.save(JSONEncoder().encode(windows), to: file)
    }
}
