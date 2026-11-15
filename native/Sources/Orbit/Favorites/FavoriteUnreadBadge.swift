import BrowserCore

/// A shared projection for Favorite tiles and pinned rows, using the existing badge policy.
struct FavoriteUnreadBadge: Equatable {
    let count: Int?
    let showsBadge: Bool

    init(tab: BrowserOrganizationTabItem, liveTitle: String?, gmailCount: Int?,
         isPrivateWindow: Bool, hidden: Set<TabID>) {
        showsBadge = !hidden.contains(tab.id)
        guard !isPrivateWindow, tab.section.keepsPinnedURL else { count = nil; return }
        if BrowserGmailAccount(url: tab.pinnedURL ?? tab.url) != nil {
            // Feed metadata remains available even when the mail Favorite is dormant.
            count = gmailCount
        } else {
            count = tab.isLoadedInThisWindow ? BrowserTitleUnreadCount.parse(liveTitle) : nil
        }
    }
}
