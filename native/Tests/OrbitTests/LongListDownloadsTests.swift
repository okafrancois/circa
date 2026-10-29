import AppKit
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Long download list recycling", .serialized)
@MainActor
struct LongListDownloadsTests {
    private let base = Date(timeIntervalSinceReferenceDate: 812_462_400)

    private func presentations(_ count: Int) -> [DownloadRowPresentation] {
        (0..<count).map { index in
            .init(id: UUID(), lifetime: UUID(), revision: 1, title: "Synthetic \(index).pdf", detail: "1 KB",
                  receivedBytes: 1, totalBytes: 1, isRunning: false, actions: [.open, .reveal, .remove],
                  startedAt: base.addingTimeInterval(-Double(index) * 1500))
        }
    }

    private func rows(in view: NSView) -> [BrowserDownloadRowView] {
        (view as? BrowserDownloadRowView).map { [$0] } ?? view.subviews.flatMap { rows(in: $0) }
    }

    private func scroll(of list: BrowserDownloadsView) throws -> NSScrollView {
        try #require(list.subviews.compactMap { $0 as? NSScrollView }.first)
    }

    /// The top of each displayed row in the stacked arrangement: 4-point top inset, 24-point day
    /// headings and 56-point rows.
    private func expectedTops(_ items: [DownloadRowPresentation]) -> [UUID: CGFloat] {
        var tops: [UUID: CGFloat] = [:], y: CGFloat = 4
        for (_, group) in BrowserDownloadsView.grouped(items) {
            y += 24
            for item in group { tops[item.id] = y; y += 56 }
        }
        return tops
    }

    @Test("A thousand downloads give views only to the rows near the viewport, at their stacked positions")
    func viewportRows() throws {
        let list = BrowserDownloadsView(frame: NSRect(x: 0, y: 0, width: 305, height: 726))
        let items = presentations(1000)
        list.render(items)
        list.layoutSubtreeIfNeeded()
        #expect(list.displayedTitles.count == 1000)
        let views = rows(in: list)
        #expect(views.count <= 24 && list.materializedRowCount == views.filter { !$0.isHidden }.count)
        let tops = expectedTops(items)
        let document = try #require(try scroll(of: list).documentView)
        #expect(document.frame.height == 4 + 1000 * 56 + 24 * CGFloat(BrowserDownloadsView.grouped(items).count) + 8)
        for row in views where !row.isHidden {
            #expect(row.frame == NSRect(x: 8, y: try #require(tops[row.id]), width: 289, height: 56))
            #expect(row.displayedTitle == items.first { $0.id == row.id }?.title)
        }
    }

    @Test("Day headings and rows sit exactly where the stacked arrangement placed them")
    func stackedGeometry() throws {
        let items = presentations(60)
        let groups = BrowserDownloadsView.grouped(items)
        #expect(groups.count >= 2)
        // The previous arrangement: a leading-aligned vertical stack, 8 points in and 4 down.
        let reference = FlippedTestDocument(frame: NSRect(x: 0, y: 0, width: 305, height: 10))
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        reference.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: reference.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: reference.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: reference.topAnchor, constant: 4)
        ])
        var stackedHeadings: [NSTextField] = [], stackedRows: [NSView] = []
        for (_, group) in groups {
            let heading = NSTextField(labelWithString: "Heading")
            heading.font = .systemFont(ofSize: 13, weight: .bold)
            heading.heightAnchor.constraint(equalToConstant: 24).isActive = true
            stack.addArrangedSubview(heading); stackedHeadings.append(heading)
            for _ in group {
                let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
                row.heightAnchor.constraint(equalToConstant: 56).isActive = true
                stack.addArrangedSubview(row); stackedRows.append(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        reference.layoutSubtreeIfNeeded()
        let list = BrowserDownloadsView(frame: NSRect(x: 0, y: 0, width: 305, height: 726))
        list.render(items)
        list.layoutSubtreeIfNeeded()
        let document = try #require(try scroll(of: list).documentView)
        let headings = document.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.sorted { $0.frame.minY < $1.frame.minY }
        let rows = rows(in: list).filter { !$0.isHidden }.sorted { $0.frame.minY < $1.frame.minY }
        #expect(!headings.isEmpty && !rows.isEmpty)
        for (heading, stacked) in zip(headings, stackedHeadings) {
            let frame = stack.convert(stacked.frame, to: reference)
            #expect(heading.frame.minX == frame.minX && heading.frame.minY == frame.minY && heading.frame.height == frame.height)
        }
        for (row, stacked) in zip(rows, stackedRows) { #expect(row.frame == stack.convert(stacked.frame, to: reference)) }
    }

    @Test("Scrolling recycles views; a row that stays visible keeps its view")
    func scrollingRecycles() throws {
        let list = BrowserDownloadsView(frame: NSRect(x: 0, y: 0, width: 305, height: 726))
        let items = presentations(1000)
        list.render(items)
        list.layoutSubtreeIfNeeded()
        let scroll = try scroll(of: list)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 112))
        let kept = try #require(rows(in: list).first { !$0.isHidden && $0.frame.minY > 400 && $0.frame.minY < 600 })
        let keptID = kept.id
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 168))
        #expect(kept.id == keptID && !kept.isHidden)
        let created = Set(rows(in: list).map(ObjectIdentifier.init))
        for y in stride(from: 0, through: 40_000, by: 120) { scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(y))) }
        #expect(Set(rows(in: list).map(ObjectIdentifier.init)).count <= created.count + 4)
        let tops = expectedTops(items)
        let visible = rows(in: list).filter { !$0.isHidden }
        #expect(!visible.isEmpty)
        for row in visible {
            #expect(row.frame.minY == tops[row.id])
            #expect(row.displayedTitle == items.first { $0.id == row.id }?.title)
        }
        #expect(Set(visible.map(\.id)).count == visible.count)
    }

    @Test("Per-item updates reach only the affected row; off-screen updates apply when the row appears")
    func deltaUpdates() throws {
        let list = BrowserDownloadsView(frame: NSRect(x: 0, y: 0, width: 305, height: 726))
        let items = presentations(400)
        list.render(items)
        list.layoutSubtreeIfNeeded()
        func changed(_ item: DownloadRowPresentation, _ detail: String) -> DownloadRowPresentation {
            .init(id: item.id, lifetime: item.lifetime, revision: 2, title: item.title, detail: detail,
                  receivedBytes: 1, totalBytes: 1, isRunning: false, actions: item.actions, startedAt: item.startedAt)
        }
        let before = Set(rows(in: list).map(ObjectIdentifier.init))
        list.update([changed(items[0], "Visible change"), changed(items[399], "Hidden change")])
        #expect(Set(rows(in: list).map(ObjectIdentifier.init)) == before, "updates never create views")
        #expect(rows(in: list).first { $0.id == items[0].id }?.detailLabel.stringValue == "Visible change")
        #expect(!rows(in: list).contains { $0.id == items[399].id && !$0.isHidden })
        let scroll = try scroll(of: list)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: try #require(scroll.documentView).frame.height))
        #expect(rows(in: list).first { $0.id == items[399].id && !$0.isHidden }?.detailLabel.stringValue == "Hidden change")
        #expect(list.renderCount == 1)
    }

    @Test("Keyboard focus survives scrolling away and is released when its row leaves the list")
    func focusedRow() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 305, height: 726), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = BrowserDownloadsView(frame: NSRect(x: 0, y: 0, width: 305, height: 726))
        window.contentView?.addSubview(list)
        let items = presentations(600)
        list.render(items)
        list.layoutSubtreeIfNeeded()
        let focused = try #require(rows(in: list).first { $0.id == items[1].id })
        #expect(window.makeFirstResponder(focused))
        let scroll = try scroll(of: list)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 20_000))
        #expect(window.firstResponder === focused && !focused.isHidden && focused.id == items[1].id)
        scroll.contentView.scroll(to: .zero)
        #expect(window.firstResponder === focused)
        list.render(items, query: "Synthetic 599")
        #expect(window.firstResponder === window)
        #expect(!rows(in: list).contains { !$0.isHidden && $0.id == items[1].id })
        #expect(list.displayedTitles == ["Synthetic 599.pdf"])
    }

    @Test("Cancelled icon work never reaches a recycled row; a cleared list ignores late results")
    func staleIconCompletions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("download-icons-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.zip"), second = directory.appendingPathComponent("second.zip")
        for url in [first, second] { try Data([1]).write(to: url) }
        let cache = BrowserDownloadIconCache()
        var delivered: [URL] = []
        let cancelled = cache.load(first, fileIcon: true, thumbnail: false) { _ in delivered.append(first) }
        cancelled.cancel()
        _ = cache.load(second, fileIcon: true, thumbnail: false) { _ in delivered.append(second) }
        for _ in 0..<400 where cache.cached(first) == nil || cache.cached(second) == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(delivered == [second], "a cancelled request still warms the cache but delivers nothing")
        #expect(cache.cached(first)?.image != nil)
        let third = directory.appendingPathComponent("third.zip")
        try Data([1]).write(to: third)
        _ = cache.load(third, fileIcon: true, thumbnail: false) { _ in delivered.append(third) }
        cache.removeAll()
        try await Task.sleep(for: .milliseconds(300))
        #expect(cache.cached(third) == nil && delivered == [second], "work started before a clear is dropped")

        let row = BrowserDownloadRowView(id: UUID(), lifetime: UUID())
        row.icons = cache
        func show(_ url: URL, _ title: String) {
            row.render(.init(id: row.id, lifetime: row.lifetime, revision: 1, title: title, detail: "",
                             receivedBytes: 1, totalBytes: 1, isRunning: false, actions: [.open], fileURL: url))
        }
        let image = directory.appendingPathComponent("picture.png")
        try NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!.write(to: image)
        show(image, "picture.png")
        row.prepareForReuse()
        row.reuse(id: UUID(), lifetime: UUID())
        row.render(.init(id: row.id, lifetime: row.lifetime, revision: 1, title: "notes.txt", detail: "",
                         receivedBytes: 1, totalBytes: 1, isRunning: false, actions: []))
        let placeholder = cache.typeIcon(forExtension: "txt")
        try await Task.sleep(for: .milliseconds(600))
        #expect(row.icon.image === placeholder, "the earlier file's icon and thumbnail are rejected")
    }

    @Test("The icon cache keeps the most recently used files within its bound")
    func iconEviction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("download-icons-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (0..<3).map { directory.appendingPathComponent("file-\($0).zip") }
        for url in urls { try Data([1]).write(to: url) }
        let cache = BrowserDownloadIconCache(capacity: 2)
        func load(_ url: URL) async throws {
            _ = cache.load(url, fileIcon: true, thumbnail: false) { _ in }
            for _ in 0..<400 where cache.cached(url) == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        try await load(urls[0])
        try await load(urls[1])
        _ = cache.cached(urls[0]) // Most recently used again.
        try await load(urls[2])
        #expect(cache.count == 2)
        #expect(cache.cached(urls[0]) != nil && cache.cached(urls[2]) != nil && cache.cached(urls[1]) == nil)
    }
}
}

@MainActor
private final class FlippedTestDocument: NSView {
    override var isFlipped: Bool { true }
}
