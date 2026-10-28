import Foundation

/// Names the importer must invent. English defaults like Arc; the app passes localized values.
public struct ArcImportNaming: Sendable, Equatable {
    public var space: String
    public var folder: String
    public var unresolvedProfile: String

    public init(space: String = "Space", folder: String = "Untitled Folder",
                unresolvedProfile: String = "Imported Profile") {
        self.space = space
        self.folder = folder
        self.unresolvedProfile = unresolvedProfile
    }
}

public struct ArcImportOptions: Sendable {
    public enum UnattributedArchives: Sendable, Equatable {
        /// Counted, not imported: their profile cannot be established (default).
        case skip
        case defaultProfile
    }

    public var namespace = "arc"
    /// Today tabs are optional (CORE-IMPORT brief); Favorites and Pinned are always imported.
    public var includeToday = true
    public var includeArchive = true
    public var includeHistory = true
    /// Arc's `Default` profile merges into the target's first profile instead of a new profile.
    public var adoptsDefaultProfile = true
    public var unattributedArchives = UnattributedArchives.skip
    /// Visits per history transaction; each chunk commits separately (BL-HIST-IMPORT-CHUNKS).
    public var historyChunkSize = 2_000
    public var naming = ArcImportNaming()
    public var legacyProfileDirectories: [String: String] = [:]

    public init() {}
}

public enum ArcImportMapper {
    /// - Parameter profileTargets: mappings recorded by earlier imports into the same target; they
    ///   win over adoption and derivation so a profile never moves between imports.
    public static func plan(_ graph: ArcSidebarGraph, options: ArcImportOptions = ArcImportOptions(),
                            defaultProfileTarget: ProfileID?, importedAt: Date,
                            profileTargets: [ArcProfileKey: ProfileID] = [:]) -> BrowserImportPlan {
        let identity = ArcImportIdentity(namespace: options.namespace)
        var plan = BrowserImportPlan()
        var seenTabs: Set<TabID> = []
        var seenFolders: Set<FolderID> = []

        // Profiles that own at least one Space, in the order of their first Space.
        var profileIDs: [ArcProfileKey: ProfileID] = [:]
        let names = Dictionary(graph.profiles.map { ($0.key, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        for space in graph.spaces where profileIDs[space.profile] == nil {
            let key = space.profile
            let derived = identity.profile(key)
            let id: ProfileID
            if let recorded = profileTargets[key] {
                id = recorded
            } else if options.adoptsDefaultProfile, key == .directory("Default"), let target = defaultProfileTarget {
                id = target
            } else {
                id = derived
            }
            profileIDs[key] = id
            let fallback = key.directory ?? options.naming.unresolvedProfile
            plan.profiles.append(.init(id: id, sourceKey: key, name: sanitizedName(names[key] ?? nil) ?? fallback,
                                       sourceDirectory: key.directory, isAdopted: id != derived))
        }
        let spacelessProfiles = Set(graph.profiles.map(\.key)).subtracting(profileIDs.keys)
        plan.skipped.profilesWithoutSpace = spacelessProfiles.count

        func tab(_ source: ArcImportedTab, keepsPinnedURL: Bool) -> BrowserOrganizedTab? {
            let id = identity.tab(source.sourceID)
            guard seenTabs.insert(id).inserted else { plan.skipped.duplicateIdentities += 1; return nil }
            return BrowserOrganizedTab(id: id, url: source.savedURL,
                pageTitle: BrowserOrganizationState.sanitizedPageTitle(source.savedTitle),
                customTitle: validTitle(source.customTitle),
                pinnedURL: keepsPinnedURL ? source.savedURL : nil,
                createdAt: source.createdAt ?? importedAt,
                lastActiveAt: importedAt)
        }

        func nodes(_ sources: [ArcImportedNode]) -> [BrowserImportPlan.Node] {
            sources.compactMap { source in
                switch source {
                case let .tab(value): return tab(value, keepsPinnedURL: true).map { .tab($0) }
                case let .folder(value):
                    let id = identity.folder(value.sourceID)
                    guard seenFolders.insert(id).inserted else { plan.skipped.duplicateIdentities += 1; return nil }
                    let folder = BrowserOrganizedFolder(id: id, title: validTitle(value.title) ?? options.naming.folder,
                        isCollapsed: value.isCollapsed, children: [], createdAt: value.createdAt ?? importedAt)
                    return .folder(folder, nodes(value.children))
                }
            }
        }

        var spacesByProfile: [ProfileID: [SpaceID]] = [:]
        var spaceProfiles: [String: (ProfileID, SpaceID)] = [:]
        for space in graph.spaces {
            guard let profileID = profileIDs[space.profile] else { continue }
            let id = identity.space(space.sourceID)
            let name = sanitizedName(space.title).flatMap { try? BrowserStore.validatedSpaceName($0) } ?? options.naming.space
            plan.spaces.append(.init(id: id, profileID: profileID, name: name, appearance: space.appearance))
            spacesByProfile[profileID, default: []].append(id)
            spaceProfiles[space.sourceID] = (profileID, id)
            let today: [BrowserOrganizedTab]
            if options.includeToday { today = space.today.compactMap { tab($0, keepsPinnedURL: false) } }
            else { today = []; plan.skipped.todayTabsExcluded += space.today.count }
            plan.sections.append(.init(spaceID: id, pinned: nodes(space.pinned), today: today))
        }

        var favorites: [ProfileID: [BrowserOrganizedTab]] = [:]
        var favoriteOrder: [ProfileID] = []
        for entry in graph.favorites {
            guard let profileID = profileIDs[entry.profile] else {
                plan.skipped.favoritesWithoutSpace += entry.tabs.count
                continue
            }
            if favorites[profileID] == nil { favoriteOrder.append(profileID) }
            favorites[profileID, default: []] += entry.tabs.compactMap { tab($0, keepsPinnedURL: true) }
        }
        plan.favorites = favoriteOrder.map { .init(profileID: $0, tabs: favorites[$0] ?? []) }

        if options.includeArchive {
            let defaultSpace = profileIDs[.directory("Default")].flatMap { spacesByProfile[$0]?.first }
            var seenArchive: Set<TabID> = []
            for record in graph.archive {
                let destination: (ProfileID, SpaceID)?
                if let source = record.spaceSourceID {
                    destination = spaceProfiles[source]
                } else if let key = record.profile {
                    destination = profileIDs[key].flatMap { profile in spacesByProfile[profile]?.first.map { (profile, $0) } }
                } else {
                    if options.unattributedArchives == .defaultProfile, let defaultSpace,
                       let profile = profileIDs[.directory("Default")] {
                        destination = (profile, defaultSpace)
                    } else {
                        plan.skipped.unattributedArchives += 1
                        continue
                    }
                }
                guard let (profileID, spaceID) = destination else { plan.skipped.archivesWithoutSpace += 1; continue }
                let id = identity.archivedTab(record.key)
                guard seenArchive.insert(id).inserted, !seenTabs.contains(id) else {
                    plan.skipped.duplicateIdentities += 1
                    continue
                }
                let archivedAt = record.archivedAt ?? importedAt
                let source = record.tab
                let created = source.createdAt ?? archivedAt
                let archived = BrowserOrganizedTab(id: id, url: source.savedURL,
                    pageTitle: BrowserOrganizationState.sanitizedPageTitle(source.savedTitle),
                    customTitle: validTitle(source.customTitle), pinnedURL: nil,
                    createdAt: created, lastActiveAt: source.lastActiveAt ?? created)
                plan.archive.append(BrowserArchivedTab(tab: archived, profileID: profileID, spaceID: spaceID,
                    origin: .today, reason: reason(record.reason), archivedAt: archivedAt))
            }
            plan.archive.sort { $0.archivedAt > $1.archivedAt }
        } else {
            plan.skipped.archivedTabsExcluded = graph.archive.count
        }

        if options.includeHistory {
            plan.historySources = plan.profiles.compactMap { profile in
                profile.sourceDirectory.map { .init(profileID: profile.id, directory: $0) }
            }
        }
        return plan
    }

    static func reason(_ value: String?) -> BrowserArchivedTab.Reason {
        let text = value?.lowercased() ?? ""
        if text.contains("auto") { return .automatic }
        if text.contains("clear") { return .cleared }
        return .closed
    }

    static func sanitizedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = String(value.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(BrowserOrganizationState.maximumTitleLength))
    }

    static func validTitle(_ value: String?) -> String? {
        sanitizedName(value).flatMap { try? BrowserOrganizationState.validatedTitle($0) }
    }
}
