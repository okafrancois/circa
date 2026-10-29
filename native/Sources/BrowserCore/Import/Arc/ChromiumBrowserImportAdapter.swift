import Darwin
import Foundation

/// Placement strings are injected by the UI through uiText/uiFormat. No view or command routing
/// is introduced here. A selected profile always gets an isolated persistent target profile.
public struct ChromiumImportPlacement: Sendable {
    public let importedSpace: String
    public let bookmarkFolder: String
    public let windowName: String
    public init(importedSpace: String, bookmarkFolder: String, windowName: String) {
        self.importedSpace = importedSpace; self.bookmarkFolder = bookmarkFolder; self.windowName = windowName
    }
}

public struct ChromiumBrowserImportAdapter: BrowserImportSourceAdapter {
    public let descriptor: BrowserImportDescriptor
    public let registration: BrowserImportRegistration
    public let profile: BrowserImportSourceProfile
    public let placement: ChromiumImportPlacement
    public init(descriptor: BrowserImportDescriptor, installationID: UUID,
                profile: BrowserImportSourceProfile, placement: ChromiumImportPlacement) {
        self.descriptor = descriptor
        registration = .init(sourceID: descriptor.id, installationID: installationID)
        self.profile = profile; self.placement = placement
    }
    public func discoverProfiles(metadata: Data) throws -> [BrowserImportSourceProfile] { try Self.profiles(metadata) }
    static func profiles(_ metadata: Data) throws -> [BrowserImportSourceProfile] {
        guard metadata.count <= ArcSourceSnapshot.maximumLocalStateBytes,
              let json = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let profiles = json["profile"] as? [String: Any],
              let cache = profiles["info_cache"] as? [String: Any] else { throw ArcImportError.unreadableSourceDocument }
        return cache.keys.sorted().compactMap { key in
            guard validDirectory(key), let entry = cache[key] as? [String: Any] else { return nil }
            return .init(directory: key, name: ArcImportMapper.sanitizedName(entry["name"] as? String) ?? key)
        }
    }
    static func validDirectory(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        !["Guest Profile", "System Profile"].contains(name)
    }
    static let bookmarkFiles = ["Bookmarks", "AccountBookmarks", "EncryptedBookmarks", "EncryptedAccountBookmarks", "EncryptedBookmarks2", "EncryptedAccountBookmarks2"]
    public func snapshot(source: URL, parent: URL, probe: any ArcRunningProbe,
                         diskSpace: any OrbitDiskSpaceProbe) throws -> ArcSourceSnapshot {
        guard Self.validDirectory(profile.directory) else { throw ArcImportError.unsupportedSourceFile }
        guard !probe.isArcRunning(sourceRoot: source) else { throw ArcImportError.arcIsRunning }
        let root = try OrbitSecureDirectory.open(source, create: false)
        guard let metadata = root.read("Local State", limit: Int(ArcSourceSnapshot.maximumLocalStateBytes)),
              try discoverProfiles(metadata: metadata).contains(where: { $0.directory == profile.directory }) else {
            throw ArcImportError.sourceNotFound
        }
        let folder = try root.directory(profile.directory, create: false)
        var manifest: [(relative: String, limit: Int64?, required: Bool)] = [("Local State", ArcSourceSnapshot.maximumLocalStateBytes, true)]
        func add(_ name: String, limit: Int64 = ArcSourceSnapshot.maximumDocumentBytes) {
            manifest.append((profile.directory + "/" + name, limit, false))
        }
        for name in Self.bookmarkFiles + ["Current Session", "Last Session", "Current Tabs", "Last Tabs"] { add(name) }
        for name in ["History", "History-wal", "History-journal"] { add(name, limit: 2 * 1024 * 1024 * 1024) }
        var sessionInventories: [String: [String]] = [:]
        for directory in ["Sessions", "Sessions_Encrypted"] {
            if folder.exists(directory) {
                let sessions = try folder.directory(directory, create: false)
                let names = sessions.entries().filter { $0.hasPrefix("Session_") || $0.hasPrefix("Tabs_") }.sorted()
                sessionInventories[directory] = names
                guard names.count <= 128 else { throw ArcImportError.unsupportedSourceFile }
                for name in names { add(directory + "/" + name) }
            }
        }
        let snapshot = try ArcSourceSnapshot.captureManifest(source: source, plan: manifest,
            historyDirectories: [profile.directory], historyPrefix: "", parent: parent, probe: probe, diskSpace: diskSpace)
        for directory in ["Sessions", "Sessions_Encrypted"] {
            let names = folder.exists(directory) ? try folder.directory(directory, create: false).entries()
                .filter { $0.hasPrefix("Session_") || $0.hasPrefix("Tabs_") }.sorted() : nil
            guard names == sessionInventories[directory] else {
                snapshot.remove(); throw ArcImportError.sourceChangedDuringCopy
            }
        }
        // Selection metadata must still describe the profile captured, never an arbitrary directory.
        guard let copied = snapshot.localState, try Data(contentsOf: copied) == metadata else {
            snapshot.remove(); throw ArcImportError.sourceChangedDuringCopy
        }
        return snapshot
    }
    public func historyReader(file: URL, directory: String) throws -> any BrowserImportHistoryReader {
        try ArcChromiumHistoryReader(snapshotFile: file, directory: directory, identity: .init(namespace: registration.namespace))
    }
    public func makePlan(snapshot: ArcSourceSnapshot, ledger: BrowserImportLedger,
                         defaultProfile: ProfileID?, importedAt: Date) throws -> BrowserImportSourcePlan {
        let identity = ArcImportIdentity(namespace: registration.profileKey(profile.directory))
        let key = registration.profileKey(profile.directory)
        let profileID = ledger.profileMappings[key].map(ProfileID.init) ?? identity.profile(.directory(profile.directory))
        var plan = BrowserImportPlan()
        plan.registration = registration
        plan.profiles = [.init(id: profileID, sourceKey: .directory(profile.directory), name: profile.name,
                               sourceDirectory: profile.directory, isAdopted: false, mappingKey: key)]
        let space = identity.space("bookmarks")
        plan.spaces = [.init(id: space, profileID: profileID, name: placement.importedSpace, appearance: .init())]
        let root = try OrbitSecureDirectory.open(snapshot.directory, create: false).directory(profile.directory, create: true)
        var capabilities: [String: BrowserImportCapability] = ["bookmarks": .empty, "tabs": .empty, "history": .empty]
        var bookmarks: [BrowserImportPlan.Node] = []
        var seen = Set<String>()
        // An encrypted primary can supersede the cleartext mirror. Never import the stale mirror.
        for (plain, encrypted) in [("Bookmarks", ["EncryptedBookmarks", "EncryptedBookmarks2"]),
                                   ("AccountBookmarks", ["EncryptedAccountBookmarks", "EncryptedAccountBookmarks2"])] {
            if encrypted.contains(where: { root.exists($0) }) { capabilities["bookmarks"] = .needsExport; continue }
            if let data = root.read(plain, limit: Int(ArcSourceSnapshot.maximumDocumentBytes)) {
                do {
                    var parsedIdentities = seen
                    bookmarks += try ChromiumBookmarkReader.nodes(data, store: plain, identity: identity,
                                                                  importedAt: importedAt, seen: &parsedIdentities)
                    seen = parsedIdentities
                    if capabilities["bookmarks"] != .needsExport { capabilities["bookmarks"] = .supported }
                } catch { if capabilities["bookmarks"] != .needsExport { capabilities["bookmarks"] = .failed } }
            }
        }
        let folder = BrowserOrganizedFolder(id: identity.folder("imported-bookmarks"), title: placement.bookmarkFolder,
                                            isCollapsed: false, children: [], createdAt: importedAt)
        plan.sections = [.init(spaceID: space, pinned: bookmarks.isEmpty ? [] : [.folder(folder, bookmarks)], today: [])]
        let sessions = try ChromiumSessionReader.latest(in: root)
        capabilities["tabs"] = sessions.capability
        for window in sessions.windows {
            let windowSpace = identity.space("window:\(window.id)")
            plan.spaces.append(.init(id: windowSpace, profileID: profileID, name: "\(placement.windowName) \(plan.spaces.count)", appearance: .init()))
            var pinned: [BrowserImportPlan.Node] = [], today: [BrowserOrganizedTab] = []
            for tab in window.tabs {
                let value = BrowserOrganizedTab(id: identity.tab("session:\(tab.id)"), url: tab.url,
                    pageTitle: BrowserOrganizationState.sanitizedPageTitle(tab.title), pinnedURL: tab.pinned ? tab.url : nil,
                    createdAt: importedAt, lastActiveAt: importedAt)
                if tab.pinned { pinned.append(.tab(value)) } else { today.append(value) }
            }
            plan.sections.append(.init(spaceID: windowSpace, pinned: pinned, today: today))
        }
        if snapshot.historyDatabases[profile.directory] != nil {
            plan.historySources = [.init(profileID: profileID, directory: profile.directory)]
            capabilities["history"] = .supported
        }
        return .init(plan: plan, capabilities: capabilities)
    }
}

/// Version 1 JSON codec, preserving root ordering and empty folders. GUID identity deduplicates
/// local/account copies, while distinct bookmarks with the same URL remain distinct.
enum ChromiumBookmarkReader {
    static func nodes(_ data: Data, store: String, identity: ArcImportIdentity, importedAt: Date,
                      seen: inout Set<String>) throws -> [BrowserImportPlan.Node] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["version"] as? Int == 1, let roots = json["roots"] as? [String: Any] else {
            throw ArcImportError.unsupportedSourceFile
        }
        var count = 0
        func node(_ value: [String: Any], path: String, depth: Int) throws -> BrowserImportPlan.Node? {
            count += 1
            guard depth <= 64, count <= 100_000 else { throw ArcImportError.unsupportedSourceFile }
            let guid = (value["guid"] as? String).flatMap(UUID.init(uuidString:))?.uuidString
            // Store-local folders can share permanent root GUIDs but contain different children.
            let identityKey = guid.map { "guid:" + $0 } ?? (value["id"] as? String ?? path)
            let key = value["type"] as? String == "folder" ? store + ":" + identityKey :
                (guid == nil ? store + ":" + identityKey : identityKey)
            guard seen.insert(key).inserted else { return nil }
            let name = ArcImportMapper.sanitizedName(value["name"] as? String) ?? ""
            let created = (value["date_added"] as? String).flatMap(Double.init).flatMap { micros -> Date? in
                let time = micros / 1_000_000 - ArcChromiumHistoryReader.chromeEpochOffset
                return time > 0 && time < 4_102_444_800 ? Date(timeIntervalSince1970: time) : nil
            } ?? importedAt
            switch value["type"] as? String {
            case "url":
                guard let text = value["url"] as? String, let url = safeURL(text) else { return nil }
                return .tab(.init(id: identity.tab("bookmark:" + key), url: url, pageTitle: name,
                                  pinnedURL: url, createdAt: created, lastActiveAt: importedAt))
            case "folder":
                guard let children = value["children"] as? [[String: Any]] else { throw ArcImportError.unreadableSourceDocument }
                return .folder(.init(id: identity.folder("bookmark:" + key), title: name, isCollapsed: false,
                    children: [], createdAt: created), try children.enumerated().compactMap {
                        try node($0.element, path: path + ":\($0.offset)", depth: depth + 1)
                    })
            default: throw ArcImportError.unsupportedSourceFile
            }
        }
        return try ["bookmark_bar", "other", "synced"].compactMap { key in
            guard let value = roots[key] as? [String: Any] else { return nil }
            return try node(value, path: key, depth: 0)
        }
    }
    static func safeURL(_ text: String) -> URL? {
        guard text.utf8.count <= 4096, let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
