import Foundation

/// A projection of the existing authorities; window occurrences, archive, permissions, history,
/// engine storage, script consent and per-machine preferences never enter the wire format.
public enum BrowserSyncMapping {
    static func id(_ kind: String, _ uuid: UUID) -> String { kind + "/" + uuid.uuidString }
    static func nodeID(_ node: BrowserOrganizationNode) -> String {
        switch node {
        case .tab(let value): id("tab", value.rawValue)
        case .folder(let value): id("folder", value.rawValue)
        case .split(let value): id("split", value.rawValue)
        }
    }
    static func node(_ id: String) -> BrowserOrganizationNode? {
        let parts = id.split(separator: "/")
        guard parts.count == 2, let uuid = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "tab": return .tab(TabID(uuid))
        case "folder": return .folder(FolderID(uuid))
        case "split": return .split(SplitGroupID(uuid))
        default: return nil
        }
    }

    static func fields<T: Encodable>(_ value: T, excluding: Set<String> = []) throws -> [String: Data] {
        let object = try JSONSerialization.jsonObject(with: BrowserSyncReplica.encodeValue(value)) as? [String: Any] ?? [:]
        var result: [String: Data] = [:]
        func flatten(_ object: [String: Any], prefix: String = "") throws {
            for (key, value) in object {
                let path = prefix + key
                if excluding.contains(path) { continue }
                if path == "content", let nested = value as? [String: Any], !nested.isEmpty { try flatten(nested, prefix: path + ".") }
                else { result[path] = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) }
            }
        }
        try flatten(object)
        return result
    }

    static func decode<T: Decodable>(_ type: T.Type, _ fields: [String: Data]) throws -> T {
        func expand(_ fields: [String: Data]) throws -> [String: Any] {
            var result: [String: Any] = [:]
            var nested: [String: [String: Data]] = [:]
            for (path, data) in fields where path != "placement" {
                let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
                if parts.count == 2 { nested[parts[0], default: [:]][parts[1]] = data }
                else { result[path] = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) }
            }
            for (key, children) in nested { result[key] = try expand(children) }
            return result
        }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: expand(fields), options: .sortedKeys))
    }

    public static func project(session: BrowserSessionDocument, settings: BrowserSettingsDocument,
                               boosts: [BrowserBoostDocument] = []) throws -> BrowserSyncProjection {
        var result = BrowserSyncProjection()
        result.lists["profiles"] = session.profiles.map { id("profile", $0.id.rawValue) }
        result.lists["spaces"] = session.spaces.map { id("space", $0.id.rawValue) }
        for profile in session.profiles {
            result.entries[id("profile", profile.id.rawValue)] = try fields(profile)
            // Extension installation and pinning belong to this machine.
            result.entries[id("profileSettings", profile.id.rawValue)] = try fields(settings.profile(profile.id), excluding: ["extensionPinOrder"])
            result.entries[id("archiveSettings", profile.id.rawValue)] = ["threshold": try BrowserSyncReplica.encodeValue(session.organization.archivePolicy.threshold(for: profile.id))]
        }
        for space in session.spaces {
            let key = id("space", space.id.rawValue)
            result.entries[key] = try fields(space)
            result.entries[id("spaceSettings", space.id.rawValue)] = try fields(settings.space(space.id))
        }
        result.entries["settings/global"] = ["enablesBoostsOnWebsites": try BrowserSyncReplica.encodeValue(settings.enablesBoostsOnWebsites)]
        let organization = session.organization
        let tabs = Dictionary(uniqueKeysWithValues: organization.tabs.map { ($0.id, $0) })
        let folders = Dictionary(uniqueKeysWithValues: organization.folders.map { ($0.id, $0) })
        let splits = Dictionary(uniqueKeysWithValues: organization.splits.map { ($0.id, $0) })
        func visit(_ nodes: [BrowserOrganizationNode], parent: String, root: String) throws {
            let sharedNodes = nodes.filter { $0.tabID.flatMap { tabs[$0]?.liveFolderChild } == nil }
            result.lists[parent] = sharedNodes.map(nodeID)
            for node in sharedNodes {
                let key = nodeID(node)
                result.roots[key] = root
                switch node {
                case .tab(let tabID):
                    if let tab = tabs[tabID] {
                        // A pinned tab's home destination syncs; transient away navigation does not.
                        var shared = tab; shared.url = tab.pinnedURL ?? tab.url
                        result.entries[key] = try fields(shared, excluding: ["lastActiveAt", "liveFolderChild", "pinnedLandingAlias", "localDocument"])
                    }
                case .folder(let folderID):
                    if let folder = folders[folderID] {
                        result.entries[key] = try fields(folder, excluding: ["children", "isCollapsed"])
                        try visit(folder.liveFolder == nil ? folder.children : [], parent: key, root: root)
                    }
                case .split(let splitID):
                    if let split = splits[splitID] {
                        result.entries[key] = try fields(split)
                        try visit(split.tabIDs.map(BrowserOrganizationNode.tab), parent: key, root: root)
                    }
                }
            }
        }
        for favorites in organization.favorites {
            let root = id("favorites", favorites.profileID.rawValue)
            try visit(favorites.items, parent: root, root: root)
        }
        for sections in organization.spaces {
            let root = id("pinned", sections.spaceID.rawValue)
            try visit(sections.pinned, parent: root, root: root)
        }
        for document in boosts {
            let parent = id("boosts", document.profileID.rawValue)
            result.lists[parent] = document.boosts.map { id("boost", $0.id.rawValue) }
            for boost in document.boosts {
                var data = try fields(boost, excluding: ["revision", "javaScriptOptIn"])
                data["profileID"] = try BrowserSyncReplica.encodeValue(document.profileID)
                result.entries[id("boost", boost.id.rawValue)] = data
            }
        }
        return result
    }

    public struct Materialized: Sendable {
        public let profiles: [BrowserProfile]
        public let spaces: [BrowserSpace]
        public let organization: BrowserOrganizationDocument
        public let settings: BrowserSettingsDocument
        public let boosts: [BrowserBoostDocument]
    }

    public static func materialize(_ records: [String: [String: Data]], local: BrowserSessionDocument,
                                   settings: BrowserSettingsDocument, boosts: [BrowserBoostDocument] = []) throws -> Materialized {
        func entries(_ prefix: String) -> [(String, [String: Data])] {
            records.filter { $0.key.hasPrefix(prefix + "/") }.sorted { $0.key < $1.key }
        }
        // This index belongs to this immutable materialization generation.
        let decoder = JSONDecoder()
        let placements = records.compactMapValues { fields in
            fields["placement"].flatMap { try? decoder.decode(BrowserSyncPlacement.self, from: $0) }
        }
        func placement(_ key: String) -> BrowserSyncPlacement? { placements[key] }
        // Preserve first-match behavior even for an unvalidated local snapshot.
        let localTabs = Dictionary(local.organization.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localFolders = Dictionary(local.organization.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localSplits = Dictionary(local.organization.splits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localState = try BrowserOrganizationState(document: local.organization)
        var retainedGeneratedIDs: Set<TabID> = []
        let localSections = Dictionary(local.organization.spaces.map { ($0.spaceID, $0) }, uniquingKeysWith: { first, _ in first })
        func ordered(_ keys: [String]) -> [String] {
            keys.sorted {
                let a = placement($0)?.order ?? .init(digits: [])
                let b = placement($1)?.order ?? .init(digits: [])
                return a == b ? $0 < $1 : a < b
            }
        }
        let profileValues = try Dictionary(uniqueKeysWithValues: entries("profile").map { ($0.0, try decode(BrowserProfile.self, $0.1)) })
        let profiles = ordered(Array(profileValues.keys)).compactMap { profileValues[$0] }
        let profileIDs = Set(profiles.map(\.id))
        let spaceValues = try Dictionary(uniqueKeysWithValues: entries("space").map { ($0.0, try decode(BrowserSpace.self, $0.1)) })
        let spaces = ordered(Array(spaceValues.keys)).compactMap { spaceValues[$0] }.filter { profileIDs.contains($0.profileID) }
        let spaceIDs = Set(spaces.map(\.id))
        let spaceProfiles = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.profileID) })
        let localSpaceProfiles = Dictionary(local.spaces.map { ($0.id, $0.profileID) }, uniquingKeysWith: { first, _ in first })
        var roots = Set(spaces.map { id("pinned", $0.id.rawValue) })
        roots.formUnion(profiles.map { id("favorites", $0.id.rawValue) })
        let nodeKeys = Set(records.keys.filter { node($0) != nil && placement($0) != nil })
        var parents: [String: String] = [:]
        for key in nodeKeys {
            guard let position = placement(key), roots.contains(position.root) else { continue }
            var current = position.parent
            var seen: Set<String> = [key]
            while nodeKeys.contains(current), seen.insert(current).inserted {
                current = placement(current)?.parent ?? ""
            }
            // Cycles and missing parents fall back deterministically to the recorded section.
            parents[key] = roots.contains(current) && current == position.root ? position.parent : position.root
        }
        var children: [String: [String]] = [:]
        for (key, parent) in parents { children[parent, default: []].append(key) }
        for parent in children.keys { children[parent] = ordered(children[parent] ?? []) }
        var sharedTabs: [BrowserOrganizedTab] = []
        var sharedFolders: [BrowserOrganizedFolder] = []
        var sharedSplits: [BrowserSplitGroup] = []
        var visited: Set<String> = []
        func build(_ key: String) throws -> [BrowserOrganizationNode] {
            guard visited.insert(key).inserted, let data = records[key], let node = node(key) else { return [] }
            switch node {
            case .tab(let tabID):
                var values = data
                values = values.filter { $0.key != "localDocument" && !$0.key.hasPrefix("localDocument.") }
                values.removeValue(forKey: "liveFolderChild")
                values.removeValue(forKey: "pinnedLandingAlias")
                let existing = localTabs[tabID]
                values["lastActiveAt"] = try BrowserSyncReplica.encodeValue(existing?.lastActiveAt ?? Date())
                var tab = try decode(BrowserOrganizedTab.self, values)
                if let existing, existing.pinnedURL == tab.pinnedURL {
                    tab.url = existing.url
                    tab.pinnedLandingAlias = existing.pinnedLandingAlias
                }
                tab.localDocument = existing?.localDocument
                sharedTabs.append(tab)
                return [node]
            case .folder(let folderID):
                var values = data
                values["children"] = try BrowserSyncReplica.encodeValue([BrowserOrganizationNode]())
                values["isCollapsed"] = try BrowserSyncReplica.encodeValue(localFolders[folderID]?.isCollapsed ?? false)
                var folder = try decode(BrowserOrganizedFolder.self, values)
                if let config = folder.liveFolder {
                    // Only the same local scope/configuration can retain this Mac's provider cache.
                    // A new Mac always gets an empty folder and waits for its own provider.
                    if let old = localFolders[folderID], old.liveFolder == config,
                       localState.section(of: .folder(folderID)).map({ section in
                           section.spaceID.map { space in
                               id("pinned", space.rawValue) == placement(key)?.root
                                   && localSpaceProfiles[space] == spaceProfiles[space]
                           } == true
                       }) == true {
                        let cached = old.children.compactMap { $0.tabID.flatMap { localTabs[$0] } }.filter {
                            $0.liveFolderChild?.folderID == folderID && $0.liveFolderChild?.identity.provider == config.provider
                        }
                        folder.children = cached.map { .tab($0.id) }
                        sharedTabs.append(contentsOf: cached)
                        retainedGeneratedIDs.formUnion(cached.map(\.id))
                    }
                } else { folder.children = try (children[key] ?? []).flatMap(build) }
                sharedFolders.append(folder)
                return [node]
            case .split:
                let nodes = try (children[key] ?? []).flatMap(build)
                var split = try decode(BrowserSplitGroup.self, data)
                guard nodes.count >= 2, nodes.count <= 4, nodes.allSatisfy({ $0.tabID != nil }) else { return nodes }
                if split.tabIDs != nodes.compactMap(\.tabID) {
                    split.tabIDs = nodes.compactMap(\.tabID); split.ratios = Array(repeating: 1 / Double(nodes.count), count: nodes.count)
                }
                sharedSplits.append(split)
                return [node]
            }
        }
        let favorites = try profiles.map { profile in
            BrowserOrganizationDocument.Favorites(profileID: profile.id,
                items: try (children[id("favorites", profile.id.rawValue)] ?? []).flatMap(build))
        }
        // Preserve Today and archived data on this Mac. A synced tab is represented once.
        let sharedIDs = Set(nodeKeys.compactMap { node($0)?.tabID })
        var todayIDs: Set<TabID> = []
        func keepLocal(_ nodes: [BrowserOrganizationNode]) -> [BrowserOrganizationNode] {
            nodes.flatMap { node -> [BrowserOrganizationNode] in
                switch node {
                case .tab(let id):
                    guard !sharedIDs.contains(id), todayIDs.insert(id).inserted,
                          let tab = localTabs[id] else { return [] }
                    sharedTabs.append(tab); return [node]
                case .split(let id):
                    guard var split = localSplits[id] else { return [] }
                    let kept = keepLocal(split.tabIDs.map(BrowserOrganizationNode.tab))
                    guard kept.count >= 2 else { return kept }
                    if kept.compactMap(\.tabID) != split.tabIDs {
                        split.tabIDs = kept.compactMap(\.tabID)
                        split.ratios = Array(repeating: 1 / Double(kept.count), count: kept.count)
                    }
                    sharedSplits.append(split); return [node]
                case .folder: return []
                }
            }
        }
        var sections = try spaces.map { space in
            let old = localSections[space.id]
            return BrowserOrganizationDocument.SpaceSections(spaceID: space.id,
                pinned: try (children[id("pinned", space.id.rawValue)] ?? []).flatMap(build),
                today: keepLocal(old?.today ?? []),
                isPinnedCollapsed: old?.isPinnedCollapsed ?? false)
        }
        // A remotely deleted/reconfigured folder must not destroy an open local page.
        let openIDs = Set(local.tabs.map(\.id))
        for tab in local.organization.tabs where tab.liveFolderChild != nil && !retainedGeneratedIDs.contains(tab.id) && openIDs.contains(tab.id) {
            guard let owner = localState.section(of: .tab(tab.id))?.spaceID,
                  let index = sections.firstIndex(where: { $0.spaceID == owner }) else { continue }
            var ordinary = tab; ordinary.liveFolderChild = nil; ordinary.pinnedURL = nil
            sharedTabs.append(ordinary)
            let old = sections[index]
            sections[index] = .init(spaceID: owner, pinned: old.pinned, today: old.today + [.tab(tab.id)],
                                    isPinnedCollapsed: old.isPinnedCollapsed)
        }
        var nextSettings = settings
        var policy = local.organization.archivePolicy
        for profile in profiles {
            if let fields = records[id("profileSettings", profile.id.rawValue)] {
                var merged = try self.fields(settings.profile(profile.id)); merged.merge(fields) { _, new in new }
                nextSettings.profiles[profile.id] = try decode(BrowserProfileSettings.self, merged)
            }
            if let bytes = records[id("archiveSettings", profile.id.rawValue)]?["threshold"] {
                policy.profileThresholds[profile.id] = try JSONDecoder().decode(BrowserAutoArchiveThreshold.self, from: bytes)
            }
        }
        for space in spaces {
            if let fields = records[id("spaceSettings", space.id.rawValue)] { nextSettings.spaces[space.id] = try decode(BrowserSpaceSettings.self, fields) }
        }
        if let bytes = records["settings/global"]?["enablesBoostsOnWebsites"] {
            nextSettings.enablesBoostsOnWebsites = try JSONDecoder().decode(Bool.self, from: bytes)
        }
        var documents: [BrowserBoostDocument] = []
        for profile in profiles {
            var document = BrowserBoostDocument(profileID: profile.id)
            for key in ordered(entries("boost").map(\.0)) {
                guard var fields = records[key], let bytes = fields.removeValue(forKey: "profileID"),
                      try JSONDecoder().decode(ProfileID.self, from: bytes) == profile.id else { continue }
                fields["revision"] = try BrowserSyncReplica.encodeValue(UInt64(1))
                fields["javaScriptOptIn"] = try BrowserSyncReplica.encodeValue(false)
                var boost = try decode(BrowserBoost.self, fields)
                // Consent stays only if the script on this Mac is exactly the one consented to.
                if let old = boosts.first(where: { $0.profileID == profile.id })?.boosts.first(where: { $0.id == boost.id }),
                   old.content.customJavaScript == boost.content.customJavaScript { boost.javaScriptOptIn = old.javaScriptOptIn }
                document.boosts.append(boost)
            }
            documents.append(document)
        }
        let owners = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.profileID) })
        let archive = local.organization.archive.filter { profileIDs.contains($0.profileID) && !sharedIDs.contains($0.id) }.map { record in
            var record = record
            if let owner = owners[record.spaceID], owner != record.profileID { record.spaceProfileWasChanged = true }
            return record
        }
        let archivedIDs = Set(archive.map(\.id))
        let organization = BrowserOrganizationDocument(tabs: sharedTabs, folders: sharedFolders, favorites: favorites,
            spaces: sections, archive: archive,
            archivePolicy: policy, splits: sharedSplits,
            archivedSpaces: local.organization.archivedSpaces.filter { profileIDs.contains($0.space.profileID) }.map { $0.retainingTabs(archivedIDs) })
        return .init(profiles: profiles, spaces: spaces, organization: organization, settings: nextSettings, boosts: documents)
    }
}

extension BrowserStore {
    /// Admission and graph publication are one actor turn. A stale network snapshot never
    /// overwrites a local command. Windows stay local and occurrences reconcile by logical ID.
    public func applySync(_ value: BrowserSyncMapping.Materialized, expected: BrowserSessionDocument) throws {
        guard deletingProfiles.isEmpty, sessionDocument() == expected else { throw BrowserSyncError.localChange }
        guard !value.spaces.isEmpty, !value.profiles.isEmpty else { throw BrowserSyncError.invalidRecord }
        let state = try BrowserOrganizationState(document: value.organization)
        try state.validate(profiles: Set(value.profiles.map(\.id)), spaces: Dictionary(uniqueKeysWithValues: value.spaces.map { ($0.id, $0.profileID) }))
        let previousSpaceProfiles = spaces.mapValues(\.profileID)
        profiles = Dictionary(uniqueKeysWithValues: value.profiles.map { ($0.id, $0) })
        spaces = Dictionary(uniqueKeysWithValues: value.spaces.map { ($0.id, $0) })
        profileOrder = value.profiles.map(\.id); spaceOrder = value.spaces.map(\.id)
        for old in organization.folders.values {
            guard let config = old.liveFolder,
                  let space = organization.section(of: .folder(old.id))?.spaceID,
                  let profile = previousSpaceProfiles[space], profiles[profile] != nil else { continue }
            if state.folders[old.id]?.liveFolder == nil {
                disableLiveFolderRecreation(config.provider, profileID: profile)
            } else if state.folders[old.id]?.liveFolder != config {
                _ = try advanceLiveFolderGeneration(for: config.provider, profileID: profile)
            }
        }
        liveFolderLocalStores = liveFolderLocalStores.filter { profiles[$0.key] != nil }
        organization = state
        themeImports = themeImports.intersection(Set(spaceOrder))
        for key in windows.keys {
            if let active = windows[key]?.activeSpaceID, spaces[active] == nil { windows[key]?.activeSpaceID = spaceOrder[0] }
        }
        rehomeStandaloneWindows()
        reconcileOccurrences()
        for key in windows.keys {
            windows[key]?.occurrenceIDsBySpace = windows[key]?.occurrenceIDsBySpace.filter { spaces[$0.key] != nil } ?? [:]
            windows[key]?.selectedOccurrenceBySpace = windows[key]?.selectedOccurrenceBySpace.filter { spaces[$0.key] != nil } ?? [:]
            windows[key]?.revision &+= 1
        }
        organizationJournals.removeAll()
        publishOrganizationChange()
    }
}
