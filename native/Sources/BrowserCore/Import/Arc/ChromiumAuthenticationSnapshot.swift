import Darwin
import Foundation

/// A selected profile's bounded authentication manifest. Construction requires explicit consent;
/// inventory/discovery never calls a key provider or opens these stores.
public final class ChromiumAuthenticationSnapshot: @unchecked Sendable {
    private let snapshot: ArcSourceSnapshot
    public let profileDirectory: URL
    public let cookieFile: URL?
    public let loginFiles: [URL]
    public let sourceID: String
    public let sourceProfile: String
    private init(snapshot: ArcSourceSnapshot, sourceID: String, profile: String, cookie: String?) {
        self.snapshot = snapshot; self.sourceID = sourceID; sourceProfile = profile
        let profileDirectory = snapshot.directory.appendingPathComponent(profile)
        self.profileDirectory = profileDirectory
        cookieFile = cookie.map { profileDirectory.appendingPathComponent($0) }
        loginFiles = ["Login Data", "Login Data For Account"].map { profileDirectory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    public func discard() { snapshot.remove() }
    public static func capture(source: URL, adapter: ChromiumBrowserImportAdapter, consent: Bool,
                               parent: URL, probe: any ArcRunningProbe,
                               diskSpace: any OrbitDiskSpaceProbe = OrbitSystemDiskSpaceProbe()) throws -> ChromiumAuthenticationSnapshot {
        guard consent else { throw BrowserAuthenticationImportError.consentRequired }
        guard ChromiumBrowserImportAdapter.validDirectory(adapter.profile.directory) else { throw BrowserAuthenticationImportError.unsupportedSource }
        let root = try OrbitSecureDirectory.open(source, create: false)
        guard let metadata = root.read("Local State"),
              try adapter.discoverProfiles(metadata: metadata).contains(where: { $0.directory == adapter.profile.directory }) else {
            throw ArcImportError.sourceNotFound
        }
        guard !probe.isArcRunning(sourceRoot: source) else { throw ArcImportError.arcIsRunning }
        let profile = try root.directory(adapter.profile.directory, create: false)
        var manifest: [(relative: String, limit: Int64?, required: Bool)] = [("Local State", 16 * 1024 * 1024, true)]
        var inventories: [String: [String]] = [:]
        func add(_ name: String, required: Bool = false) {
            manifest.append((adapter.profile.directory + "/" + name, 512 * 1024 * 1024, required))
        }
        // Prefer Network/Cookies only when present; never combine two independent cookie stores.
        let network = profile.exists("Network") ? try profile.directory("Network", create: false) : nil
        let cookie = network?.exists("Cookies") == true ? "Network/Cookies" : profile.exists("Cookies") ? "Cookies" : nil
        for name in ["Login Data", "Login Data For Account"] + (cookie.map { [$0] } ?? []) {
            add(name); add(name + "-wal"); add(name + "-journal")
        }
        func walk(_ directory: OrbitSecureDirectory, _ prefix: String, depth: Int) throws {
            guard depth <= 12, manifest.count < 10_000 else { throw ArcImportError.unsupportedSourceFile }
            let names = try directory.checkedEntries().sorted()
            inventories[prefix] = names
            for name in names {
                guard !name.contains("\0") else { throw ArcImportError.unsupportedSourceFile }
                if directory.kind(name) == S_IFDIR { try walk(directory.directory(name, create: false), prefix + "/" + name, depth: depth + 1) }
                else if directory.kind(name) == S_IFREG { add(prefix + "/" + name, required: true) }
                else { throw ArcImportError.unsupportedSourceFile }
            }
        }
        let storageNames = ["Local Storage", "IndexedDB", "WebStorage"].filter { profile.exists($0) }
        for name in storageNames {
            try walk(profile.directory(name, create: false), name, depth: 0)
        }
        guard manifest.count <= 10_000 else { throw ArcImportError.unsupportedSourceFile }
        let snapshot = try ArcSourceSnapshot.captureManifest(source: source, plan: manifest, historyDirectories: [], historyPrefix: "",
            parent: parent, probe: probe, diskSpace: diskSpace)
        do {
            let currentNetwork = profile.exists("Network") ? try profile.directory("Network", create: false) : nil
            let currentCookie = currentNetwork?.exists("Cookies") == true ? "Network/Cookies" : profile.exists("Cookies") ? "Cookies" : nil
            guard currentCookie == cookie, storageNames == ["Local Storage", "IndexedDB", "WebStorage"].filter({ profile.exists($0) }) else {
                throw ArcImportError.sourceChangedDuringCopy
            }
            for (path, names) in inventories {
                guard try profile.directory(path, create: false).checkedEntries().sorted() == names else { throw ArcImportError.sourceChangedDuringCopy }
            }
            guard let copied = snapshot.localState, try Data(contentsOf: copied) == metadata,
                  !probe.isArcRunning(sourceRoot: source) else { throw ArcImportError.sourceChangedDuringCopy }
            _ = try OrbitSecureDirectory.open(snapshot.directory, create: false).directory(adapter.profile.directory, create: true)
            return Self(snapshot: snapshot, sourceID: adapter.descriptor.id, profile: adapter.profile.directory, cookie: cookie)
        } catch { snapshot.remove(); throw error }
    }
}
