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
    private var images: [Key: NSImage] = [:]
    private var removedProfiles = Set<ProfileID>()

    func image(profile: ProfileID, home: URL) -> NSImage? {
        guard !removedProfiles.contains(profile), let origin = FavoriteIconStore.origin(home) else { return nil }
        return images[Key(profile: profile, origin: origin)]
    }

    func put(_ image: NSImage, profile: ProfileID, home: URL) {
        guard !removedProfiles.contains(profile), let origin = FavoriteIconStore.origin(home) else { return }
        images[Key(profile: profile, origin: origin)] = image
    }

    func remove(profile: ProfileID) {
        removedProfiles.insert(profile)
        images = images.filter { $0.key.profile != profile }
    }

    func preload(document: BrowserSessionDocument, store: FavoriteIconStore) async {
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
                guard image(profile: space.profileID, home: home) == nil,
                      let pixels = await store.cachedImage(profile: space.profileID, home: home),
                      let decoded = await pixels.nativeImage() else { continue }
                put(decoded, profile: space.profileID, home: home)
            }
        }
    }
}
