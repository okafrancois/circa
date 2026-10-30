import BrowserCore
import Foundation

/// The confined import probe uses the production parser and merge without accessing a profile.
@MainActor
enum BrowserPinnedImportFixture {
    struct ImportedSpace {
        let id: SpaceID
        let profileID: ProfileID
        let theme: BrowserSpaceTheme
    }

    static func install(_ data: Data, in store: BrowserStore, profile: ProfileID?) async throws -> ImportedSpace? {
        let graph = try ArcSidebarParser.parse(sidebar: ArcJSON.parse(data), archive: nil, localState: nil)
        let plan = ArcImportMapper.plan(graph, defaultProfileTarget: profile, importedAt: Date())
        func allows(_ tab: BrowserOrganizedTab) -> Bool {
            ["http", "https"].contains(tab.url.scheme ?? "") && ["127.0.0.1", "localhost"].contains(tab.url.host ?? "")
        }
        func allows(_ nodes: [BrowserImportPlan.Node]) -> Bool {
            nodes.allSatisfy { node in
                switch node {
                case .tab(let tab): return allows(tab)
                case .folder(_, let children): return allows(children)
                }
            }
        }
        guard plan.sections.allSatisfy({ allows($0.pinned) && $0.today.allSatisfy(allows) }),
              plan.favorites.allSatisfy({ $0.tabs.allSatisfy(allows) }),
              let space = plan.spaces.first, let theme = ArcSpaceThemeImport.theme(for: space.appearance) else { return nil }
        _ = try await store.applyImport(plan, ledger: BrowserImportLedger())
        return ImportedSpace(id: space.id, profileID: space.profileID, theme: theme)
    }
}
