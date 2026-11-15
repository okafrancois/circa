import Darwin
import Foundation

/// Chromium keeps its own history databases in every `profile-<uuid>` directory and holds them
/// open while it runs. Clearing all history (or removing a profile) records a durable request
/// here; the next launch deletes those files before the engine opens any profile. Chromium then
/// recreates them empty, so `:visited` styling and the extensions history API keep working for
/// new visits.
///
/// The request file lives in the data root (directory 0700, file 0600) and names profile
/// identities only. Every removal goes through descriptors opened one component at a time with
/// `O_NOFOLLOW`; a symbolic link anywhere refuses the purge, and an entry that is itself a link
/// is unlinked, never followed.
public enum BrowserEngineHistoryPurge {
    static let requestName = "engine-history-purge.json"
    /// Chromium's history, visited-link, top-site, favicon, omnibox-shortcut and predictor stores.
    public static let profileFiles = ["History", "Visited Links", "Top Sites", "Favicons", "Shortcuts",
                                      "Network Action Predictor"]
    static let companions = ["", "-journal", "-wal", "-shm"]

    struct Request: Codable, Equatable { var profiles: [UUID] }

    public enum Failure: Error, Equatable { case unsafePath, unreadableRequest, removalFailed }

    /// Adds `profileID` to the pending request. Idempotent; safe while the engine runs.
    public static func schedule(_ profileID: ProfileID, dataRoot: URL) throws {
        let root = try open(dataRoot)
        // An unreadable request (never expected: writes are atomic) is replaced, not kept forever.
        var request = (try? pending(in: root)) ?? Request(profiles: [])
        guard !request.profiles.contains(profileID.rawValue) else { return }
        request.profiles.append(profileID.rawValue)
        try save(request, in: root)
    }

    /// Profiles waiting for a purge (tests and diagnostics; never logged with paths).
    public static func pendingProfiles(dataRoot: URL) throws -> [ProfileID] {
        try pending(in: open(dataRoot)).profiles.map { ProfileID($0) }
    }

    /// Runs before the engine starts, with the data root lock held. Deletes the listed files of
    /// every requested profile, then the request. A profile directory that no longer exists is
    /// done. On failure the request stays for the next launch. Returns the purged profile count.
    @discardableResult
    public static func performPending(dataRoot: URL, engineRoot: URL) throws -> Int {
        let root = try open(dataRoot)
        let request = try pending(in: root)
        guard !request.profiles.isEmpty else { return 0 }
        let engine: OrbitSecureDirectory
        do { engine = try OrbitSecureDirectory.open(engineRoot, create: false) }
        catch ArcImportError.backupNotFound { try clear(in: root); return request.profiles.count }
        catch { throw Failure.unsafePath }
        for profile in request.profiles {
            let name = "profile-" + profile.uuidString.lowercased()
            let directory: OrbitSecureDirectory
            do { directory = try engine.directory(name, create: false) }
            catch ArcImportError.backupNotFound { continue }
            catch { throw Failure.unsafePath }
            for file in profileFiles {
                for companion in companions {
                    do {
                        guard let kind = try directory.checkedKind(file + companion) else { continue }
                        // A directory under one of these names is not Chromium's; leave it.
                        guard kind != S_IFDIR else { continue }
                        try directory.removeChecked(file + companion)
                    } catch { throw Failure.removalFailed }
                }
            }
        }
        try clear(in: root)
        return request.profiles.count
    }

    private static func open(_ dataRoot: URL) throws -> OrbitSecureDirectory {
        do { return try OrbitSecureDirectory.open(dataRoot, create: false) }
        catch { throw Failure.unsafePath }
    }

    private static func pending(in root: OrbitSecureDirectory) throws -> Request {
        guard try root.checkedKind(requestName) != nil else { return Request(profiles: []) }
        guard let data = root.read(requestName, limit: 1024 * 1024),
              let request = try? JSONDecoder().decode(Request.self, from: data) else { throw Failure.unreadableRequest }
        return request
    }

    private static func save(_ request: Request, in root: OrbitSecureDirectory) throws {
        do { try root.write(try JSONEncoder().encode(request), to: requestName) }
        catch { throw Failure.removalFailed }
    }

    private static func clear(in root: OrbitSecureDirectory) throws {
        do { try root.removeChecked(requestName) } catch { throw Failure.removalFailed }
    }
}
