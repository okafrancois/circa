import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@MainActor
struct GmailPresentationTests {
    private func item() -> FavoriteTileItem {
        .init(tab: .init(id: TabID(), section: .favorites(ProfileID()), url: URL(string: "https://mail.google.com/mail/u/0/")!,
            pinnedURL: URL(string: "https://mail.google.com/mail/u/0/")!, pageTitle: "Synthetic inbox", customTitle: nil,
            occurrenceID: nil, isLoadedInThisWindow: false, isSelected: false, isOpenInAnotherWindow: false), favicon: nil)
    }

    @Test("The unread indicator is specific to mail and clears when a retained tile loses its inbox")
    func tileBadge() throws {
        var item = item(); item.gmailUnreadCount = 3
        let tile = FavoriteTileView(item: item)
        tile.frame = .init(x: 0, y: 0, width: 70, height: 47)
        tile.layoutSubtreeIfNeeded()
        let badge = try #require(tile.subviews.first { $0.identifier?.rawValue == "gmail-unread" })
        #expect(!badge.isHidden && badge.frame.size == NSSize(width: 6, height: 6))
        item.showsGmailBadge = false; tile.update(item)
        #expect(badge.isHidden)
        item.showsGmailBadge = true; item.gmailUnreadCount = nil; tile.update(item)
        #expect(badge.isHidden)
    }

    @Test("Pinned row reuse clears unread mail state and the trailing mark yields to hover controls")
    func pinnedBadge() throws {
        let row = SidebarTabRow(item: .init(id: TabID(), title: "Synthetic inbox", selected: false, isPinned: true))
        row.frame = .init(x: 0, y: 0, width: 220, height: 32)
        row.setGmailUnread(count: 3, showsBadge: true)
        row.layoutSubtreeIfNeeded()
        let badge = try #require(row.subviews.first { $0.identifier?.rawValue == "gmail-unread" })
        #expect(!badge.isHidden && badge.frame.size == NSSize(width: 6, height: 6))
        row.resetForReuse()
        #expect(badge.isHidden)
    }

    @Test("Inbox text remains native text, message identity routes the click, and long lists scroll")
    func nativeRows() throws {
        let view = GmailPreviewView(frame: .init(x: 0, y: 0, width: 250, height: 300))
        let inbox = BrowserGmailInbox(unreadCount: 20, messages: (1...20).map {
            .init(id: String($0, radix: 16), sender: "Synthetic sender", subject: "<b>Plain subject</b>",
                  summary: "A longer invented message preview wraps across two lines without opening the email or rendering remote markup.", receivedAt: nil)
        })
        var chosen: String?
        view.onMessage = { chosen = $0 }
        view.render(inbox); view.layoutSubtreeIfNeeded()
        #expect(view.contentHeight == 300)
        let document = try #require(view.scroll.documentView)
        #expect(abs(document.frame.height - CGFloat(20 * 84)) < 0.01)
        let rows = document.subviews.filter { $0.accessibilityRole() == .button }
        #expect(rows.count == 20)
        #expect(rows.first?.accessibilityLabel()?.contains("<b>Plain subject</b>") == true)
        let row = try #require(rows.first)
        row.layoutSubtreeIfNeeded()
        let summary = try #require(row.subviews.compactMap { $0 as? NSTextField }.first { $0.maximumNumberOfLines == 2 })
        #expect(try #require(summary.cell).cellSize(forBounds: summary.bounds).height > 20)
        #expect(rows.first?.accessibilityPerformPress() == true)
        #expect(chosen == "1")
        view.render(.init(unreadCount: 0, messages: []))
        #expect(view.contentHeight == 84)
        #expect(document.subviews.filter { $0.accessibilityRole() == .button }.isEmpty)
    }

    @Test("Relative dates have enough drawing width to avoid truncating short hour labels")
    func dateDrawingWidth() throws {
        let view = GmailPreviewView(frame: .init(x: 0, y: 0, width: 250, height: 84))
        view.render(.init(unreadCount: 1, messages: [.init(id: "abc", sender: "Synthetic sender", subject: "Synthetic subject",
            summary: "Synthetic preview", receivedAt: Date().addingTimeInterval(-7200))]))
        view.layoutSubtreeIfNeeded()
        let row = try #require(view.scroll.documentView?.subviews.first { $0.accessibilityRole() == .button })
        row.layoutSubtreeIfNeeded()
        let date = try #require(row.subviews.compactMap { $0 as? NSTextField }.first { $0.alignment == .right })
        let font = try #require(date.font)
        let textWidth = (date.stringValue as NSString).size(withAttributes: [.font: font]).width
        let cell = try #require(date.cell)
        let drawingWidth = cell.drawingRect(forBounds: date.bounds).width
        #expect(!date.stringValue.isEmpty)
        #expect(drawingWidth >= ceil(textWidth))
        #expect(date.bounds.width >= ceil(cell.cellSize.width))
    }
}
}
