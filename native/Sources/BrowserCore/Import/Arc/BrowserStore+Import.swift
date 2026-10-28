import Foundation

/// Identities an import has already brought into the store. A re-run adds an object only if it is
/// neither in the store nor in this ledger, so deleting an imported item and re-importing does not
/// resurrect it. UUIDs only: no names, titles or URLs.
public struct BrowserImportLedger: Codable, Equatable, Sendable {
    public var profiles: Set<UUID> = []
    public var spaces: Set<UUID> = []
    public var tabs: Set<UUID> = []
    public var folders: Set<UUID> = []
    public var archive: Set<UUID> = []
    /// Arc profile → target profile chosen by the first import (`ArcProfileKey.ledgerKey`). Reused
    /// by every re-import, so Arc's Default stays attached to the same Orbit profile even after the
    /// target's first profile changes.
    public var profileMappings: [String: UUID] = [:]

    public init() {}

    public mutating func formUnion(_ other: BrowserImportLedger) {
        profileMappings.merge(other.profileMappings) { first, _ in first }
        profiles.formUnion(other.profiles)
        spaces.formUnion(other.spaces)
        tabs.formUnion(other.tabs)
        folders.formUnion(other.folders)
        archive.formUnion(other.archive)
    }

    public var isEmpty: Bool {
        profiles.isEmpty && spaces.isEmpty && tabs.isEmpty && folders.isEmpty && archive.isEmpty && profileMappings.isEmpty
    }

    /// Stored mappings, ignoring malformed keys.
    public var profileTargets: [ArcProfileKey: ProfileID] {
        var result: [ArcProfileKey: ProfileID] = [:]
        for (key, value) in profileMappings {
            if let profile = ArcProfileKey(ledgerKey: key) { result[profile] = ProfileID(value) }
        }
        return result
    }

    private enum CodingKeys: String, CodingKey { case version, profiles, spaces, tabs, folders, archive, profileMappings }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else { throw BrowserSessionError.unsupportedVersion }
        profiles = Set(try container.decode([UUID].self, forKey: .profiles))
        spaces = Set(try container.decode([UUID].self, forKey: .spaces))
        tabs = Set(try container.decode([UUID].self, forKey: .tabs))
        folders = Set(try container.decode([UUID].self, forKey: .folders))
        archive = Set(try container.decode([UUID].self, forKey: .archive))
        profileMappings = try container.decodeIfPresent([String: UUID].self, forKey: .profileMappings) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        func sorted(_ values: Set<UUID>) -> [UUID] { values.sorted { $0.uuidString < $1.uuidString } }
        try container.encode(1, forKey: .version)
        try container.encode(sorted(profiles), forKey: .profiles)
        try container.encode(sorted(spaces), forKey: .spaces)
        try container.encode(sorted(tabs), forKey: .tabs)
        try container.encode(sorted(folders), forKey: .folders)
        try container.encode(sorted(archive), forKey: .archive)
        try container.encode(profileMappings, forKey: .profileMappings)
    }
}

/// What a merge added or found, counts only.
public struct BrowserImportMergeCounts: Codable, Equatable, Sendable {
    public var profilesAdded = 0
    public var profilesPresent = 0
    public var spacesAdded = 0
    public var spacesPresent = 0
    public var favoritesAdded = 0
    public var pinnedTabsAdded = 0
    public var pinnedFoldersAdded = 0
    public var todayTabsAdded = 0
    public var archivedTabsAdded = 0
    /// Already in the store from an earlier import: left where the user put them, untouched.
    public var itemsPresent = 0
    /// Imported earlier, then deleted by the user: not resurrected.
    public var itemsPreviouslyRemoved = 0
    /// Inside a Space, profile or folder that the user deleted since an earlier import.
    public var itemsWithoutDestination = 0
    /// Oldest archive records beyond the per-profile cap, evicted immediately.
    public var archivedTabsEvicted = 0
    /// A Space identity that now belongs to another profile (not merged).
    public var conflicts = 0
    /// Encoded size of the session document after the merge (what the next launch must read).
    public var projectedSessionBytes = 0

    public init() {}

    public var addedItems: Int { favoritesAdded + pinnedTabsAdded + pinnedFoldersAdded + todayTabsAdded }
}

public struct BrowserImportMergeResult: Sendable, Equatable {
    public let counts: BrowserImportMergeCounts
    /// Identities of the plan now present in (or deliberately absent from) the store.
    public let ledger: BrowserImportLedger
}

extension BrowserStore {
    /// Largest merged session an import may produce: 90 % of the read limit applied at launch
    /// (`BrowserSessionDocument.defaultMaximumInputBytes`), leaving room for later browsing state.
    public static let importSessionBudgetBytes = BrowserSessionDocument.defaultMaximumInputBytes / 10 * 9

    /// Counts what `applyImport` would do now, without changing anything, including the encoded
    /// size of the resulting session.
    public func previewImport(_ plan: BrowserImportPlan, ledger: BrowserImportLedger) -> BrowserImportMergeCounts {
        (try? mergeImport(plan, ledger: ledger, commit: false, maximumSessionBytes: .max).counts) ?? BrowserImportMergeCounts()
    }

    /// Adds the plan's profiles, Spaces, Favorites, Pinned (with folders), Today and archive in one
    /// actor turn. Existing objects keep their names, positions and contents; new ones are appended
    /// in source order. Imported tabs have no live occurrence: nothing loads. Not undoable (the
    /// importer keeps a backup). A thrown error leaves the store unchanged.
    /// Refused with `sessionTooLarge`, before any mutation, when the merged session would exceed
    /// `maximumSessionBytes`.
    public func applyImport(_ plan: BrowserImportPlan, ledger: BrowserImportLedger,
                            maximumSessionBytes: Int = BrowserStore.importSessionBudgetBytes) throws -> BrowserImportMergeResult {
        try mergeImport(plan, ledger: ledger, commit: true, maximumSessionBytes: maximumSessionBytes)
    }

    private func mergeImport(_ plan: BrowserImportPlan, ledger: BrowserImportLedger,
                             commit: Bool, maximumSessionBytes: Int) throws -> BrowserImportMergeResult {
        guard plan.profiles.allSatisfy({ !deletingProfiles.contains($0.id) }) else {
            throw BrowserSettingsError.profileBeingDeleted
        }
        var counts = BrowserImportMergeCounts()
        var present = BrowserImportLedger()
        let saved = (profiles, spaces, profileOrder, spaceOrder)
        func restoreCatalog() { (profiles, spaces, profileOrder, spaceOrder) = saved }

        var usableProfiles: Set<ProfileID> = []
        for profile in plan.profiles {
            defer {
                if usableProfiles.contains(profile.id) { present.profileMappings[profile.sourceKey.ledgerKey] = profile.id.rawValue }
            }
            if profiles[profile.id] != nil {
                counts.profilesPresent += 1
                usableProfiles.insert(profile.id)
                if !profile.isAdopted { present.profiles.insert(profile.id.rawValue) }
            } else if ledger.profiles.contains(profile.id.rawValue) {
                counts.itemsPreviouslyRemoved += 1
            } else {
                profiles[profile.id] = BrowserProfile(id: profile.id, name: profile.name)
                profileOrder.append(profile.id)
                usableProfiles.insert(profile.id)
                present.profiles.insert(profile.id.rawValue)
                counts.profilesAdded += 1
            }
        }
        var usableSpaces: Set<SpaceID> = []
        for space in plan.spaces {
            guard usableProfiles.contains(space.profileID) else { counts.itemsWithoutDestination += 1; continue }
            if let existing = spaces[space.id] {
                guard existing.profileID == space.profileID else { counts.conflicts += 1; continue }
                counts.spacesPresent += 1
            } else if ledger.spaces.contains(space.id.rawValue) {
                counts.itemsPreviouslyRemoved += 1
                continue
            } else {
                spaces[space.id] = BrowserSpace(id: space.id, profileID: space.profileID, name: space.name)
                spaceOrder.append(space.id)
                counts.spacesAdded += 1
            }
            usableSpaces.insert(space.id)
            present.spaces.insert(space.id.rawValue)
        }
        let catalogChanged = counts.profilesAdded + counts.spacesAdded > 0

        do {
            // Merge a copy first: the projected session must fit before anything is published.
            var candidate = organization
            Self.mergeOrganization(&candidate, plan: plan, ledger: ledger, usableProfiles: usableProfiles,
                                   usableSpaces: usableSpaces, counts: &counts, present: &present)
            let current = organization
            organization = candidate
            defer { organization = current }
            if commit {
                counts.projectedSessionBytes = try sessionDocument().encoded().count
            } else {
                counts.projectedSessionBytes = (try? sessionDocument().encoded().count) ?? 0
            }
        } catch {
            restoreCatalog()
            throw error
        }
        guard commit else {
            restoreCatalog()
            return BrowserImportMergeResult(counts: counts, ledger: present)
        }
        guard counts.projectedSessionBytes <= maximumSessionBytes else {
            restoreCatalog()
            throw ArcImportError.sessionTooLarge(projectedBytes: counts.projectedSessionBytes, limitBytes: maximumSessionBytes)
        }
        do {
            let patch = try commitOrganization { state in
                var replayCounts = BrowserImportMergeCounts()
                var replayLedger = BrowserImportLedger()
                Self.mergeOrganization(&state, plan: plan, ledger: ledger, usableProfiles: usableProfiles,
                                       usableSpaces: usableSpaces, counts: &replayCounts, present: &replayLedger)
            }
            if patch == nil, catalogChanged { publishOrganizationChange() }
        } catch {
            restoreCatalog()
            throw error
        }
        return BrowserImportMergeResult(counts: counts, ledger: present)
    }

    /// Pure merge of the plan into an organization state; shared by preview and apply.
    private static func mergeOrganization(
        _ state: inout BrowserOrganizationState, plan: BrowserImportPlan, ledger: BrowserImportLedger,
        usableProfiles: Set<ProfileID>, usableSpaces: Set<SpaceID>,
        counts: inout BrowserImportMergeCounts, present: inout BrowserImportLedger
    ) {
        let archived = Set(state.archive.map(\.id))
        func add(_ tab: BrowserOrganizedTab, into container: BrowserOrganizationContainer, counter: WritableKeyPath<BrowserImportMergeCounts, Int>) {
            if state.tabs[tab.id] != nil || archived.contains(tab.id) {
                counts.itemsPresent += 1
                present.tabs.insert(tab.id.rawValue)
            } else if ledger.tabs.contains(tab.id.rawValue) {
                counts.itemsPreviouslyRemoved += 1
            } else {
                state.addTab(tab, into: container, at: state.children(of: container).count)
                present.tabs.insert(tab.id.rawValue)
                counts[keyPath: counter] += 1
            }
        }
        func descendants(_ nodes: [BrowserImportPlan.Node]) -> Int {
            nodes.reduce(0) { total, node in
                if case let .folder(_, children) = node { return total + 1 + descendants(children) }
                return total + 1
            }
        }
        func add(_ nodes: [BrowserImportPlan.Node], into container: BrowserOrganizationContainer) {
            for node in nodes {
                switch node {
                case let .tab(tab): add(tab, into: container, counter: \.pinnedTabsAdded)
                case let .folder(folder, children):
                    if state.folders[folder.id] != nil {
                        counts.itemsPresent += 1
                    } else if ledger.folders.contains(folder.id.rawValue) {
                        counts.itemsPreviouslyRemoved += 1
                        counts.itemsWithoutDestination += descendants(children)
                        continue
                    } else {
                        state.addFolder(folder, into: container, at: state.children(of: container).count)
                        counts.pinnedFoldersAdded += 1
                    }
                    present.folders.insert(folder.id.rawValue)
                    add(children, into: .folder(folder.id))
                }
            }
        }
        for favorites in plan.favorites {
            guard usableProfiles.contains(favorites.profileID) else {
                counts.itemsWithoutDestination += favorites.tabs.count
                continue
            }
            for tab in favorites.tabs { add(tab, into: .favorites(favorites.profileID), counter: \.favoritesAdded) }
        }
        for section in plan.sections {
            guard usableSpaces.contains(section.spaceID) else {
                counts.itemsWithoutDestination += descendants(section.pinned) + section.today.count
                continue
            }
            add(section.pinned, into: .pinned(section.spaceID))
            for tab in section.today { add(tab, into: .today(section.spaceID), counter: \.todayTabsAdded) }
        }
        var records: [BrowserArchivedTab] = []
        for record in plan.archive {
            if state.tabs[record.id] != nil || archived.contains(record.id) {
                counts.itemsPresent += 1
                present.archive.insert(record.id.rawValue)
            } else if ledger.archive.contains(record.id.rawValue) {
                counts.itemsPreviouslyRemoved += 1
            } else if !usableSpaces.contains(record.spaceID) {
                counts.itemsWithoutDestination += 1
            } else {
                records.append(record)
                // Evicted records are recorded too, so a re-run does not churn them again.
                present.archive.insert(record.id.rawValue)
            }
        }
        let before = state.archive.count
        state.insertArchive(records)
        counts.archivedTabsAdded = records.count
        counts.archivedTabsEvicted = before + records.count - state.archive.count
    }
}
