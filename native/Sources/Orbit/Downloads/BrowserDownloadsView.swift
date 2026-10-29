import AppKit
import BrowserCore
import BrowserShell
import Foundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct DownloadRowPresentation {
    enum Action { case cancel, pause, resume, open, reveal, remove }
    let id: UUID
    let lifetime: UUID
    let revision: UInt64
    let title: String
    let detail: String
    let receivedBytes: Int64
    let totalBytes: Int64?
    let isRunning: Bool
    let actions: [Action]
    var fileURL: URL? = nil
    var startedAt: Date? = nil
}

/// Placement, grouping and search identity of one download. Its row content is built on demand.
struct DownloadListEntry {
    let id: UUID
    let lifetime: UUID
    let title: String
    let startedAt: Date?
}

/// A profile-scoped native list. Transfer ownership and file effects belong to the coordinator.
/// Placement is arithmetic over every entry; only rows near the viewport have views, which are
/// recycled while scrolling.
@MainActor
final class BrowserDownloadsView: NSView {
    private enum Metrics {
        static let inset: CGFloat = 8
        static let top: CGFloat = 4
        static let bottom: CGFloat = 8
        static let headingHeight: CGFloat = 24
        static let rowHeight: CGFloat = 56
        static let overscan: CGFloat = 4 * rowHeight
        /// Viewport assumed before the list has been laid out.
        static let unplacedHeight: CGFloat = 900
    }
    private enum Slot { case heading(Day), row(Int) }

    var onDragFile: ((UUID, UUID, UInt64) -> URL?)?
    var onAction: ((UUID, UUID, UInt64, DownloadRowPresentation.Action) -> Void)?
    private(set) var renderCount = 0
    private let scroll = NSScrollView()
    private let document = FlippedDownloadDocument()
    private let empty = BrowserLibraryEmptyView()
    var emptyQuery = "" { didSet { empty.configure(symbol: BrowserLibraryCategory.downloads.symbol, title: uiText("No Downloads"), query: emptyQuery, largeGlyph: true) } }
    let icons = BrowserDownloadIconCache()
    private var entries: [DownloadListEntry] = []
    private var indexByID: [UUID: Int] = [:]
    private var presentation: ((Int) -> DownloadRowPresentation)?
    private var updates: [UUID: DownloadRowPresentation] = [:]
    private var slots: [Slot] = []
    private var slotTops: [CGFloat] = []
    private var contentHeight = Metrics.top + Metrics.bottom
    private var rowViews: [UUID: BrowserDownloadRowView] = [:]
    private var headings: [Day: NSTextField] = [:]
    private var rowPool: [BrowserDownloadRowView] = []
    private var headingPool: [NSTextField] = []
    private var query = ""
    private let dates = BrowserLibraryDateObserver()
    private var dayFormatter = BrowserDownloadsView.makeDayFormatter()
    enum Day: Hashable { case dated(Date), undated }

    static func grouped(_ presentations: [DownloadRowPresentation], calendar: Calendar = .current) -> [(Day, [DownloadRowPresentation])] {
        days(presentations, startedAt: \.startedAt, calendar: calendar)
    }

    /// Newest day first, undated last, newest first within a day. The sort is stable: equal start
    /// times keep their input order.
    static func days<Item>(_ items: [Item], startedAt: (Item) -> Date?, calendar: Calendar) -> [(Day, [Item])] {
        let ordered = items.sorted {
            switch (startedAt($0), startedAt($1)) {
            case let (a?, b?): return a > b
            case (.some, nil): return true
            default: return false
            }
        }
        var groups: [(Day, [Item])] = []
        var day: (start: Date, end: Date)?
        for item in ordered {
            guard let date = startedAt(item) else {
                if case .undated? = groups.last?.0 { groups[groups.count - 1].1.append(item) }
                else { groups.append((.undated, [item])) }
                continue
            }
            if let day, date >= day.start, date < day.end {
                groups[groups.count - 1].1.append(item)
            } else {
                let start = calendar.startOfDay(for: date)
                day = (start, calendar.dateInterval(of: .day, for: date)?.end ?? start.addingTimeInterval(86_400))
                groups.append((.dated(start), [item]))
            }
        }
        return groups
    }

    private static func makeDayFormatter() -> DateFormatter {
        let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        return formatter
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        BrowserLibraryStyle.configure(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        addSubview(scroll)
        empty.configure(symbol: BrowserLibraryCategory.downloads.symbol, title: uiText("No Downloads"), largeGlyph: true)
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        dates.onChange = { [weak self] in
            guard let self, let presentation else { return }
            dayFormatter = Self.makeDayFormatter()
            render(entries, query: query, presentation: presentation)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); dates.setAttached(window != nil) }

    override func layout() {
        super.layout()
        placeDocument()
        materialize()
    }

    @objc private func clipBoundsDidChange(_ notification: Notification) { materialize() }

    func render(_ presentations: [DownloadRowPresentation], query: String = "") {
        render(presentations.map { DownloadListEntry(id: $0.id, lifetime: $0.lifetime, title: $0.title, startedAt: $0.startedAt) },
               query: query, presentation: { presentations[$0] })
    }

    /// `presentation` builds the row for an entry index; it runs only for rows given a view.
    func render(_ entries: [DownloadListEntry], query: String, presentation: @escaping (Int) -> DownloadRowPresentation) {
        self.entries = entries
        self.query = query
        self.presentation = presentation
        updates = [:]
        renderCount += 1
        indexByID = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        if entries.isEmpty { icons.removeAll() }
        let visible = entries.indices.filter { query.isEmpty || entries[$0].title.localizedCaseInsensitiveContains(query) }
        slots = []; slotTops = []
        slots.reserveCapacity(visible.count + 32); slotTops.reserveCapacity(visible.count + 32)
        var y = Metrics.top
        for (day, items) in Self.days(visible, startedAt: { entries[$0].startedAt }, calendar: .current) {
            slots.append(.heading(day)); slotTops.append(y); y += Metrics.headingHeight
            for index in items { slots.append(.row(index)); slotTops.append(y); y += Metrics.rowHeight }
        }
        contentHeight = y + Metrics.bottom
        placeDocument()
        materialize(reconfigure: true)
        empty.isHidden = !visible.isEmpty
    }

    func canUpdate(_ delta: BrowserDownloadCoordinator.Delta, profileID: ProfileID) -> Bool {
        guard delta.removed.isEmpty else { return false }
        return delta.changed.filter { $0.owner.profileID == profileID }.allSatisfy { item in
            guard let index = indexByID[item.key.id] else { return false }
            let entry = entries[index]
            return entry.lifetime == item.key.lifetime && entry.startedAt == item.startedAt
                && entry.title == (item.destinationURL?.lastPathComponent ?? item.suggestedFilename)
        }
    }

    /// Per-item deltas touch only the affected rows that have a view.
    func update(_ changes: [DownloadRowPresentation]) {
        for change in changes where indexByID[change.id] != nil {
            updates[change.id] = change
            rowViews[change.id]?.render(change)
        }
    }

    var displayedTitles: [String] {
        slots.compactMap { if case let .row(index) = $0 { return entries[index].title }; return nil }
    }

    var materializedRowCount: Int { rowViews.count }

    private func placeDocument() {
        let size = NSSize(width: scroll.contentView.bounds.width, height: contentHeight)
        if document.frame.size != size { document.setFrameSize(size) }
    }

    private func frame(ofSlot index: Int) -> NSRect {
        let height = if case .heading = slots[index] { Metrics.headingHeight } else { Metrics.rowHeight }
        return NSRect(x: Metrics.inset, y: slotTops[index], width: max(0, document.bounds.width - 2 * Metrics.inset), height: height)
    }

    /// Gives views to the slots near the visible rect and recycles the others. A row holding
    /// keyboard focus keeps its view while it remains listed.
    private func materialize(reconfigure: Bool = false) {
        var visible = scroll.contentView.bounds
        if visible.height <= 0 { visible.size.height = Metrics.unplacedHeight }
        let band = visible.insetBy(dx: 0, dy: -Metrics.overscan)
        var lower = 0, upper = slotTops.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if slotTops[middle] <= band.minY { lower = middle + 1 } else { upper = middle }
        }
        var range = max(0, lower - 1)..<max(0, lower - 1)
        while range.upperBound < slots.count, slotTops[range.upperBound] < band.maxY { range = range.lowerBound..<(range.upperBound + 1) }
        var neededRows: [UUID: Int] = [:], neededDays: [Day: Int] = [:]
        for index in range {
            switch slots[index] {
            case let .heading(day): neededDays[day] = index
            case let .row(entry): neededRows[entries[entry].id] = index
            }
        }
        let focused = focusedRowID()
        for (id, row) in rowViews where neededRows[id] == nil {
            if id == focused, let index = indexByID[id], entries[index].lifetime == row.lifetime,
               let slot = slots.firstIndex(where: { if case .row(index) = $0 { return true }; return false }) {
                neededRows[id] = slot
                continue
            }
            rowViews[id] = nil
            recycle(row)
        }
        for (day, heading) in headings where neededDays[day] == nil {
            headings[day] = nil
            heading.isHidden = true
            headingPool.append(heading)
        }
        for (day, slot) in neededDays.sorted(by: { $0.value < $1.value }) {
            let heading: NSTextField
            if let existing = headings[day] {
                heading = existing
                if reconfigure { configure(heading, day) }
            } else {
                heading = headingPool.popLast() ?? makeHeading()
                heading.isHidden = false
                configure(heading, day)
                headings[day] = heading
            }
            // The stacked layout aligned the label's alignment rect, not its frame.
            let frame = heading.frame(forAlignmentRect: frame(ofSlot: slot))
            if heading.frame != frame { heading.frame = frame }
        }
        for (id, slot) in neededRows.sorted(by: { $0.value < $1.value }) {
            guard case let .row(index) = slots[slot] else { continue }
            let entry = entries[index]
            let row: BrowserDownloadRowView
            if let existing = rowViews[id], existing.lifetime == entry.lifetime {
                row = existing
                if reconfigure, let content = content(index) { row.render(content) }
            } else {
                if let stale = rowViews.removeValue(forKey: id) { recycle(stale) }
                row = dequeueRow(entry)
                if let content = content(index) { row.render(content) }
            }
            let frame = frame(ofSlot: slot)
            if row.frame != frame { row.frame = frame }
        }
    }

    private func content(_ index: Int) -> DownloadRowPresentation? {
        updates[entries[index].id] ?? presentation?(index)
    }

    private func focusedRowID() -> UUID? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        return rowViews.first { responder === $0.value || responder.isDescendant(of: $0.value) }?.key
    }

    private func dequeueRow(_ entry: DownloadListEntry) -> BrowserDownloadRowView {
        let row: BrowserDownloadRowView
        if let reused = rowPool.popLast() {
            row = reused
            row.reuse(id: entry.id, lifetime: entry.lifetime)
            row.isHidden = false
        } else {
            row = BrowserDownloadRowView(id: entry.id, lifetime: entry.lifetime)
            row.translatesAutoresizingMaskIntoConstraints = true
            row.icons = icons
            row.onDragFile = { [weak self] id, lifetime, revision in self?.onDragFile?(id, lifetime, revision) }
            row.onAction = { [weak self] id, lifetime, revision, action in self?.onAction?(id, lifetime, revision, action) }
            document.addSubview(row)
        }
        rowViews[entry.id] = row
        return row
    }

    /// A row leaving the list while it has focus releases it, as a removed view would.
    private func recycle(_ row: BrowserDownloadRowView) {
        if let window, let responder = window.firstResponder as? NSView, responder === row || responder.isDescendant(of: row) {
            window.makeFirstResponder(nil)
        }
        row.prepareForReuse()
        row.isHidden = true
        rowPool.append(row)
    }

    private func makeHeading() -> NSTextField {
        let heading = NSTextField(labelWithString: "")
        heading.font = .systemFont(ofSize: 13, weight: .bold)
        heading.textColor = BrowserLibraryStyle.foreground.withAlphaComponent(0.65)
        heading.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        document.addSubview(heading)
        return heading
    }

    private func configure(_ heading: NSTextField, _ day: Day) {
        switch day {
        case .undated: heading.stringValue = uiText("Undated")
        case .dated(let date):
            heading.stringValue = Calendar.current.isDateInToday(date) ? uiText("Today")
                : Calendar.current.isDateInYesterday(date) ? uiText("Yesterday") : dayFormatter.string(from: date)
        }
    }
}

@MainActor
private final class FlippedDownloadDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class BrowserDownloadRowView: NSView, NSDraggingSource {
    private(set) var id: UUID
    private(set) var lifetime: UUID
    var onDragFile: ((UUID, UUID, UInt64) -> URL?)?
    var onAction: ((UUID, UUID, UInt64, DownloadRowPresentation.Action) -> Void)?
    private var revision: UInt64 = 0
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var restingTitleTrailing: NSLayoutConstraint!
    private var activeTitleTrailing: NSLayoutConstraint!
    var areActionsVisible: Bool { !actionStack.isHidden }
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let actionStack = NSStackView()
    let icon = NSImageView()
    var icons = BrowserDownloadIconCache()
    private var fileURL: URL?
    private var iconRequest: BrowserDownloadIconCache.Request?
    private var actionButtons: [(DownloadRowPresentation.Action, NSButton)] = []
    private var shownActions: [DownloadRowPresentation.Action] = []
    private var builtActions: [DownloadRowPresentation.Action] = []
    var displayedTitle: String { titleLabel.stringValue }

    init(id: UUID, lifetime: UUID) {
        self.id = id
        self.lifetime = lifetime
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        actionStack.orientation = .horizontal
        actionStack.spacing = 2
        icon.imageScaling = .scaleProportionallyUpOrDown
        for view in [icon, titleLabel, detailLabel, progress, actionStack] {
            view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
        }
        restingTitleTrailing = titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        activeTitleTrailing = titleLabel.trailingAnchor.constraint(equalTo: actionStack.leadingAnchor, constant: -4)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24), icon.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            restingTitleTrailing,
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            progress.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        actionStack.isHidden = true
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    func reuse(id: UUID, lifetime: UUID) {
        self.id = id
        self.lifetime = lifetime
        revision = 0
    }

    /// A recycled row forgets its item: no icon work, hover or progress animation survives.
    override func prepareForReuse() {
        super.prepareForReuse()
        iconRequest?.cancel()
        iconRequest = nil
        fileURL = nil
        icon.image = nil
        progress.stopAnimation(nil)
        if hovered { layer?.backgroundColor = NSColor.clear.cgColor }
        hovered = false
        updateActionsVisibility()
    }

    func render(_ row: DownloadRowPresentation) {
        revision = row.revision
        updateIcon(row)
        titleLabel.stringValue = row.title
        detailLabel.stringValue = row.detail
        progress.isHidden = !row.isRunning
        progress.isIndeterminate = row.totalBytes == nil || row.totalBytes == 0
        if let total = row.totalBytes, total > 0 {
            progress.doubleValue = min(1, Double(row.receivedBytes) / Double(total))
            progress.stopAnimation(nil)
        } else if row.isRunning { progress.startAnimation(nil) }
        shownActions = row.actions
        if !actionStack.isHidden { buildActionButtons() }
    }

    private static func symbol(_ action: DownloadRowPresentation.Action) -> (name: String, label: String) {
        switch action {
        case .cancel: return ("xmark", uiText("Cancel"))
        case .pause: return ("pause", uiText("Pause"))
        case .resume: return ("arrow.clockwise", uiText("Resume"))
        case .open: return ("arrow.up.right.square", uiText("Open File"))
        case .reveal: return ("magnifyingglass", uiText("Show in Finder"))
        case .remove: return ("trash", uiText("Remove from List"))
        }
    }

    /// Action buttons are hidden at rest, so a row builds them only when they first show.
    private func buildActionButtons() {
        guard builtActions != shownActions else { return }
        for view in actionStack.arrangedSubviews { view.removeFromSuperview() }
        actionButtons.removeAll()
        builtActions = shownActions
        for action in shownActions {
            let pair = Self.symbol(action)
            let button = NSButton(image: NSImage(systemSymbolName: pair.name, accessibilityDescription: pair.label)!,
                                  target: self, action: #selector(performRowAction(_:)))
            button.isBordered = false
            button.image = button.image?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            button.widthAnchor.constraint(equalToConstant: 16).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            button.toolTip = pair.label
            button.setAccessibilityLabel(pair.label)
            actionStack.addArrangedSubview(button)
            actionButtons.append((action, button))
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { setActionsVisible(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in self?.updateActionsVisibility() }
        }
        return accepted
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated), name: NSWindow.didUpdateNotification, object: window)
        }
        hovered = false
        updateActionsVisibility()
    }
    @objc private func windowUpdated() { updateActionsVisibility() }
    private func updateActionsVisibility() {
        let responder = window?.firstResponder as? NSView
        setActionsVisible(hovered || responder === self || responder?.isDescendant(of: actionStack) == true)
    }
    private func setActionsVisible(_ visible: Bool) {
        guard actionStack.isHidden == visible else { return }
        if visible {
            buildActionButtons()
            restingTitleTrailing.isActive = false
            activeTitleTrailing.isActive = true
        } else {
            activeTitleTrailing.isActive = false
            restingTitleTrailing.isActive = true
        }
        actionStack.isHidden = !visible
    }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 36, 76: if shownActions.contains(.open) { onAction?(id, lifetime, revision, .open) }
        case 51, 117: if shownActions.contains(.remove) { onAction?(id, lifetime, revision, .remove) }
        default: super.keyDown(with: event)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        for action in shownActions {
            let item = NSMenuItem(title: Self.symbol(action).label, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (revision, action)
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }
    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let (revision, action) = sender.representedObject as? (UInt64, DownloadRowPresentation.Action) else { return }
        onAction?(id, lifetime, revision, action)
    }

    /// The type icon shows until the file's own icon, then its thumbnail, arrive from the cache's
    /// background work. Completions for an earlier file or item are dropped.
    private func updateIcon(_ row: DownloadRowPresentation) {
        guard icon.image == nil || fileURL != row.fileURL else { return }
        iconRequest?.cancel()
        iconRequest = nil
        if let previous = fileURL, row.fileURL == nil { icons.forget(previous) }
        fileURL = row.fileURL
        let placeholder = icons.typeIcon(forExtension: (row.title as NSString).pathExtension)
        guard let url = fileURL else { icon.image = placeholder; return }
        let cached = icons.cached(url)
        icon.image = cached?.image ?? placeholder
        guard cached?.isComplete != true || cached?.image == nil else { return }
        iconRequest = icons.load(url, fileIcon: cached?.image == nil, thumbnail: cached?.isComplete != true) { [weak self] image in
            guard let self, fileURL == url else { return }
            icon.image = image
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        titleLabel.textColor = BrowserLibraryStyle.foreground
        detailLabel.textColor = BrowserLibraryStyle.foreground.withAlphaComponent(0.55)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        updateActionsVisibility()
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        layer?.backgroundColor = NSColor.clear.cgColor
        updateActionsVisibility()
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)), shownActions.contains(.open) else { return }
        onAction?(id, lifetime, revision, .open)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let url = onDragFile?(id, lifetime, revision) else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(origin: point, size: NSSize(width: 32, height: 32)), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    @objc private func performRowAction(_ sender: NSButton) {
        guard let action = actionButtons.first(where: { $0.1 === sender })?.0 else { return }
        onAction?(id, lifetime, revision, action)
    }
}

/// File icons and thumbnails for the rows on screen, bounded and least recently used first out.
/// A list that clears forgets them, as its rows used to.
@MainActor
final class BrowserDownloadIconCache {
    /// One row's pending icon work. Cancelling drops later deliveries and the QuickLook job.
    @MainActor
    final class Request {
        fileprivate let deliver: (NSImage) -> Void
        fileprivate var thumbnail: QLThumbnailGenerator.Request?
        private(set) var isCancelled = false
        fileprivate init(_ deliver: @escaping (NSImage) -> Void) { self.deliver = deliver }
        func cancel() {
            isCancelled = true
            if let thumbnail { QLThumbnailGenerator.shared.cancel(thumbnail) }
            thumbnail = nil
        }
    }
    private struct Entry {
        var image: NSImage?
        /// The thumbnail request finished, with or without an image.
        var isComplete = false
        var lastUse: UInt64 = 0
    }
    private struct Icon: @unchecked Sendable { let image: NSImage }
    let capacity: Int
    private var files: [URL: Entry] = [:]
    private var types: [String: NSImage] = [:]
    private var clock: UInt64 = 0
    private var generation: UInt64 = 0
    var count: Int { files.count }

    init(capacity: Int = 256) { self.capacity = capacity }

    func typeIcon(forExtension pathExtension: String) -> NSImage {
        if let image = types[pathExtension] { return image }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: pathExtension) ?? .data)
        if types.count >= 64 { types.removeAll() }
        types[pathExtension] = image
        return image
    }

    func cached(_ url: URL) -> (image: NSImage?, isComplete: Bool)? {
        guard files[url] != nil else { return nil }
        clock += 1
        files[url]?.lastUse = clock
        return files[url].map { ($0.image, $0.isComplete) }
    }

    func forget(_ url: URL) { files[url] = nil }

    func removeAll() {
        files.removeAll()
        generation &+= 1
    }

    /// Resolves the file icon off the main thread, then a 24-point thumbnail, as asked.
    func load(_ url: URL, fileIcon: Bool, thumbnail wantsThumbnail: Bool, deliver: @escaping (NSImage) -> Void) -> Request {
        let request = Request(deliver)
        let generation = generation
        if fileIcon {
            Task.detached(priority: .userInitiated) { [weak self] in
                let icon = Icon(image: NSWorkspace.shared.icon(forFile: url.path))
                await self?.received(icon, for: url, generation: generation, request: request)
            }
        }
        guard wantsThumbnail else { return request }
        let thumbnail = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: 24, height: 24), scale: 2, representationTypes: .thumbnail)
        request.thumbnail = thumbnail
        QLThumbnailGenerator.shared.generateBestRepresentation(for: thumbnail) { [weak self] representation, _ in
            let image = representation?.cgImage
            Task { @MainActor [weak self, image] in
                guard let self, self.generation == generation, !request.isCancelled else { return }
                let thumbnail = image.map { NSImage(cgImage: $0, size: .zero) }
                store(url) { entry in
                    if let thumbnail { entry.image = thumbnail }
                    entry.isComplete = true
                }
                if let thumbnail { request.deliver(thumbnail) }
            }
        }
        return request
    }

    private func received(_ icon: Icon, for url: URL, generation: UInt64, request: Request) {
        guard self.generation == generation, files[url]?.image == nil else { return }
        store(url) { $0.image = icon.image }
        if !request.isCancelled { request.deliver(icon.image) }
    }

    private func store(_ url: URL, _ change: (inout Entry) -> Void) {
        clock += 1
        var entry = files[url] ?? Entry()
        change(&entry)
        entry.lastUse = clock
        files[url] = entry
        if files.count > capacity, let oldest = files.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            files[oldest] = nil
        }
    }
}
