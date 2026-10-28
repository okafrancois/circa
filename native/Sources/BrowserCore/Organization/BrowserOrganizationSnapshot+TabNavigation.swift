import Foundation

public extension BrowserOrganizationSnapshot {
    /// A split occupies one Sidebar item. Collapsed folders retain their child tab order.
    var tabNavigationItems: [BrowserOrganizationTabItem] {
        func tabs(in items: [BrowserOrganizationItem]) -> [BrowserOrganizationTabItem] {
            items.flatMap { item in
                switch item {
                case .tab(let tab): [tab]
                case .folder(let folder): tabs(in: folder.children)
                case .split(let split): (split.activeTab ?? split.tabs.first).map { [$0] } ?? []
                }
            }
        }
        return tabs(in: favorites + pinned + today)
    }
}
