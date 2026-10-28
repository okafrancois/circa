import Foundation

/// Records which keys a mutation touched, so an undo patch captures exactly those keys.
struct BrowserOrganizationChangeSet: Sendable {
    var nodes: Set<BrowserOrganizationNode> = []
    var tabFields: Set<TabID> = []
    var folderTitles: Set<FolderID> = []
    var splits: Set<SplitGroupID> = []
    var archive: Set<TabID> = []
    /// Visible but non-undoable changes: destinations, web titles, collapse state, policy.
    var metadata = false

    var isEmpty: Bool {
        nodes.isEmpty && tabFields.isEmpty && folderTitles.isEmpty && splits.isEmpty && archive.isEmpty && !metadata
    }
}

/// Position of a node at one moment; neighbors let a later reinsertion survive concurrent edits.
struct BrowserOrganizationPlacement: Equatable, Sendable {
    let container: BrowserOrganizationContainer
    let index: Int
    let previous: BrowserOrganizationNode?
    let next: BrowserOrganizationNode?
}

/// The value-type organization graph owned by `BrowserStore`. All structural mutations go through
/// the primitives below, which maintain the parent index and the change set.
struct BrowserOrganizationState: Sendable {
    var tabs: [TabID: BrowserOrganizedTab] = [:]
    var folders: [FolderID: BrowserOrganizedFolder] = [:]
    var splits: [SplitGroupID: BrowserSplitGroup] = [:]
    var favorites: [ProfileID: [BrowserOrganizationNode]] = [:]
    var pinned: [SpaceID: [BrowserOrganizationNode]] = [:]
    var today: [SpaceID: [BrowserOrganizationNode]] = [:]
    var collapsedPinnedSections: Set<SpaceID> = []
    /// Newest first.
    var archive: [BrowserArchivedTab] = []
    var archivedSpaces: [BrowserArchivedSpace] = []
    var policy = BrowserArchivePolicy()
    var changes = BrowserOrganizationChangeSet()
    private(set) var parents: [BrowserOrganizationNode: BrowserOrganizationContainer] = [:]
    /// Version of each node's placement, assigned when a command moves, creates or restores the
    /// node and left alone when siblings shift. Undo preconditions compare it, so a concurrent
    /// reorder of the same node is a conflict while unrelated insertions are not. In memory only,
    /// like the undo journals; nodes decoded from a document start at 0.
    private(set) var placementVersions: [BrowserOrganizationNode: UInt64] = [:]
    private var lastPlacementVersion: UInt64 = 0

    init() {}

    // MARK: Queries

    func children(of container: BrowserOrganizationContainer) -> [BrowserOrganizationNode] {
        switch container {
        case let .favorites(id): return favorites[id] ?? []
        case let .pinned(id): return pinned[id] ?? []
        case let .today(id): return today[id] ?? []
        case let .folder(id): return folders[id]?.children ?? []
        case let .split(id): return splits[id]?.tabIDs.map(BrowserOrganizationNode.tab) ?? []
        }
    }

    func contains(_ node: BrowserOrganizationNode) -> Bool {
        switch node {
        case let .tab(id): return tabs[id] != nil
        case let .folder(id): return folders[id] != nil
        case let .split(id): return splits[id] != nil
        }
    }

    func container(of node: BrowserOrganizationNode) -> BrowserOrganizationContainer? { parents[node] }

    /// Walks up folders to the section root. Bounded so a corrupted index cannot loop.
    func section(of node: BrowserOrganizationNode) -> BrowserOrganizationSection? {
        var current = parents[node]
        var steps = 0
        while let parent = current?.owningNode {
            steps += 1
            guard steps <= folders.count + splits.count else { return nil }
            current = parents[parent]
        }
        return current?.rootSection
    }

    func section(ofContainer container: BrowserOrganizationContainer) -> BrowserOrganizationSection? {
        if let root = container.rootSection { return root }
        guard let node = container.owningNode, contains(node) else { return nil }
        return section(of: node)
    }

    func ancestors(of node: BrowserOrganizationNode) -> [FolderID] {
        var result: [FolderID] = []
        var current = parents[node]
        var visited = 0
        while let node = current?.owningNode, visited <= folders.count + splits.count {
            visited += 1
            if let id = node.folderID { result.append(id) }
            current = parents[node]
        }
        return result
    }

    func placement(of node: BrowserOrganizationNode) -> BrowserOrganizationPlacement? {
        guard let container = parents[node] else { return nil }
        let list = children(of: container)
        guard let index = list.firstIndex(of: node) else { return nil }
        return BrowserOrganizationPlacement(container: container, index: index,
            previous: index > 0 ? list[index - 1] : nil,
            next: index + 1 < list.count ? list[index + 1] : nil)
    }

    /// Every tab of a subtree, in sidebar order.
    func tabIDs(in node: BrowserOrganizationNode) -> [TabID] {
        var result: [TabID] = []
        var stack = [node]
        while let current = stack.popLast() {
            switch current {
            case let .tab(id): result.append(id)
            case let .folder(id): stack.append(contentsOf: (folders[id]?.children ?? []).reversed())
            case let .split(id): result.append(contentsOf: splits[id]?.tabIDs ?? [])
            }
        }
        return result
    }

    func folderIDs(in node: BrowserOrganizationNode) -> [FolderID] {
        var result: [FolderID] = []
        var stack = [node]
        while let current = stack.popLast() {
            guard case let .folder(id) = current else { continue }
            result.append(id)
            stack.append(contentsOf: (folders[id]?.children ?? []).reversed())
        }
        return result
    }

    /// Placements of many nodes with one scan per container, instead of one scan per node.
    func placements<Nodes: Sequence>(
        of nodes: Nodes
    ) -> [BrowserOrganizationNode: BrowserOrganizationPlacement] where Nodes.Element == BrowserOrganizationNode {
        var wanted: [BrowserOrganizationContainer: Set<BrowserOrganizationNode>] = [:]
        for node in nodes {
            if let container = parents[node] { wanted[container, default: []].insert(node) }
        }
        var result: [BrowserOrganizationNode: BrowserOrganizationPlacement] = [:]
        for (container, members) in wanted {
            let list = children(of: container)
            for (index, node) in list.enumerated() where members.contains(node) && result[node] == nil {
                result[node] = BrowserOrganizationPlacement(container: container, index: index,
                    previous: index > 0 ? list[index - 1] : nil,
                    next: index + 1 < list.count ? list[index + 1] : nil)
            }
        }
        return result
    }

    func placementVersion(of node: BrowserOrganizationNode) -> UInt64 { placementVersions[node] ?? 0 }

    /// Sorts nodes in sidebar order: section (Favorites, Pinned, Today), then depth-first position,
    /// as the rows appear. One walk over the sections involved, then an integer sort.
    func sortedInSidebarOrder(_ nodes: [BrowserOrganizationNode]) -> [BrowserOrganizationNode] {
        guard nodes.count > 1 else { return nodes }
        var roots: Set<BrowserOrganizationContainer> = []
        for node in nodes {
            var container = parents[node]
            var steps = 0
            while let parent = container?.owningNode, steps <= folders.count + splits.count {
                steps += 1
                container = parents[parent]
            }
            if let container, container.rootSection != nil { roots.insert(container) }
        }
        func rank(_ container: BrowserOrganizationContainer) -> (Int, String) {
            switch container {
            case let .favorites(id): return (0, id.rawValue.uuidString)
            case let .pinned(id): return (1, id.rawValue.uuidString)
            case let .today(id): return (2, id.rawValue.uuidString)
            case let .folder(id): return (3, id.rawValue.uuidString)
            case let .split(id): return (4, id.rawValue.uuidString)
            }
        }
        var order: [BrowserOrganizationNode: Int] = [:]
        var position = 0
        for root in roots.sorted(by: { rank($0) < rank($1) }) {
            var stack = Array(children(of: root).reversed())
            while let node = stack.popLast(), position <= tabs.count + folders.count + splits.count {
                order[node] = position
                position += 1
                if case let .folder(id) = node { stack.append(contentsOf: (folders[id]?.children ?? []).reversed()) }
                if case let .split(id) = node { stack.append(contentsOf: (splits[id]?.tabIDs ?? []).reversed().map(BrowserOrganizationNode.tab)) }
            }
        }
        // Nodes outside the sidebar sort first; callers refuse them.
        return nodes.map { ($0, order[$0] ?? -1) }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    func archivedTab(_ id: TabID) -> BrowserArchivedTab? { archive.first { $0.id == id } }

    // MARK: Primitives

    private mutating func setChildren(_ nodes: [BrowserOrganizationNode], of container: BrowserOrganizationContainer) {
        switch container {
        case let .favorites(id): favorites[id] = nodes.isEmpty ? nil : nodes
        case let .pinned(id): pinned[id] = nodes.isEmpty ? nil : nodes
        case let .today(id): today[id] = nodes.isEmpty ? nil : nodes
        case let .folder(id): folders[id]?.children = nodes
        case let .split(id):
            if var split = splits[id] {
                let weights = Dictionary(uniqueKeysWithValues: zip(split.tabIDs, split.ratios))
                split.tabIDs = nodes.compactMap(\.tabID)
                let raw = split.tabIDs.map { weights[$0] ?? 1 }
                let total = raw.reduce(0, +)
                split.ratios = raw.map { $0 / max(total, Double.leastNonzeroMagnitude) }
                splits[id] = split
                changes.splits.insert(id)
            }
        }
    }

    @discardableResult
    mutating func detach(_ node: BrowserOrganizationNode) -> BrowserOrganizationPlacement? {
        guard let placement = placement(of: node) else {
            if parents.removeValue(forKey: node) != nil { changes.nodes.insert(node) }
            return nil
        }
        var list = children(of: placement.container)
        list.remove(at: placement.index)
        setChildren(list, of: placement.container)
        parents[node] = nil
        changes.nodes.insert(node)
        return placement
    }

    /// Detaches many nodes with one rebuild per container.
    mutating func detach<Nodes: Sequence>(all nodes: Nodes) where Nodes.Element == BrowserOrganizationNode {
        var leaving: [BrowserOrganizationContainer: Set<BrowserOrganizationNode>] = [:]
        for node in nodes {
            guard let container = parents.removeValue(forKey: node) else { continue }
            leaving[container, default: []].insert(node)
            changes.nodes.insert(node)
        }
        for (container, members) in leaving {
            setChildren(children(of: container).filter { !members.contains($0) }, of: container)
        }
    }

    mutating func insert(_ node: BrowserOrganizationNode, into container: BrowserOrganizationContainer, at index: Int) {
        insert([node], into: container, at: index)
    }

    /// Inserts a block of detached nodes, keeping their order.
    mutating func insert(_ nodes: [BrowserOrganizationNode], into container: BrowserOrganizationContainer, at index: Int) {
        guard !nodes.isEmpty else { return }
        var list = children(of: container)
        list.insert(contentsOf: nodes, at: min(max(index, 0), list.count))
        setChildren(list, of: container)
        for node in nodes {
            parents[node] = container
            changes.nodes.insert(node)
        }
    }

    mutating func addTab(_ tab: BrowserOrganizedTab, into container: BrowserOrganizationContainer, at index: Int) {
        tabs[tab.id] = tab
        insert(.tab(tab.id), into: container, at: index)
    }

    mutating func addFolder(_ folder: BrowserOrganizedFolder, into container: BrowserOrganizationContainer, at index: Int) {
        var empty = folder
        empty.children = []
        folders[folder.id] = empty
        insert(.folder(folder.id), into: container, at: index)
    }

    /// Callers move or remove the children first.
    mutating func removeEmptyFolder(_ id: FolderID) {
        detach(.folder(id))
        changes.nodes.insert(.folder(id))
        folders.removeValue(forKey: id)
    }

    /// Custom title and pinned URL are undoable; other field changes are metadata.
    mutating func updateTab(_ id: TabID, _ body: (inout BrowserOrganizedTab) -> Void) {
        guard var tab = tabs[id] else { return }
        let before = tab
        body(&tab)
        guard tab != before else { return }
        tabs[id] = tab
        if tab.customTitle != before.customTitle || tab.pinnedURL != before.pinnedURL {
            changes.tabFields.insert(id)
        }
        if tab.url != before.url || tab.pageTitle != before.pageTitle { changes.metadata = true }
    }

    /// Not tracked: viewing time is neither visible in snapshots nor undoable.
    mutating func touch(_ id: TabID, at date: Date) {
        tabs[id]?.lastActiveAt = date
    }

    mutating func renameFolder(_ id: FolderID, to title: String) {
        guard let folder = folders[id], folder.title != title else { return }
        folders[id]?.title = title
        changes.folderTitles.insert(id)
    }

    mutating func setFolderCollapsed(_ id: FolderID, _ collapsed: Bool) {
        guard let folder = folders[id], folder.isCollapsed != collapsed else { return }
        folders[id]?.isCollapsed = collapsed
        changes.metadata = true
    }

    mutating func setPinnedSectionCollapsed(_ spaceID: SpaceID, _ collapsed: Bool) {
        let changed = collapsed ? collapsedPinnedSections.insert(spaceID).inserted
            : collapsedPinnedSections.remove(spaceID) != nil
        if changed { changes.metadata = true }
    }

    struct ArchiveRequest: Sendable {
        let id: TabID
        let reason: BrowserArchivedTab.Reason
        let origin: BrowserArchivedTab.Origin
        let profileID: ProfileID
        let spaceID: SpaceID
    }

    /// Removes a tab from the sidebar into the archive, newest first, within the policy's cap.
    @discardableResult
    mutating func archiveTab(
        _ id: TabID, reason: BrowserArchivedTab.Reason, origin: BrowserArchivedTab.Origin,
        profileID: ProfileID, spaceID: SpaceID, at date: Date
    ) -> BrowserArchivedTab? {
        archiveTabs([ArchiveRequest(id: id, reason: reason, origin: origin, profileID: profileID, spaceID: spaceID)],
                    at: date).first
    }

    /// Archives many tabs with one detach per container and one merge into the archive. The result
    /// matches archiving them one by one: the last request becomes the newest record.
    @discardableResult
    mutating func archiveTabs(_ requests: [ArchiveRequest], at date: Date) -> [BrowserArchivedTab] {
        var seen: Set<TabID> = []
        let requests = requests.filter { tabs[$0.id] != nil && seen.insert($0.id).inserted }
        detach(all: requests.map { BrowserOrganizationNode.tab($0.id) })
        var records: [BrowserArchivedTab] = []
        for request in requests {
            guard let tab = tabs.removeValue(forKey: request.id) else { continue }
            changes.nodes.insert(.tab(request.id))
            records.append(BrowserArchivedTab(tab: tab, profileID: request.profileID, spaceID: request.spaceID,
                                              origin: request.origin, reason: request.reason, archivedAt: date))
        }
        insertArchive(records.reversed())
        return records
    }

    mutating func insertArchive(_ record: BrowserArchivedTab) {
        insertArchive([record])
    }

    /// Merges records given newest first. At equal dates, inserted records precede existing ones.
    /// The cap is applied once, after every insertion, so it only ever evicts the oldest records.
    mutating func insertArchive<Records: Collection>(_ records: Records) where Records.Element == BrowserArchivedTab {
        guard !records.isEmpty else { return }
        // Callers pass newest first already; the stable sort only protects the merge.
        let records = records.enumerated()
            .sorted { ($0.element.archivedAt, -$0.offset) > ($1.element.archivedAt, -$1.offset) }
            .map(\.element)
        var merged: [BrowserArchivedTab] = []
        merged.reserveCapacity(archive.count + records.count)
        var existing = archive[...]
        for record in records {
            while let first = existing.first, first.archivedAt > record.archivedAt {
                merged.append(first)
                existing.removeFirst()
            }
            merged.append(record)
            noteArchiveChange(record)
        }
        merged.append(contentsOf: existing)
        archive = merged
        capArchive()
    }

    /// Keeps the newest `maximumArchivedTabs` records of each profile: one profile's sweep never
    /// evicts another profile's records. Returns the evicted records.
    @discardableResult
    mutating func capArchive() -> [BrowserArchivedTab] {
        let limit = max(policy.maximumArchivedTabs, 0)
        var counts: [ProfileID: Int] = [:]
        var evicted: [BrowserArchivedTab] = []
        var kept: [BrowserArchivedTab] = []
        kept.reserveCapacity(archive.count)
        for record in archive {
            counts[record.profileID, default: 0] += 1
            if counts[record.profileID, default: 0] <= limit { kept.append(record) } else { evicted.append(record) }
        }
        guard !evicted.isEmpty else { return [] }
        archive = kept
        for record in evicted { noteArchiveChange(record) }
        return evicted
    }

    private mutating func noteArchiveChange(_ record: BrowserArchivedTab) {
        changes.archive.insert(record.id)
    }

    /// One pass over the archive for a snapshot: the profile's record count, whether ⇧⌘T has a
    /// manual record to restore, and a revision derived from the profile's records (identity,
    /// date, reason, in order). Equal archives give equal revisions, across restoration too, so a
    /// view refetches `archivedTabs(from:)` exactly when the archive it shows changed.
    func archiveSummary(of profileID: ProfileID) -> (count: Int, canRestore: Bool, revision: UInt64) {
        var count = 0
        var canRestore = false
        var revision: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ value: UInt64) {
            for shift in stride(from: 0, to: 64, by: 8) {
                revision = (revision ^ ((value >> UInt64(shift)) & 0xFF)) &* 0x0000_0100_0000_01B3
            }
        }
        for record in archive where record.profileID == profileID {
            count += 1
            if record.reason != .automatic { canRestore = true }
            let uuid = record.id.rawValue.uuid
            mix(withUnsafeBytes(of: uuid) { $0.load(fromByteOffset: 0, as: UInt64.self) })
            mix(withUnsafeBytes(of: uuid) { $0.load(fromByteOffset: 8, as: UInt64.self) })
            mix(record.archivedAt.timeIntervalSinceReferenceDate.bitPattern)
            switch record.reason {
            case .closed: mix(1)
            case .automatic: mix(2)
            case .cleared: mix(3)
            case .removed: mix(4)
            }
        }
        mix(UInt64(count))
        return (count, canRestore, revision)
    }

    @discardableResult
    mutating func removeArchive(_ id: TabID) -> BrowserArchivedTab? {
        guard let index = archive.firstIndex(where: { $0.id == id }) else { return nil }
        let record = archive.remove(at: index)
        noteArchiveChange(record)
        return record
    }

    mutating func normalizeArchivedSpaces() {
        guard !archivedSpaces.isEmpty else { return }
        let allowed = Set(archive.map(\.id))
        let normalized = archivedSpaces.map { $0.retainingTabs(allowed) }
        if normalized != archivedSpaces { archivedSpaces = normalized; changes.metadata = true }
    }

    mutating func removeSpace(_ space: BrowserSpace, at date: Date) {
        let id = space.id, profileID = space.profileID
        let roots = (pinned[id] ?? []) + (today[id] ?? [])
        let foldersToRemove = roots.flatMap(folderIDs(in:))
        let splitsToRemove = splits.keys.filter { section(of: .split($0))?.spaceID == id }
        let tabIDsToSave = Set(roots.flatMap(tabIDs(in:)))
        let snapshot = BrowserOrganizationDocument(tabs: tabIDsToSave.compactMap { tabs[$0] }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString },
            folders: foldersToRemove.compactMap { folders[$0] }, favorites: [],
            spaces: [.init(spaceID: id, pinned: pinned[id] ?? [], today: today[id] ?? [],
                           isPinnedCollapsed: collapsedPinnedSections.contains(id))],
            archive: [], archivePolicy: .init(), splits: splitsToRemove.compactMap { splits[$0] })
        archivedSpaces.removeAll { $0.id == id }
        archivedSpaces.insert(.init(space: space, contents: snapshot, archivedAt: date), at: 0)
        let requests = roots.flatMap { root in
            tabIDs(in: root).map { tab in
                ArchiveRequest(id: tab, reason: .removed,
                    origin: section(of: .tab(tab)) == .pinned(id) ? .pinned : .today,
                    profileID: profileID, spaceID: id)
            }
        }
        archiveTabs(requests, at: date)
        detach(all: roots)
        for folder in foldersToRemove { folders[folder] = nil; parents[.folder(folder)] = nil; placementVersions[.folder(folder)] = nil }
        for split in splitsToRemove { splits[split] = nil; parents[.split(split)] = nil; placementVersions[.split(split)] = nil }
        pinned[id] = nil
        today[id] = nil
        collapsedPinnedSections.remove(id)
        rebuildParents()
    }

    /// Forgets everything the organization keeps for a profile being deleted, with its Spaces:
    /// Favorites, Pinned and Today sections (tabs and folders), collapse flags, auto-archive
    /// override and archive records. Afterwards nothing in the organization names the profile.
    mutating func removeProfile(_ profileID: ProfileID, spaces spaceIDs: Set<SpaceID>) {
        let savedSpaceCount = archivedSpaces.count
        archivedSpaces.removeAll { $0.space.profileID == profileID }
        if archivedSpaces.count != savedSpaceCount { changes.metadata = true }
        var roots = favorites[profileID] ?? []
        for spaceID in spaceIDs { roots += (pinned[spaceID] ?? []) + (today[spaceID] ?? []) }
        let removedTabs = roots.flatMap(tabIDs(in:))
        let removedFolders = roots.flatMap(folderIDs(in:))
        let removedSplits = splits.keys.filter { id in
            section(of: .split(id)).map { section in
                if case let .favorites(profile) = section { return profile == profileID }
                return section.spaceID.map(spaceIDs.contains) ?? false
            } ?? false
        }
        detach(all: roots)
        for id in removedSplits {
            splits[id] = nil; parents[.split(id)] = nil; placementVersions[.split(id)] = nil
            changes.nodes.insert(.split(id)); changes.splits.insert(id)
        }
        for id in removedTabs where tabs.removeValue(forKey: id) != nil { changes.nodes.insert(.tab(id)) }
        for id in removedFolders where folders.removeValue(forKey: id) != nil {
            parents[.folder(id)] = nil
            changes.nodes.insert(.folder(id))
        }
        for id in removedTabs { parents[.tab(id)] = nil }
        for node in removedTabs.map(BrowserOrganizationNode.tab) + removedFolders.map(BrowserOrganizationNode.folder) {
            placementVersions[node] = nil
        }
        if collapsedPinnedSections.contains(where: spaceIDs.contains) {
            collapsedPinnedSections.subtract(spaceIDs)
            changes.metadata = true
        }
        var nextPolicy = policy
        nextPolicy.profileThresholds[profileID] = nil
        setPolicy(nextPolicy)
        let purged = archive.filter { $0.profileID == profileID }
        if !purged.isEmpty {
            let ids = Set(purged.map(\.id))
            archive.removeAll { ids.contains($0.id) }
            for record in purged { noteArchiveChange(record) }
        }
    }

    mutating func setPolicy(_ policy: BrowserArchivePolicy) {
        guard self.policy != policy else { return }
        self.policy = policy
        changes.metadata = true
    }

    /// Rebuilds the derived parent index after decoding. Duplicates are reported by `validate`.
    mutating func rebuildParents() {
        parents = [:]
        func record(_ nodes: [BrowserOrganizationNode], in container: BrowserOrganizationContainer) {
            for node in nodes where parents[node] == nil { parents[node] = container }
        }
        for (id, nodes) in favorites { record(nodes, in: .favorites(id)) }
        for (id, nodes) in pinned { record(nodes, in: .pinned(id)) }
        for (id, nodes) in today { record(nodes, in: .today(id)) }
        for (id, folder) in folders { record(folder.children, in: .folder(id)) }
        for (id, split) in splits { record(split.tabIDs.map(BrowserOrganizationNode.tab), in: .split(id)) }
    }

    // MARK: Validation

    static let maximumTitleLength = 1_024

    static func validatedTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumTitleLength,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw BrowserOrganizationError.invalidTitle
        }
        return trimmed
    }

    /// Engine titles are never refused; they are bounded so a page cannot bloat the session file.
    static func sanitizedPageTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let cleaned = String(title.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maximumTitleLength))
    }

    /// Structural invariants: every node lives in exactly one container, sections hold the node
    /// kinds they accept, the tree is acyclic, pinned URLs match their section, and archive records
    /// stay inside existing profile/Space boundaries.
    func validate(profiles: Set<ProfileID>, spaces: [SpaceID: ProfileID]) throws {
        var seen: Set<BrowserOrganizationNode> = []
        func visit(_ roots: [BrowserOrganizationNode], section: BrowserOrganizationSection) throws {
            var stack = roots.reversed().map { $0 }
            while let node = stack.popLast() {
                guard seen.insert(node).inserted else { throw BrowserSessionError.organizationDuplicateNode }
                switch node {
                case let .tab(id):
                    guard let tab = tabs[id] else { throw BrowserSessionError.organizationItemMissing }
                    try Self.validateTab(tab)
                    guard (tab.pinnedURL != nil) == section.keepsPinnedURL else {
                        throw BrowserSessionError.organizationInvalidPinnedURL
                    }
                case let .split(id):
                    guard let split = splits[id], split.isValid else { throw BrowserSessionError.invalidSplitGroup }
                    guard case .favorites = section else {
                        stack.append(contentsOf: split.tabIDs.reversed().map(BrowserOrganizationNode.tab))
                        continue
                    }
                    throw BrowserSessionError.organizationInvalidSection
                case let .folder(id):
                    guard section.acceptsFolders else { throw BrowserSessionError.organizationInvalidSection }
                    guard let folder = folders[id] else { throw BrowserSessionError.organizationItemMissing }
                    guard (try? Self.validatedTitle(folder.title)) == folder.title else {
                        throw BrowserSessionError.organizationInvalidTitle
                    }
                    stack.append(contentsOf: folder.children.reversed())
                }
            }
        }
        for (id, nodes) in favorites {
            guard profiles.contains(id) else { throw BrowserSessionError.profileMissing }
            try visit(nodes, section: .favorites(id))
        }
        for (id, nodes) in pinned {
            guard spaces[id] != nil else { throw BrowserSessionError.spaceMissing }
            try visit(nodes, section: .pinned(id))
        }
        for (id, nodes) in today {
            guard spaces[id] != nil else { throw BrowserSessionError.spaceMissing }
            try visit(nodes, section: .today(id))
        }
        guard collapsedPinnedSections.allSatisfy({ spaces[$0] != nil }) else { throw BrowserSessionError.spaceMissing }
        // Unreachable folders, including cycles detached from every root, are orphans.
        guard seen.count == tabs.count + folders.count + splits.count else { throw BrowserSessionError.organizationOrphanedItem }
        var archiveIndex: [TabID: BrowserArchivedTab] = [:]
        for record in archive {
            guard archiveIndex.updateValue(record, forKey: record.id) == nil else { throw BrowserSessionError.duplicateIdentity }
        }
        var archivedSpaceIDs: Set<SpaceID> = []
        for saved in archivedSpaces {
            guard archivedSpaceIDs.insert(saved.id).inserted, profiles.contains(saved.space.profileID),
                  saved.contents.archivedSpaces.isEmpty, saved.contents.archive.isEmpty,
                  saved.contents.favorites.isEmpty, saved.contents.spaces.count == 1,
                  saved.contents.spaces.first?.spaceID == saved.id,
                  saved.contents.tabs.allSatisfy({ tab in
                      archiveIndex[tab.id]?.profileID == saved.space.profileID && archiveIndex[tab.id]?.tab == tab
                  }) else { throw BrowserSessionError.organizationInvalidArchive }
            try saved.space.theme?.validate()
            let graph = try BrowserOrganizationState(document: saved.contents)
            try graph.validate(profiles: [saved.space.profileID], spaces: [saved.id: saved.space.profileID])
        }
        var archived: Set<TabID> = []
        for record in archive {
            guard archived.insert(record.id).inserted, tabs[record.id] == nil else {
                throw BrowserSessionError.duplicateIdentity
            }
            // Origins are historical: a Space may have been deleted or moved to another profile.
            // Restoration checks current ownership and falls back within the archive's profile.
            guard profiles.contains(record.profileID),
                  spaces[record.spaceID] == nil || spaces[record.spaceID] == record.profileID
                    || record.spaceProfileWasChanged == true else {
                throw BrowserSessionError.organizationInvalidArchive
            }
            try Self.validateTab(record.tab)
        }
        guard zip(archive, archive.dropFirst()).allSatisfy({ $0.archivedAt >= $1.archivedAt }) else {
            throw BrowserSessionError.organizationInvalidArchive
        }
        var archivedPerProfile: [ProfileID: Int] = [:]
        for record in archive { archivedPerProfile[record.profileID, default: 0] += 1 }
        guard policy.maximumArchivedTabs >= 0,
              archivedPerProfile.values.allSatisfy({ $0 <= policy.maximumArchivedTabs }),
              policy.defaultThreshold.isValid,
              policy.profileThresholds.allSatisfy({ profiles.contains($0.key) && $0.value.isValid }) else {
            throw BrowserSessionError.organizationInvalidPolicy
        }
    }

    private static func validateTab(_ tab: BrowserOrganizedTab) throws {
        try BrowserSessionDocument.validateDestination(tab.url)
        if let pinnedURL = tab.pinnedURL { try BrowserSessionDocument.validateDestination(pinnedURL) }
        if let title = tab.customTitle, (try? validatedTitle(title)) != title {
            throw BrowserSessionError.organizationInvalidTitle
        }
        if let title = tab.pageTitle, sanitizedPageTitle(title) != title {
            throw BrowserSessionError.organizationInvalidTitle
        }
    }
}

// MARK: Document conversion

extension BrowserOrganizationState {
    init(document: BrowserOrganizationDocument) throws {
        for tab in document.tabs {
            guard tabs.updateValue(tab, forKey: tab.id) == nil else { throw BrowserSessionError.duplicateIdentity }
        }
        for folder in document.folders {
            guard folders.updateValue(folder, forKey: folder.id) == nil else {
                throw BrowserSessionError.duplicateIdentity
            }
        }
        for split in document.splits {
            guard splits.updateValue(split, forKey: split.id) == nil else { throw BrowserSessionError.duplicateIdentity }
        }
        for entry in document.favorites {
            guard favorites[entry.profileID] == nil else { throw BrowserSessionError.duplicateIdentity }
            if !entry.items.isEmpty { favorites[entry.profileID] = entry.items }
        }
        var sections: Set<SpaceID> = []
        for entry in document.spaces {
            guard sections.insert(entry.spaceID).inserted else { throw BrowserSessionError.duplicateIdentity }
            if !entry.pinned.isEmpty { pinned[entry.spaceID] = entry.pinned }
            if !entry.today.isEmpty { today[entry.spaceID] = entry.today }
            if entry.isPinnedCollapsed { collapsedPinnedSections.insert(entry.spaceID) }
        }
        archive = document.archive
        archivedSpaces = document.archivedSpaces
        policy = document.archivePolicy
        rebuildParents()
    }

    /// Canonical, deterministic export ordered by the catalog.
    func document(profileOrder: [ProfileID], spaceOrder: [SpaceID]) -> BrowserOrganizationDocument {
        let profileRank = Dictionary(uniqueKeysWithValues: profileOrder.enumerated().map { ($1, $0) })
        let spaceRank = Dictionary(uniqueKeysWithValues: spaceOrder.enumerated().map { ($1, $0) })
        let favoriteEntries = favorites
            .sorted { (profileRank[$0.key] ?? .max, $0.key.rawValue.uuidString)
                < (profileRank[$1.key] ?? .max, $1.key.rawValue.uuidString) }
            .map { BrowserOrganizationDocument.Favorites(profileID: $0.key, items: $0.value) }
        let sectionSpaces = Set(pinned.keys).union(today.keys).union(collapsedPinnedSections)
        let spaceEntries = sectionSpaces
            .sorted { (spaceRank[$0] ?? .max, $0.rawValue.uuidString) < (spaceRank[$1] ?? .max, $1.rawValue.uuidString) }
            .map { BrowserOrganizationDocument.SpaceSections(spaceID: $0, pinned: pinned[$0] ?? [],
                today: today[$0] ?? [], isPinnedCollapsed: collapsedPinnedSections.contains($0)) }
        return BrowserOrganizationDocument(
            tabs: tabs.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString },
            folders: folders.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString },
            favorites: favoriteEntries, spaces: spaceEntries, archive: archive, archivePolicy: policy,
            splits: splits.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }, archivedSpaces: archivedSpaces)
    }
}

// MARK: Reversible patches

struct BrowserValueChange<Value: Equatable & Sendable>: Sendable {
    var before: Value
    var after: Value

    var reversed: BrowserValueChange { BrowserValueChange(before: after, after: before) }
}

struct BrowserTabFieldChange: Sendable {
    var customTitle: BrowserValueChange<String?>?
    var pinnedURL: BrowserValueChange<URL?>?

    var reversed: BrowserTabFieldChange {
        BrowserTabFieldChange(customTitle: customTitle?.reversed, pinnedURL: pinnedURL?.reversed)
    }
}

/// A node's placement on both sides of a command, with the placement versions that identify them.
struct BrowserPlacementChange: Sendable {
    var before: BrowserOrganizationPlacement?
    var after: BrowserOrganizationPlacement?
    var beforeVersion: UInt64
    var afterVersion: UInt64

    var reversed: BrowserPlacementChange {
        BrowserPlacementChange(before: after, after: before, beforeVersion: afterVersion, afterVersion: beforeVersion)
    }
}

/// An archive record on both sides of a command, with its rank so equal dates keep their order.
struct BrowserArchiveChange: Sendable {
    var before: BrowserArchivedTab?
    var after: BrowserArchivedTab?
    var beforeIndex: Int?
    var afterIndex: Int?

    var reversed: BrowserArchiveChange {
        BrowserArchiveChange(before: after, after: before, beforeIndex: afterIndex, afterIndex: beforeIndex)
    }
}

/// The exact difference made by one command, restricted to the keys it touched. Applying it checks
/// that every recorded key still holds the value (or placement version) the other side left, so an
/// edit made since by another window turns the patch into a conflict instead of being overwritten.
/// Keys the command did not touch are never written: concurrent changes to them survive.
struct BrowserOrganizationPatch: Sendable {
    var placements: [BrowserOrganizationNode: BrowserPlacementChange] = [:]
    /// Existence changes only; surviving tabs keep their live destination and web title.
    var tabRecords: [TabID: BrowserValueChange<BrowserOrganizedTab?>] = [:]
    var tabFields: [TabID: BrowserTabFieldChange] = [:]
    /// Existence changes; children are rebuilt from placements.
    var folderRecords: [FolderID: BrowserValueChange<BrowserOrganizedFolder?>] = [:]
    var folderTitles: [FolderID: BrowserValueChange<String>] = [:]
    var splitRecords: [SplitGroupID: BrowserValueChange<BrowserSplitGroup?>] = [:]
    var archive: [TabID: BrowserArchiveChange] = [:]

    init() {}

    /// Placement versions are assigned afterwards by `BrowserOrganizationState.stampPlacements`.
    init(from old: BrowserOrganizationState, to new: BrowserOrganizationState, changes: BrowserOrganizationChangeSet) {
        let oldPlacements = old.placements(of: changes.nodes)
        let newPlacements = new.placements(of: changes.nodes)
        for node in changes.nodes {
            let before = oldPlacements[node]
            let after = newPlacements[node]
            if before != after {
                let version = old.placementVersion(of: node)
                placements[node] = BrowserPlacementChange(before: before, after: after,
                                                          beforeVersion: version, afterVersion: version)
            }
            switch node {
            case let .tab(id):
                if (old.tabs[id] == nil) != (new.tabs[id] == nil) {
                    tabRecords[id] = BrowserValueChange(before: old.tabs[id], after: new.tabs[id])
                }
            case .split: break // Split records include layout and membership below.
            case let .folder(id):
                if (old.folders[id] == nil) != (new.folders[id] == nil) {
                    folderRecords[id] = BrowserValueChange(before: old.folders[id].map(Self.emptied),
                                                           after: new.folders[id].map(Self.emptied))
                }
            }
        }
        for id in changes.splits.union(changes.nodes.compactMap(\.splitID)) where old.splits[id] != new.splits[id] {
            splitRecords[id] = BrowserValueChange(before: old.splits[id], after: new.splits[id])
        }
        for id in changes.tabFields {
            guard let before = old.tabs[id], let after = new.tabs[id] else { continue }
            var change = BrowserTabFieldChange()
            if before.customTitle != after.customTitle {
                change.customTitle = BrowserValueChange(before: before.customTitle, after: after.customTitle)
            }
            if before.pinnedURL != after.pinnedURL {
                change.pinnedURL = BrowserValueChange(before: before.pinnedURL, after: after.pinnedURL)
            }
            if change.customTitle != nil || change.pinnedURL != nil { tabFields[id] = change }
        }
        for id in changes.folderTitles {
            guard let before = old.folders[id], let after = new.folders[id], before.title != after.title else { continue }
            folderTitles[id] = BrowserValueChange(before: before.title, after: after.title)
        }
        if !changes.archive.isEmpty {
            let oldIndex = old.archiveIndex(of: changes.archive)
            let newIndex = new.archiveIndex(of: changes.archive)
            for id in changes.archive {
                let before = oldIndex[id].map { old.archive[$0] }
                let after = newIndex[id].map { new.archive[$0] }
                if before != after {
                    archive[id] = BrowserArchiveChange(before: before, after: after,
                                                       beforeIndex: oldIndex[id], afterIndex: newIndex[id])
                }
            }
        }
    }

    var isEmpty: Bool {
        placements.isEmpty && tabRecords.isEmpty && tabFields.isEmpty
            && folderRecords.isEmpty && folderTitles.isEmpty && splitRecords.isEmpty && archive.isEmpty
    }

    var reversed: BrowserOrganizationPatch {
        var result = BrowserOrganizationPatch()
        result.placements = placements.mapValues(\.reversed)
        result.tabRecords = tabRecords.mapValues(\.reversed)
        result.tabFields = tabFields.mapValues(\.reversed)
        result.folderRecords = folderRecords.mapValues(\.reversed)
        result.folderTitles = folderTitles.mapValues(\.reversed)
        result.splitRecords = splitRecords.mapValues(\.reversed)
        result.archive = archive.mapValues(\.reversed)
        return result
    }

    /// Tabs whose sidebar membership or position this patch changes, including the descendants
    /// of moved folders as they are in `state`.
    func affectedTabIDs(in state: BrowserOrganizationState) -> Set<TabID> {
        var result = Set(tabRecords.keys)
        for node in placements.keys {
            switch node {
            case let .tab(id): result.insert(id)
            case .folder, .split: result.formUnion(state.tabIDs(in: node))
            }
        }
        return result
    }

    mutating func recordEvictions(
        from old: BrowserOrganizationState, to new: BrowserOrganizationState,
        replaying applied: BrowserOrganizationPatch, undoing: Bool
    ) {
        let kept = Set(new.archive.map(\.id))
        for (index, record) in old.archive.enumerated()
        where !kept.contains(record.id) && applied.archive[record.id] == nil {
            // `applied` went from `old` to `new`; this patch is stored in the forward direction.
            archive[record.id] = undoing
                ? BrowserArchiveChange(before: nil, after: record, beforeIndex: nil, afterIndex: index)
                : BrowserArchiveChange(before: record, after: nil, beforeIndex: index, afterIndex: nil)
        }
    }

    /// Tabs this patch removes from the sidebar.
    var removedTabIDs: [TabID] { tabRecords.compactMap { $0.value.after == nil ? $0.key : nil } }

    private static func emptied(_ folder: BrowserOrganizedFolder) -> BrowserOrganizedFolder {
        var copy = folder
        copy.children = []
        return copy
    }
}

extension BrowserArchivedTab {
    /// Archive records never change in place; replaying a command may only refresh the live
    /// destination and web title they carry.
    func isSameRecord(as other: BrowserArchivedTab?) -> Bool {
        guard let other else { return false }
        return id == other.id && archivedAt == other.archivedAt && reason == other.reason && origin == other.origin
            && profileID == other.profileID && spaceID == other.spaceID
            && tab.customTitle == other.tab.customTitle && tab.pinnedURL == other.tab.pinnedURL
    }
}

extension BrowserOrganizationState {
    func archiveIndex(of ids: Set<TabID>) -> [TabID: Int] {
        var result: [TabID: Int] = [:]
        for (index, record) in archive.enumerated() where ids.contains(record.id) && result[record.id] == nil {
            result[record.id] = index
        }
        return result
    }

    /// Gives every node whose placement the patch changes a fresh version, recorded in the patch.
    mutating func stampPlacements(_ patch: inout BrowserOrganizationPatch) {
        for (node, change) in patch.placements {
            if change.after == nil {
                placementVersions[node] = nil
                patch.placements[node]?.afterVersion = 0
            } else {
                lastPlacementVersion &+= 1
                placementVersions[node] = lastPlacementVersion
                patch.placements[node]?.afterVersion = lastPlacementVersion
            }
        }
    }

    /// Section of `node` once `patch` is applied, without applying it. Nil when it leaves the sidebar.
    func section(of node: BrowserOrganizationNode, applying patch: BrowserOrganizationPatch) -> BrowserOrganizationSection? {
        func container(of node: BrowserOrganizationNode) -> BrowserOrganizationContainer? {
            if let change = patch.placements[node] { return change.after?.container }
            return parents[node]
        }
        var current = container(of: node)
        var steps = 0
        while let parent = current?.owningNode {
            steps += 1
            guard steps <= folders.count + splits.count + patch.folderRecords.count + patch.splitRecords.count else { return nil }
            current = container(of: parent)
        }
        return current?.rootSection
    }

    /// Checks every precondition of `patch` against the current state without mutating it: each
    /// recorded key still holds its `before` value or placement version; a removed tab keeps the
    /// custom title and pinned URL it had; a removed folder keeps its title and holds only nodes the
    /// patch relocates; target folders exist. Structural validation still runs after `apply`.
    func canApply(_ patch: BrowserOrganizationPatch) -> Bool {
        for (node, change) in patch.placements {
            guard parents[node] == change.before?.container else { return false }
            if change.before != nil, placementVersion(of: node) != change.beforeVersion { return false }
            if change.before == nil, contains(node) { return false }
        }
        for (id, change) in patch.splitRecords where splits[id] != change.before { return false }
        for (id, change) in patch.tabRecords {
            if let recorded = change.before {
                // Removing a tab overwrites all of its user fields: a rename or re-pin since conflicts.
                guard let tab = tabs[id], tab.customTitle == recorded.customTitle,
                      tab.pinnedURL == recorded.pinnedURL else { return false }
            } else if tabs[id] != nil {
                return false
            }
        }
        for (id, change) in patch.folderRecords {
            if let recorded = change.before {
                guard let folder = folders[id], folder.title == recorded.title else { return false }
                if change.after == nil, !folder.children.allSatisfy({ patch.placements[$0] != nil }) { return false }
            } else if folders[id] != nil {
                return false
            }
        }
        for (id, change) in patch.tabFields {
            guard let tab = tabs[id] else { return false }
            if let title = change.customTitle, tab.customTitle != title.before { return false }
            if let url = change.pinnedURL, tab.pinnedURL != url.before { return false }
        }
        for (id, change) in patch.folderTitles where folders[id]?.title != change.before { return false }
        if !patch.archive.isEmpty {
            let index = archiveIndex(of: Set(patch.archive.keys))
            for (id, change) in patch.archive {
                let current = index[id].map { archive[$0] }
                if let before = change.before {
                    guard current?.isSameRecord(as: before) == true else { return false }
                } else if current != nil {
                    return false
                }
            }
        }
        for change in patch.placements.values {
            guard case let .folder(id)? = change.after?.container else { continue }
            let removed = patch.folderRecords[id].map { $0.after == nil } ?? false
            let created = patch.folderRecords[id].map { $0.before == nil } ?? false
            guard created || (folders[id] != nil && !removed) else { return false }
        }
        return true
    }

    /// Transforms the `before` side of `patch` into its `after` side, or throws `undoConflict`
    /// without a meaningful partial state (callers apply it to a copy). Removals happen before
    /// insertions, in the sidebar and in the archive, whose cap is then applied once: the order of
    /// a dictionary never decides which record survives. Live fields (destination, web title) move
    /// between a tab and its archive record so a replay never rewinds navigation.
    mutating func apply(_ patch: BrowserOrganizationPatch, preconditionsChecked: Bool = false) throws {
        guard preconditionsChecked || canApply(patch) else { throw BrowserOrganizationError.undoConflict }
        let archived = archiveIndex(of: Set(patch.archive.keys))

        detach(all: patch.placements.keys)
        // Membership is rebuilt from placements; layout records are restored after reinsertion.
        for (id, change) in patch.splitRecords {
            if let group = change.after {
                splits[id] = BrowserSplitGroup(id: id, tabIDs: splits[id]?.tabIDs ?? [],
                                              orientation: group.orientation, ratios: group.ratios)
            } else { splits[id] = nil }
            changes.splits.insert(id)
        }
        var leaving: [TabID: BrowserOrganizedTab] = [:]
        for (id, change) in patch.tabRecords where change.after == nil {
            leaving[id] = tabs.removeValue(forKey: id)
            changes.nodes.insert(.tab(id))
        }
        for (id, change) in patch.folderRecords where change.after == nil {
            folders.removeValue(forKey: id)
            changes.nodes.insert(.folder(id))
        }
        for (id, change) in patch.tabRecords where change.before == nil {
            guard var tab = change.after else { continue }
            if let record = archived[id].map({ archive[$0] }) {
                tab.url = record.tab.url
                tab.pageTitle = record.tab.pageTitle
            }
            tabs[id] = tab
        }
        for (id, change) in patch.folderRecords where change.before == nil {
            folders[id] = change.after
        }
        for (id, change) in patch.tabFields {
            updateTab(id) { tab in
                if let title = change.customTitle { tab.customTitle = title.after }
                if let url = change.pinnedURL { tab.pinnedURL = url.after }
            }
        }
        for (id, change) in patch.folderTitles { renameFolder(id, to: change.after) }
        try reinsert(patch.placements.compactMap { node, change in change.after.map { (node, $0) } })
        for (id, change) in patch.splitRecords { splits[id] = change.after }
        for (node, change) in patch.placements {
            placementVersions[node] = change.after == nil ? nil : change.afterVersion
        }

        if !patch.archive.isEmpty {
            let removed = Set(patch.archive.keys)
            for record in archive where removed.contains(record.id) { noteArchiveChange(record) }
            archive.removeAll { removed.contains($0.id) }
            changes.archive.formUnion(removed)
            let inserted = patch.archive.compactMap { id, change -> (BrowserArchivedTab, Int)? in
                guard var record = change.after else { return nil }
                if let live = leaving[id] {
                    var tab = record.tab
                    tab.url = live.url
                    tab.pageTitle = live.pageTitle
                    record = BrowserArchivedTab(tab: tab, profileID: record.profileID, spaceID: record.spaceID,
                                                origin: record.origin, reason: record.reason,
                                                archivedAt: record.archivedAt)
                }
                return (record, change.afterIndex ?? .max)
            }
            insertArchive(inserted.sorted { $0.1 < $1.1 }.map(\.0))
            // A replay must not archive a tab only for the cap to evict it at once: that would
            // delete it. Records evicted otherwise are recorded by the caller for the opposite replay.
            let kept = Set(archive.map(\.id))
            guard inserted.allSatisfy({ kept.contains($0.0.id) }) else { throw BrowserOrganizationError.undoConflict }
        }
    }

    /// Reinserts nodes at their recorded placements, per container in ascending recorded index so
    /// earlier siblings are back before later anchors are resolved: after `previous` when it is in
    /// the container, else before `next`, else at the recorded index. Linked insertion keeps a
    /// large undo linear instead of scanning the list for every anchor.
    private mutating func reinsert(_ insertions: [(BrowserOrganizationNode, BrowserOrganizationPlacement)]) throws {
        let byContainer = Dictionary(grouping: insertions, by: \.1.container)
        for (container, entries) in byContainer {
            if case let .folder(id) = container, folders[id] == nil { throw BrowserOrganizationError.undoConflict }
            var list = BrowserLinkedNodes(children(of: container))
            let ordered = entries.sorted { left, right in
                left.1.index != right.1.index ? left.1.index < right.1.index
                    : Self.orderingKey(left.0) < Self.orderingKey(right.0)
            }
            for (node, placement) in ordered {
                if let previous = placement.previous, list.contains(previous) {
                    list.insert(node, after: previous)
                } else if let next = placement.next, list.contains(next) {
                    list.insert(node, before: next)
                } else {
                    list.insert(node, at: placement.index)
                }
            }
            setChildren(list.nodes, of: container)
            for (node, _) in entries {
                parents[node] = container
                changes.nodes.insert(node)
            }
        }
    }

    private static func orderingKey(_ node: BrowserOrganizationNode) -> String {
        switch node {
        case let .tab(id): return "t" + id.rawValue.uuidString
        case let .folder(id): return "f" + id.rawValue.uuidString
        case let .split(id): return "s" + id.rawValue.uuidString
        }
    }
}

/// A doubly linked list of distinct nodes with O(1) insertion next to a member.
private struct BrowserLinkedNodes {
    private var head: BrowserOrganizationNode?
    private var tail: BrowserOrganizationNode?
    private var nextOf: [BrowserOrganizationNode: BrowserOrganizationNode] = [:]
    private var previousOf: [BrowserOrganizationNode: BrowserOrganizationNode] = [:]
    private var members: Set<BrowserOrganizationNode> = []

    init(_ nodes: [BrowserOrganizationNode]) {
        for node in nodes where !members.contains(node) { append(node) }
    }

    func contains(_ node: BrowserOrganizationNode) -> Bool { members.contains(node) }

    var nodes: [BrowserOrganizationNode] {
        var result: [BrowserOrganizationNode] = []
        result.reserveCapacity(members.count)
        var current = head
        while let node = current {
            result.append(node)
            current = nextOf[node]
        }
        return result
    }

    mutating func insert(_ node: BrowserOrganizationNode, after anchor: BrowserOrganizationNode) {
        guard let following = nextOf[anchor] else { return append(node) }
        link(node, between: anchor, and: following)
    }

    mutating func insert(_ node: BrowserOrganizationNode, before anchor: BrowserOrganizationNode) {
        guard let preceding = previousOf[anchor] else { return prepend(node) }
        link(node, between: preceding, and: anchor)
    }

    /// Positions past either end clamp to it; only interior positions walk the list.
    mutating func insert(_ node: BrowserOrganizationNode, at index: Int) {
        if index <= 0 || head == nil { return prepend(node) }
        if index >= members.count { return append(node) }
        var anchor = head
        for _ in 1..<index { anchor = anchor.flatMap { nextOf[$0] } }
        guard let anchor else { return append(node) }
        insert(node, after: anchor)
    }

    private mutating func append(_ node: BrowserOrganizationNode) {
        members.insert(node)
        if let tail {
            nextOf[tail] = node
            previousOf[node] = tail
        } else {
            head = node
        }
        tail = node
    }

    private mutating func prepend(_ node: BrowserOrganizationNode) {
        members.insert(node)
        if let head {
            previousOf[head] = node
            nextOf[node] = head
        } else {
            tail = node
        }
        head = node
    }

    private mutating func link(_ node: BrowserOrganizationNode, between left: BrowserOrganizationNode,
                               and right: BrowserOrganizationNode) {
        members.insert(node)
        nextOf[left] = node
        previousOf[node] = left
        nextOf[node] = right
        previousOf[right] = node
    }
}

// MARK: Moves

extension BrowserOrganizationState {
    /// Insertion index in `container` for `position`, before any of `moving` is detached, adjusted
    /// for moved siblings that precede it.
    func insertionIndex(
        in container: BrowserOrganizationContainer, position: BrowserOrganizationPosition,
        moving: Set<BrowserOrganizationNode> = []
    ) throws -> Int {
        let list = children(of: container)
        let index: Int
        switch position {
        case .start: index = 0
        case .end: index = list.count
        case let .before(anchor):
            guard let found = list.firstIndex(of: anchor) else { throw BrowserOrganizationError.invalidPosition }
            index = found
        case let .after(anchor):
            guard let found = list.firstIndex(of: anchor) else { throw BrowserOrganizationError.invalidPosition }
            index = found + 1
        }
        guard !moving.isEmpty else { return index }
        return index - list[..<index].reduce(0) { $0 + (moving.contains($1) ? 1 : 0) }
    }

    /// Nodes carried by a moved ancestor are dropped; the rest keep their sidebar order.
    func movableRoots(_ nodes: [BrowserOrganizationNode]) -> [BrowserOrganizationNode] {
        let requestedSplits = Set(nodes.compactMap(\.splitID))
        let requestedFolders = Set(nodes.compactMap(\.folderID))
        var seen: Set<BrowserOrganizationNode> = []
        let roots = nodes.filter { node in
            seen.insert(node).inserted
                && !(parents[node]?.owningNode?.splitID.map(requestedSplits.contains) ?? false)
                && (requestedFolders.isEmpty || !ancestors(of: node).contains(where: requestedFolders.contains))
        }
        return sortedInSidebarOrder(roots)
    }

    mutating func move(
        _ nodes: [BrowserOrganizationNode], to destination: BrowserOrganizationDestination,
        destinationSection: BrowserOrganizationSection
    ) throws {
        let roots = movableRoots(nodes)
        guard !roots.isEmpty else { throw BrowserOrganizationError.emptySelection }
        guard roots.allSatisfy(contains) else { throw BrowserOrganizationError.itemMissing }
        if case .favorites = destinationSection, roots.contains(where: { $0.splitID != nil }) {
            throw BrowserOrganizationError.invalidDestination
        }
        if !destinationSection.acceptsFolders, roots.contains(where: { $0.folderID != nil }) {
            throw BrowserOrganizationError.invalidDestination
        }
        if case let .folder(target) = destination.container {
            guard folders[target] != nil else { throw BrowserOrganizationError.itemMissing }
            let targetChain = Set([target] + ancestors(of: .folder(target)))
            if roots.contains(where: { $0.folderID.map(targetChain.contains) ?? false }) {
                throw BrowserOrganizationError.cycle
            }
        }
        let index = try insertionIndex(in: destination.container, position: destination.position,
                                       moving: Set(roots))
        detach(all: roots)
        insert(roots, into: destination.container, at: index)
        for tabID in roots.flatMap(tabIDs(in:)) {
            updateTab(tabID) { tab in
                if destinationSection.keepsPinnedURL {
                    if tab.pinnedURL == nil { tab.pinnedURL = tab.url }
                } else {
                    tab.pinnedURL = nil
                }
            }
        }
    }
}
