import Foundation

public struct BrowserBookmarkLabels: Sendable {
    public let favorites: String
    public let split: String
    public let untitled: String
    public init(favorites: String = "Favorites", split: String = "Split View", untitled: String = "Untitled") {
        self.favorites = favorites
        self.split = split
        self.untitled = untitled
    }
}

extension BrowserStore {
    /// Favorites and Pinned retain the saved home URL, even when a live tab is
    /// elsewhere. Today, history, archived links and other profiles are excluded.
    public func exportBookmarks(from context: BrowserContext,
                                labels: BrowserBookmarkLabels = .init()) throws -> BrowserBookmarkDocument {
        _ = try organizationWindow(context)
        let graph = organization
        var skipped = 0
        func entries(_ nodes: [BrowserOrganizationNode], depth: Int) throws -> [BrowserBookmarkDocument.Entry] {
            guard depth <= BrowserBookmarkHTML.maximumDepth else { throw BrowserBookmarkTransferError.excessiveDepth }
            var result: [BrowserBookmarkDocument.Entry] = []
            for node in nodes {
                switch node {
                case let .tab(id):
                    guard let tab = graph.tabs[id] else { throw BrowserOrganizationError.itemMissing }
                    let url = tab.pinnedURL ?? tab.url
                    guard BrowserBookmarkHTML.isPortableURL(url) else { skipped += 1; continue }
                    result.append(.link(title: tab.resolvedTitle ?? url.absoluteString, url: url))
                case let .folder(id):
                    guard let folder = graph.folders[id] else { throw BrowserOrganizationError.itemMissing }
                    result.append(.folder(title: folder.title, children: try entries(folder.children, depth: depth + 1)))
                case let .split(id):
                    guard let split = graph.splits[id] else { throw BrowserOrganizationError.itemMissing }
                    result.append(.folder(title: labels.split,
                        children: try entries(split.tabIDs.map(BrowserOrganizationNode.tab), depth: depth + 1)))
                }
            }
            return result
        }
        var roots: [BrowserBookmarkDocument.Entry] = []
        let favorites = try entries(graph.favorites[context.profileID] ?? [], depth: 1)
        if !favorites.isEmpty { roots.append(.folder(title: labels.favorites, children: favorites)) }
        for id in spaceOrder {
            guard let space = spaces[id], space.profileID == context.profileID else { continue }
            let pinned = try entries(graph.pinned[id] ?? [], depth: 1)
            if !pinned.isEmpty { roots.append(.folder(title: space.name, children: pinned)) }
        }
        let document = BrowserBookmarkDocument(entries: roots, skippedLinkCount: skipped)
        _ = try BrowserBookmarkHTML.encode(document)
        return document
    }

    /// Import is one undoable, all-or-nothing folder creation in the captured
    /// Space. Links stay dormant; no web content is created or navigated.
    @discardableResult
    public func importBookmarks(_ document: BrowserBookmarkDocument, folderTitle: String,
                                from context: BrowserContext,
                                labels: BrowserBookmarkLabels = .init()) throws -> (FolderID, BrowserWindowState) {
        _ = try organizationWindow(context)
        _ = try BrowserBookmarkHTML.encode(document)
        let rootTitle = try BrowserOrganizationState.validatedTitle(folderTitle)
        let fallback = try BrowserOrganizationState.validatedTitle(labels.untitled)
        let date = clock()
        let root = BrowserOrganizedFolder(id: FolderID(), title: rootTitle, createdAt: date)
        func title(_ source: String) -> String {
            let bounded = BrowserOrganizedTab.normalizedPageTitle(source)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return bounded.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        func insert(_ entries: [BrowserBookmarkDocument.Entry], in folder: FolderID,
                    state: inout BrowserOrganizationState) {
            for entry in entries {
                let container = BrowserOrganizationContainer.folder(folder)
                let index = state.children(of: container).count
                switch entry {
                case let .link(name, url):
                    state.addTab(BrowserOrganizedTab(id: TabID(), url: url, customTitle: title(name), pinnedURL: url,
                                                    createdAt: date, lastActiveAt: date), into: container, at: index)
                case let .folder(name, children):
                    let child = BrowserOrganizedFolder(id: FolderID(), title: title(name), createdAt: date)
                    state.addFolder(child, into: container, at: index)
                    insert(children, in: child.id, state: &state)
                }
            }
        }
        try commitOrganization(.importBookmarks, in: context) { state in
            let container = BrowserOrganizationContainer.pinned(context.spaceID)
            state.addFolder(root, into: container, at: state.children(of: container).count)
            insert(document.entries, in: root.id, state: &state)
        }
        return (root.id, try captureWindowState(in: context.windowID))
    }
}
