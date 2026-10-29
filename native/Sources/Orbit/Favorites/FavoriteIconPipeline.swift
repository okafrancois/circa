import AppKit
import BrowserCore
import BrowserEngine
import ImageIO

/// Prefers the owned Chromium surface, with a profile-local persistent cache for dormant tiles.
@MainActor
final class FavoriteIconPipeline<Surface: BrowserEngineSurface> {
    typealias Resolver = @MainActor (Surface, URL) async -> NSImage?
    /// Injected resolvers must capture UI owners weakly and honor task cancellation.
    var resolve: Resolver = { surface, url in
        if let image = surface.navigationState.faviconImage, image.sourceURL == url {
            return await image.nativeImage()
        }
        return inlineImage(url)
    }
    var onChange: (() -> Void)?
    var store: FavoriteIconStore?
    var memoryCache = SidebarIconMemoryCache()
    private struct CachedIcon {
        let profile: ProfileID
        let home: URL
        let token = UUID()
        var image: NSImage?
        var task: Task<Void, Never>?
    }
    private var cachedIcons: [TabID: CachedIcon] = [:]
    private struct Request: Equatable {
        let profile: ProfileID
        let surface: ObjectIdentifier
        let generation: UInt64
        let url: URL
        let home: URL
        let image: BrowserFaviconImage?
        let revision: UInt64
    }
    private struct Entry {
        var resolvedPixels: BrowserFaviconImage?
        let request: Request
        let token: UUID
        var task: Task<Void, Never>?
        var image: NSImage?
    }
    private var entries: [TabID: Entry] = [:]

    func image(for tab: BrowserOrganizationTabItem, surface: Surface?,
               isOwned: @escaping @MainActor (Surface) -> Bool) -> NSImage? {
        if case .favorites(let profile) = tab.section {
            if entries[tab.id]?.request.profile != profile {
                entries.removeValue(forKey: tab.id)?.task?.cancel()
            }
            if let surface, surface.profileID != profile { return nil }
        }
        let home = tab.pinnedURL ?? tab.url
        restoreIcon(for: tab, home: home)
        let profile: ProfileID?
        if case .favorites(let id) = tab.section { profile = id }
        else { profile = surface?.profileID }
        let cachedImage = cachedIcons[tab.id]?.image
            ?? profile.flatMap { memoryCache.image(profile: $0, home: home) }
        if let cached = entries[tab.id], cached.request.home != home ||
            (surface != nil && cached.request.profile != surface?.profileID) {
            entries.removeValue(forKey: tab.id)?.task?.cancel()
        }
        guard let surface, isOwned(surface), !surface.isDisposed,
              let committed = surface.navigationState.committedURL,
              BrowserSiteOrigin(url: committed) == BrowserSiteOrigin(url: home),
              BrowserSiteOrigin(url: home) != nil else { return entries[tab.id]?.image ?? cachedImage }
        let state = surface.navigationState
        guard !state.isLoading, state.faviconMetadataIsSettled else { return entries[tab.id]?.image ?? cachedImage }
        guard let url = state.faviconURL else {
            entries.removeValue(forKey: tab.id)?.task?.cancel()
            return cachedImage
        }
        let request = Request(profile: surface.profileID, surface: ObjectIdentifier(surface), generation: surface.documentGeneration, url: url, home: home, image: state.faviconImage, revision: state.faviconRevision)
        if entries[tab.id]?.request == request { return entries[tab.id]?.image ?? cachedImage }
        let previous = entries.removeValue(forKey: tab.id)
        previous?.task?.cancel()
        if entries.count >= 256, let evicted = entries.keys.first {
            entries.removeValue(forKey: evicted)?.task?.cancel()
        }
        let token = UUID()
        entries[tab.id] = Entry(request: request, token: token, image: previous?.image)
        let reusableImage: NSImage?
        if previous?.request.profile == request.profile, previous?.request.home == home,
           let pixels = request.image, pixels.sourceURL == url,
           previous?.resolvedPixels?.png == pixels.png {
            reusableImage = previous?.image
        } else { reusableImage = nil }
        let resolver = resolve
        let task = Task { [weak self, weak surface] in
            guard let surface else { return }
            let image: NSImage?
            if let reusableImage { image = reusableImage }
            else { image = await resolver(surface, url) }
            guard !Task.isCancelled, let self, self.entries[tab.id]?.token == token,
                  isOwned(surface), !surface.isDisposed, surface.documentGeneration == request.generation,
                  !surface.navigationState.isLoading, surface.navigationState.faviconMetadataIsSettled,
                  BrowserSiteOrigin(url: surface.navigationState.committedURL ?? url) == BrowserSiteOrigin(url: home),
                  surface.navigationState.faviconRevision == request.revision,
                  surface.navigationState.faviconURL == url,
                  surface.navigationState.faviconImage == request.image else { return }
            let retainedImage = image ?? self.entries[tab.id]?.image
            if image != nil { self.entries[tab.id]?.resolvedPixels = request.image }
            self.entries[tab.id]?.image = retainedImage
            self.entries[tab.id]?.task = nil
            if let image { self.memoryCache.put(image, profile: request.profile, home: home) }
            if let pixels = request.image, image != nil, let store = self.store {
                await store.put(pixels, profile: request.profile, home: home)
                guard !Task.isCancelled, self.entries[tab.id]?.token == token else { return }
                self.cachedIcons[tab.id]?.image = image
            }
            self.onChange?()
        }
        entries[tab.id]?.task = task
        return previous?.image ?? cachedImage
    }

    private func restoreIcon(for tab: BrowserOrganizationTabItem, home: URL) {
        guard let store, case .favorites(let profile) = tab.section else { return }
        if let cached = cachedIcons[tab.id], cached.profile == profile, cached.home == home { return }
        cachedIcons.removeValue(forKey: tab.id)?.task?.cancel()
        let entry = CachedIcon(profile: profile, home: home, image: memoryCache.image(profile: profile, home: home))
        cachedIcons[tab.id] = entry
        if entry.image != nil { return }
        cachedIcons[tab.id]?.task = Task { [weak self] in
            let pixels = await store.image(profile: profile, home: home)
            let image = await pixels?.nativeImage()
            guard !Task.isCancelled, let self, self.cachedIcons[tab.id]?.token == entry.token else { return }
            self.cachedIcons[tab.id]?.image = image
            self.cachedIcons[tab.id]?.task = nil
            if let image { self.memoryCache.put(image, profile: profile, home: home) }
            self.onChange?()
        }
    }

    func retain(_ ids: Set<TabID>) {
        for id in Array(entries.keys) where !ids.contains(id) { entries.removeValue(forKey: id)?.task?.cancel() }
        for id in Array(cachedIcons.keys) where !ids.contains(id) { cachedIcons.removeValue(forKey: id)?.task?.cancel() }
    }
    func clear() { retain([]) }

    static func inlineImage(_ url: URL) -> NSImage? {
        guard url.scheme == "data", url.absoluteString.utf8.count <= 262_144,
              let comma = url.absoluteString.firstIndex(of: ",") else { return nil }
        let header = url.absoluteString[..<comma].lowercased()
        guard header.hasPrefix("data:image/"), header.hasSuffix(";base64"),
              let data = Data(base64Encoded: String(url.absoluteString[url.absoluteString.index(after: comma)...])),
              data.count <= 131_072,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 512, height <= 512,
              let image = NSImage(data: data),
              image.size.width > 0, image.size.height > 0,
              image.size.width <= 512, image.size.height <= 512 else { return nil }
        return image
    }
}
