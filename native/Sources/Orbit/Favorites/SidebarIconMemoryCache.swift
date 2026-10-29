import AppKit
import BrowserCore

/// Decoded, profile-scoped pixels shared by live rows and detached Space previews.
/// The disk pass finishes before restored windows are exposed; network discovery stays lazy.
@MainActor
final class SidebarIconMemoryCache {
    private struct Key: Hashable {
        let profile: ProfileID
        let origin: URL
    }
    private var images: BrowserCostCache<Key, NSImage>
    private var diskStore: FavoriteIconStore?
    private var removedProfiles = Set<ProfileID>()

    init(store: FavoriteIconStore? = nil, budget: Int = 4 * 1024 * 1024) {
        diskStore = store
        images = BrowserCostCache(budget: budget)
    }

    func image(profile: ProfileID, home: URL) -> NSImage? {
        guard !removedProfiles.contains(profile), let origin = FavoriteIconStore.origin(home) else { return nil }
        let key = Key(profile: profile, origin: origin)
        if let image = images.value(for: key) { return image }
        // A cold known icon must be available in this same render, including the first hover
        // of a collapsed folder. Only a cache miss pays the bounded local thumbnail decode.
        guard let file = diskStore?.cachedFile(profile: profile, home: home),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= 131_072,
              let image = BrowserIconRaster.image(data: data) else { return nil }
        put(image, profile: profile, home: home)
        return image
    }

    func put(_ image: NSImage, profile: ProfileID, home: URL) {
        guard !removedProfiles.contains(profile), let origin = FavoriteIconStore.origin(home) else { return }
        images.insert(image, for: Key(profile: profile, origin: origin), cost: BrowserIconRaster.cost(image) + origin.absoluteString.utf8.count + 64)
    }

    func remove(profile: ProfileID) {
        removedProfiles.insert(profile)
        for key in images.keys where key.profile == profile { images.remove(key) }
    }

    func releaseMemory() { images.removeAll() }

    var cacheStatistics: [String: Int] {
        ["entries": images.count, "bytes": images.cost, "representations": images.values.reduce(0) { $0 + $1.representations.count }]
    }

    func preload(document: BrowserSessionDocument, store: FavoriteIconStore) async {
        diskStore = store
        let folders = Dictionary(document.organization.folders.map { ($0.id, $0.children) }, uniquingKeysWith: { first, _ in first })
        let splits = Dictionary(document.organization.splits.map { ($0.id, $0.tabIDs) }, uniquingKeysWith: { first, _ in first })
        for space in document.spaces {
            let favorites = SpaceSwipePreview.favorites(document: document, spaceID: space.id, windowID: nil)?.items ?? []
            // A collapsed folder's icons are needed on its very first hover too. Traverse the
            // stored tree rather than the visible (collapsed) sidebar rows; never open a page.
            let section = document.organization.spaces.first { $0.spaceID == space.id }
            var stack = (section?.pinned ?? []) + (section?.today ?? [])
            var visited = Set<BrowserOrganizationNode>(), rowIDs = Set<TabID>()
            while let node = stack.popLast() {
                guard visited.insert(node).inserted else { continue }
                switch node {
                case let .tab(id): rowIDs.insert(id)
                case let .folder(id):
                    stack.append(contentsOf: folders[id] ?? [])
                case let .split(id):
                    rowIDs.formUnion(splits[id] ?? [])
                }
            }
            let homes = favorites.map { $0.tab.pinnedURL ?? $0.tab.url }
                + document.organization.tabs.filter { rowIDs.contains($0.id) }.map { $0.pinnedURL ?? $0.url }
            for home in homes {
                guard let origin = FavoriteIconStore.origin(home),
                      images.peekValue(for: Key(profile: space.profileID, origin: origin)) == nil,
                      let pixels = await store.cachedImage(profile: space.profileID, home: home),
                      let decoded = await pixels.nativeImage() else { continue }
                put(decoded, profile: space.profileID, home: home)
            }
        }
    }
}
