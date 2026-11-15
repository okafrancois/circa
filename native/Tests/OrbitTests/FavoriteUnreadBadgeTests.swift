import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

@MainActor
struct FavoriteUnreadBadgeTests {
    private func tab(mail: Bool = false, loaded: Bool = true, pinned: Bool = false) -> BrowserOrganizationTabItem {
        let url = URL(string: mail ? "https://mail.google.com/mail/u/0/" : "https://inbox.example.test/")!
        return .init(id: TabID(), section: pinned ? .pinned(SpaceID()) : .favorites(ProfileID()),
            url: url, pinnedURL: url, pageTitle: "(45) Stored title", customTitle: "(67) Custom title",
            occurrenceID: loaded ? TabOccurrenceID() : nil, isLoadedInThisWindow: loaded,
            isSelected: false, isOpenInAnotherWindow: false)
    }

    @Test("A retained Favorite uses live titles and clears the same dot as counts change")
    func liveUpdates() throws {
        let tab = tab()
        let tile = FavoriteTileView(item: .init(tab: tab))
        let dot = try #require(tile.subviews.first { $0.identifier?.rawValue == "gmail-unread" })
        for (title, count) in [("Inbox", nil), ("(3) Inbox", 3), ("(12) Inbox", 12), ("(99+) Inbox", 99), ("Inbox", nil)] {
            let state = FavoriteUnreadBadge(tab: tab, liveTitle: title, gmailCount: nil, isPrivateWindow: false, hidden: [])
            tile.update(.init(tab: tab, unreadCount: state.count, showsUnreadBadge: state.showsBadge))
            #expect(tile.item.unreadCount == count)
            #expect(dot.isHidden == (count == nil))
        }
        #expect(FavoriteUnreadBadge(tab: tab, liveTitle: nil, gmailCount: nil, isPrivateWindow: false, hidden: []).count == nil)
        #expect(FavoriteUnreadBadge(tab: self.tab(loaded: false), liveTitle: "(3) Inbox", gmailCount: nil, isPrivateWindow: false, hidden: []).count == nil)
    }

    @Test("Mail feed precedence includes zero, unavailable metadata and dormant Favorites")
    func feedPrecedence() {
        for loaded in [false, true] {
            for count: Int? in [nil, 0, 8] {
                let state = FavoriteUnreadBadge(tab: tab(mail: true, loaded: loaded), liveTitle: "(3) Inbox",
                    gmailCount: count, isPrivateWindow: false, hidden: [])
                #expect(state.count == count)
            }
        }
    }

    @Test("The same hidden-tab preference and private suppression apply to both count sources")
    func privacyAndPreference() {
        for mail in [false, true] {
            let tab = tab(mail: mail)
            let hidden = FavoriteUnreadBadge(tab: tab, liveTitle: "(3) Inbox", gmailCount: 8, isPrivateWindow: false, hidden: [tab.id])
            #expect(!hidden.showsBadge)
            #expect(hidden.count == (mail ? 8 : 3))
            let otherTab = FavoriteUnreadBadge(tab: tab, liveTitle: "(3) Inbox", gmailCount: 8, isPrivateWindow: false, hidden: [TabID()])
            #expect(otherTab.showsBadge)
            let privateState = FavoriteUnreadBadge(tab: tab, liveTitle: "(3) Inbox", gmailCount: 8, isPrivateWindow: true, hidden: [])
            #expect(privateState.count == nil)
        }
    }

    @Test("Pinned rows reuse their dot and hide preference for title counts")
    func pinnedRow() throws {
        let tab = tab(pinned: true)
        let row = SidebarTabRow(item: .init(id: tab.id, title: "Inbox", selected: false, isPinned: true))
        let dot = try #require(row.subviews.first { $0.identifier?.rawValue == "gmail-unread" })
        for hidden: Set<TabID> in [[], [tab.id]] {
            let state = FavoriteUnreadBadge(tab: tab, liveTitle: "[3] Inbox", gmailCount: nil, isPrivateWindow: false, hidden: hidden)
            row.setGmailUnread(count: state.count, showsBadge: state.showsBadge)
            #expect(dot.isHidden == hidden.contains(tab.id))
        }
    }
}
