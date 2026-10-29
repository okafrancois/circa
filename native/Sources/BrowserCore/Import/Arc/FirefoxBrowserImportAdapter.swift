import Darwin
import Foundation

public enum FirefoxImportRegistry {
    public static let descriptors: [BrowserImportDescriptor] = [
        .init(id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox", supportPath: "Firefox"),
        .init(id: "zen", name: "Zen", bundleID: "app.zen-browser.zen", supportPath: "zen")
    ]
    public static func installed(inventory: (String) -> [URL]) -> [BrowserImportDescriptor] {
        descriptors.filter { !inventory($0.bundleID).isEmpty }
    }
}

/// Metadata-only discovery. Absolute metadata paths require an explicit matching external root
/// at snapshot time; relative paths cannot escape the selected installation root.
public struct FirefoxBrowserImportAdapter: BrowserImportSourceAdapter {
    public let descriptor: BrowserImportDescriptor
    public let registration: BrowserImportRegistration
    public let profile: BrowserImportSourceProfile
    public let placement: ChromiumImportPlacement
    public let authenticationConsent: Bool
    public let externalProfileRoot: URL?
    public init(descriptor: BrowserImportDescriptor, installationID: UUID, profile: BrowserImportSourceProfile,
                placement: ChromiumImportPlacement, authenticationConsent: Bool = false, externalProfileRoot: URL? = nil) {
        self.descriptor = descriptor; registration = .init(sourceID: descriptor.id, installationID: installationID)
        self.profile = profile; self.placement = placement; self.authenticationConsent = authenticationConsent
        self.externalProfileRoot = externalProfileRoot
    }
    static func ini(_ data: Data) throws -> [String: [String: String]] {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw ArcImportError.unreadableSourceDocument }
        var sections: [String: [String: String]] = [:], section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                guard sections[section] == nil else { throw ArcImportError.unreadableSourceDocument }
                sections[section] = [:]
            } else {
                guard !section.isEmpty, let equal = line.firstIndex(of: "=") else { throw ArcImportError.unreadableSourceDocument }
                let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
                guard sections[section]?[key] == nil else { throw ArcImportError.unreadableSourceDocument }
                sections[section]?[key] = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return sections
    }
    static func relativePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4096 && !path.contains("\\") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            OrbitSecureDirectory.validName(String($0)) && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }
    public func discoverProfiles(metadata: Data) throws -> [BrowserImportSourceProfile] {
        try discoverProfiles(metadata: metadata, installs: nil)
    }
    public func discoverProfiles(metadata: Data, installs: Data?) throws -> [BrowserImportSourceProfile] {
        let sections = try Self.ini(metadata)
        let defaults = Set(try (installs.map(Self.ini) ?? [:]).values.compactMap { $0["Default"] } +
            sections.filter { $0.key.hasPrefix("Install") }.values.compactMap { $0["Default"] })
        var seen = Set<String>()
        return sections.keys.sorted().filter { $0.hasPrefix("Profile") }.compactMap { key in
            guard let entry = sections[key], let path = entry["Path"],
                  entry["IsRelative"] == "1" ? Self.relativePath(path) : entry["IsRelative"] == "0" && path.hasPrefix("/") && Self.relativePath(String(path.dropFirst())),
                  seen.insert(path).inserted else { return nil }
            return BrowserImportSourceProfile(directory: path, name: ArcImportMapper.sanitizedName(entry["Name"]) ?? key)
        }.sorted { a, b in
            if defaults.contains(a.directory) != defaults.contains(b.directory) { return defaults.contains(a.directory) }
            return a.directory < b.directory
        }
    }
    private struct ClosedProbe: ArcRunningProbe {
        let base: any ArcRunningProbe
        func isArcRunning(sourceRoot: URL) -> Bool {
            if base.isArcRunning(sourceRoot: sourceRoot) { return true }
            // Query regular advisory locks without acquiring, truncating or deleting them.
            // Legacy symlink locks are refused conservatively, including stale ones.
            for name in ["parent.lock", ".parentlock", "lock", "SingletonLock"] {
                var info = stat()
                let path = sourceRoot.appendingPathComponent(name).path
                if lstat(path, &info) == 0 {
                    guard info.st_mode & S_IFMT == S_IFREG else { return true }
                    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { return true }
                    var request = Darwin.flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
                    let result = fcntl(fd, F_GETLK, &request)
                    close(fd)
                    if result == -1 || request.l_type != F_UNLCK { return true }
                }
            }
            return false
        }
    }
    public func snapshot(source: URL, parent: URL, probe: any ArcRunningProbe, diskSpace: any OrbitDiskSpaceProbe) throws -> ArcSourceSnapshot {
        guard FirefoxImportRegistry.descriptors.contains(descriptor) else { throw ArcImportError.unsupportedSourceFile }
        let metadataRoot = try OrbitSecureDirectory.open(source, create: false)
        guard let metadata = metadataRoot.read("profiles.ini", limit: 1_048_576),
              try discoverProfiles(metadata: metadata).contains(where: { $0.directory == profile.directory }) else { throw ArcImportError.sourceNotFound }
        let installs = metadataRoot.read("installs.ini", limit: 1_048_576)
        if let installs { _ = try Self.ini(installs) }
        let selected: OrbitSecureDirectory
        if profile.directory.hasPrefix("/") {
            guard let externalProfileRoot, externalProfileRoot.path == profile.directory else { throw ArcImportError.unsupportedSourceFile }
            selected = try OrbitSecureDirectory.open(externalProfileRoot, create: false)
        } else { selected = try metadataRoot.directory(profile.directory, create: false) }
        if selected.exists("sessionstore-backups") { _ = try selected.directory("sessionstore-backups", create: false) }
        let checked = ClosedProbe(base: probe)
        guard !checked.isArcRunning(sourceRoot: source) else { throw ArcImportError.arcIsRunning }
        var manifest: [(relative: String, limit: Int64?, required: Bool)] = []
        func add(_ name: String, _ limit: Int64 = 32 * 1024 * 1024) { manifest.append((name, limit, false)) }
        for name in ["places.sqlite", "formhistory.sqlite", "permissions.sqlite"] + (authenticationConsent ? ["cookies.sqlite"] : []) {
            for suffix in ["", "-wal", "-journal"] { add(name + suffix, 512 * 1024 * 1024) }
        }
        for name in FirefoxSessionReader.files + ["zen-sessions.jsonlz4", "extensions.json", "logins.json", "search.json.mozlz4"] { add(name) }
        let snapshot = try ArcSourceSnapshot.captureManifest(source: selected.url, plan: manifest, historyDirectories: [], historyPrefix: "", parent: parent, probe: checked, diskSpace: diskSpace)
        do {
            guard metadataRoot.read("profiles.ini", limit: 1_048_576) == metadata,
                  metadataRoot.read("installs.ini", limit: 1_048_576) == installs,
                  !checked.isArcRunning(sourceRoot: source) else { throw ArcImportError.sourceChangedDuringCopy }
            let copied = try OrbitSecureDirectory.open(snapshot.directory, create: false)
            if copied.exists("places.sqlite") { snapshot.historyDatabases[profile.directory] = snapshot.directory.appendingPathComponent("places.sqlite") }
            return snapshot
        } catch { snapshot.remove(); throw error }
    }
    public func historyReader(file: URL, directory: String) throws -> any BrowserImportHistoryReader {
        try FirefoxHistoryReader(file: file, directory: directory, identity: .init(namespace: registration.namespace))
    }
    public func makePlan(snapshot: ArcSourceSnapshot, ledger: BrowserImportLedger, defaultProfile: ProfileID?, importedAt: Date) throws -> BrowserImportSourcePlan {
        let key = registration.profileKey(profile.directory), identity = ArcImportIdentity(namespace: key)
        let id = ledger.profileMappings[key].map(ProfileID.init) ?? identity.profile(.directory(profile.directory))
        var plan = BrowserImportPlan(); plan.registration = registration
        plan.profiles = [.init(id: id, sourceKey: .directory(profile.directory), name: profile.name, sourceDirectory: profile.directory, isAdopted: false, mappingKey: key)]
        let space = identity.space("bookmarks")
        plan.spaces = [.init(id: space, profileID: id, name: placement.importedSpace, appearance: .init())]
        let root = try OrbitSecureDirectory.open(snapshot.directory, create: false)
        var counts: [String: Int] = [:]
        let bookmarks = root.exists("places.sqlite") ? try FirefoxPlacesReader.bookmarks(file: root.url.appendingPathComponent("places.sqlite"), identity: identity, importedAt: importedAt, counts: &counts) : []
        plan.sections = [.init(spaceID: space, pinned: bookmarks.isEmpty ? [] : [.folder(.init(id: identity.folder("imported-bookmarks"), title: placement.bookmarkFolder, isCollapsed: false, children: [], createdAt: importedAt), bookmarks)], today: [])]
        let sessions = try FirefoxSessionReader.read(root: root, zen: descriptor.id == "zen")
        counts.merge(sessions.counts, uniquingKeysWith: +)
        for (index, window) in sessions.windows.enumerated() {
            let windowSpace = identity.space("session:\(index)")
            plan.spaces.append(.init(id: windowSpace, profileID: id, name: window.name ?? "\(placement.windowName) \(index + 1)", appearance: .init()))
            var pinned: [BrowserImportPlan.Node] = [], today: [BrowserOrganizedTab] = []
            for (offset, tab) in window.tabs.enumerated() {
                let value = BrowserOrganizedTab(id: identity.tab("session:\(index):\(offset)"), url: tab.url, pageTitle: tab.title,
                    pinnedURL: tab.pinnedURL, createdAt: importedAt, lastActiveAt: importedAt)
                if tab.pinnedURL != nil { pinned.append(.tab(value)) } else { today.append(value) }
            }
            plan.sections.append(.init(spaceID: windowSpace, pinned: pinned, today: today))
        }
        if snapshot.historyDatabases[profile.directory] != nil { plan.historySources = [.init(profileID: id, directory: profile.directory)] }
        for (file, table, category) in [("formhistory.sqlite", "moz_formhistory", "formHistory"), ("permissions.sqlite", "moz_perms", "permissions")] where root.exists(file) {
            counts[category] = try FirefoxPlacesReader.count(root.url.appendingPathComponent(file), table: table)
        }
        for (file, field, category) in [("extensions.json", "addons", "extensions"), ("logins.json", "logins", "passwordsExportRequired")] {
            if let data = root.read(file, limit: 32 * 1024 * 1024) {
                counts[category] = (try FirefoxSessionReader.json(data)[field] as? [Any])?.count ?? 0
            }
        }
        if let data = root.read("search.json.mozlz4", limit: 32 * 1024 * 1024) {
            counts["searchEngines"] = (try FirefoxSessionReader.json(MozLz4.decode(data))["engines"] as? [Any])?.count ?? 0
        }
        var capabilities: [String: BrowserImportCapability] = ["bookmarks": bookmarks.isEmpty ? .empty : .supported,
            "history": plan.historySources.isEmpty ? .empty : .supported, "tabs": sessions.capability,
            "passwords": root.exists("logins.json") ? .needsExport : .empty,
            "extensions": .unsupported, "formHistory": .unsupported, "permissions": .unsupported, "searchEngines": .unsupported,
            "siteData": .unsupported, "containers": .unsupported, "partitionedCookies": .unsupported]
        if root.exists("cookies.sqlite") {
            let result = try FirefoxCookieImport.inspect(file: root.url.appendingPathComponent("cookies.sqlite"))
            counts.merge(result, uniquingKeysWith: +); capabilities["cookies"] = .supported
        } else { capabilities["cookies"] = .empty }
        return .init(plan: plan, capabilities: capabilities, sourceCounts: counts,
            notImported: ["extensions", "formHistory", "permissions", "searchEngines", "siteData", "containers", "partitionedCookies", "passwordsRequireCSV"])
    }
}
