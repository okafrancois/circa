import AppKit
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Library download and archive presentation", .serialized)
@MainActor
struct LibraryDownloadsArchiveTests {
    @Test("Archive cells retain the title, URL and cached icon across row reuse")
    func archiveCellReuse() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let now = Date(), profile = ProfileID(), space = SpaceID()
        func record(_ title: String, path: String) -> BrowserArchivedTab {
            .init(tab: .init(id: TabID(), url: URL(string: "https://library.test/\(path)")!,
                customTitle: title, createdAt: now, lastActiveAt: now),
                profileID: profile, spaceID: space, origin: .today, reason: .closed, archivedAt: now)
        }
        let first = record("A long custom title", path: "one"), second = record("Second", path: "two")
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let cell = BrowserArchiveCell(frame: NSRect(x: 0, y: 0, width: 289, height: 56))
        cell.configure(first, icon: icon)
        cell.layoutSubtreeIfNeeded()
        #expect(cell.titleLabel.stringValue == "A long custom title")
        #expect(cell.detailLabel.stringValue == first.tab.url.absoluteString)
        #expect(cell.imageView?.image === icon)
        #expect(cell.titleLabel.alignmentRect(forFrame: cell.titleLabel.frame).minX == 44)
        #expect(cell.detailLabel.frame.minX == cell.titleLabel.frame.minX)
        cell.configure(second, icon: nil)
        #expect(cell.titleLabel.stringValue == "Second")
        #expect(cell.detailLabel.stringValue == second.tab.url.absoluteString)
        #expect(cell.imageView?.image !== icon)
    }

    @Test("Archive day headings are skipped while restore and delete retain record identity")
    func archiveSelectionActions() throws {
        let view = BrowserArchiveView(frame: NSRect(x: 0, y: 0, width: 305, height: 780))
        view.setLibraryEmbedded()
        let now = Date(), profile = ProfileID(), space = SpaceID(), id = TabID()
        let record = BrowserArchivedTab(tab: .init(id: id, url: URL(string: "https://library.test/one")!,
            pageTitle: "Synthetic page", createdAt: now, lastActiveAt: now),
            profileID: profile, spaceID: space, origin: .today, reason: .closed, archivedAt: now)
        view.render([record], profileName: "Synthetic", setting: 0)
        #expect(!view.tableView(view.table, shouldSelectRow: 0))
        #expect(view.tableView(view.table, heightOfRow: 1) == 56)
        var restored: TabID?, deleted: TabID?
        view.onRestore = { restored = $0 }; view.onDelete = { deleted = $0 }
        let editor = NSTextView()
        #expect(view.control(view.searchField, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        view.table.onReturn?(); view.table.onDelete?()
        #expect(restored == id && deleted == id)
        #expect(view.searchField.placeholderString == uiText("Search Archive…"))
        view.render([], profileName: "Synthetic", setting: 0)
        restored = nil; deleted = nil
        view.table.onReturn?(); view.table.onDelete?()
        #expect(restored == nil && deleted == nil)
    }

    @Test("Download actions are hidden at rest and remain available through hover, focus and menus")
    func downloadActionVisibility() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 305, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let row = BrowserDownloadRowView(id: UUID(), lifetime: UUID())
        row.frame = NSRect(x: 0, y: 0, width: 305, height: 56)
        window.contentView?.addSubview(row)
        func render(_ revision: UInt64) {
            row.render(.init(id: row.id, lifetime: row.lifetime, revision: revision, title: "Synthetic.pdf",
                detail: "12 KB", receivedBytes: 12000, totalBytes: 12000, isRunning: false, actions: [.open, .reveal, .remove]))
        }
        render(1)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        #expect(!row.areActionsVisible)
        row.mouseEntered(with: event)
        #expect(row.areActionsVisible)
        row.mouseExited(with: event)
        #expect(!row.areActionsVisible)
        #expect(window.makeFirstResponder(row))
        #expect(row.areActionsVisible)
        row.mouseEntered(with: event); row.mouseExited(with: event)
        #expect(row.areActionsVisible)
        window.makeFirstResponder(nil)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(!row.areActionsVisible)
        let menu = try #require(row.menu(for: event))
        #expect(menu.items.map(\.title) == [uiText("Open File"), uiText("Show in Finder"), uiText("Remove from List")])
        var received: [(UInt64, DownloadRowPresentation.Action)] = []
        row.onAction = { _, _, revision, action in received.append((revision, action)) }
        for item in menu.items { (item.target as? NSObject)?.perform(try #require(item.action), with: item) }
        #expect(received.map { $0.1 } == [.open, .reveal, .remove])
        render(2)
        let item = try #require(menu.items.last)
        (item.target as? NSObject)?.perform(try #require(item.action), with: item)
        #expect(received.last?.0 == 1)
        #expect(!row.areActionsVisible)
    }

    @Test("Archive row menus preserve record identity without footer controls")
    func archiveRowMenus() throws {
        let view = BrowserArchiveView(frame: NSRect(x: 0, y: 0, width: 305, height: 780))
        view.setLibraryEmbedded()
        let now = Date(), profile = ProfileID(), space = SpaceID()
        func record() -> BrowserArchivedTab {
            .init(tab: .init(id: TabID(), url: URL(string: "https://library.test/page")!,
                pageTitle: "Synthetic", createdAt: now, lastActiveAt: now), profileID: profile, spaceID: space,
                origin: .today, reason: .closed, archivedAt: now)
        }
        let first = record(), second = record()
        view.render([first, second], profileName: "Synthetic", setting: 0)
        let index = try #require(view.rows.firstIndex { if case .tab(let r) = $0 { return r.id == first.id }; return false })
        let menu = try #require(view.contextMenu(for: index))
        #expect(view.contextMenu(for: 0) == nil)
        #expect(menu.items.map(\.title) == [uiText("Restore"), uiText("Delete")])
        view.table.selectRowIndexes(IndexSet(integer: index == 1 ? 2 : 1), byExtendingSelection: false)
        var restored: TabID?, deleted: TabID?
        view.onRestore = { restored = $0 }; view.onDelete = { deleted = $0 }
        for item in menu.items { (item.target as? NSObject)?.perform(try #require(item.action), with: item) }
        #expect(restored == first.id && deleted == first.id)
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        #expect(!buttons(in: view).contains { [uiText("Restore"), uiText("Delete")].contains($0.title) })
        view.render([], profileName: "Synthetic", setting: 0)
        restored = nil; deleted = nil
        for item in menu.items { (item.target as? NSObject)?.perform(try #require(item.action), with: item) }
        #expect(restored == nil && deleted == nil)
    }

    @Test("Empty archive and download searches align their messages in the Library body")
    func emptyAlignment() throws {
        func empty(in view: NSView) -> BrowserLibraryEmptyView? {
            (view as? BrowserLibraryEmptyView) ?? view.subviews.compactMap { empty(in: $0) }.first
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 305, height: 780))
        let downloads = BrowserDownloadsPane(frame: root.bounds), archive = BrowserArchiveView(frame: root.bounds)
        downloads.setLibraryEmbedded(); archive.setLibraryEmbedded()
        root.addSubview(downloads); root.addSubview(archive)
        downloads.searchField.stringValue = "Synthetic query"; downloads.setProfileName("Synthetic")
        archive.searchField.stringValue = "Synthetic query"; archive.render([], profileName: "Synthetic", setting: 0)
        root.layoutSubtreeIfNeeded()
        let a = try #require(empty(in: archive)), d = try #require(empty(in: downloads))
        let af = a.message.convert(a.message.bounds, to: root), df = d.message.convert(d.message.bounds, to: root)
        #expect(abs(af.midY - df.midY) < 2, "Archive: \(af), Downloads: \(df), body: \(archive.frame)")
    }

    @Test("Download dates sort newest first and legacy rows share one final undated group")
    func dateGroups() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        func row(_ date: Date?) -> DownloadRowPresentation {
            .init(id: UUID(), lifetime: UUID(), revision: 1, title: "Synthetic", detail: "",
                  receivedBytes: 0, totalBytes: nil, isRunning: false, actions: [], startedAt: date)
        }
        let old = row(today.addingTimeInterval(-86400)), newest = row(today), missing = row(nil), anotherMissing = row(nil)
        let groups = BrowserDownloadsView.grouped([missing, old, anotherMissing, newest], calendar: calendar)
        #expect(groups.count == 3)
        #expect(groups[0].1.map(\.id) == [newest.id])
        #expect(groups[1].1.map(\.id) == [old.id])
        #expect(groups[2].0 == .undated)
        #expect(Set(groups[2].1.map(\.id)) == [missing.id, anotherMissing.id])
    }

    @Test("Repeated transfer projections reuse the row and its known file icon")
    func downloadProjectionReuse() throws {
        let list = BrowserDownloadsView(frame: NSRect(x: 0, y: 0, width: 305, height: 726))
        let id = UUID(), lifetime = UUID()
        let row = DownloadRowPresentation(id: id, lifetime: lifetime, revision: 1,
            title: "Synthetic.pdf", detail: "12 KB", receivedBytes: 12000, totalBytes: 12000,
            isRunning: false, actions: [.open, .reveal, .remove])
        list.render([row]); list.layoutSubtreeIfNeeded()
        func findRow(_ view: NSView) -> BrowserDownloadRowView? {
            (view as? BrowserDownloadRowView) ?? view.subviews.compactMap { findRow($0) }.first
        }
        let first = try #require(findRow(list)), image = try #require(first.icon.image)
        list.render([row]); list.layoutSubtreeIfNeeded()
        #expect(findRow(list) === first)
        #expect(first.icon.image === image)
        #expect(first.bounds.height == 56)
        #expect(first.titleLabel.alignmentRect(forFrame: first.titleLabel.frame).minX == 44)
        list.render([row], query: "Missing")
        #expect(list.displayedTitles.isEmpty)
        list.render([row])
        #expect(findRow(list) === first && first.icon.image === image)
        list.render([])
        #expect(list.displayedTitles.isEmpty)
    }
}
}
