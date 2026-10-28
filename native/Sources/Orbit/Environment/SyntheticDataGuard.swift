import Darwin
import Foundation

/// Keeps an automated run (mock Keychain) inside its synthetic data root (CHROMIUM-APP-R2).
/// A location is compared in every form the file system accepts for it: case-insensitively after
/// resolving symlinks, and by file identity (device and inode) of every existing ancestor, which
/// also covers other spellings of the same directory (firmlinks such as
/// `/System/Volumes/Data/Users/…`). Paths that do not exist yet are resolved through their
/// deepest existing ancestor.
struct SyntheticDataGuard: Equatable {
    enum Violation: Error, Equatable, CustomStringConvertible {
        /// The path is, or lies inside, a personal location (`~/Library`, the personal data root).
        case personalLocation(String)
        case outsideSyntheticRoot(String)
        /// A symlink where the run only accepts real entries (it could point at personal data).
        case symbolicLink(String)
        /// A file with more than one hard link (it could be personal data under another name).
        case hardLink(String)
        case unexpectedFileType(String)
        case unresolvable(String)
        case tooManyEntries(Int)

        var description: String {
            switch self {
            case .personalLocation(let path): "synthetic runs refuse the personal location \(path)"
            case .outsideSyntheticRoot(let path): "\(path) is outside the synthetic data root"
            case .symbolicLink(let path): "synthetic runs refuse the symbolic link \(path)"
            case .hardLink(let path): "synthetic runs refuse the multiply linked file \(path)"
            case .unexpectedFileType(let path): "\(path) has an unexpected file type"
            case .unresolvable(let path): "\(path) cannot be resolved"
            case .tooManyEntries(let count): "the synthetic data root holds more than \(count) entries"
            }
        }
    }

    /// Links Chromium itself keeps in its user data directory, never followed for data, which
    /// survive a killed run: the process singleton's lock token, cookie and socket path
    /// (`chrome_constants.h`) and the app shim's running-version token (`app_mode_common.h`).
    static let engineRootLinks: Set<String> = ["SingletonLock", "SingletonCookie", "SingletonSocket", "RunningChromeVersion"]
    /// A synthetic root is fresh; a larger tree is refused rather than walked for long.
    static let maximumEntries = 200_000

    let syntheticRoot: URL
    let personalLocations: [URL]

    init(syntheticRoot: URL, personalLocations: [URL]) {
        self.syntheticRoot = syntheticRoot.standardizedFileURL
        self.personalLocations = personalLocations.map(\.standardizedFileURL)
    }

    /// The synthetic root must be outside personal locations and, if present, a real directory.
    /// Check it before layout creation: validating only its children would follow a substituted
    /// root link and write directories, permissions and the instance lock into its target.
    func checkRoot() throws {
        try refusePersonal(syntheticRoot)
        try refuseLinkedDirectory(syntheticRoot)
    }

    /// A session file named explicitly by a synthetic run (`--session-file`).
    func checkSessionFile(_ file: URL) throws {
        try checkInside(file)
        try refuseLinkedFile(file)
    }

    /// Refuses `candidate` unless it lies inside the synthetic root and outside every personal
    /// location, in every spelling.
    func checkInside(_ candidate: URL) throws {
        let path = candidate.standardizedFileURL.path
        try refusePersonal(candidate)
        guard let resolved = Self.resolved(candidate), let root = Self.resolved(syntheticRoot) else {
            throw Violation.unresolvable(path)
        }
        if let rootIdentity = Self.identity(of: root.path) {
            guard Self.ancestorIdentities(of: resolved).contains(rootIdentity) else {
                throw Violation.outsideSyntheticRoot(path)
            }
        } else if !Self.lexicallyInside(resolved, root) {
            throw Violation.outsideSyntheticRoot(path)
        }
    }

    /// The derived layout of a run: the engine root (CEF `root_cache_path`), its global cache and
    /// the session file are real entries inside the root, and nothing under the root is a symlink
    /// (except Chromium's singleton links at the engine root) or a multiply linked file.
    func checkLayout(engineRoot: URL, sessionFile: URL) throws {
        try checkRoot()
        for directory in [engineRoot, engineRoot.appendingPathComponent("default", isDirectory: true)] {
            try checkInside(directory)
            try refuseLinkedDirectory(directory)
        }
        try checkSessionFile(sessionFile)
        try checkTree(engineRoot: engineRoot)
    }

    /// Walks the synthetic root without following links.
    func checkTree(engineRoot: URL) throws {
        let root = syntheticRoot.path
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return }
        let engine = engineRoot.standardizedFileURL.path
        var count = 0
        while let relative = enumerator.nextObject() as? String {
            count += 1
            guard count <= Self.maximumEntries else { throw Violation.tooManyEntries(Self.maximumEntries) }
            let path = (root as NSString).appendingPathComponent(relative)
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }  // Removed while walking.
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                let parent = (path as NSString).deletingLastPathComponent
                let name = (path as NSString).lastPathComponent
                guard parent == engine, Self.engineRootLinks.contains(name) else {
                    throw Violation.symbolicLink(path)
                }
            case S_IFREG:
                guard info.st_nlink <= 1 else { throw Violation.hardLink(path) }
            default:
                break
            }
        }
    }

    // MARK: Primitives

    struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private func refusePersonal(_ candidate: URL) throws {
        let path = candidate.standardizedFileURL.path
        guard let resolved = Self.resolved(candidate) else { throw Violation.unresolvable(path) }
        let ancestors = Set(Self.ancestorIdentities(of: resolved))
        for location in personalLocations {
            if let identity = Self.identity(of: location.path), ancestors.contains(identity) {
                throw Violation.personalLocation(path)
            }
            if let personal = Self.resolved(location), Self.lexicallyInside(resolved, personal) {
                throw Violation.personalLocation(path)
            }
            if Self.lexicallyInside(candidate.standardizedFileURL, location) {
                throw Violation.personalLocation(path)
            }
        }
    }

    private func refuseLinkedFile(_ file: URL) throws {
        var info = stat()
        guard lstat(file.standardizedFileURL.path, &info) == 0 else { return }  // Created later by the run.
        switch info.st_mode & S_IFMT {
        case S_IFLNK: throw Violation.symbolicLink(file.path)
        case S_IFREG: guard info.st_nlink <= 1 else { throw Violation.hardLink(file.path) }
        default: throw Violation.unexpectedFileType(file.path)
        }
    }

    private func refuseLinkedDirectory(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.standardizedFileURL.path, &info) == 0 else { return }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: throw Violation.symbolicLink(directory.path)
        case S_IFDIR: return
        default: throw Violation.unexpectedFileType(directory.path)
        }
    }

    /// `realpath` of the deepest existing ancestor (a dangling link does not resolve), with the
    /// missing components appended verbatim.
    static func resolved(_ url: URL) -> URL? {
        var base = url.standardizedFileURL.path
        var missing: [String] = []
        var info = stat()
        while lstat(base, &info) != 0 {
            guard base != "/" else { return nil }
            missing.insert((base as NSString).lastPathComponent, at: 0)
            base = (base as NSString).deletingLastPathComponent
        }
        guard let real = realpath(base, nil) else { return nil }
        defer { free(real) }
        var path = String(cString: real)
        for component in missing { path = (path as NSString).appendingPathComponent(component) }
        return URL(fileURLWithPath: path)
    }

    static func identity(of path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// Identities of every existing prefix of an already resolved path, the path included.
    static func ancestorIdentities(of resolved: URL) -> [FileIdentity] {
        var identities: [FileIdentity] = []
        var path = ""
        for component in resolved.pathComponents {
            path = path.isEmpty ? component : (path as NSString).appendingPathComponent(component)
            if let identity = identity(of: path) { identities.append(identity) }
        }
        return identities
    }

    /// Case-insensitive component prefix (APFS default volumes are case-insensitive).
    static func lexicallyInside(_ candidate: URL, _ root: URL) -> Bool {
        let child = candidate.standardizedFileURL.pathComponents.map { $0.lowercased() }
        let parent = root.standardizedFileURL.pathComponents.map { $0.lowercased() }
        return child.count >= parent.count && Array(child.prefix(parent.count)) == parent
    }
}
