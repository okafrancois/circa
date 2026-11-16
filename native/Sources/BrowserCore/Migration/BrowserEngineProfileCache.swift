import Darwin
import Foundation

/// Chromium on macOS keeps a profile's HTTP and code caches outside the profile directory when
/// that directory lives under the user's Application Support folder: the cache goes to the same
/// relative path under the user's Caches folder (`<Caches>/<data root name>/Chromium/profile-<uuid>`).
/// Any other location (synthetic data roots, laboratory roots) keeps the cache inside the profile
/// directory, which profile removal already deletes, so there is no external cache root.
///
/// Removal only ever touches `profile-<uuid>` directories directly under the cache root derived
/// from the running engine root. Every directory is opened one component at a time without
/// following links; an entry that is itself a link is unlinked, never followed.
public enum BrowserEngineProfileCache {
    public enum Failure: Error, Equatable { case unsafePath, removalFailed }

    /// Cache root of `engineRoot`, or nil when Chromium keeps caches inside its profile directories.
    /// Mirrors Chromium's lexical rule; the engine root must sit at least two components below
    /// Application Support (`<data root>/Chromium`) so the result is never Caches itself or a
    /// folder shared with other applications.
    public static func cacheRoot(engineRoot: URL, applicationSupport: URL, caches: URL) -> URL? {
        // Lexical, like Chromium: no standardization that could shorten one path and not another.
        let support = applicationSupport.pathComponents
        let engine = engineRoot.pathComponents
        let cacheBase = caches.pathComponents
        guard engineRoot.isFileURL, applicationSupport.isFileURL, caches.isFileURL,
              [support, engine, cacheBase].allSatisfy({ $0.first == "/" && !$0.contains(".") && !$0.contains("..") }),
              support.count > 1, cacheBase.count > 1, support != cacheBase,
              engine.count >= support.count + 2, engine.starts(with: support) else { return nil }
        return engine.dropFirst(support.count).reduce(caches) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// The cache root for the current user's folders.
    public static func cacheRoot(engineRoot: URL, fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return cacheRoot(engineRoot: engineRoot, applicationSupport: support, caches: caches)
    }

    public static func directoryName(_ profileID: ProfileID) -> String {
        "profile-" + profileID.rawValue.uuidString.lowercased()
    }

    /// The profile a cache directory name designates; nil for anything else (`Default`, files).
    static func profileID(directoryName name: String) -> ProfileID? {
        guard name.hasPrefix("profile-"), let id = UUID(uuidString: String(name.dropFirst("profile-".count))),
              directoryName(ProfileID(id)) == name else { return nil }
        return ProfileID(id)
    }

    static let retiredPrefix = ".orbit-removed-"

    /// Deletes the cache directory of `profileID`: one rename first, so the name is free again at
    /// once and a partial deletion never leaves a half cache under the profile's name, then the
    /// retired tree. Absent root or directory: nothing to do. A failure leaves a retired entry that
    /// `purgeRetired` deletes at the next launch.
    public static func remove(_ profileID: ProfileID, cacheRoot: URL) throws {
        guard let root = try openRoot(cacheRoot), let retired = try retire(directoryName(profileID), in: root) else { return }
        try removeTree(retired, in: root.descriptor)
    }

    /// Launch sweep, before the engine opens any profile: retires the cache directories whose
    /// profile directory no longer exists in the engine root (removed profiles, including removals
    /// whose cache deletion failed or was cut short). Returns the count retired; `purgeRetired`
    /// deletes them and can run in the background once this returns.
    @discardableResult
    public static func sweep(cacheRoot: URL, engineRoot: URL) throws -> Int {
        guard let root = try openRoot(cacheRoot) else { return 0 }
        let engine: OrbitSecureDirectory?
        do { engine = try OrbitSecureDirectory.open(engineRoot, create: false) }
        catch let error where OrbitSecureDirectory.isMissing(error) { engine = nil }
        catch { throw Failure.unsafePath }
        let entries: [String]
        do { entries = try root.checkedEntries() } catch { throw Failure.removalFailed }
        var retired = 0
        for name in entries.sorted() where profileID(directoryName: name) != nil {
            let live: Bool
            do { live = try engine?.checkedKind(name) != nil } catch { throw Failure.unsafePath }
            guard !live else { continue }
            if try retire(name, in: root) != nil { retired += 1 }
        }
        return retired
    }

    /// Deletes every retired cache tree. Returns the count deleted.
    @discardableResult
    public static func purgeRetired(cacheRoot: URL) throws -> Int {
        guard let root = try openRoot(cacheRoot) else { return 0 }
        let entries: [String]
        do { entries = try root.checkedEntries() } catch { throw Failure.removalFailed }
        var removed = 0
        for name in entries where name.hasPrefix(retiredPrefix) {
            try removeTree(name, in: root.descriptor)
            removed += 1
        }
        return removed
    }

    private static func retire(_ name: String, in root: OrbitSecureDirectory) throws -> String? {
        let retired = retiredPrefix + name + "-" + UUID().uuidString.prefix(8).lowercased()
        guard renameat(root.descriptor, name, root.descriptor, retired) == 0 else {
            if errno == ENOENT { return nil }
            throw Failure.removalFailed
        }
        return retired
    }

    private static func openRoot(_ cacheRoot: URL) throws -> OrbitSecureDirectory? {
        do { return try OrbitSecureDirectory.open(cacheRoot, create: false) }
        catch let error where OrbitSecureDirectory.isMissing(error) { return nil }
        catch { throw Failure.unsafePath }
    }

    /// Removes `name` below `parent` without following links and without per-entry syncs (caches
    /// hold many thousands of files and need no durability).
    static func removeTree(_ name: String, in parent: Int32) throws {
        guard OrbitSecureDirectory.validName(name) else { throw Failure.unsafePath }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw Failure.removalFailed
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw Failure.removalFailed }
            defer { Darwin.close(child) }
            for entry in try entries(of: child) { try removeTree(entry, in: child) }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT else { throw Failure.removalFailed }
        } else {
            guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else { throw Failure.removalFailed }
        }
    }

    private static func entries(of descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw Failure.removalFailed }
        guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw Failure.removalFailed }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Failure.removalFailed }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }
}
