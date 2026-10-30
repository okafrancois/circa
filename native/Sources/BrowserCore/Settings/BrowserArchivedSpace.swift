import Foundation

/// Recovery metadata for a deleted Space. Tab payloads follow the normal archive lifetime;
/// empty folders and the remaining hierarchy survive individual tab restores and eviction.
public struct BrowserArchivedSpace: Codable, Equatable, Sendable, Identifiable {
    public var id: SpaceID { space.id }
    public let space: BrowserSpace
    public let contents: BrowserOrganizationDocument
    public let archivedAt: Date

    init(space: BrowserSpace, contents: BrowserOrganizationDocument, archivedAt: Date) {
        self.space = space
        self.contents = contents
        self.archivedAt = archivedAt
    }

    func retainingTabs(_ allowed: Set<TabID>) -> BrowserArchivedSpace {
        guard contents.tabs.contains(where: { !allowed.contains($0.id) }) else { return self }
        let folders = Dictionary(uniqueKeysWithValues: contents.folders.map { ($0.id, $0) })
        let splits = Dictionary(uniqueKeysWithValues: contents.splits.map { ($0.id, $0) })
        var keptFolders: [BrowserOrganizedFolder] = []
        var keptSplits: [BrowserSplitGroup] = []
        func nodes(_ input: [BrowserOrganizationNode]) -> [BrowserOrganizationNode] {
            input.flatMap { node -> [BrowserOrganizationNode] in
                switch node {
                case .tab(let id): return allowed.contains(id) ? [node] : []
                case .folder(let id):
                    guard let folder = folders[id] else { return [] }
                    let children = nodes(folder.children)
                    keptFolders.append(.init(id: id, title: folder.title, isCollapsed: folder.isCollapsed,
                                             children: children, createdAt: folder.createdAt, liveFolder: folder.liveFolder))
                    return [node]
                case .split(let id):
                    guard let split = splits[id] else { return [] }
                    let indexes = split.tabIDs.indices.filter { allowed.contains(split.tabIDs[$0]) }
                    if indexes.count < 2 { return indexes.map { .tab(split.tabIDs[$0]) } }
                    let sum = indexes.reduce(0) { $0 + split.ratios[$1] }
                    keptSplits.append(.init(id: id, tabIDs: indexes.map { split.tabIDs[$0] }, orientation: split.orientation,
                                            ratios: indexes.map { split.ratios[$0] / sum }))
                    return [node]
                }
            }
        }
        let sections = contents.spaces.map {
            BrowserOrganizationDocument.SpaceSections(spaceID: $0.spaceID, pinned: nodes($0.pinned),
                today: nodes($0.today), isPinnedCollapsed: $0.isPinnedCollapsed)
        }
        return .init(space: space, contents: .init(tabs: contents.tabs.filter { allowed.contains($0.id) },
            folders: keptFolders.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }, favorites: [],
            spaces: sections, archive: [], archivePolicy: contents.archivePolicy,
            splits: keptSplits.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }), archivedAt: archivedAt)
    }
}
