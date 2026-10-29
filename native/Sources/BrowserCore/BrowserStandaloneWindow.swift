import Foundation

/// Ordered, machine-local tabs of a window. These records are deliberately outside the shared
/// organization document: the sync projection has no path to them.
public struct BrowserStandaloneWindow: Codable, Equatable, Sendable {
    public let profileID: ProfileID
    public let tabs: [BrowserOrganizedTab]
    public let nodes: [BrowserOrganizationNode]?
    public let splits: [BrowserSplitGroup]?

    public init(profileID: ProfileID, tabs: [BrowserOrganizedTab] = [], nodes: [BrowserOrganizationNode]? = nil, splits: [BrowserSplitGroup]? = nil) {
        self.profileID = profileID
        self.tabs = tabs
        self.nodes = nodes
        self.splits = splits
    }
}

extension BrowserOrganizationState {
    func standaloneOwner(of node: BrowserOrganizationNode) -> WindowID? {
        var current = container(of: node)
        var remaining = folders.count + splits.count + 1
        while let owner = current?.owningNode, remaining > 0 {
            remaining -= 1
            current = container(of: owner)
        }
        if case let .standalone(id) = current { return id }
        return nil
    }

    func standaloneDocument(_ id: WindowID, profileID: ProfileID) -> BrowserStandaloneWindow {
        let nodes = standalone[id] ?? []
        return BrowserStandaloneWindow(profileID: profileID,
            tabs: nodes.flatMap { tabIDs(in: $0) }.compactMap { tabs[$0] }, nodes: nodes,
            splits: nodes.compactMap { $0.splitID.flatMap { splits[$0] } })
    }

    mutating func restoreStandalone(_ saved: BrowserStandaloneWindow, windowID: WindowID, home: SpaceID) throws {
        standaloneHomes[windowID] = home
        standalone[windowID] = []
        for tab in saved.tabs {
            guard tabs[tab.id] == nil else { throw BrowserSessionError.duplicateIdentity }
            addTab(tab, into: .standalone(windowID), at: .max)
        }
        for group in saved.splits ?? [] {
            guard splits[group.id] == nil else { throw BrowserSessionError.duplicateIdentity }
            splits[group.id] = group
        }
        if let nodes = saved.nodes { standalone[windowID] = nodes }
        rebuildParents()
        changes = BrowserOrganizationChangeSet()
    }
}

public extension BrowserStore {
    /// The home context is retained for engine/profile APIs, but no Space or shared section is
    /// created. Only this window can address its local list.
    func createStandaloneWindow(profileID: ProfileID, homeSpaceID: SpaceID) throws -> WindowID {
        guard spaces[homeSpaceID]?.profileID == profileID else { throw BrowserStoreError.profileMissing }
        let id = try createWindow(activeSpaceID: homeSpaceID)
        windows[id]?.standaloneProfileID = profileID
        organization.standaloneHomes[id] = homeSpaceID
        organization.standalone[id] = []
        return id
    }
}
